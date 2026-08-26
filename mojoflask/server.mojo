"""mojoflask.server — the poll-driven multi-worker HTTP engine.

Role
    Owns everything with a file descriptor: the listen socket, per-connection
    state machines, the poll event loop, and the pre-fork acceptor that hands
    connections to workers. `serve()` is the library entry point.

Darwin quirks encoded here (all verified against macOS 26 arm64)
    - SO_REUSEPORT does NOT load-balance on Darwin: every connection is
      delivered to one listener (last-binder-wins). The boot therefore binds
      ONCE in the parent, forks N workers, and the parent distributes
      accepted fds round-robin over pre-fork socketpairs via sendmsg /
      SCM_RIGHTS (see send_fd/recv_fd in mojoflask.ffi).
    - fcntl cannot be reached through Mojo's variadic FFI, so sockets stay
      BLOCKING; instead of non-blocking I/O we gate every recv/send behind
      poll(), which makes the short blocking calls safe in practice.
    - signal(SIGPIPE, SIG_IGN) is installed first thing: Darwin raises
      SIGPIPE on writes to closed peers and would otherwise kill workers.
    - Errnos are compared against hard-coded Darwin values: EAGAIN == 35,
      EINTR == 4 (the variadic FFI boundary cannot see errno.h macros).
      EINTR retries in place; anything else tears the connection down.
    - SockAddrIn carries sin_len because BSD sockets want the length byte.

Connection lifecycle (ConnState.phase)
    PARSE_HEAD     -> accumulate bytes until CRLFCRLF; resolve route, latch
                      the prebuilt response (or mark the route dynamic), note
                      Content-Length and any explicit Connection: close; the
                      request head's absolute offset is anchored in
                      req_start for later resolver dispatch.
    READ_BODY      -> drain request body bytes (QUERY/POST) before replying;
                      once drained, dynamic routes invoke the process
                      resolver while static routes aim the writer at the
                      prebuilt response; both fall through to flushing.
                      normalize_buffer is suspended across this whole phase:
                      head and body routinely arrive in separate recv events
                      on fresh connections, and compaction here would orphan
                      the req_start anchor and overwrite head bytes with the
                      incoming body.
    WRITE_RESPONSE -> send() slices of the latched response until done; then
                      either keep-alive back to PARSE_HEAD or close the
                      socket.

Dynamic routes and the single process resolver
    Mojo 1.0 forbids module-level mutable globals ("global variables are not
    supported") AND storing function values inside struct fields ("struct
    fields do not support trait types"), so a runtime set_resolver(f) cell is
    impossible in-language. The single-per-process hook therefore travels as
    a COMPTIME parameter: register dynamic routes, then enter the loop with
    serve_dynamic[resolve](config, routes, responses) (App: run_dynamic[...])
    — exactly one resolver per process tree, inherited by every forked
    worker, installed before any request is served. Static-only apps keep
    plain run()/serve(), whose hot path never touches the resolver.

    When a resolved route's kind is ROUTE_DYNAMIC, the engine waits until the
    head AND body are fully read, then calls the resolver once with:

      - route_index  which add_dynamic() registration matched
      - method_code  the request's METHOD_* bit (0 when unrecognized)
      - req_head/head_len   span of the full request head inside the
                            connection's receive buffer
      - body/body_len       span of the drained request body (may be empty)

    ALIASING HAZARD: both spans point INTO the connection recv buffer, which
    is reused for the next request as soon as the response write completes —
    the handler MUST copy anything it retains past its return.

    The resolver answers through one DynamicOut mutable argument:

      - static_route >= 0  serve responses.at(static_route) instead — the
        fast-return idiom lets a handler answer warm-cache hits from an
        existing prebuilt buffer with zero allocation; data/length are then
        ignored.
      - otherwise data/length describe fresh response bytes (a complete
        HTTP/1.x message including headers). owns=True makes the engine
        free() data after the write finishes or the connection dies;
        owns=False means the handler keeps ownership. Returning True with an
        empty payload, or returning False, serves the fallback response.

    Serving a dynamic route under plain serve() (no resolver) serves the
    fallback response — never a crash.
"""

from std.os import getenv

from std.origin import UntrackedOrigin

