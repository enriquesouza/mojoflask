# mojoflask

A small HTTP server library for **Mojo 1.0** whose serving hot path performs
**zero per-request allocation**: every response is a fully serialized byte
buffer built once at startup, then written by pointer forever after.

Think of it as the fast lane between Fiber/Axum ergonomics and a raw-socket
benchmark server. 

## Status

v0.5.0 — working, benchmarked, macOS arm64 first. Linux (epoll) is untested;
the poll(2) core is POSIX so porting is mostly FFI constants.

## Usage (App layer)

`App` registers route + prebuilt response together, one verb helper each:

```mojo
from mojoflask import App


def main():
    var app = App(port=8080)
    app.get("/health", "{\"status\":\"ok\"}")
    app.post("/echo-note", "{\"note\":\"received\"}")   # POST-only
    app.put("/items", "{}")
    app.patch("/items", "{}")
    app.delete_route("/items", "{}")                    # DELETE (keyword-safe name)
    app.fallback("{\"error\":\"not found\"}")           # 404 for misses
    app.run()
```

Each verb binds its route to that HTTP method's mask; a request with a
different verb on the same path falls through to the fallback response.
`app.get_file(path, file)` and `app.get_status(path, status, body)` stay
string/file-flavored; `app.route(mask, path, status, body)` and
`app.route_file(mask, path, status, file)` take an explicit METHOD_* mask
(e.g. `METHOD_GET | METHOD_QUERY`) for combined-verb handlers and non-200
write statuses. `get_file` is GET-bound. Under the hood routes carry method
bitmasks (`METHOD_GET`,
`METHOD_POST`, `METHOD_PUT`, `METHOD_PATCH`, `METHOD_DELETE`, `METHOD_QUERY`,
or `METHOD_ANY`), and `RouteTable.add_method(mask, pattern)` exposes them to
raw-table users while `routes.add(pattern)` keeps accepting any method.

Method codes are computed from the bytes of the existing request-line scan —
routing stays allocation-free and adds no extra parsing pass.

