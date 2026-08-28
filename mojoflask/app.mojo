"""app — the human-facing layer of mojoflask.

`App` owns the startup arena, the route table and the response set, so
application code never sees a pointer:

    var app = App(port=8080)
    app.get("/health", "{\\"status\\":\\"ok\\"}")
    app.get_file("/search", "payloads/search.json")
    app.fallback("{\\"error\\":\\"not found\\"}")
    app.run()

Every verb helper (`get`, `post`, `put`, `patch`, `delete_route`) registers
the route AND its prebuilt response together, which keeps their indexes in
lockstep (the server looks responses up by route index). Routes are bound to
their verb's method mask; requests using a different verb on the same path
fall through to the fallback response. `route`/`route_file` take an explicit
METHOD_* mask for combined-verb handlers and non-200 write statuses. Bodies
passed as strings are serialized once here at startup; bodies loaded from
files stream through a private arena that is reused for each subsequent file.
After run() the hot path performs zero allocations.
"""

from .ffi import (
    BytePtr,
    UntrackedBytePtr,
    fatal,
    make_cstr,
    malloc_bytes,
    read_file_into,
    retracked,
    untrack,
)
from .http import (
    ResponseBuffer,
    ResponseSet,
    build_response,
    build_response_exact,
    response_set,
)
from .router import (
    METHOD_GET,
    METHOD_POST,
    METHOD_PUT,
    METHOD_PATCH,
    METHOD_DELETE,
    RouteTable,
    route_table,
)
from .server import (
    DynamicOut,
    ResolverFn,
    WorkerConfig,
    serve,
    serve_dynamic,
    worker_config,
    worker_config_from_env,
)


