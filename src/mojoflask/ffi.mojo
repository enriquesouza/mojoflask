"""mojoflask.ffi — every libc/POSIX touchpoint of the server lives here.

Role
    The rest of mojoflask never calls `external_call` directly. This module is
    the single translation layer between Mojo and the C runtime: raw malloc,
    errno inspection, socket-address/poll structs, and the SCM_RIGHTS file
    descriptor passing used by the pre-fork acceptor (see mojoflask.server).

Darwin quirks encoded here
    - EAGAIN == 35 and EINTR == 4: hard-coded Darwin errno values, because the
      variadic FFI boundary cannot reliably read `errno.h` macros.
    - `__error()` is the Darwin/libSystem accessor for the thread-local errno;
      we call it after every fallible syscall instead of trusting return codes.
    - sendmsg/recvmsg msghdr/cmsg structures are poked byte-by-byte into raw
      malloc'd memory (little-endian stores) because Mojo cannot declare C
      unions; SCM_RIGHTS fd passing needs a control message with
      level=SOL_SOCKET(0xFFFF) and type=SCM_RIGHTS(1).
    - SockAddrIn carries an explicit sin_len first field — BSD sockets require
      the length byte; Linux does not.
"""

from std.ffi import external_call, c_int, c_long, c_size_t, c_ssize_t
from std.origin import MutAnyOrigin, UntrackedOrigin


comptime AF_INET = c_int(2)
comptime AF_UNIX = c_int(1)
comptime SOCK_STREAM = c_int(1)
comptime SOL_SOCKET = c_int(0xFFFF)
comptime SCM_RIGHTS = c_int(1)
comptime SO_REUSEADDR = c_int(4)
comptime SO_REUSEPORT = c_int(0x200)
comptime O_RDONLY = c_int(0)
comptime POLLIN = UInt16(0x0001)
comptime POLLOUT = UInt16(0x0004)
comptime POLLERR = UInt16(0x0008)
comptime POLLHUP = UInt16(0x0010)
comptime POLLNVAL = UInt16(0x0020)
comptime EAGAIN_CODE = 35
comptime EINTR_CODE = 4
comptime SIGPIPE_SIGNAL = 13
comptime SIG_IGN_HANDLER = 1


comptime BytePtr = Pointer[T=Byte, mut=True, origin=MutAnyOrigin]
comptime Int32Ptr = Pointer[T=Int32, mut=True, origin=MutAnyOrigin]
comptime IntPtr = Pointer[T=Int, mut=True, origin=MutAnyOrigin]
comptime UntrackedBytePtr = Pointer[T=Byte, mut=True, origin=UntrackedOrigin[mut=True]]
comptime UntrackedInt32Ptr = Pointer[T=Int32, mut=True, origin=UntrackedOrigin[mut=True]]
comptime UntrackedPollFdPtr = Pointer[T=PollFd, mut=True, origin=UntrackedOrigin[mut=True]]


@fieldwise_init
struct SockAddrIn(RegisterPassable):
    """BSD-style IPv4 socket address; sin_len must lead on Darwin."""

    var sin_len: UInt8
    var sin_family: UInt8
    var sin_port: UInt16
    var sin_addr: UInt32
    var sin_zero: UInt64


@fieldwise_init
struct PollFd(RegisterPassable):
    """One entry of a poll() array; layout matches <poll.h> exactly."""

    var fd: Int32
    var events: UInt16
    var revents: UInt16


def htons(port: UInt16) -> UInt16:
    """Swap byte order of a port number for network order."""
    return (port >> 8) | (port << 8)


def min_int(a: Int, b: Int) -> Int:
    """Smaller of two integers."""
    if a < b:
        return a
    return b


def errno_now() -> Int:
    """Read the thread-local errno via Darwin's __error() accessor."""
    var ep = external_call["__error", Pointer[T=c_int, mut=True, origin=MutAnyOrigin]]()
    return Int(ep[0])


def ignore_sigpipe():
    """SIG_IGN on SIGPIPE so writing to a closed peer never kills the worker."""
    external_call["signal", c_ssize_t](c_int(SIGPIPE_SIGNAL), c_int(SIG_IGN_HANDLER))


def fatal(message: String):
    """Print a startup error and abort the process."""
    print(message)
    external_call["exit", c_int](c_int(1))


def malloc_bytes(n: Int) -> BytePtr:
    """Raw malloc as a mutable byte pointer."""
    return external_call["malloc", BytePtr](c_size_t(n))


def free_bytes(p: BytePtr):
    """Free a pointer obtained from malloc_bytes or make_cstr."""
    external_call["free", c_ssize_t](p)


