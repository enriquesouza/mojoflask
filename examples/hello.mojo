"""hello — minimal mojoflask app.

Static routes are answered from buffers serialized once at startup:

    GET  /            -> {"message":"hello from mojoflask"}
    GET  /health      -> {"status":"ok"}
    POST /echo-note   -> {"note":"received"}   (GET on it falls to the 404)
    GET  /warmed      -> {"served":"from-prebuilt-via-static-route"}

Dynamic routes run code per request through THE single process resolver
(attached via run_dynamic[resolve]; it switches on route_index internally,
so the indexes below are deterministic by registration order):

    GET  /time-dyn    -> fresh JSON built per request (owns=True payload)
    GET  /warm-dyn    -> resolver returns static_route = /warmed's index,
                         so the engine serves that prebuilt buffer with zero
                         allocation (the warm-cache fast-return idiom)

Run:
    pixi run build-example && MOJOFLASK_PORT=8080 ./hello
"""

from mojoflask import (
    App,
    BytePtr,
    DynamicOut,
    METHOD_GET,
    build_response,
    free_bytes,
    make_cstr,
    null_bytes,
)


comptime WARMED_IDX = 3
comptime TIME_DYN_IDX = 4
comptime WARM_DYN_IDX = 5

comptime TIME_BODY = "{\"route\":\"/time-dyn\",\"hook\":\"dynamic\"}"


def resolve(
    route_index: Int,
    method_code: UInt8,
    req_head: BytePtr,
    head_len: Int,
    body: BytePtr,
    body_len: Int,
    mut out_buf: DynamicOut,
) -> Bool:
    _ = method_code
    _ = req_head
    _ = head_len
    _ = body
    _ = body_len
    if route_index == TIME_DYN_IDX:
        var msg = make_cstr(String(TIME_BODY))
        var rb = build_response("200 OK", msg, String(TIME_BODY).byte_length())
        out_buf = DynamicOut(data=rb.data, length=rb.length, owns=True, static_route=-1)
        free_bytes(msg)
        return True
    if route_index == WARM_DYN_IDX:
        out_buf = DynamicOut(
            data=null_bytes(),
            length=0,
            owns=False,
            static_route=WARMED_IDX,
        )
        return True
    return False


def main():
    var app = App(port=18090)

    app.get("/", "{\"message\":\"hello from mojoflask\"}")
    app.get("/health", "{\"status\":\"ok\"}")
    app.post("/echo-note", "{\"note\":\"received\"}")
    app.get("/warmed", "{\"served\":\"from-prebuilt-via-static-route\"}")
    app.dynamic(METHOD_GET, "/time-dyn")
    app.dynamic(METHOD_GET, "/warm-dyn")
    app.fallback("{\"error\":\"not found\"}")

    app.run_dynamic[resolve]()
    app.run()
