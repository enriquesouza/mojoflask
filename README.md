# mojoflask

A small HTTP server library for **Mojo 1.0** whose serving hot path performs
**zero per-request allocation**: every response is a fully serialized byte
buffer built once at startup, then written by pointer forever after.

Think of it as the fast lane between Fiber/Axum ergonomics and a raw-socket
benchmark server. 

## Status

v0.3.0 — working, benchmarked, macOS arm64 first. Linux (epoll) is untested;
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

## Usage (request bodies)

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
| `router.mojo` | pattern strings -> segment matchers (`literal`, `{name}` any, `{name:d}` digits) with per-route method masks; resolution is a linear segment walk, no allocations |
| `server.mojo` | connection state pool, poll(2) event loop, pre-fork acceptor that round-robins accepted fds to workers over Unix socketpairs, keep-alive state machine |

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
mojoflask/router.mojo     RouteTable
mojoflask/server.mojo     event loop + workers + serve()
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