def null_bytes() -> UntrackedBytePtr:
    """Non-null dummy address used as 'no buffer yet' sentinel; never
    dereferenced (the compiler forbids literal null Pointers)."""
    return UntrackedBytePtr(unsafe_from_address=8)


def untrack(p: BytePtr) -> UntrackedBytePtr:
    """Drop origin tracking for storage inside a struct field."""
    return UntrackedBytePtr(unsafe_from_address=Int(p))


def retracked(p: UntrackedBytePtr) -> BytePtr:
    """Recover a tracked pointer from its untracked form."""
    return BytePtr(unsafe_from_address=Int(p))


def make_cstr(s: String) -> BytePtr:
    """Heap-copy a String and NUL-terminate it."""
    var n = s.byte_length()
    var p = malloc_bytes(n + 1)
    var i = 0
    for b in s.bytes():
        p[i] = b
        i += 1
    p[n] = UInt8(0)
    return p


def zero_bytes(p: BytePtr, n: Int):
    """Fill n bytes with zero."""
    var i = 0
    while i < n:
        p[i] = UInt8(0)
        i += 1


def store_u64_le(p: BytePtr, v_in: Int):
    """Write 8 little-endian bytes."""
    var x = v_in
    var i = 0
    while i < 8:
        p[i] = UInt8(x & 255)
        x >>= 8
        i += 1


def store_u32_le(p: BytePtr, v_in: Int):
    """Write 4 little-endian bytes."""
    var x = v_in
    var i = 0
    while i < 4:
        p[i] = UInt8(x & 255)
        x >>= 8
        i += 1


def load_u32_le(p: BytePtr) -> Int:
    """Read 4 little-endian bytes."""
    return Int(p[0]) | (Int(p[1]) << 8) | (Int(p[2]) << 16) | (Int(p[3]) << 24)


def send_fd(pair_fd: Int32, fd_to_send: Int32) -> Bool:
    """Send one file descriptor over a Unix socketpair via SCM_RIGHTS.

    Builds a minimal msghdr: one 1-byte iov plus one 16-byte cmsghdr whose
    payload is the descriptor itself. All structs are hand-poked because the
    FFI layer cannot express the C unions involved.
    """
    var pay = malloc_bytes(1)
    var iov = malloc_bytes(16)
    var cm = malloc_bytes(16)
    var mh = malloc_bytes(48)
    zero_bytes(iov, 16)
    zero_bytes(cm, 16)
    zero_bytes(mh, 48)
    store_u64_le(iov, Int(pay))
    store_u64_le(iov + 8, 1)
    store_u32_le(cm, 16)
    store_u32_le(cm + 4, Int(SOL_SOCKET))
    store_u32_le(cm + 8, Int(SCM_RIGHTS))
    store_u32_le(cm + 12, Int(fd_to_send))
    store_u64_le(mh + 16, Int(iov))
    store_u64_le(mh + 24, 1)
    store_u64_le(mh + 32, Int(cm))
    store_u32_le(mh + 40, 16)
    var r = external_call["sendmsg", c_ssize_t](pair_fd, mh, c_int(0))
    free_bytes(pay)
    free_bytes(iov)
    free_bytes(cm)
    free_bytes(mh)
    return Int(r) > 0


def recv_fd(pair_fd: Int32) -> Int:
    """Receive one file descriptor over a socketpair; returns -1 on failure.

    Mirrors send_fd: the 32-byte control buffer is scanned for a SOL_SOCKET /
    SCM_RIGHTS control message and the embedded descriptor is extracted.
    """
    var pay = malloc_bytes(1)
    var iov = malloc_bytes(16)
    var cm = malloc_bytes(32)
    var mh = malloc_bytes(48)
    zero_bytes(iov, 16)
    zero_bytes(cm, 32)
    zero_bytes(mh, 48)
    store_u64_le(iov, Int(pay))
    store_u64_le(iov + 8, 1)
    store_u64_le(mh + 16, Int(iov))
    store_u64_le(mh + 24, 1)
    store_u64_le(mh + 32, Int(cm))
    store_u32_le(mh + 40, 32)
    var r = external_call["recvmsg", c_ssize_t](pair_fd, mh, c_int(0))
    var out = -1
    if Int(r) > 0:
        if load_u32_le(cm + 4) == Int(SOL_SOCKET) and load_u32_le(cm + 8) == Int(SCM_RIGHTS):
            out = load_u32_le(cm + 12)
    free_bytes(pay)
    free_bytes(iov)
    free_bytes(cm)
    free_bytes(mh)
    return out


