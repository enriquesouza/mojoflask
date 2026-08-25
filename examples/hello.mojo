"""hello — minimal mojoflask app, the Mojo equivalent of `fiber.New()`.

Serves two routes with responses serialized once at startup:

    GET /         -> {"message":"hello from mojoflask"}
    GET /health   -> {"status":"ok"}

Run:
    mojo build -I src examples/hello.mojo -o hello && ALUGUE_PORT=8080 ./hello
"""

from mojoflask import (
    BytePtr,
    ResponseBuffer,
    build_response,
    make_cstr,
    response_set,
    route_table,
    serve,
    worker_config_from_env,
)


comptime HELLO_BODY = "{\"message\":\"hello from mojoflask\"}"
comptime HEALTH_BODY = "{\"status\":\"ok\"}"


def static_response(status: String, body: String) -> ResponseBuffer:
    """Serialize one literal JSON body into a reusable HTTP buffer."""
    var ptr: BytePtr = make_cstr(body)
    return build_response(status, ptr, body.byte_length())


def main():
    var routes = route_table()
    _ = routes.add("/")
    _ = routes.add("/health")

    var responses = response_set()
    _ = responses.add(static_response("200 OK", HELLO_BODY))
    _ = responses.add(static_response("200 OK", HEALTH_BODY))
    responses.set_fallback(static_response("404 Not Found", "{\"error\":\"not found\"}"))

    var config = worker_config_from_env(18090)
    serve(config, routes, responses)
