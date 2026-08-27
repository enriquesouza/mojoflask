"""mojoflask.http — HTTP request parsing and response assembly.

Role
    Everything that reads or writes the wire format: locating the end of the
    request head, extracting method/path/headers case-insensitively, and
    stamping out complete response buffers once at startup so the serving hot
    path never allocates (the prebuilt-static-buffer model).

Darwin quirks encoded here
    - None of its own; this layer is pure byte crunching. The errno values it
      relies on indirectly (EAGAIN=35/EINTR=4) are defined in mojoflask.ffi.
    - Header scanning is deliberately allocation-free: keys are pre-lowered
      copies built at startup (see standard_header_keys) because per-request
      malloc would dominate the profile on small responses.
"""

from mojoflask.ffi import (
    BytePtr,
    UntrackedBytePtr,
    fatal,
    free_bytes,
    malloc_bytes,
    null_bytes,
    untrack,
)

from mojoflask.router import (
    METHOD_DELETE,
    METHOD_GET,
    METHOD_PATCH,
    METHOD_POST,
    METHOD_PUT,
    METHOD_QUERY,
)


comptime CR = UInt8(13)
comptime LF = UInt8(10)
comptime SLASH = UInt8(47)
comptime SPACE = UInt8(32)
comptime TAB = UInt8(9)
comptime QMARK = UInt8(63)

comptime LETTER_G = UInt8(71)
comptime LETTER_P = UInt8(80)
comptime LETTER_D = UInt8(68)
comptime LETTER_Q = UInt8(81)


comptime HEADER_TAIL = "\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'; base-uri 'none'\r\nReferrer-Policy: strict-origin-when-cross-origin\r\nPermissions-Policy: geolocation=(), microphone=(), camera=()\r\nVary: origin\r\nAccess-Control-Allow-Credentials: true\r\nAccess-Control-Expose-Headers: retry-after\r\nConnection: keep-alive\r\n\r\n"
comptime HEADER_CONTENT_LENGTH_KEY = "content-length:"
comptime HEADER_CONNECTION_KEY = "connection:"
comptime TOKEN_CLOSE = "close"


comptime MAX_ROUTES = 128
comptime MAX_RESPONSES = MAX_ROUTES * 2
comptime RESPONSE_BUFFER_BYTES = 16
comptime UntrackedResponseBufferPtr = Pointer[
    T=ResponseBuffer, mut=True, origin=UntrackedOrigin[mut=True]
]


@fieldwise_init
struct ResponseBuffer(RegisterPassable, ImplicitlyCopyable):
    """One fully serialized HTTP response (status line through last body byte),
    built once at startup and served by pointer forever after."""

    var data: UntrackedBytePtr
    var length: Int


@fieldwise_init
struct ResponseSet(RegisterPassable, ImplicitlyCopyable):
    """Route-indexed table of prebuilt responses plus a fallback for misses.

    Capacity is MAX_RESPONSES = MAX_ROUTES * 2 (256 with the default 128
    routes; MAX_ROUTES is duplicated in mojoflask.router and the two must
    stay in sync). In the lockstep App flow every route — static or
    dynamic — consumes exactly one ResponseSet slot, so responses never
    outnumber routes there; the 2x headroom covers raw-table users whose
    dynamic-resolver returns static_route indexes of extra prebuilt
    responses registered beyond the lockstep prefix. add() refuses to
    write past the table and aborts at startup instead of corrupting the
    heap.
    """

    var count: Int
    var buffers: UntrackedResponseBufferPtr
    var fallback: ResponseBuffer

    def add(mut self, response: ResponseBuffer) -> Int:
        """Register a response; returns its route index.

        Startup-only. Aborts the process when the table is already at
        MAX_RESPONSES entries — an unchecked append here used to write
        past the allocation and silently corrupt adjacent heap (route 0/1
        buffers), because ResponseBuffer is 16 bytes but the table was
        sized as if it were 8.
        """
        if self.count >= MAX_RESPONSES:
            fatal(
                "response set full: "
                + String(MAX_RESPONSES)
                + " entries (MAX_RESPONSES = MAX_ROUTES * 2)"
            )
        self.buffers[self.count] = response
        self.count += 1
        return self.count - 1

    def set_fallback(mut self, response: ResponseBuffer):
        """Install the response served when no route matches."""
        self.fallback = response

    def at(self, route_index: Int) -> ResponseBuffer:
        """Response for a route index; anything unresolved gets the fallback."""
        if route_index < 0 or route_index >= self.count:
            return self.fallback
        return self.buffers[route_index]


def response_set() -> ResponseSet:
    """Create an empty response table (startup-only, heap-backed).

    Allocates RESPONSE_BUFFER_BYTES * MAX_RESPONSES bytes so the byte size
    and the slot count agree: ResponseBuffer is one pointer plus one Int
    (16 bytes on every supported 64-bit target). The original bug sized
    this as 8 bytes per entry, so the 512-byte block only held 32 slots
    while unchecked adds kept writing.
    """
    return ResponseSet(
        count=0,
        buffers=UntrackedResponseBufferPtr(
            unsafe_from_address=Int(
                malloc_bytes(RESPONSE_BUFFER_BYTES * MAX_RESPONSES)
            )
        ),
        fallback=ResponseBuffer(data=null_bytes(), length=0),
    )


