"""hello — minimal mojoflask app.

Serves two routes with responses serialized once at startup:

    GET /         -> {"message":"hello from mojoflask"}
    GET /health   -> {"status":"ok"}

Run:
    pixi run build-example && MOJOFLASK_PORT=8080 ./hello
"""

from mojoflask import App


def main():
    var app = App(port=18090)

    app.get("/", "{\"message\":\"hello from mojoflask\"}")
    app.get("/health", "{\"status\":\"ok\"}")
    app.fallback("{\"error\":\"not found\"}")

    app.run()
