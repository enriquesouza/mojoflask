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
fall through to the fallback response. Bodies passed as strings are
serialized once here at startup; bodies loaded from files stream through a
private arena that is reused for each subsequent file. After run() the hot
path performs zero allocations.
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
from .http import ResponseSet, build_response, response_set
from .router import (
    METHOD_GET,
    METHOD_POST,
    METHOD_PUT,
    METHOD_PATCH,
    METHOD_DELETE,
    RouteTable,
    route_table,
)
from .server import WorkerConfig, serve, worker_config, worker_config_from_env


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
        var route = self.routes.add_method(METHOD_GET, path)
        if self.arena_used >= self.arena_cap:
            fatal("App arena exhausted; construct with a larger arena_mb")
        var dst: BytePtr = retracked(self.arena) + self.arena_used
        var n = read_file_into(file_path, dst, self.arena_cap - self.arena_used)
        _ = self.responses.add(build_response("200 OK", dst, n, self.server_name))
        self.arena_used += n
        return route

    def fallback(mut self, body: String):
        """Serve `body` with status 404 when no route matches."""
        var ptr: BytePtr = make_cstr(body)
        self.responses.set_fallback(
            build_response("404 Not Found", ptr, body.byte_length(), self.server_name)
        )

    def run(self):
        """Bind, fork workers and enter the event loop. Never returns."""
        serve(self.config, self.routes, self.responses)


def app_from_env(default_port: Int, arena_mb: Int = 4, server_name: String = "mojoflask") -> App:
    """Build an App whose port/workers come from MOJOFLASK_PORT/MOJOFLASK_WORKERS.

    Mirrors worker_config_from_env(); falls back to `default_port` and one
    worker when the environment variables are unset.
    """
    var app = App(port=default_port, arena_mb=arena_mb, read_env=True, server_name=server_name)
    return app^
