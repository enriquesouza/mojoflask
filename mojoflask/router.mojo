"""mojoflask.router — pattern-based route matching for request paths.

Role
    Turns path-pattern strings declared at startup (e.g.
    "/{lang}/api/listings/{id:d}") into segment matchers, and resolves
    incoming request paths to a route index at serve time. All matcher state
    is built once by `RouteTable.add`; resolution allocates nothing.

Pattern syntax
    - Segments are separated by '/' and compared case-sensitively.
    - "literal"   matches exactly that text ("nearby", "api").
    - "{name}"    wildcard — matches any non-empty segment ("{lang}").
    - "{name:d}"  digit-wildcard — matches a non-empty run of ASCII digits,
                  used for numeric ids so "/listings/abc" stays a 404.

Segment-splitting algorithm (resolve)
    The request path must start with '/'. For each registered route we walk
    the path and the route's matchers in lockstep:
      1. Take the next path segment [pos, seg_end), where seg_end is the
         next '/' or the end of the path.
      2. Compare it against matcher #seg of this route (literal equality,
         non-empty wildcard, or all-digits).
      3. On mismatch the route is rejected immediately.
      4. If the matchers are exhausted, the whole path must be consumed too;
         if the path is exhausted early, the route needs more segments than
         were supplied. Reject either way.
    The first route that consumes both sides wins and its registration index
    is returned. A path without a leading '/', or no match at all, yields -1
    so the caller serves its fallback response.

Darwin quirks encoded here
    None — pure in-memory string machinery, identical on every platform.
"""

from std.origin import UntrackedOrigin

from mojoflask.ffi import (
    BytePtr,
    UntrackedBytePtr,
    fatal,
    free_bytes,
    make_cstr,
    malloc_bytes,
    null_bytes,
    untrack,
)


comptime MAX_ROUTE_SEGS = 8
comptime MAX_ROUTES = 64

comptime SEG_LITERAL = UInt8(0)
comptime SEG_WILDCARD = UInt8(1)
comptime SEG_DIGITS = UInt8(2)

comptime ROUTE_STATIC = UInt8(0)
comptime ROUTE_DYNAMIC = UInt8(1)

comptime SLASH = UInt8(47)
comptime DIGIT_LO = UInt8(48)
comptime DIGIT_HI = UInt8(57)

comptime BRACE_OPEN = UInt8(123)
comptime BRACE_CLOSE = UInt8(125)
comptime COLON = UInt8(58)
comptime LETTER_D = UInt8(100)


comptime METHOD_GET = UInt8(1)
comptime METHOD_POST = UInt8(2)
comptime METHOD_PUT = UInt8(4)
comptime METHOD_PATCH = UInt8(8)
comptime METHOD_DELETE = UInt8(16)
comptime METHOD_QUERY = UInt8(32)
comptime METHOD_ANY = UInt8(63)


@fieldwise_init
struct RouteMatcher(RegisterPassable, ImplicitlyCopyable):
    """One path-segment test: a kind plus optional literal bytes."""

    var kind: UInt8
    var literal: UntrackedBytePtr
    var literal_len: Int


