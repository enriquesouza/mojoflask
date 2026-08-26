"""mojoflask.cache — startup-built search cache mirroring Go's ResponseCache
hit path.

Role
    Consumers that mirror a Go service's query-cache layer use this module to
    hash a request's canonical key (FNV-1a 64-bit), look it up in a flat slot
    table, and serve the same prebuilt `ResponseBuffer` the Go path would have
    served. Like the rest of mojoflask, the serving hot path performs zero
    per-request allocation: the only heap copy ever taken is the key bytes at
    insert time (`set`). The table is single-threaded by design, matching the
    per-process cache in the Go reference (one table per forked worker).

Grid rounding contract
    `round3_half_away` implements Go `math.Round(v*1000)/1000`: halfway cases
    go AWAY from zero. Because the multiply happens in IEEE-754 float64, the
    result follows float reality, not decimal intuition. The documented edge:

        grid3(-23.5505) == "-23.551"

    since Float64(-23.5505) * 1000 is exactly -23550.5, half away from zero
    rounds to -23551, and the snapped value formats as "-23.551". Meanwhile
    grid3(-23.5504) == "-23.550" and grid3(46.6326) == "46.633". Always trust
    the snapped-value print, never decimal reasoning about the raw input.
"""

from std.ffi import c_int, external_call
from std.math import ceil, floor

from mojoflask.ffi import (
    BytePtr,
    malloc_bytes,
    null_bytes,
    retracked,
    untrack,
)

from mojoflask.http import ResponseBuffer
from std.origin import UntrackedOrigin


comptime UntrackedBytePtr = Pointer[T=Byte, mut=True, origin=UntrackedOrigin[mut=True]]
comptime UntrackedIntPtr = Pointer[T=Int, mut=True, origin=UntrackedOrigin[mut=True]]
comptime FNV_OFFSET = UInt64(14695981039346656037)
comptime FNV_PRIME = UInt64(1099511628211)
comptime DEFAULT_CAPACITY = 4096
comptime KEY_CAP = 512
comptime CLOCK_MONOTONIC = 6
comptime MAX_SLOTS = 1 << 20


@fieldwise_init
struct TimeSpec(RegisterPassable):
    """POSIX timespec; both fields are long (64-bit) on arm64."""

    var sec: Int
    var nsec: Int


def fnv_init() -> UInt64:
    """Starting hash state for FNV-1a 64-bit."""
    return FNV_OFFSET


def fnv_byte(h: UInt64, buf: BytePtr, length: Int) -> UInt64:
    """Fold `length` bytes of `buf` into hash `h`, progressive FNV-1a."""
    var acc = h
    var i = 0
    while i < length:
        acc = (acc ^ UInt64(buf[i])) * FNV_PRIME
        i += 1
    return acc


def round3_half_away(v: Float64) -> Float64:
    """Go math.Round(v*1000)/1000 — halfway cases away from zero.

    Note the multiply runs in float64 first, so inputs whose scaled value sits
    just under .5 in decimal can land exactly on it in binary (see module
    docstring: -23.5505 scales to exactly -23550.5 and rounds AWAY to -23.551).
    """
    var x = v * 1000.0
    if x >= 0.0:
        return floor(x + 0.5) / 1000.0
    return ceil(x - 0.5) / 1000.0


def key_hash(kb: KeyBuilder) -> UInt64:
    """FNV-1a over everything appended to the builder so far."""
    return fnv_byte(fnv_init(), retracked(kb.buf), kb.len)