from mojoflask.ffi import (
    EINTR_CODE,
    POLLERR,
    POLLHUP,
    POLLIN,
    POLLNVAL,
    POLLOUT,
    PollFd,
    BytePtr,
    Int32Ptr,
    UntrackedBytePtr,
    UntrackedInt32Ptr,
    UntrackedPollFdPtr,
    accept_connection,
    close_fd,
    create_listen_socket,
    current_pid,
    dup_fd,
    errno_now,
    fatal,
    fork_process,
    ignore_sigpipe,
    malloc_bytes,
    malloc_int32s,
    malloc_pollfds,
    min_int,
    null_bytes,
    open_socket,
    recv_bytes,
    recv_fd,
    retracked,
    send_bytes,
    send_fd,
    socketpair,
    untrack,
    wait_on_poll,
)

from mojoflask.http import (
    RequestHeaderKeys,
    ResponseSet,
    find_header_end,
    parse_request_head,
    standard_header_keys,
)

from mojoflask.router import ROUTE_DYNAMIC, RouteTable


comptime PHASE_PARSE_HEAD = 0
comptime PHASE_READ_BODY = 1
comptime PHASE_WRITE_RESPONSE = 2

comptime DEFAULT_BACKLOG = 1024
comptime DEFAULT_BUF_CAP = 32768
comptime DEFAULT_MAX_CONNS = 4096

comptime MAX_HEAD_BYTES = 30000
comptime COMPACT_THRESHOLD = 16384
comptime RESERVED_FD_GUARDS = 96

# Padded per-slot stride for the heap allocation backing ConnTable; generous
# on purpose so field additions never under-allocate.
comptime CONN_SLOT_STRIDE = 192


# One process-wide dynamic-route resolver (full contract in the module
# docstring). Because Mojo 1.0 cannot store function values in fields or
# globals, it travels as a comptime parameter through serve_dynamic[] /
# run_dynamic[]. Arguments: route_index, method_code, req_head, head_len,
# body, body_len, plus one mutable DynamicOut the handler fills. Return True
# to accept out_buf (static_route fast-return or fresh owned/borrowed bytes),
# False to serve the fallback response.
comptime ResolverFn = def(
    Int, UInt8, BytePtr, Int, BytePtr, Int, mut DynamicOut
) thin -> Bool


@fieldwise_init
struct DynamicOut(RegisterPassable):
    """What a dynamic resolver hands back to the engine.

    static_route >= 0 wins over data/length: the engine serves that prebuilt
    ResponseBuffer with zero allocation (warm-cache-hit idiom). Otherwise
    data/length must describe a complete HTTP response message; owns=True
    transfers free() responsibility to the engine after the write finishes or
    the connection dies. `data` is untracked for field storage exactly like
    ResponseBuffer.data.
    """

    var data: UntrackedBytePtr
    var length: Int
    var owns: Bool
    var static_route: Int


@fieldwise_init
struct WorkerConfig(RegisterPassable):
    """All tunables of one serving process tree."""

    var port: Int
    var workers: Int
    var backlog: Int
    var buf_cap: Int
    var max_conns: Int


@fieldwise_init
struct ConnState(RegisterPassable, ImplicitlyCopyable):
    """Everything owned by one client connection.

    One struct per potential connection replaces the parallel arrays of the
    prototype; each field access compiles to a base+offset load exactly like
    the old per-array indexing, so the hot path pays no extra cost.
    """

    var fd: Int32
    var recv_buf: UntrackedBytePtr
    var has_recv_buf: Bool
    var buf_off: Int32
    var data_len: Int32
    var phase: Int32
    var body_remaining: Int32
    var wants_close: Bool
    var resp_data: UntrackedBytePtr
    var resp_len: Int32
    var write_off: Int32
    var write_remaining: Int32
    var dyn_route: Int32
    var req_method: Int32
    var req_start: Int32
    var head_span: Int32
    var body_span: Int32
    var dyn_data: UntrackedBytePtr
    var dyn_len: Int32
    var dyn_owned: Bool


