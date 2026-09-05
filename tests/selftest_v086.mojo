"""Selftest for the v0.8.6 absorption: the IncomingRequest carrier moved
verbatim from the application (route index, method code, raw head/body
spans) and the serve_family trampoline that forwards a carrier to the
comptime-resolved FamilyResolverFn."""

from mojoflask import (
    METHOD_QUERY,
    DynamicOut,
    IncomingRequest,
    UntrackedBytePtr,
    null_bytes,
    serve_family,
)


comptime PROBE_HEAD = "GET /search/nearby?skip=0 HTTP/1.1"

comptime PROBE_BODY = "hello"


def probe_family_resolver(
    request: IncomingRequest, mut out_buffer: DynamicOut
) -> Bool:
    out_buffer.static_route = 900 + request.route_index
    out_buffer.length = Int(request.method_code)
    return (
        request.method_code == METHOD_QUERY
        and request.head_length == PROBE_HEAD.byte_length()
        and request.body_length == PROBE_BODY.byte_length()
    )


def refused_family_resolver(
    request: IncomingRequest, mut out_buffer: DynamicOut
) -> Bool:
    _ = request
    _ = out_buffer
    return False


struct Harness(Movable):
    var passes: Int
    var failures: List[String]

    def __init__(out self):
        self.passes = 0
        self.failures = List[String]()

    def check(mut self, name: String, ok: Bool):
        self.passes += Int(ok)
        if not ok:
            self.failures.append(name)


def main() raises:
    var harness = Harness()

    # --- incoming_request: carrier constructs with raw spans ---------------
    var probe_request = IncomingRequest(
        route_index=4,
        method_code=METHOD_QUERY,
        head=UntrackedBytePtr(
            unsafe_from_address=Int(PROBE_HEAD.as_bytes().unsafe_ptr())
        ),
        head_length=PROBE_HEAD.byte_length(),
        body=UntrackedBytePtr(
            unsafe_from_address=Int(PROBE_BODY.as_bytes().unsafe_ptr())
        ),
        body_length=PROBE_BODY.byte_length(),
    )
    harness.check(
        "carrier keeps route index and method code",
        probe_request.route_index == 4
        and probe_request.method_code == METHOD_QUERY,
    )
    harness.check(
        "carrier head span reads back the request head",
        String(
            unsafe_from_utf8=Span[Byte](
                unsafe_ptr=probe_request.head,
                length=probe_request.head_length,
            )
        )
        == String(PROBE_HEAD),
    )
    harness.check(
        "carrier body span reads back the request body",
        String(
            unsafe_from_utf8=Span[Byte](
                unsafe_ptr=probe_request.body,
                length=probe_request.body_length,
            )
        )
        == String(PROBE_BODY),
    )
    harness.check(
        "carrier copies and moves without detaching spans",
        probe_request.copy().head_length == PROBE_HEAD.byte_length(),
    )

    # --- incoming_request: serve_family dispatches a probe -----------------
    var dispatched_out = DynamicOut(
        data=null_bytes(), length=0, owns=False, static_route=-2
    )
    var dispatched = serve_family[probe_family_resolver](
        probe_request, dispatched_out
    )
    harness.check(
        "serve_family forwards the carrier to the family resolver",
        dispatched and dispatched_out.static_route == 904,
    )
    harness.check(
        "resolver mutations of the output slot reach the caller",
        dispatched_out.length == Int(METHOD_QUERY)
        and not dispatched_out.owns,
    )

    var refused_out = DynamicOut(
        data=null_bytes(), length=0, owns=False, static_route=-2
    )
    var refused = serve_family[refused_family_resolver](
        probe_request, refused_out
    )
    harness.check(
        "serve_family returns the resolver verdict unchanged",
        not refused and refused_out.static_route == -2,
    )

    var failure_names = harness.failures.copy()
    var failure_count = len(failure_names)
    print("PASS", harness.passes, "/", harness.passes + failure_count)
    for failed_name in failure_names^:
        print("FAIL:", failed_name)
    if failure_count > 0:
        raise Error("mojoflask v0.8.6 selftest failures")