struct KeyBuilder:
    """Fixed 512-byte owned key buffer built up piecewise before hashing.

    All appends are allocation-free: bytes land directly in the owned buffer.
    Keys longer than KEY_CAP are truncated silently by the append guards.
    """

    var buf: UntrackedBytePtr
    var len: Int

    def __init__(out self):
        self.buf = untrack(malloc_bytes(KEY_CAP))
        self.len = 0

    def reset(mut self):
        """Empty the builder for reuse; the buffer stays allocated."""
        self.len = 0

    def append_bytes(mut self, p: BytePtr, n: Int):
        """Append n raw bytes, truncating anything past the buffer capacity."""
        var i = 0
        while i < n and self.len < KEY_CAP:
            self.buf[self.len] = p[i]
            self.len += 1
            i += 1

    def append_str(mut self, s: String):
        """Append a String's UTF-8 bytes, truncating past capacity."""
        for b in s.bytes():
            if self.len >= KEY_CAP:
                return
            self.buf[self.len] = b
            self.len += 1

    def append_int(mut self, value: Int):
        """Append the decimal form of an Int, allocation-free.

        Digits are produced least-significant-first into the buffer's unused
        tail and then shifted down to the write position.
        """
        if self.len >= KEY_CAP - 1:
            return
        var v = value
        var neg = v < 0
        if neg:
            v = -v
        var pos = KEY_CAP
        if v == 0:
            pos -= 1
            self.buf[pos] = UInt8(48)
        while v > 0:
            pos -= 1
            self.buf[pos] = UInt8(48 + v % 10)
            v //= 10
        if neg:
            pos -= 1
            self.buf[pos] = UInt8(45)
        var n = KEY_CAP - pos
        var i = 0
        while i < n and self.len < KEY_CAP:
            self.buf[self.len] = self.buf[pos]
            self.len += 1
            pos += 1
            i += 1

    def append_grid3(mut self, v: Float64):
        """Append the SNAPPED coordinate formatted as always-3-decimals text.

        Snaps via round3_half_away (Go math.Round semantics — see its
        docstring for the -23.5505 edge), then emits the exact bytes
        Go's fmt.Sprintf("%.3f", snapped) would: sign, integer digits,
        '.', three zero-padded fraction digits ("-23.550", "46.633",
        "-23.551"). The formatting is arithmetic rather than libc snprintf
        because Mojo's C-FFI variadic boundary zeroes float arguments on
        arm64; since the snapped value is always an exact integer scaled by
        1000, the digits are recovered losslessly.
        """
        if self.len >= KEY_CAP - 32:
            return
        var xs = v * 1000.0
        var xi = 0.0
        if xs >= 0.0:
            xi = floor(xs + 0.5)
        else:
            xi = ceil(xs - 0.5)
        var mag = 0
        var neg = xi < 0.0
        if neg:
            mag = Int(-xi)
        else:
            mag = Int(xi)
        if neg:
            self.buf[self.len] = UInt8(45)
            self.len += 1
        var whole = mag // 1000
        var frac = mag % 1000
        self.append_int(whole)
        self.buf[self.len] = UInt8(46)
        self.len += 1
        self.buf[self.len] = UInt8(48 + frac // 100)
        self.buf[self.len + 1] = UInt8(48 + (frac // 10) % 10)
        self.buf[self.len + 2] = UInt8(48 + frac % 10)
        self.len += 3


struct SlotTable:
    """Open-addressed-by-hash-slot cache of prebuilt responses.

    Parallel arrays sized once at construction: inline key copies (512 bytes
    per slot), key lengths, expiry stamps (monotonic ns; 0 = never), and the
    response buffers themselves. Lookups take the low bits of the FNV hash as
    the slot, confirm with a full-key compare, and check TTL. Expired entries
    are treated as misses but left in place — the next `set` overwrites them.
    Last writer wins on hash collisions between different keys. Single-
    threaded like the Go per-process cache: give each forked worker its own.
    """

    var slots: Int
    var mask: UInt64
    var ttl_ns: Int
    var keys: UntrackedBytePtr
    var key_lens: UntrackedIntPtr
    var expiry: UntrackedIntPtr
    var values: List[ResponseBuffer]

    def __init__(out self, capacity_request: Int, ttl_ns: Int):
        var cap = 16
        while cap < capacity_request and cap < MAX_SLOTS:
            cap <<= 1
        if cap > MAX_SLOTS:
            cap = MAX_SLOTS
        self.slots = cap
        self.mask = UInt64(cap - 1)
        self.ttl_ns = ttl_ns
        self.keys = untrack(malloc_bytes(cap * KEY_CAP))
        self.key_lens = UntrackedIntPtr(unsafe_from_address=Int(malloc_bytes(8 * cap)))
        self.expiry = UntrackedIntPtr(unsafe_from_address=Int(malloc_bytes(8 * cap)))
        self.values = List[ResponseBuffer]()
        var miss = ResponseBuffer(data=null_bytes(), length=0)
        var i = 0
        while i < cap:
            self.key_lens[i] = 0
            self.expiry[i] = 0
            self.values.append(miss)
            i += 1

    def get(self, h: UInt64, key: BytePtr, klen: Int) -> ResponseBuffer:
        """Lookup by hash + full key; miss returns the zero-length sentinel.

        Read-only and lock-free. Length mismatch, byte mismatch, or an expired
        stamp all yield the sentinel; expired entries are NOT cleared here.
        """
        var idx = Int(h & self.mask)
        if self.key_lens[idx] != klen:
            return ResponseBuffer(data=null_bytes(), length=0)
        if self._expired(idx):
            return ResponseBuffer(data=null_bytes(), length=0)
        var base = self.keys + idx * KEY_CAP
        var i = 0
        while i < klen:
            if base[i] != key[i]:
                return ResponseBuffer(data=null_bytes(), length=0)
            i += 1
        return self.values[idx]

    def set(mut self, h: UInt64, key: BytePtr, klen: Int, value: ResponseBuffer):
        """Insert/overwrite the slot for this hash+key, copying the key bytes.

        This is the only place the cache allocates per call (the key copy).
        With ttl_ns <= 0 entries never expire; otherwise the stamp is
        monotonic-now + ttl_ns.
        """
        if klen > KEY_CAP:
            return
        var idx = Int(h & self.mask)
        var base = self.keys + idx * KEY_CAP
        var i = 0
        while i < klen:
            base[i] = key[i]
            i += 1
        self.key_lens[idx] = klen
        self.values[idx] = value
        if self.ttl_ns > 0:
            self.expiry[idx] = _now_ns() + self.ttl_ns
        else:
            self.expiry[idx] = 0

    def _expired(self, idx: Int) -> Bool:
        """True when the slot carries an expiry stamp already in the past."""
        var e = self.expiry[idx]
        return e != 0 and _now_ns() > e


def _now_ns() -> Int:
    """Monotonic clock in nanoseconds (Darwin CLOCK_MONOTONIC = 6)."""
    var ts = TimeSpec(sec=0, nsec=0)
    _ = external_call["clock_gettime", c_int](c_int(CLOCK_MONOTONIC), Pointer(to=ts))
    return ts.sec * 1_000_000_000 + ts.nsec
