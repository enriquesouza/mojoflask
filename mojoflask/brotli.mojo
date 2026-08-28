"""mojoflask.brotli — runtime-dlopen'd libbrotlienc bindings (content
encoding for cached HTTP responses).

Compress-once-at-fill is the intended shape: a cache layer builds the
identity response, then stores a brotli variant of the same body; repeated
hits serve the pre-compressed bytes with `Content-Encoding: br` — the
one-shot `BrotliEncoderCompress` covers exactly that (no streaming state).

The library is probed through the same candidate list / RTLD_NOW dlopen /
`ExternalFunction[name, type].load()` dlsym pattern the pqmojo driver uses;
nothing is linked at build time. When no candidate loads, compress()
returns len 0 and callers keep serving identity.
"""

from std.ffi import c_int, c_size_t, dlopen
from std.python._cpython import ExternalFunction, _DLHandle

from .ffi import BytePtr, free_bytes, malloc_bytes


comptime RTLD_NOW: Int32 = 2

comptime _FnMaxCompressedSize = def(c_size_t) thin abi("C") -> c_size_t

comptime _FnEncoderCompress = def(
    c_int, c_int, c_int, c_size_t, BytePtr, BytePtr, BytePtr
) thin abi("C") -> c_int

comptime _BrotliEncoderMaxCompressedSize = ExternalFunction[
    "BrotliEncoderMaxCompressedSize", _FnMaxCompressedSize
]
comptime _BrotliEncoderCompress = ExternalFunction[
    "BrotliEncoderCompress", _FnEncoderCompress
]

comptime BROTLI_LGWIN = c_int(22)
comptime BROTLI_MODE_GENERIC = c_int(0)


def brotli_candidates() -> List[String]:
    var out = List[String]()
    out.append(String("/opt/homebrew/lib/libbrotlienc.1.dylib"))
    out.append(String("/opt/homebrew/lib/libbrotlienc.dylib"))
    out.append(String("/usr/local/lib/libbrotlienc.1.dylib"))
    out.append(String("libbrotlienc.1.dylib"))
    out.append(String("libbrotlienc.dylib"))
    out.append(String("libbrotlienc.so.1"))
    out.append(String("libbrotlienc.so"))
    return out^


def c_char_string(s: String) -> BytePtr:
    var b = s.as_bytes()
    var out = malloc_bytes(len(b) + 1)
    var i = 0
    while i < len(b):
        out[unsafe_offset=i] = b[i]
        i += 1
    out[unsafe_offset=len(b)] = 0
    return out


def imm_char(p: BytePtr) -> Pointer[Int8, ImmUntrackedOrigin]:
    return Pointer[Int8, ImmUntrackedOrigin](unsafe_from_address=Int(p))


@fieldwise_init
struct Brotli(Movable):
    """One loaded libbrotlienc handle; handle==0 means unavailable."""

    var handle: Int

    def __init__(out self):
        self.handle = 0
        var candidates = brotli_candidates()
        for ci in range(len(candidates)):
            var name = c_char_string(candidates[ci])
            var h = dlopen(imm_char(name), RTLD_NOW)
            free_bytes(name)
            if h:
                self.handle = Int(h.value())
                return

    def compress(
        self, src: BytePtr, src_len: Int, quality: Int = 4
    ) raises -> Tuple[BytePtr, Int]:
        """One-shot compress; (ptr, len) with len==0 = keep identity.
        Binds the two symbols per call — compress runs once per cache
        fill, so the double dlsym is noise."""
        if src_len == 0 or self.handle == 0:
            return (src, 0)
        var dlh = _DLHandle(
            Pointer[NoneType, MutUntrackedOrigin](
                unsafe_from_address=self.handle
            )
        )
        var max_size = _BrotliEncoderMaxCompressedSize.load(dlh)
        var compress_raw = _BrotliEncoderCompress.load(dlh)
        var cap = Int(max_size(c_size_t(src_len)))
        if cap <= 0:
            return (src, 0)
        var dst = malloc_bytes(cap)
        var out_size_holder = malloc_bytes(8)
        store_le64(out_size_holder, cap)
        var ok = compress_raw(
            c_int(quality),
            BROTLI_LGWIN,
            BROTLI_MODE_GENERIC,
            c_size_t(src_len),
            src,
            out_size_holder,
            dst,
        )
        var final_len = read_le64(out_size_holder)
        free_bytes(out_size_holder)
        if ok == 0 or final_len <= 0 or final_len > cap:
            free_bytes(dst)
            return (src, 0)
        if final_len == cap:
            return (dst, final_len)
        var tight = malloc_bytes(final_len)
        var i = 0
        while i < final_len:
            tight[unsafe_offset=i] = dst[unsafe_offset=i]
            i += 1
        free_bytes(dst)
        return (tight, final_len)


def store_le64(p: BytePtr, value: Int):
    var i = 0
    while i < 8:
        p[unsafe_offset=i] = UInt8((value >> (8 * i)) & 0xFF)
        i += 1


def read_le64(p: BytePtr) -> Int:
    var v = 0
    var i = 7
    while i >= 0:
        v = (v << 8) | Int(p[unsafe_offset=i])
        i -= 1
    return v