@fieldwise_init
struct RequestHeaderKeys(RegisterPassable, ImplicitlyCopyable):
    """Pre-lowered header lookup needles shared by every connection scan."""

    var content_length_key: UntrackedBytePtr
    var content_length_len: Int
    var connection_key: UntrackedBytePtr
    var connection_len: Int
    var close_token: UntrackedBytePtr
    var close_token_len: Int


def standard_header_keys() -> RequestHeaderKeys:
    """Build lowered copies of the three needles used while parsing heads."""
    var cl = lower_bytes_copy(HEADER_CONTENT_LENGTH_KEY)
    var co = lower_bytes_copy(HEADER_CONNECTION_KEY)
    var tk = lower_bytes_copy(TOKEN_CLOSE)
    return RequestHeaderKeys(
        content_length_key=untrack(cl),
        content_length_len=HEADER_CONTENT_LENGTH_KEY.byte_length(),
        connection_key=untrack(co),
        connection_len=HEADER_CONNECTION_KEY.byte_length(),
        close_token=untrack(tk),
        close_token_len=TOKEN_CLOSE.byte_length(),
    )


def ascii_lower_byte(b: UInt8) -> UInt8:
    """Lowercase a single ASCII letter; other bytes pass through."""
    if b >= UInt8(65) and b <= UInt8(90):
        return b + UInt8(32)
    return b


def lower_bytes_copy(s: String) -> BytePtr:
    """Heap-copy a String with ASCII letters lowercased (header needles)."""
    var n = s.byte_length()
    var p = malloc_bytes(n)
    var i = 0
    for b in s.bytes():
        p[i] = ascii_lower_byte(b)
        i += 1
    return p


def decimal_digit_count(v_in: Int) -> Int:
    """How many decimal digits v needs when printed."""
    var n = 1
    var x = v_in // 10
    while x > 0:
        n += 1
        x //= 10
    return n


def append_string(dst: BytePtr, at: Int, s: String) -> Int:
    """Copy s into dst at offset at; returns the next free offset."""
    var i = at
    for b in s.bytes():
        dst[i] = b
        i += 1
    return i


def write_decimal(dst: BytePtr, at: Int, v_in: Int) -> Int:
    """Write v as decimal digits at offset at; returns the next free offset."""
    var tmp = malloc_bytes(24)
    var n = 0
    var v = v_in
    if v == 0:
        tmp[0] = UInt8(48)
        n = 1
    else:
        while v > 0:
            tmp[n] = UInt8(48 + (v % 10))
            n += 1
            v //= 10
    var i = at
    var k = n
    while k > 0:
        k -= 1
        dst[i] = tmp[k]
        i += 1
    free_bytes(tmp)
    return i


def build_response(
    status_line: String, body: BytePtr, body_len: Int, server_name: String = "mojoflask"
) -> ResponseBuffer:
    """Serialize one full HTTP response around a preloaded body.

    Layout: status line, Server, Content-Type, Content-Length, fixed
    security-header tail, body. Called only during startup; the returned
    buffer is immutable in practice. `server_name` fills the Server header.
    """
    var head_pre = "HTTP/1.1 " + status_line + "\r\nServer: " + server_name + "\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: "
    var total = head_pre.byte_length() + decimal_digit_count(body_len) + HEADER_TAIL.byte_length() + body_len
    var p = malloc_bytes(total)
    var at = append_string(p, 0, head_pre)
    at = write_decimal(p, at, body_len)
    at = append_string(p, at, HEADER_TAIL)
    var i = 0
    while i < body_len:
        p[at + i] = body[i]
        i += 1
    return ResponseBuffer(data=untrack(p), length=total)


def find_header_end(p: BytePtr, start: Int, end: Int) -> Int:
    """Offset of the CRLFCRLF that terminates the request head, else -1.

    Scans for the 4-byte sequence \\r\\n\\r\\n between start and end.
    """
    var j = start
    while j + 3 < end:
        if p[j] == CR and p[j + 1] == LF and p[j + 2] == CR and p[j + 3] == LF:
            return j
        j += 1
    return -1


def ci_find(p: BytePtr, s: Int, e: Int, key: UntrackedBytePtr, kn: Int) -> Int:
    """Case-insensitive substring search of key within p[s:e]; -1 when absent.

    The needle must already be lowercase; the haystack is lowered on the fly.
    """
    if e - s < kn:
        return -1
    var i = s
    var lim = e - kn
    while i <= lim:
        var k = 0
        var ok = True
        while k < kn:
            if ascii_lower_byte(p[i + k]) != key[k]:
                ok = False
                break
            k += 1
        if ok:
            return i
        i += 1
    return -1