@fieldwise_init
struct ConnTable(RegisterPassable, ImplicitlyCopyable):
    """Fixed-size pool of ConnStates plus its poll scratch arrays."""

    var slots: Pointer[T=ConnState, mut=True, origin=UntrackedOrigin[mut=True]]
    var capacity: Int
    var buf_cap: Int
    var poll_fds: UntrackedPollFdPtr
    var poll_map: UntrackedInt32Ptr

    def close_conn(mut self, i: Int):
        """Tear down slot i; release any dynamic payload, keep recv buffer."""
        self.release_dynamic(i)
        var fd = self.slots[i].fd
        if Int(fd) >= 0:
            close_fd(fd)
        self.slots[i].fd = Int32(-1)

    def release_dynamic(mut self, i: Int):
        """Free a resolver-produced response buffer the engine owns.

        Runs when the write finishes or the connection dies; clears the slot's
        dynamic fields so keep-alive requests never see stale pointers.
        """
        if self.slots[i].dyn_owned and Int(self.slots[i].dyn_len) > 0:
            free_bytes(retracked(self.slots[i].dyn_data))
        self.slots[i].dyn_data = null_bytes()
        self.slots[i].dyn_len = Int32(0)
        self.slots[i].dyn_owned = False
        self.slots[i].dyn_route = Int32(-1)
        self.slots[i].req_start = Int32(0)

    def find_free_slot(self) -> Int:
        """First empty slot index, or -1 when the pool is full."""
        var j = 0
        while j < self.capacity:
            if Int(self.slots[j].fd) < 0:
                return j
            j += 1
        return -1

    def register_connection(mut self, cfd: Int32):
        """Place a fresh accepted socket into an empty slot, or reject it."""
        var slot = self.find_free_slot()
        if slot < 0:
            close_fd(cfd)
            return
        if not self.slots[slot].has_recv_buf:
            self.slots[slot].recv_buf = untrack(malloc_bytes(self.buf_cap))
            self.slots[slot].has_recv_buf = True
        self.slots[slot].fd = cfd
        self.slots[slot].buf_off = Int32(0)
        self.slots[slot].data_len = Int32(0)
        self.slots[slot].phase = Int32(PHASE_PARSE_HEAD)
        self.slots[slot].body_remaining = Int32(0)
        self.slots[slot].wants_close = False
        self.slots[slot].resp_len = Int32(0)
        self.slots[slot].write_off = Int32(0)
        self.slots[slot].write_remaining = Int32(0)
        self.slots[slot].dyn_route = Int32(-1)
        self.slots[slot].req_method = Int32(0)
        self.slots[slot].req_start = Int32(0)
        self.slots[slot].head_span = Int32(0)
        self.slots[slot].body_span = Int32(0)
        self.slots[slot].dyn_data = null_bytes()
        self.slots[slot].dyn_len = Int32(0)
        self.slots[slot].dyn_owned = False

    def flush_write(mut self, i: Int):
        """Send more of the latched response; finish or keep-alive on completion."""
        if Int(self.slots[i].write_remaining) <= 0:
            return
        var fd = self.slots[i].fd
        var cursor = retracked(self.slots[i].resp_data) + Int(self.slots[i].write_off)
        var n = send_bytes(fd, cursor, Int(self.slots[i].write_remaining))
        if Int(n) < 0:
            if errno_now() == EINTR_CODE:
                return
            self.close_conn(i)
            return
        if Int(n) == 0:
            self.close_conn(i)
            return
        self.slots[i].write_off = self.slots[i].write_off + Int32(Int(n))
        self.slots[i].write_remaining = self.slots[i].write_remaining - Int32(Int(n))
        if Int(self.slots[i].write_remaining) == 0 and Int(self.slots[i].phase) == PHASE_WRITE_RESPONSE:
            self.release_dynamic(i)
            if self.slots[i].wants_close:
                self.close_conn(i)
            else:
                self.slots[i].phase = Int32(PHASE_PARSE_HEAD)
                self.slots[i].wants_close = False

    def advance_state[resolve: ResolverFn](
        mut self,
        routes: RouteTable,
        responses: ResponseSet,
        keys: RequestHeaderKeys,
        i: Int,
    ):
        """Run one connection's state machine as far as buffered bytes allow.

        Invariant: `moved` restarts the machine whenever a phase made
        progress, letting head-parse flow into body-drain and response-write
        within one event. The three `break`s are deliberate — an early
        `return` would skip normalize_buffer() below and let the read offset
        creep until healthy connections get killed at the cap (the exact bug
        documented as BENCHMARK.md caveat 3).
        """
        var moved = True
        while moved:
            if Int(self.slots[i].fd) < 0:
                return
            moved = False
            var buf = retracked(self.slots[i].recv_buf)
            var off = Int(self.slots[i].buf_off)
            var dl = Int(self.slots[i].data_len)
            if Int(self.slots[i].phase) == PHASE_PARSE_HEAD:
                var hend = find_header_end(buf, off, off + dl)
                if hend < 0:
                    if dl >= MAX_HEAD_BYTES:
                        self.close_conn(i)
                        return
                    break
                var head = parse_request_head(buf, off, hend, keys)
                var route_idx = routes.resolve_method(
                    buf, head.path_start, head.path_end, head.method_code
                )
                if route_idx >= 0 and routes.kind_at(route_idx) == ROUTE_DYNAMIC:
                    self.slots[i].dyn_route = Int32(route_idx)
                else:
                    self.slots[i].dyn_route = Int32(-1)
                self.slots[i].req_method = Int32(head.method_code)
                self.slots[i].req_start = Int32(off)
                self.slots[i].head_span = Int32((hend + 4) - off)
                self.slots[i].body_span = Int32(head.content_length)
                var chosen: ResponseBuffer
                if Int(self.slots[i].dyn_route) >= 0:
                    chosen = responses.at(-1)
                else:
                    chosen = responses.at(route_idx)
                self.slots[i].resp_data = chosen.data
                self.slots[i].resp_len = Int32(chosen.length)
                self.slots[i].body_remaining = Int32(head.content_length)
                if head.connection_close:
                    self.slots[i].wants_close = True
                var adv = (hend + 4) - off
                self.slots[i].buf_off = Int32(off + adv)
                self.slots[i].data_len = Int32(dl - adv)
                self.slots[i].phase = Int32(PHASE_READ_BODY)
                moved = True
            elif Int(self.slots[i].phase) == PHASE_READ_BODY:
                var take = min_int(Int(self.slots[i].data_len), Int(self.slots[i].body_remaining))
                if take > 0:
                    self.slots[i].buf_off = self.slots[i].buf_off + Int32(take)
                    self.slots[i].data_len = self.slots[i].data_len - Int32(take)
                    self.slots[i].body_remaining = self.slots[i].body_remaining - Int32(take)
                    moved = True
                if Int(self.slots[i].body_remaining) > 0:
                    break
                # body -> write: request fully consumed; dynamic routes get
                # one resolver shot at replacing the latched fallback, then
                # the first flush happens inline so tiny responses leave
                # without another poll cycle.
                if Int(self.slots[i].dyn_route) >= 0:
                    self.dispatch_dynamic[resolve](responses, i, buf)
                    if Int(self.slots[i].fd) < 0:
                        return
                self.slots[i].write_off = Int32(0)
                self.slots[i].write_remaining = self.slots[i].resp_len
                self.slots[i].phase = Int32(PHASE_WRITE_RESPONSE)
                self.flush_write(i)
                if Int(self.slots[i].fd) < 0:
                    return
                if Int(self.slots[i].write_remaining) > 0:
                    break
                moved = True
        self.normalize_buffer(i)

    def dispatch_dynamic[resolve: ResolverFn](
        mut self, responses: ResponseSet, i: Int, buf: BytePtr
    ):
        """Run the process resolver for slot i's just-consumed request.

        The head span is addressed FORWARD from req_start, the offset recorded
        when PARSE_HEAD consumed this request's head; the body span follows it
        contiguously. Forward addressing is what keeps split-segment arrivals
        correct: when the head and body land in separate recv events, the
        in-flight window is never compacted (normalize_buffer skips
        PHASE_READ_BODY), so req_start stays valid and buf_off — which only
        counts bytes up to the body's end — would NOT be a valid anchor for
        backwards recovery. On success the write targets are re-aimed at
        either a prebuilt buffer (static_route fast-return) or fresh resolver
        bytes (ownership tracked in dyn_owned); on any failure the latched
        fallback response stands.
        """
        var hs = Int(self.slots[i].req_start)
        var he = hs + Int(self.slots[i].head_span)
        var be = he + Int(self.slots[i].body_span)
        if hs < 0 or Int(self.slots[i].head_span) <= 0 or be > Int(self.slots[i].buf_off):
            return
        var out_buf = DynamicOut(data=null_bytes(), length=0, owns=False, static_route=-1)
        var ok = resolve(
            Int(self.slots[i].dyn_route),
            UInt8(Int(self.slots[i].req_method) & 0xFF),
            buf + hs,
            Int(self.slots[i].head_span),
            buf + he,
            Int(self.slots[i].body_span),
            out_buf,
        )
        if not ok:
            return
        if out_buf.static_route >= 0:
            var pre = responses.at(out_buf.static_route)
            self.slots[i].resp_data = pre.data
            self.slots[i].resp_len = Int32(pre.length)
            return
        if out_buf.length > 0:
            self.slots[i].dyn_data = out_buf.data
            self.slots[i].dyn_len = Int32(out_buf.length)
            self.slots[i].dyn_owned = out_buf.owns
            self.slots[i].resp_data = out_buf.data
            self.slots[i].resp_len = Int32(out_buf.length)

    def normalize_buffer(self, i: Int):
        """Compact the receive buffer so offsets never march past buf_cap.

        Skipped while a request is mid-flight (PHASE_READ_BODY: head consumed,
        body draining, resolver not yet run): the bytes from req_start through
        buf_off are the request the dispatcher will address by absolute offset,
        and resetting buf_off to zero on an empty tail would both orphan that
        anchor and let the next recv overwrite the head with body bytes —
        exactly the fresh-connection split-segment failure this slot field
        exists to prevent. buf_off stays bounded because recv_bytes never
        writes past buf_cap and every drained byte advances it.
        """
        if Int(self.slots[i].phase) == PHASE_READ_BODY:
            return
        var dl = Int(self.slots[i].data_len)
        if dl == 0:
            self.slots[i].buf_off = Int32(0)
        elif Int(self.slots[i].buf_off) > COMPACT_THRESHOLD:
            var buf = retracked(self.slots[i].recv_buf)
            var src = Int(self.slots[i].buf_off)
            var k = 0
            while k < dl:
                buf[k] = buf[src + k]
                k += 1
            self.slots[i].buf_off = Int32(0)

    def handle_readable[resolve: ResolverFn](
        mut self,
        routes: RouteTable,
        responses: ResponseSet,
        keys: RequestHeaderKeys,
        i: Int,
    ):
        """Read whatever arrived and push the state machine forward."""
        if Int(self.slots[i].fd) < 0:
            return
        var fd = self.slots[i].fd
        var buf = retracked(self.slots[i].recv_buf)
        var used = Int(self.slots[i].buf_off) + Int(self.slots[i].data_len)
        if used >= self.buf_cap:
            self.advance_state[resolve](routes, responses, keys, i)
            if Int(self.slots[i].fd) < 0:
                return
            if (Int(self.slots[i].buf_off) + Int(self.slots[i].data_len)) >= self.buf_cap:
                self.close_conn(i)
                return
            used = Int(self.slots[i].buf_off) + Int(self.slots[i].data_len)
        var n = recv_bytes(fd, buf + used, self.buf_cap - used)
        if Int(n) < 0:
            if errno_now() == EINTR_CODE:
                return
            self.close_conn(i)
            return
        if Int(n) == 0:
            self.close_conn(i)
            return
        self.slots[i].data_len = self.slots[i].data_len + Int32(Int(n))
        self.advance_state[resolve](routes, responses, keys, i)


