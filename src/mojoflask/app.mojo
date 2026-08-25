"""app — the human-facing layer of mojoflask.

`App` owns the startup arena, the route table and the response set, so
application code never sees a pointer:

    var app = App(port=8080)
    app.get("/health", "{\\"status\\":\\"ok\\"}")
    app.get_file("/search", "payloads/search.json")
    app.fallback("{\\"error\\":\\"not found\\"}")
    app.run()

Every `get*` call registers the route AND its prebuilt response together,
which keeps their indexes in lockstep (the server looks responses up by
route index). Bodies passed as strings are serialized once here at startup;
bodies loaded from files stream through a private arena that is reused for
each subsequent file. After run() the hot path performs zero allocations.
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
from .router import RouteTable, route_table
from .server import WorkerConfig, serve, worker_config, worker_config_from_env


struct App(Movable):
    """A mojoflask application: routes + prebuilt responses + worker config."""

    var routes: RouteTable
    var responses: ResponseSet
    var config: WorkerConfig
    var arena: UntrackedBytePtr
    var arena_cap: Int
    var arena_used: Int

    def __init__(out self, port: Int = 18090, workers: Int = 1, arena_mb: Int = 4):
        self.routes = route_table()
        self.responses = response_set()
        self.config = worker_config(port, workers)
        self.arena_cap = arena_mb * 1024 * 1024
        self.arena_used = 0
        self.arena = untrack(malloc_bytes(self.arena_cap))

    def get(mut self, path: String, body: String) -> Int:
        """Serve `body` verbatim with status 200 on GET `path`."""
        return self.get_status(path, "200 OK", body)

    def get_status(mut self, path: String, status: String, body: String) -> Int:
        """Serve `body` verbatim with a custom status line on GET `path`."""
        var route = self.routes.add(path)
        var ptr: BytePtr = make_cstr(body)
        _ = self.responses.add(build_response(status, ptr, body.byte_length()))
        return route

    def get_file(mut self, path: String, file_path: String) -> Int:
        """Serve the bytes of `file_path` with status 200 on GET `path`.

        The file is read once into the App's startup arena and never touched
        again — requests are answered from the prebuilt response buffer.
        """
        var route = self.routes.add(path)
        if self.arena_used >= self.arena_cap:
            fatal("App arena exhausted; construct with a larger arena_mb")
        var dst: BytePtr = retracked(self.arena) + self.arena_used
        var n = read_file_into(file_path, dst, self.arena_cap - self.arena_used)
        _ = self.responses.add(build_response("200 OK", dst, n))
        self.arena_used += n
        return route

    def fallback(mut self, body: String):
        """Serve `body` with status 404 when no route matches."""
        var ptr: BytePtr = make_cstr(body)
        self.responses.set_fallback(build_response("404 Not Found", ptr, body.byte_length()))

    def run(self):
        """Bind, fork workers and enter the event loop. Never returns."""
        serve(self.config, self.routes, self.responses)

    def adopt_config(mut self, owned config: WorkerConfig):
        """Replace the worker config (used by app_from_env)."""
        self.config = config^


def app_from_env(default_port: Int, arena_mb: Int = 4) -> App:
    """Build an App whose port/workers come from ALUGUE_PORT/ALUGUE_WORKERS.

    Mirrors worker_config_from_env(); falls back to `default_port` and one
    worker when the environment variables are unset.
    """
    var app = App(port=0, workers=1, arena_mb=arena_mb)
    app.adopt_config(worker_config_from_env(default_port))
    return app^