def parse_content_length(p: BytePtr, hs: Int, he: Int, keys: RequestHeaderKeys) -> Int:
    """Numeric Content-Length from the head [hs,he); 0 when absent/garbled."""
    var k = ci_find(p, hs, he, keys.content_length_key, keys.content_length_len)
    if k < 0:
        return 0
    var i = k + keys.content_length_len
    while i < he and (p[i] == SPACE or p[i] == TAB):
        i += 1
    var v = 0
    while i < he:
        var b = p[i]
        if b < UInt8(48) or b > UInt8(57):
            break
        v = v * 10 + (Int(b) - 48)
        i += 1
    return v


def wants_close(p: BytePtr, hs: Int, he: Int, keys: RequestHeaderKeys) -> Bool:
    """True when Connection: close appears anywhere in the head."""
    var k = ci_find(p, hs, he, keys.connection_key, keys.connection_len)
    if k < 0:
        return False
    var vs = k + keys.connection_len
    var ve = vs
    while ve < he and p[ve] != CR and p[ve] != LF:
        ve += 1
    return ci_find(p, vs, ve, keys.close_token, keys.close_token_len) >= 0


@fieldwise_init
struct ParsedHead(RegisterPassable):
    """Result of splitting one request head into its routing-relevant parts.

    method_start/method_end bracket the verb; method_code is the router's
    METHOD_* bit for that verb (0 when unrecognized), computed from the same
    bytes during the request-line scan — no extra pass. path_start/path_end
    bracket the path with any ?query stripped. content_length drives body
    draining and connection_close records an explicit Connection: close.
    """

    var method_start: Int
    var method_end: Int
    var path_start: Int
    var path_end: Int
    var content_length: Int
    var connection_close: Bool
    var method_code: UInt8


def method_code_from_span(p: BytePtr, s: Int, e: Int) -> UInt8:
    """Router METHOD_* bit for the verb bytes p[s:e); 0 when unrecognized.

    Compares at most six bytes already touched by the request-line scan.
    Method names are case-sensitive per RFC 7231, so lowercase verbs yield 0
    and fall to the fallback route resolution like any unknown method.
    """
    var n = e - s
    if n < 3 or n > 6:
        return UInt8(0)
    if p[s] == LETTER_G:
        if n == 3 and p[s + 1] == UInt8(69) and p[s + 2] == UInt8(84):
            return METHOD_GET
        return UInt8(0)
    if p[s] == LETTER_P:
        if n == 3 and p[s + 1] == UInt8(85) and p[s + 2] == UInt8(84):
            return METHOD_PUT
        if n == 4 and p[s + 1] == UInt8(79) and p[s + 2] == UInt8(83) and p[s + 3] == UInt8(84):
            return METHOD_POST
        if n == 5 and p[s + 1] == UInt8(65) and p[s + 2] == UInt8(84) and p[s + 3] == UInt8(67) and p[s + 4] == UInt8(72):
            return METHOD_PATCH
        return UInt8(0)
    if p[s] == LETTER_D:
        if (
            n == 6
            and p[s + 1] == UInt8(69)
            and p[s + 2] == UInt8(76)
            and p[s + 3] == UInt8(69)
            and p[s + 4] == UInt8(84)
            and p[s + 5] == UInt8(69)
        ):
            return METHOD_DELETE
        return UInt8(0)
    if p[s] == LETTER_Q:
        if (
            n == 5
            and p[s + 1] == UInt8(85)
            and p[s + 2] == UInt8(69)
            and p[s + 3] == UInt8(82)
            and p[s + 4] == UInt8(89)
        ):
            return METHOD_QUERY
        return UInt8(0)
    return UInt8(0)


def parse_request_head(p: BytePtr, start: Int, head_end: Int, keys: RequestHeaderKeys) -> ParsedHead:
    """Split the first request line of the head [start, head_end).

    Line ends at the first CR or LF; method is text before the first space;
    path runs to the next space, truncated at '?'. Malformed lines yield an
    empty path so routing falls through to 404 rather than crashing. Header
    scans reuse the caller's pre-lowered `keys` needles.
    """
    var line_end = start
    while line_end < head_end and p[line_end] != CR and p[line_end] != LF:
        line_end += 1
    var m1 = start
    while m1 < line_end and p[m1] != SPACE:
        m1 += 1
    if m1 >= line_end:
        return ParsedHead(
            method_start=start,
            method_end=start,
            path_start=start,
            path_end=start,
            content_length=0,
            connection_close=False,
            method_code=UInt8(0),
        )
    var ps = m1 + 1
    var pe = ps
    while pe < line_end and p[pe] != SPACE:
        pe += 1
    var q = ps
    while q < pe:
        if p[q] == QMARK:
            pe = q
            break
        q += 1
    return ParsedHead(
        method_start=start,
        method_end=m1,
        path_start=ps,
        path_end=pe,
        content_length=parse_content_length(p, start, head_end, keys),
        connection_close=wants_close(p, start, head_end, keys),
        method_code=method_code_from_span(p, start, m1),
    )