The search-cache substrate (FNV-1a keyed TTL slot cache) lives in the
standalone [mojoka](https://github.com/enriquesouza/mojoka) package as of
v0.6.0 — mojoflask itself no longer ships it.

## Usage (request bodies)

Bodies are drained in full up to the declared Content-Length before any
response is written or a resolver runs — close(2) with unread receive data
emits a TCP reset that destroys the in-flight response, which is exactly what
pre-0.7.1 did to any request whose head+body exceeded the 32KB receive buffer
(RST at ~32-64KB and up; long-standing, present since v0.6.3). Engine bounds:
a Content-Length above `MAX_BODY_BYTES` (10MB) is rejected at head parse with
a connection close mirroring the `MAX_HEAD_BYTES` (30KB) header rejection, and
each body read must make progress within 3 seconds (`DRAIN_IDLE_MS`) or the
connection is evicted — with v0.7.0's read-idle timer gone, that deadline is
the de-facto read timeout for the whole request. The receive buffer grows
once (bounded, re-anchoring the in-flight request) so a 10MB body can drain
through a 32KB buffer; grown buffers are released when the connection closes.
Pipelined bursts (hundreds of requests in one send) still drain in a single
pass without growth.

`parse_json_body` decodes a flat JSON body into a `ParsedBody` register struct
using [EmberJson](https://github.com/bgreni/EmberJson). Unknown keys are
ignored, missing keys keep their defaults (`limit=12`, `page=1`, lat/lng `0`,
`has_geo=False`, `ok=False`), numbers-as-strings are accepted, and any
malformed payload or non-object document yields the defaults with `ok=False`.

```mojo
from mojoflask import BytePtr, parse_json_body

def handle(body: BytePtr, body_len: Int) -> Int:
    var b = parse_json_body(body, body_len)
    if not b.ok:
        return 400
    if b.has_geo:
        return b.limit * (Int(b.lat) + 1)
    return b.limit * b.page
```

## Usage (dynamic routes)

Static routes serve prebuilt buffers with zero per-request allocation. When
you need code to run per request — cache miss → DB query → fresh response —
register a **dynamic route** and attach ONE process resolver. Mojo 1.0 cannot
store function values in fields or globals, so the resolver is a comptime
parameter on the serving entry point (`run_dynamic[resolve]`): exactly one
resolver per worker tree, installed before any request is served, switching
on `route_index` internally.

```mojo
from mojoflask import App, BytePtr, DynamicOut, METHOD_GET, build_response, free_bytes, make_cstr

comptime IDX_FRESH = 4   # deterministic: registration order

def resolve(route_index: Int, method_code: UInt8, req_head: BytePtr,
            head_len: Int, body: BytePtr, body_len: Int,
            mut out_buf: DynamicOut) -> Bool:
    if route_index == IDX_FRESH:
        var msg = make_cstr("{\"fresh\":true}")
        var rb = build_response("200 OK", msg, 15)
        out_buf = DynamicOut(data=rb.data, length=rb.length, owns=True, static_route=-1)
        free_bytes(msg)                      # build_response copied it
        return True                          # engine frees rb after write
    return False                             # -> fallback response

def main():
    var app = App(port=8080)
    app.dynamic(METHOD_GET, "/fresh")        # consumes no ResponseSet slot
    app.fallback("{\"error\":\"not found\"}")
    app.run_dynamic[resolve]()               # plain run() would 404 instead
```

The resolver receives raw spans of the head and body **inside the connection
receive buffer** — copy anything you keep past your return (aliasing hazard).
Returning `False`, or `True` with an empty payload, serves the fallback.

**Warm-cache fast-return idiom:** set `out_buf.static_route` (default `-1`)
to any existing prebuilt route index and the engine serves that buffer with
zero allocation and zero ownership bookkeeping — hit → cached buffer, miss →
fresh bytes, in one resolver:

```mojo
    if cache_hit():
        out_buf = DynamicOut(data=null_bytes(), length=0, owns=False,
                             static_route=IDX_CACHED)
        return True
```

Owned payloads (`owns=True`) are freed by the engine when the write finishes
or the connection dies; partial sends resume from the same dynamic bytes.

## Usage (the Fiber comparison)

Go + Fiber:

```go
app := fiber.New()
app.Get("/:lang/api/listings/:id", handler)
app.Listen(":8080")
```

mojoflask — same shape, one mental-model change: instead of a handler that
runs per request, you register **prebuilt responses** per route. Routing still
happens per request; serialization does not.

```mojo
from mojoflask import (
    BytePtr, ResponseBuffer, build_response, make_cstr,
    response_set, route_table, serve, worker_config_from_env,
)

def static_response(status: String, body: String) -> ResponseBuffer:
    var ptr: BytePtr = make_cstr(body)
    return build_response(status, ptr, body.byte_length())

def main():
    var routes = route_table()
    _ = routes.add("/{lang}/api/listings/{id:d}")   # :d = digits wildcard
    _ = routes.add("/health")                        # literal segments

    var responses = response_set()
    _ = responses.add(static_response("200 OK", "{\"status\":\"ok\"}"))
    responses.set_fallback(static_response("404 Not Found", "{\"error\":\"not found\"}"))

    serve(worker_config_from_env(8080), routes, responses)
```

Run it:

```sh
pixi install                       # or use system mojo >= 1.0.0
pixi run build-example
MOJOFLASK_PORT=8080 ./hello
curl localhost:8080/health
```

`MOJOFLASK_PORT` sets the port, `MOJOFLASK_WORKERS` the pre-forked worker count
(default 1; each worker is a full event loop sharing the listener via fd
passing).

## When to use it

- Responses are cacheable / computable at startup (JSON envelopes, rendered pages, health checks)
- You need maximum RPS and minimum tail latency on modest hardware
- You are comfortable owning your payload pipeline (EmberJson serializes once, mojoflask serves forever)

Not yet for: per-request dynamic bodies (handler closures are the roadmap to
that), TLS, HTTP/2 — put nginx/Caddy in front if you need those today.

## Architecture

| module | role |
|---|---|
| `bodyjson.mojo` | EmberJson-backed flat request-body decoding into a register struct; ASCII scanners cover numbers-as-strings |
| `ffi.mojo` | every libc/POSIX touchpoint: sockets, malloc, errno, poll structs, SCM_RIGHTS fd passing. All Darwin quirks documented inline. |
| `http.mojo` | HTTP/1.1 head parsing (method code, path, Content-Length, Connection) and response assembly |
| `reqscan.mojo` | request-head scanning over raw (BytePtr, head_len) spans: query-text range, first-match query-parameter lookup, nth path segment, body-span views |
| `router.mojo` | pattern strings -> segment matchers (`literal`, `{name}` any, `{name:d}` digits) with per-route method masks; resolution is a linear segment walk, no allocations |
| `server.mojo` | connection state pool, poll(2) event loop, pre-fork acceptor that round-robins accepted fds to workers over Unix socketpairs, keep-alive state machine |
| `text.mojo` | ASCII text normalization: whitespace-class trims, ASCII-only lowercasing, fold, StaticString literal compares over byte ranges, byte-range String materialization, validating UTF-8 rune decode |

### Darwin quirks encoded here (read before porting)

- macOS `SO_REUSEPORT` does **not** load-balance listeners (last binder wins),
  so the parent process accepts and distributes connections via
  `sendmsg`/`SCM_RIGHTS`; on Linux you could skip that, we don't yet.
- `fcntl` variadic args mangle through Mojo's C-FFI, so sockets stay blocking
  and every syscall is gated behind a `poll` readiness event.
- `SIGPIPE` is ignored at startup; writes to dead peers return errors instead
  of killing the worker.
- `EAGAIN=35`, `EINTR=4`, `SO_REUSEPORT=0x200` are hardcoded Darwin values.

## Layout

```
mojoflask/__init__.mojo   public API surface
mojoflask/bodyjson.mojo   request-body JSON (EmberJson)
mojoflask/ffi.mojo        libc layer (the only ugly file, quarantined)
mojoflask/http.mojo       parsing + assembly
mojoflask/reqscan.mojo    request-head scanners (query text, params, path segments)
mojoflask/router.mojo     RouteTable
mojoflask/server.mojo     event loop + workers + serve()
mojoflask/text.mojo       text normalization + UTF-8 rune decode
examples/hello.mojo           minimal app
```

### Dependency note

The `emberjson` dependency comes from the prebuilt package on the
`modular-community` conda channel (same 0.3.4 tag as upstream). Building it as
a nested pixi git dependency (`git = ".../EmberJson.git", tag = "0.3.4"`)
currently fails: EmberJson's source does not compile under a source build in
this workspace (`InlineArray` unknown declaration + deprecation errors in its
`_deserialize` modules), so the prebuilt artifact is used instead.

## Roadmap

1. Handler closures (`routes.get(pattern, fn)` with a request context struct)
2. Linux CI + epoll constants audit
3. Response streaming (chunked) for bodies larger than memory
4. Optional brotli/gzip of prebuilt buffers at startup

## License

MIT