def worker_config(port: Int, workers: Int) -> WorkerConfig:
    """Full config from port + worker count, filling safe defaults."""
    var w = workers
    if w < 1:
        w = 1
    return WorkerConfig(
        port=port,
        workers=w,
        backlog=DEFAULT_BACKLOG,
        buf_cap=DEFAULT_BUF_CAP,
        max_conns=DEFAULT_MAX_CONNS,
    )


def env_int(name: String, default_value: Int) -> Int:
    """Integer env var; non-digits ignored, zero falls back to the default."""
    var raw = getenv(name, "0")
    var parsed = 0
    for ch in raw:
        var d = ord(ch)
        if d >= 48 and d <= 57:
            parsed = parsed * 10 + Int(d - 48)
    if parsed == 0:
        return default_value
    return parsed


def worker_config_from_env(default_port: Int) -> WorkerConfig:
    """MOJOFLASK_PORT / MOJOFLASK_WORKERS driven config for drop-in deployments."""
    return worker_config(env_int("MOJOFLASK_PORT", default_port), env_int("MOJOFLASK_WORKERS", 1))


def conn_table(config: WorkerConfig) -> ConnTable:
    """Allocate the pool and park every slot in the empty state."""
    var capacity = config.max_conns
    var slots = Pointer[T=ConnState, mut=True, origin=UntrackedOrigin[mut=True]](
        unsafe_from_address=Int(malloc_bytes(CONN_SLOT_STRIDE * capacity))
    )
    var empty = ConnState(
        fd=Int32(-1),
        recv_buf=null_bytes(),
        has_recv_buf=False,
        buf_off=Int32(0),
        data_len=Int32(0),
        phase=Int32(-1),
        body_remaining=Int32(0),
        wants_close=False,
        resp_data=null_bytes(),
        resp_len=Int32(0),
        write_off=Int32(0),
        write_remaining=Int32(0),
        dyn_route=Int32(-1),
        req_method=Int32(0),
        req_start=Int32(0),
        head_span=Int32(0),
        body_span=Int32(0),
        dyn_data=null_bytes(),
        dyn_len=Int32(0),
        dyn_owned=False,
    )
    var j = 0
    while j < capacity:
        slots[j] = empty
        j += 1
    return ConnTable(
        slots=slots,
        capacity=capacity,
        buf_cap=config.buf_cap,
        poll_fds=malloc_pollfds(capacity + 1),
        poll_map=UntrackedInt32Ptr(unsafe_from_address=Int(malloc_bytes(4 * (capacity + 1)))),
    )


