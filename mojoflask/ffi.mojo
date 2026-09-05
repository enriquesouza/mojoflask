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
comptime IPPROTO_TCP = c_int(6)
comptime TCP_NODELAY = c_int(1)
comptime POLLIN = UInt16(0x0001)
comptime POLLOUT = UInt16(0x0004)
comptime POLLERR = UInt16(0x0008)
comptime POLLHUP = UInt16(0x0010)
comptime POLLNVAL = UInt16(0x0020)
comptime CLOCK_MONOTONIC = c_int(6)
comptime CLOCK_REALTIME = c_int(0)
comptime EAGAIN_CODE = 35
comptime EINTR_CODE = 4
comptime SIGPIPE_SIGNAL = 13
comptime SIG_IGN_HANDLER = 1
comptime WNOHANG_FLAG = 1


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


@fieldwise_init
struct Timespec(RegisterPassable):
    """Layout twin of Darwin's `struct timespec` (two 64-bit longs)."""

    var sec: Int
    var nsec: Int


def monotonic_ms() -> Int:
    """CLOCK_MONOTONIC in milliseconds; immune to wall-clock steps, so it is
    the only safe clock for connection deadlines (drain idle timeout)."""
    var ts = Timespec(sec=0, nsec=0)
    _ = external_call["clock_gettime", c_int](CLOCK_MONOTONIC, Pointer(to=ts))
    return Int(ts.sec) * 1000 + Int(ts.nsec) // 1000000


def wall_clock_milliseconds() -> Int:
    """CLOCK_REALTIME in milliseconds; wall-clock, so it steps with system
    time changes — used only for identifiers that must resemble the boot
    wall clock, never for measuring durations."""
    var ts = Timespec(sec=0, nsec=0)
    _ = external_call["clock_gettime", c_int](CLOCK_REALTIME, Pointer(to=ts))
    return Int(ts.sec) * 1000 + Int(ts.nsec) // 1000000


def wall_clock_nanoseconds() -> Int:
    """CLOCK_REALTIME in nanoseconds since the epoch; wall-clock, so it
    steps with system time changes — used only for identifiers that want
    sub-millisecond separation between concurrent requests."""
    var ts = Timespec(sec=0, nsec=0)
    _ = external_call["clock_gettime", c_int](CLOCK_REALTIME, Pointer(to=ts))
    return Int(ts.sec) * 1000000000 + Int(ts.nsec)


def publish_environment_value(name: String, value: String) -> None:
    """setenv(name, value, overwrite=1) with NUL-terminated C copies of the
    Mojo strings; the buffers are leaked one-shot wiring, matching how the
    reference runtime publishes pointer slots for late retrieval."""
    var name_buffer = malloc_bytes(name.byte_length() + 1)
    var name_bytes = name.as_bytes()
    var byte_index = 0
    while byte_index < len(name_bytes):
        name_buffer[byte_index] = name_bytes[byte_index]
        byte_index += 1
    name_buffer[byte_index] = 0
    var value_buffer = malloc_bytes(value.byte_length() + 1)
    var value_bytes = value.as_bytes()
    byte_index = 0
    while byte_index < len(value_bytes):
        value_buffer[byte_index] = value_bytes[byte_index]
        byte_index += 1
    value_buffer[byte_index] = 0
    _ = external_call["setenv", c_int](
        name_buffer, value_buffer, c_int(1)
    )


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


def exit_now(code: Int):
    """_exit(): terminate immediately, skipping atexit handlers and stdio
    flush — the only safe way out of a child whose allocator state is
    already suspect."""
    external_call["_exit", c_int](c_int(code))


def waitpid_nohang(pid: Int32, status_out: Int32Ptr) -> Int32:
    """waitpid(pid, &status, WNOHANG): 0 while the child still runs, the pid
    once it has exited (raw wait status written into status_out[0]), -1 on
    error (ECHILD etc. — treat as dead)."""
    return external_call["waitpid", c_int](pid, status_out, c_int(WNOHANG_FLAG))


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


