"""bench_echo — the 1-vs-N worker distribution harness.

Two routes, deliberately shaped like the API's two serving paths:

    GET /echo-static  a prebuilt ~1 KB response served straight from the
                      ResponseSet (the warm-cache/fast-return idiom)
    GET /echo-dyn     a dynamic route whose resolver builds a fresh ~1 KB
                      response PER REQUEST (owns=True) — the resolve_details
                      shape without any database

Run one configuration per process tree:

    pixi run build-bench-echo
    MOJOFLASK_PORT=18090 MOJOFLASK_WORKERS=1  ./build/bench_echo &
    wrk -t8 -c100 -d15s --latency http://127.0.0.1:18090/echo-static
    wrk -t8 -c100 -d15s --latency http://127.0.0.1:18090/echo-dyn

Then repeat with MOJOFLASK_WORKERS=16 on another port and diff RPS.
tools/bench_echo.sh drives the whole matrix in one shot.
"""

from mojoflask import (
    METHOD_GET,
    App,
    app_from_env,
    BytePtr,
    DynamicOut,
    build_response as build_resp,
    free_bytes as free_cstr,
    make_cstr,
)


comptime DYN_IDX = 2  # 0=/ 1=/echo-static registered before it, in order

comptime ECHO_BODY = (
    '{"id":2,"title":"Apartamento 2 quartos Vila Mariana - 944 byte payload"'
    ',"description":"bench_echo dyn resolver payload mirroring the details'
    ' response size class. 01234567890123456789012345678901234567890123456789'
    '012345678901234567890123456789012345678901234567890123456789012345678901'
    '234567890123456789012345678901234567890123456789012345678901234567890123'
    '456789012345678901234567890123456789012345678901234567890123456789012345'
    '678901234567890123456789012345678901234567890123456789012345678901234567'
    '8901234567890123456789012345678901234567890123456789","ok":true}'
)


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
    if route_index == DYN_IDX:
        var msg = make_cstr(String(ECHO_BODY))
        var rb = build_resp("200 OK", msg, String(ECHO_BODY).byte_length())
        out_buf.data = rb.data
        out_buf.length = rb.length
        out_buf.owns = True
        out_buf.static_route = -1
        free_cstr(msg)
        return True
    return False


def main():
    var app = app_from_env(18090)
    app.get("/", "{\"message\":\"bench_echo\"}")
    app.get("/echo-static", String(ECHO_BODY))
    app.dynamic(METHOD_GET, "/echo-dyn")
    app.fallback("{\"error\":\"not found\"}")
    app.run_dynamic[resolve]()