def reserve_low_descriptors():
    """Duplicate a spare socket 96 times and abandon the copies.

    Preserved verbatim from the prototype: occupying this block of low
    descriptor numbers before fork keeps later opens from landing on numbers
    that SCM_RIGHTS receivers might recycle mid-flight. Harmless leak.
    """
    var spare = open_socket()
    var guard = malloc_int32s(RESERVED_FD_GUARDS)
    var g = 0
    while g < RESERVED_FD_GUARDS:
        guard[g] = dup_fd(spare)
        g += 1


def acceptor_forever(listener: Int32, pairs: Int32Ptr, worker_count: Int):
    """Parent-side acceptor: hand every new fd to workers round-robin."""
    var next_worker = 0
    var single = malloc_pollfds(1)
    while True:
        single[0] = PollFd(fd=listener, events=POLLIN, revents=UInt16(0))
        var ready = wait_on_poll(single, 1)
        if ready <= 0:
            continue
        var cfd = accept_connection(listener)
        if Int(cfd) < 0:
            continue
        _ = send_fd(pairs[(next_worker % worker_count) * 2], cfd)
        close_fd(cfd)
        next_worker += 1


def worker_loop[resolve: ResolverFn](
    listener: Int32,
    pair_fd: Int32,
    config: WorkerConfig,
    routes: RouteTable,
    responses: ResponseSet,
    keys: RequestHeaderKeys,
):
    """Per-worker poll loop: harvest new fds, then dispatch conn events.

    Entry 0 of the poll array watches the fd source — the SCM_RIGHTS pair
    when fanned out, otherwise the listener directly. Remaining entries map
    through poll_map to ConnTable slots.
    """
    var conns = conn_table(config)
    var source_fd = listener
    if Int(pair_fd) >= 0:
        source_fd = pair_fd
    print("mojoflask worker pid=", current_pid(), " port=", config.port)
    while True:
        var count = 1
        conns.poll_fds[0] = PollFd(fd=source_fd, events=POLLIN, revents=UInt16(0))
        conns.poll_map[0] = Int32(-1)
        var j = 0
        while j < conns.capacity:
            var fd = conns.slots[j].fd
            if Int(fd) >= 0:
                var events: Int = Int(POLLIN)
                if Int(conns.slots[j].write_remaining) > 0:
                    events = events | Int(POLLOUT)
                conns.poll_fds[count] = PollFd(fd=fd, events=UInt16(events), revents=UInt16(0))
                conns.poll_map[count] = Int32(j)
                count += 1
            j += 1
        var ready = wait_on_poll(conns.poll_fds, count)
        if ready <= 0:
            continue
        if conns.poll_fds[0].revents != UInt16(0):
            var cfd = Int32(-1)
            if Int(pair_fd) >= 0:
                cfd = Int32(recv_fd(pair_fd))
            else:
                cfd = accept_connection(listener)
            if Int(cfd) >= 0:
                conns.register_connection(cfd)
        var q = 1
        while q < count:
            var rev = Int(conns.poll_fds[q].revents)
            if rev != 0:
                var idx = Int(conns.poll_map[q])
                if Int(conns.slots[idx].fd) >= 0:
                    if ((rev & Int(POLLNVAL)) != 0) or ((rev & Int(POLLERR)) != 0):
                        conns.close_conn(idx)
                    else:
                        if (rev & Int(POLLOUT)) != 0:
                            conns.flush_write(idx)
                        if Int(conns.slots[idx].fd) >= 0:
                            if ((rev & Int(POLLIN)) != 0) or ((rev & Int(POLLHUP)) != 0):
                                conns.handle_readable[resolve](routes, responses, keys, idx)
            q += 1


