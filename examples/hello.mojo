"""hello — minimal mojoflask app.

Serves three routes with responses serialized once at startup:

    GET  /            -> {"message":"hello from mojoflask"}
    GET  /health      -> {"status":"ok"}
    POST /echo-note   -> {"note":"received"}   (GET on it falls to the 404)

Run:
    pixi run build-example && MOJOFLASK_PORT=8080 ./hello
"""

from mojoflask import App


def main():
    var app = App(port=18090)

    app.get("/", "{\"message\":\"hello from mojoflask\"}")
    app.get("/health", "{\"status\":\"ok\"}")
    app.post("/echo-note", "{\"note\":\"received\"}")
    app.fallback("{\"error\":\"not found\"}")

    app.run()