@fieldwise_init
struct FdPassScratch(RegisterPassable):
    """Preallocated msghdr/iov/cmsg buffers for SCM_RIGHTS passing.

    send_fd/recv_fd used to malloc and free EIGHT small buffers per passed
    descriptor; under reconnect storms (worker respawn during miss storms)
    that put the allocator on the parent's hot path. One scratch per loop,
    allocated once at startup, is reused for every pass. Fields are stored
    as UntrackedBytePtr because Mojo struct fields cannot expose AnyOrigin;
    helpers recover tracked pointers locally via retracked()."""

    var pay: UntrackedBytePtr
    var iov: UntrackedBytePtr
    var cm: UntrackedBytePtr
    var mh: UntrackedBytePtr


def fd_pass_scratch() -> FdPassScratch:
    """Allocate the never-freed process-lifetime fd-passing buffers."""
    return FdPassScratch(
        pay=untrack(malloc_bytes(1)),
        iov=untrack(malloc_bytes(16)),
        cm=untrack(malloc_bytes(32)),
        mh=untrack(malloc_bytes(48)),
    )


def _fill_send_msghdr(s: FdPassScratch, fd_to_send: Int32):
    var iov = retracked(s.iov)
    var cm = retracked(s.cm)
    var mh = retracked(s.mh)
    zero_bytes(iov, 16)
    zero_bytes(cm, 16)
    zero_bytes(mh, 48)
    store_u64_le(iov, Int(retracked(s.pay)))
    store_u64_le(iov + 8, 1)
    store_u32_le(cm, 16)
    store_u32_le(cm + 4, Int(SOL_SOCKET))
    store_u32_le(cm + 8, Int(SCM_RIGHTS))
    store_u32_le(cm + 12, Int(fd_to_send))
    store_u64_le(mh + 16, Int(iov))
    store_u64_le(mh + 24, 1)
    store_u64_le(mh + 32, Int(cm))
    store_u32_le(mh + 40, 16)


def _fill_recv_msghdr(s: FdPassScratch):
    var iov = retracked(s.iov)
    var cm = retracked(s.cm)
    var mh = retracked(s.mh)
    zero_bytes(iov, 16)
    zero_bytes(cm, 32)
    zero_bytes(mh, 48)
    store_u64_le(iov, Int(retracked(s.pay)))
    store_u64_le(iov + 8, 1)
    store_u64_le(mh + 16, Int(iov))
    store_u64_le(mh + 24, 1)
    store_u64_le(mh + 32, Int(cm))
    store_u32_le(mh + 40, 32)


def send_fd(pair_fd: Int32, fd_to_send: Int32, mut s: FdPassScratch) -> Bool:
    """Send one file descriptor over a Unix socketpair via SCM_RIGHTS.

    Builds a minimal msghdr: one 1-byte iov plus one 16-byte cmsghdr whose
    payload is the descriptor itself. All structs are hand-poked because the
    FFI layer cannot express the C unions involved; the backing memory comes
    from the caller-owned scratch so the hot path allocates nothing.

    The caller MUST verify writability first (poll_single POLLOUT timeout 0):
    these are blocking sockets, so an unchecked sendmsg parks the process
    once the peer stops draining its pair.
    """
    _fill_send_msghdr(s, fd_to_send)
    retracked(s.pay)[0] = UInt8(0)
    var r = external_call["sendmsg", c_ssize_t](pair_fd, s.mh, c_int(0))
    return Int(r) > 0


def recv_fd(pair_fd: Int32, mut s: FdPassScratch) -> Int:
    """Receive one file descriptor over a socketpair; returns -1 on failure.

    Mirrors send_fd: the 32-byte control buffer is scanned for a SOL_SOCKET /
    SCM_RIGHTS control message and the embedded descriptor is extracted.
    Call only when poll single-entry reports POLLIN (else recvmsg blocks).
    """
    _fill_recv_msghdr(s)
    var r = external_call["recvmsg", c_ssize_t](pair_fd, s.mh, c_int(0))
    var out = -1
    if Int(r) > 0:
        if load_u32_le(retracked(s.cm) + 4) == Int(SOL_SOCKET) and load_u32_le(
            retracked(s.cm) + 8
        ) == Int(SCM_RIGHTS):
            out = load_u32_le(retracked(s.cm) + 12)
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