def _static_noop(
    route_index: Int,
    method_code: UInt8,
    req_head: BytePtr,
    head_len: Int,
    body: BytePtr,
    body_len: Int,
    mut out_buf: DynamicOut,
) -> Bool:
    """Stand-in resolver for static-only serve(); never reached because
    static tables register no ROUTE_DYNAMIC routes."""
    _ = route_index
    _ = method_code
    _ = req_head
    _ = head_len
    _ = body
    _ = body_len
    return False


def serve(config: WorkerConfig, routes: RouteTable, responses: ResponseSet):
    """Bind, optionally fork SCM_RIGHTS-fanned-out workers, and serve forever.

    Static-only entry point: every resolved route must be ROUTE_STATIC and
    backed by a prebuilt ResponseBuffer. Callers must build `routes` and
    `responses` BEFORE calling serve(): the forks below copy-on-write share
    those prebuilt buffers across workers, which is what keeps summed RSS low.
    Dynamic routes need serve_dynamic[] instead.
    """
    _serve_impl[_static_noop](config, routes, responses)


def serve_dynamic[resolve: ResolverFn](
    config: WorkerConfig, routes: RouteTable, responses: ResponseSet
):
    """serve() with THE one-per-process dynamic-route resolver attached.

    `resolve` is a comptime parameter because Mojo 1.0 cannot store function
    values in fields or globals; passing it here means exactly one resolver
    per process tree, installed before any request is served. Route indexes
    registered via RouteTable.add_dynamic / App.dynamic are handed to the
    resolver as its first argument — switch on them internally (see the
    module docstring for the full contract and the recv-buffer aliasing
    hazard). Static-only apps should keep plain serve().
    """
    _serve_impl[resolve](config, routes, responses)