@fieldwise_init
struct RouteTable(RegisterPassable, ImplicitlyCopyable):
    """Ordered list of compiled routes; earlier registrations win on overlap.

    Each route carries a method bitmask (METHOD_GET, METHOD_POST, ... or the
    all-bits METHOD_ANY); resolution only accepts routes whose mask admits the
    request's method code. Routes registered through `add` keep mask ANY, so
    method-less tables behave exactly as before masks existed.

    Every route also carries a kind: ROUTE_STATIC (registered through add /
    add_method; backed by a prebuilt ResponseBuffer) or ROUTE_DYNAMIC
    (registered through add_dynamic; dispatched to the process resolver at
    request time). The server consults kind_at() after resolve_method().
    """

    var count: Int
    var seg_counts: Pointer[T=Int32, mut=True, origin=UntrackedOrigin[mut=True]]
    var matchers: Pointer[
        T=RouteMatcher, mut=True, origin=UntrackedOrigin[mut=True]
    ]
    var method_masks: Pointer[T=UInt8, mut=True, origin=UntrackedOrigin[mut=True]]
    var kinds: Pointer[T=UInt8, mut=True, origin=UntrackedOrigin[mut=True]]

    def add(mut self, pattern: String) -> Int:
        """Compile one pattern into matchers; returns its registration index.

        Startup-only. Segments between slashes are classified by
        compile_matcher; literals keep their exact bytes because matching is
        case-sensitive by design. The route accepts every HTTP method (mask
        ANY); use add_method to restrict it.
        """
        return self.add_method(METHOD_ANY, pattern)

    def add_method(mut self, method_mask: UInt8, pattern: String) -> Int:
        """Compile one static route bound to `method_mask`; returns its index.

        The mask is one or more METHOD_* bits OR-ed together; matching later
        requires the request's method code to share at least one bit. A mask
        of METHOD_ANY restores unconditional acceptance. Static routes are
        answered from a prebuilt ResponseBuffer; register those in the paired
        ResponseSet at the returned index.
        """
        return self._compile(method_mask, pattern, ROUTE_STATIC)

    def add_dynamic(mut self, method_mask: UInt8, pattern: String) -> Int:
        """Compile one dynamic route bound to `method_mask`; returns its index.

        Dynamic routes match exactly like static ones but consume NO
        ResponseSet slot: at request time the server hands the raw request
        head/body spans to the single process resolver (see mojoflask.server,
        ResolverFn), which must be installed before serve(). If no resolver is
        installed when a dynamic route matches, the fallback response is
        served instead.
        """
        return self._compile(method_mask, pattern, ROUTE_DYNAMIC)

    def _compile(
        mut self, method_mask: UInt8, pattern: String, kind: UInt8
    ) -> Int:
        """Shared pattern compiler for add_method/add_dynamic."""
        var route = self.count
        if route >= MAX_ROUTES:
            fatal("route limit exceeded")
        var pat = make_cstr(pattern)
        var total = pattern.byte_length()
        var seg = 0
        var i = 0
        while i < total:
            while i < total and pat[i] == SLASH:
                i += 1
            if i >= total:
                break
            var start = i
            while i < total and pat[i] != SLASH:
                i += 1
            if seg >= MAX_ROUTE_SEGS:
                fatal("too many segments in route: " + pattern)
            self.matchers[route * MAX_ROUTE_SEGS + seg] = compile_matcher(pat, start, i)
            seg += 1
        free_bytes(pat)
        if seg == 0 and total != 1:
            fatal("empty route pattern")
        self.seg_counts[route] = Int32(seg)
        self.method_masks[route] = method_mask
        self.kinds[route] = kind
        self.count += 1
        return route

    def kind_at(self, route_index: Int) -> UInt8:
        """ROUTE_STATIC or ROUTE_DYNAMIC for a registered route index."""
        if route_index < 0 or route_index >= self.count:
            return ROUTE_STATIC
        return self.kinds[route_index]

    def resolve(self, p: BytePtr, ps: Int, pe: Int) -> Int:
        """Index of the first route matching path p[ps:pe), else -1.

        Method-agnostic form kept for existing callers; equivalent to
        resolve_method with METHOD_ANY.
        """
        return self.resolve_method(p, ps, pe, METHOD_ANY)

    def resolve_method(self, p: BytePtr, ps: Int, pe: Int, method_code: UInt8) -> Int:
        """Index of the first route matching path AND method, else -1.

        A route matches when its segment pattern accepts the path and its
        mask admits the method code — ANY-masked routes always do; masked
        routes need at least one shared bit. Unmatched methods fall through
        to -1 so the caller serves its fallback response.
        """
        if ps >= pe or p[ps] != SLASH:
            return -1
        var r = 0
        while r < self.count:
            if self.route_matches(r, p, ps, pe):
                var m = self.method_masks[r]
                if m == METHOD_ANY or (m & method_code) != UInt8(0):
                    return r
            r += 1
        return -1

    def route_matches(self, r: Int, p: BytePtr, ps: Int, pe: Int) -> Bool:
        """Lockstep walk of path segments vs route r's matchers (module doc).

        Walks one request-path segment per iteration and tests it against the
        corresponding matcher; bails out on the first disagreement or on an
        endpoint/count mismatch between pattern and path.
        """
        var nseg = Int(self.seg_counts[r])
        if nseg == 0:
            return pe - ps == 1
        var pos = ps + 1
        var seg = 0
        while True:
            var seg_end = pos
            while seg_end < pe and p[seg_end] != SLASH:
                seg_end += 1
            var m = self.matchers[r * MAX_ROUTE_SEGS + seg]
            if not matcher_accepts(m, p, pos, seg_end):
                return False
            seg += 1
            if seg == nseg:
                return seg_end == pe
            if seg_end == pe:
                return False
            pos = seg_end + 1