def read_file_into(path: String, dst: BytePtr, cap: Int) -> Int:
    """Read a whole file into dst; returns byte count, exits the process on
    failure. Startup-only helper for prebuilt payloads."""
    var cp = make_cstr(path)
    var fd = external_call["open", c_int](cp, O_RDONLY)
    free_bytes(cp)
    if Int(fd) < 0:
        print("payload open failed: " + path)
        external_call["exit", c_int](c_int(1))
    var size = 0
    while size < cap:
        var n = external_call["read", c_ssize_t](fd, dst + size, c_size_t(cap - size))
        if Int(n) <= 0:
            break
        size += Int(n)
    external_call["close", c_int](fd)
    return size


def open_socket() -> Int32:
    """TCP/IPv4 stream socket."""
    return external_call["socket", c_int](AF_INET, SOCK_STREAM, c_int(0))


def create_listen_socket(port: Int, backlog: Int) -> Int32:
    """SO_REUSEADDR+SO_REUSEPORT socket bound to 0.0.0.0:port and listening.

    On Darwin SO_REUSEPORT does NOT balance across listeners (see server
    module doc); it is still set so a crashed predecessor's port releases.
    """
    var lfd = open_socket()
    if Int(lfd) < 0:
        return lfd
    var one = c_int(1)
    external_call["setsockopt", c_int](lfd, SOL_SOCKET, SO_REUSEADDR, Pointer(to=one), c_int(4))
    external_call["setsockopt", c_int](lfd, SOL_SOCKET, SO_REUSEPORT, Pointer(to=one), c_int(4))
    var sa = SockAddrIn(
        sin_len=UInt8(16),
        sin_family=UInt8(2),
        sin_port=htons(UInt16(Int(port) & 0xFFFF)),
        sin_addr=UInt32(0),
        sin_zero=UInt64(0),
    )
    var br = external_call["bind", c_int](lfd, Pointer(to=sa), c_int(16))
    if Int(br) < 0:
        close_fd(lfd)
        return Int32(-1)
    external_call["listen", c_int](lfd, c_int(backlog))
    return lfd


def accept_connection(lfd: Int32) -> Int32:
    """Accept one connection; -1 on failure."""
    var ca = SockAddrIn(
        sin_len=UInt8(0),
        sin_family=UInt8(0),
        sin_port=UInt16(0),
        sin_addr=UInt32(0),
        sin_zero=UInt64(0),
    )
    var slen = UInt32(16)
    return external_call["accept", c_int](lfd, Pointer(to=ca), Pointer(to=slen))


def close_fd(fd: Int32):
    """Close a descriptor."""
    external_call["close", c_int](fd)


def dup_fd(fd: Int32) -> Int32:
    """Duplicate a descriptor (fd-range reservation)."""
    return external_call["dup", c_int](fd)


def fork_process() -> Int32:
    """fork(); 0 in the child, child pid in the parent, -1 on failure."""
    return external_call["fork", c_int]()


def current_pid() -> Int32:
    """Process id of the caller."""
    return external_call["getpid", c_int]()


def socketpair(sp: Int32Ptr):
    """Create one AF_UNIX SOCK_STREAM pair written into sp[0]/sp[1]."""
    external_call["socketpair", c_int](AF_UNIX, SOCK_STREAM, c_int(0), sp)


def wait_on_poll(fds: UntrackedPollFdPtr, n: Int) -> Int:
    """poll() over n entries, blocking forever (-1 timeout)."""
    var r = external_call["poll", c_int](fds, c_int(n), c_int(-1))
    return Int(r)


def send_bytes(fd: Int32, p: BytePtr, n: Int) -> Int:
    """send() n bytes from p; returns bytes sent or -1."""
    var r = external_call["send", c_ssize_t](fd, p, c_size_t(n), c_int(0))
    return Int(r)


def recv_bytes(fd: Int32, p: BytePtr, n: Int) -> Int:
    """recv() up to n bytes into p; returns bytes read or -1."""
    var r = external_call["recv", c_ssize_t](fd, p, c_size_t(n), c_int(0))
    return Int(r)


def malloc_int32s(n: Int) -> Int32Ptr:
    """Raw int32 array allocation."""
    return external_call["malloc", Int32Ptr](c_size_t(4 * n))


def malloc_pollfds(n: Int) -> UntrackedPollFdPtr:
    """Raw pollfd array allocation."""
    return UntrackedPollFdPtr(unsafe_from_address=Int(malloc_bytes(8 * n)))