def _serve_impl[resolve: ResolverFn](
    config: WorkerConfig, routes: RouteTable, responses: ResponseSet
):
    """Shared boot: signals, fd reservation, bind, fork fan-out, loops."""
    ignore_sigpipe()
    reserve_low_descriptors()

    var listener = create_listen_socket(config.port, config.backlog)
    if Int(listener) < 0:
        fatal("listen socket failed")

    var keys = standard_header_keys()

    if config.workers > 1:
        var pairs = malloc_int32s(2 * config.workers)
        var k = 0
        while k < config.workers:
            var sp = malloc_int32s(2)
            sp[0] = Int32(-1)
            sp[1] = Int32(-1)
            socketpair(sp)
            pairs[k * 2] = sp[0]
            pairs[k * 2 + 1] = sp[1]
            k += 1
        var my_pair = Int32(-1)
        var k2 = 0
        while k2 < config.workers:
            var child_pid = fork_process()
            if Int(child_pid) == 0:
                my_pair = pairs[k2 * 2 + 1]
                break
            if Int(child_pid) < 0:
                break
            k2 += 1
        if Int(my_pair) < 0:
            acceptor_forever(listener, pairs, config.workers)
            return
        worker_loop[resolve](listener, my_pair, config, routes, responses, keys)
        return
    worker_loop[resolve](listener, Int32(-1), config, routes, responses, keys)