def route_table() -> RouteTable:
    """Create an empty table (startup-only; heap-backed matcher storage)."""
    return RouteTable(
        count=0,
        seg_counts=Pointer[T=Int32, mut=True, origin=UntrackedOrigin[mut=True]](
            unsafe_from_address=Int(malloc_bytes(4 * MAX_ROUTES))
        ),
        matchers=Pointer[T=RouteMatcher, mut=True, origin=UntrackedOrigin[mut=True]](
            unsafe_from_address=Int(malloc_bytes(24 * MAX_ROUTES * MAX_ROUTE_SEGS))
        ),
        method_masks=Pointer[T=UInt8, mut=True, origin=UntrackedOrigin[mut=True]](
            unsafe_from_address=Int(malloc_bytes(MAX_ROUTES))
        ),
        kinds=Pointer[T=UInt8, mut=True, origin=UntrackedOrigin[mut=True]](
            unsafe_from_address=Int(malloc_bytes(MAX_ROUTES))
        ),
    )


def compile_matcher(pat: BytePtr, s: Int, e: Int) -> RouteMatcher:
    """Classify one pattern segment into literal / wildcard / digit-wildcard.

    "{...}" segments become wildcards; a ':d' suffix inside the braces selects
    the digit-only variant. Everything else becomes an exact-match literal
    copied verbatim into matcher-owned storage.
    """
    var n = e - s
    if n >= 2 and pat[s] == BRACE_OPEN and pat[e - 1] == BRACE_CLOSE:
        if n >= 4 and pat[e - 3] == COLON and pat[e - 2] == LETTER_D:
            return RouteMatcher(
                kind=SEG_DIGITS, literal=null_bytes(), literal_len=0
            )
        return RouteMatcher(
            kind=SEG_WILDCARD, literal=null_bytes(), literal_len=0
        )
    var lit = malloc_bytes(n)
    var j = 0
    while j < n:
        lit[j] = pat[s + j]
        j += 1
    return RouteMatcher(kind=SEG_LITERAL, literal=untrack(lit), literal_len=n)


def matcher_accepts(m: RouteMatcher, p: BytePtr, s: Int, e: Int) -> Bool:
    """Does the path segment p[s:e) satisfy this matcher?"""
    var length = e - s
    if m.kind == SEG_WILDCARD:
        return length > 0
    if m.kind == SEG_DIGITS:
        if length == 0:
            return False
        var k = s
        while k < e:
            if p[k] < DIGIT_LO or p[k] > DIGIT_HI:
                return False
            k += 1
        return True
    if length != m.literal_len:
        return False
    var k = 0
    while k < length:
        if p[s + k] != m.literal[k]:
            return False
        k += 1
    return True