struct App(Movable):
    """A mojoflask application: routes + prebuilt responses + worker config."""

    var routes: RouteTable
    var responses: ResponseSet
    var config: WorkerConfig
    var server_name: String
    var arena: UntrackedBytePtr
    var arena_cap: Int
    var arena_used: Int

    def __init__(
        out self,
        port: Int = 18090,
        workers: Int = 1,
        arena_mb: Int = 4,
        read_env: Bool = False,
        server_name: String = "mojoflask",
    ):
        self.server_name = server_name
        self.routes = route_table()
        self.responses = response_set()
        if read_env:
            self.config = worker_config_from_env(port)
        else:
            self.config = worker_config(port, workers)
        self.arena_cap = arena_mb * 1024 * 1024
        self.arena_used = 0
        self.arena = untrack(malloc_bytes(self.arena_cap))

    def get(mut self, path: String, body: String) -> Int:
        """Serve `body` verbatim with status 200 on GET `path`."""
        return self.get_status(path, "200 OK", body)

    def get_status(mut self, path: String, status: String, body: String) -> Int:
        """Serve `body` verbatim with a custom status line on GET `path`."""
        return self._register(METHOD_GET, path, status, body)

    def post(mut self, path: String, body: String) -> Int:
        """Serve `body` verbatim with status 200 on POST `path`.

        Same lockstep registration as get(): the route index and its prebuilt
        response share one slot. Other verbs on this path fall through to the
        fallback response.
        """
        return self._register(METHOD_POST, path, "200 OK", body)

    def put(mut self, path: String, body: String) -> Int:
        """Serve `body` verbatim with status 200 on PUT `path`."""
        return self._register(METHOD_PUT, path, "200 OK", body)

    def patch(mut self, path: String, body: String) -> Int:
        """Serve `body` verbatim with status 200 on PATCH `path`."""
        return self._register(METHOD_PATCH, path, "200 OK", body)

    def delete_route(mut self, path: String, body: String) -> Int:
        """Serve `body` verbatim with status 200 on DELETE `path`.

        Named delete_route instead of delete to stay clear of reserved-word
        territory across Mojo tooling.
        """
        return self._register(METHOD_DELETE, path, "200 OK", body)

    def _register(mut self, mask: UInt8, path: String, status: String, body: String) -> Int:
        """Bind one method mask to a pattern and prebuild its response.

        Single funnel for every verb helper; keeps route and response indexes
        in lockstep because each call appends to both tables.
        """
        var route = self.routes.add_method(mask, path)
        var ptr: BytePtr = make_cstr(body)
        _ = self.responses.add(
            build_response(status, ptr, body.byte_length(), self.server_name)
        )
        return route

    def get_file(mut self, path: String, file_path: String) -> Int:
        """Serve the bytes of `file_path` with status 200 on GET `path`.

        The file is read once into the App's startup arena and never touched
        again — requests are answered from the prebuilt response buffer.
        """
        return self._register_file(METHOD_GET, path, "200 OK", file_path)

    def get_file_status(
        mut self, path: String, status: String, file_path: String
    ) -> Int:
        """Serve the bytes of `file_path` with a custom status on GET `path`."""
        return self._register_file(METHOD_GET, path, status, file_path)

    def route(mut self, mask: UInt8, path: String, status: String, body: String) -> Int:
        """Bind an explicit METHOD_* mask to a pattern and a string body.

        Escape hatch for combinations the verb helpers don't name: combined
        masks (METHOD_GET | METHOD_QUERY) and non-200 statuses on writes.
        """
        return self._register(mask, path, status, body)

    def route_file(
        mut self, mask: UInt8, path: String, status: String, file_path: String
    ) -> Int:
        """Bind an explicit METHOD_* mask to a pattern and a file-backed body."""
        return self._register_file(mask, path, status, file_path)

    def dynamic(mut self, mask: UInt8, path: String) -> Int:
        """Register a per-request (dynamic) route; returns its route index.

        The route consumes a PLACEHOLDER response slot (a zero-length buffer
        that is never served — the engine answers matched dynamic routes
        through the resolver or the fallback, never this slot), so route and
        response indexes stay in lockstep for every static route registered
        after it. When a request matches, the engine invokes THE process
        resolver with the raw request head/body spans; the resolver answers
        with fresh bytes or a static_route fast-return. Run the app through
        run_dynamic[resolver] so that resolver is attached; under plain run()
        matching this route serves the fallback response.
        """
        var route = self.routes.add_dynamic(mask, path)
        var placeholder: BytePtr = make_cstr("")
        _ = self.responses.add(
            build_response("200 OK", placeholder, 0, self.server_name)
        )
        free_bytes(placeholder)
        return route

    def _register_file(
        mut self, mask: UInt8, path: String, status: String, file_path: String
    ) -> Int:
        """File-backed twin of _register: read once, prebuild, keep indexes in
        lockstep.

        The body streams straight from disk into the startup arena, so large
        payloads are never copied through a second buffer.
        """
        var route = self.routes.add_method(mask, path)
        if self.arena_used >= self.arena_cap:
            fatal("App arena exhausted; construct with a larger arena_mb")
        var dst: BytePtr = retracked(self.arena) + self.arena_used
        var n = read_file_into(file_path, dst, self.arena_cap - self.arena_used)
        _ = self.responses.add(build_response(status, dst, n, self.server_name))
        self.arena_used += n
        return route

    def fallback_exact(
        mut self, status_line: String, body: String, content_type: String
    ):
        """Serve a raw prebuilt fallback: no Server header, the exact
        Content-Type given (empty = omit). For canonical zero-byte 404s."""
        var ptr: BytePtr = make_cstr(body)
        self.responses.set_fallback(
            build_response_exact(
                status_line, ptr, body.byte_length(), content_type, False
            )
        )
        free_bytes(ptr)

    def fallback(mut self, body: String):
        """Serve `body` with status 404 when no route matches."""
        var ptr: BytePtr = make_cstr(body)
        self.responses.set_fallback(
            build_response("404 Not Found", ptr, body.byte_length(), self.server_name)
        )

    def run(self):
        """Bind, fork workers and enter the event loop. Never returns.

        Static-only entry point; dynamic routes fall back to the 404.
        """
        serve(self.config, self.routes, self.responses)

    def run_dynamic[resolve: ResolverFn](self):
        """Bind, fork workers and serve with `resolve` as THE dynamic hook.

        Mojo 1.0 cannot store function values in fields or globals, so the
        one-per-process resolver is a comptime parameter — installed once for
        the whole worker tree before any request is served. It receives each
        dynamic route's index as its first argument and switches on it
        internally (see mojoflask.server for the full contract). Never
        returns.
        """
        serve_dynamic[resolve](self.config, self.routes, self.responses)


def app_from_env(default_port: Int, arena_mb: Int = 4, server_name: String = "mojoflask") -> App:
    """Build an App whose port/workers come from MOJOFLASK_PORT/MOJOFLASK_WORKERS.

    Mirrors worker_config_from_env(); falls back to `default_port` and one
    worker when the environment variables are unset.
    """
    var app = App(port=default_port, arena_mb=arena_mb, read_env=True, server_name=server_name)
    return app^