def set_nodelay(fd: Int32):
    """TCP_NODELAY on: Nagle off, mirroring rust-skinny main.rs (listener and
    every accepted socket). Kills delayed-ACK stalls on multi-segment writes."""
    var one = c_int(1)
    _ = external_call["setsockopt", c_int](
        fd, IPPROTO_TCP, TCP_NODELAY, Pointer(to=one), c_int(4)
    )


def create_listen_socket(port: Int, backlog: Int) -> Int32:
    """SO_REUSEADDR+SO_REUSEPORT socket bound to 0.0.0.0:port and listening.

    On Darwin SO_REUSEPORT does NOT balance across listeners (see server
    module doc); it is still set so a crashed predecessor's port releases.
    Also stamps TCP_NODELAY so accepted sockets inherit it (set again
    explicitly per accepted fd — belt and suspenders).
    """
    var lfd = open_socket()
    if Int(lfd) < 0:
        return lfd
    var one = c_int(1)
    external_call["setsockopt", c_int](lfd, SOL_SOCKET, SO_REUSEADDR, Pointer(to=one), c_int(4))
    external_call["setsockopt", c_int](lfd, SOL_SOCKET, SO_REUSEPORT, Pointer(to=one), c_int(4))
    set_nodelay(lfd)
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
    """Accept one connection; -1 on failure. TCP_NODELAY stamped on success."""
    var ca = SockAddrIn(
        sin_len=UInt8(0),
        sin_family=UInt8(0),
        sin_port=UInt16(0),
        sin_addr=UInt32(0),
        sin_zero=UInt64(0),
    )
    var slen = UInt32(16)
    var cfd = external_call["accept", c_int](lfd, Pointer(to=ca), Pointer(to=slen))
    if Int(cfd) >= 0:
        set_nodelay(cfd)
    return cfd


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


def wait_on_poll_timeout(fds: UntrackedPollFdPtr, n: Int, timeout_ms: Int) -> Int:
    """poll() over n entries with a millisecond timeout so supervision loops
    can wake periodically; returns -1 with errno EINTR when a signal (e.g.
    SIGCHLD) lands mid-wait."""
    var r = external_call["poll", c_int](fds, c_int(n), c_int(timeout_ms))
    return Int(r)


def poll_single(fd: Int32, events: UInt16, timeout_ms: Int) -> Int:
    """poll() over exactly ONE descriptor on the stack.

    The non-blocking gate this codebase leans on everywhere: every socket
    here stays BLOCKING (no fcntl via variadic FFI), so before any accept,
    sendmsg or extra recvmsg beyond the one an outer poll already justified,
    poll_single(fd, POLLIN/POLLOUT, 0) answers "is it safe RIGHT NOW".
    Returns poll's raw count of ready entries (>0 means go).
    """
    var pfd = PollFd(fd=fd, events=events, revents=UInt16(0))
    return Int(external_call["poll", c_int](Pointer(to=pfd), c_int(1), c_int(timeout_ms)))


def parent_pid() -> Int32:
    """getppid(): lets a forked worker detect it has been orphaned."""
    return external_call["getppid", c_int]()


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


def malloc_ints(n: Int) -> IntPtr:
    """Raw pointer-width int array allocation (stores addresses)."""
    return external_call["malloc", IntPtr](c_size_t(8 * n))


def malloc_pollfds(n: Int) -> UntrackedPollFdPtr:
    """Raw pollfd array allocation."""
    return UntrackedPollFdPtr(unsafe_from_address=Int(malloc_bytes(8 * n)))
