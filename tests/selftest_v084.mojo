"""Selftest for the v0.8.4 request-identity addition: the x-request-id
placeholder baked by the response builders, the in-place refresh that keeps
prebuilt responses per-request, and the fixed-width identity shape."""

from mojoflask import (
    BytePtr,
    REQUEST_IDENTITY_KEY,
    REQUEST_IDENTITY_PLACEHOLDER_LINE,
    build_response_exact,
    fixed_width_request_identity,
    refresh_response_request_identity,
)


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

    var placeholder = REQUEST_IDENTITY_PLACEHOLDER_LINE
    var placeholder_bytes = placeholder.as_bytes()

    var baked = build_response_exact(
        "200 OK",
        BytePtr(unsafe_from_address=Int(placeholder_bytes.unsafe_ptr())),
        0,
        "application/json",
        False,
    )

    var fresh_one = fixed_width_request_identity()
    var baked_head = String(
        unsafe_from_utf8=Span[Byte](
            unsafe_ptr=baked.data, length=Int(baked.length)
        )
    )
    harness.check(
        "builder bakes the placeholder line",
        placeholder in baked_head,
    )
    harness.check(
        "builder tail exposes x-request-id",
        baked_head.find("Access-Control-Expose-Headers: retry-after,x-request-id") >= 0,
    )

    _ = fresh_one
    refresh_response_request_identity(baked.data, Int(baked.length))
    var refreshed_head = String(
        unsafe_from_utf8=Span[Byte](
            unsafe_ptr=baked.data, length=Int(baked.length)
        )
    )
    var first_start = refreshed_head.find(REQUEST_IDENTITY_KEY) + len(
        REQUEST_IDENTITY_KEY.as_bytes()
    )
    _ = first_start
    var identity_one = refreshed_head[byte=first_start : first_start + 27]
    harness.check(
        "refreshed identity is hex-hex shaped",
        identity_one.byte_length() == 27
        and identity_one.find("-") == 13,
    )

    refresh_response_request_identity(baked.data, Int(baked.length))
    var refreshed_twice = String(
        unsafe_from_utf8=Span[Byte](
            unsafe_ptr=baked.data, length=Int(baked.length)
        )
    )
    var second_start = refreshed_twice.find(REQUEST_IDENTITY_KEY) + len(
        REQUEST_IDENTITY_KEY.as_bytes()
    )
    var identity_two = refreshed_twice[byte=second_start : second_start + 27]
    harness.check(
        "second refresh moved the identity",
        identity_two != identity_one,
    )
    harness.check(
        "two mints of the same width",
        fresh_one.byte_length() == identity_one.byte_length(),
    )

    var failure_names = harness.failures.copy()
    var failure_count = len(failure_names)
    print("PASS", harness.passes, "/", harness.passes + failure_count)
    for failed_name in failure_names^:
        print("FAIL:", failed_name)
    if failure_count > 0:
        raise Error("mojoflask v0.8.4 selftest failures")
