"""Selftest for the v0.8.5 absorption: the statemod state-slot pattern
(publish through the environment, find the address back, rebuild a typed
view) and the serving send helpers (each helper's exact canonical bytes and
the DynamicOut ownership wiring)."""

from mojoflask import (
    DynamicOut,
    REQUEST_IDENTITY_PLACEHOLDER_LINE,
    RESPONSE_HEADER_TAIL,
    ResponseBuffer,
    allocate_string_that_is_never_freed,
    build_preformatted_json_response,
    build_preformatted_text_response,
    find_published_state_address,
    hash_name_to_hex64,
    make_cstr,
    null_bytes,
    publish_state_slot,
    send_buffered_response_as_text,
    send_response,
    send_response_taking_ownership_of_bytes,
    send_serde_buffer_as_json,
    state_slot_as_type,
)

from mojoflask.ffi import publish_environment_value

from mojoflask.http import HEADER_TAIL

from mojoserde import ByteBuf


comptime TEST_STATE_ENV = "MOJOFLASK_V085_TEST_STATE"

comptime TEST_STATE_MISSING_ENV = "MOJOFLASK_V085_TEST_STATE_MISSING"

comptime TEST_STATE_LONG_ENV = "MOJOFLASK_V085_TEST_STATE_LONG"

comptime TEST_STATE_GARBAGE_ENV = "MOJOFLASK_V085_TEST_STATE_GARBAGE"

comptime JSON_BODY = "{\"ok\":true}"

comptime TEXT_BODY = "missing"


@fieldwise_init
struct ProbeState(Movable):
    var answer: Int


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


def response_as_string(response: ResponseBuffer) -> String:
    return String(
        unsafe_from_utf8=Span[Byte](
            unsafe_ptr=response.data, length=response.length
        )
    )


def fresh_out() -> DynamicOut:
    return DynamicOut(data=null_bytes(), length=0, owns=False, static_route=-2)


def main() raises:
    var harness = Harness()

    # --- statemod: hash_name_to_hex64 -------------------------------------
    harness.check(
        "hex64 zero pads to 16 digits",
        hash_name_to_hex64(0) == "0000000000000000",
    )
    harness.check(
        "hex64 lowercase",
        hash_name_to_hex64(255) == "00000000000000ff",
    )
    harness.check(
        "hex64 deadbeef",
        hash_name_to_hex64(3735928559) == "00000000deadbeef",
    )

    # --- statemod: allocate_string_that_is_never_freed --------------------
    harness.check(
        "never-freed string copy readable",
        allocate_string_that_is_never_freed(String("persist")) == "persist",
    )

    # --- statemod: publish / find / typed roundtrip via the environment ---
    var boot_state = ProbeState(answer=4242)
    harness.check(
        "publish_state_slot reports success",
        publish_state_slot(boot_state, TEST_STATE_ENV),
    )
    var found_address = find_published_state_address(TEST_STATE_ENV)
    harness.check(
        "find returns the published nonzero address",
        found_address != 0,
    )
    var state_slot = state_slot_as_type[ProbeState](found_address)
    harness.check(
        "typed slot reads the published copy",
        state_slot[].answer == 4242,
    )
    harness.check(
        "absent environment key finds nothing",
        find_published_state_address(TEST_STATE_MISSING_ENV) == 0,
    )
    publish_environment_value(TEST_STATE_LONG_ENV, "00000000000000000")
    harness.check(
        "17-character value refused",
        find_published_state_address(TEST_STATE_LONG_ENV) == 0,
    )
    publish_environment_value(TEST_STATE_GARBAGE_ENV, "zz-not-hex")
    harness.check(
        "non-hex value refused",
        find_published_state_address(TEST_STATE_GARBAGE_ENV) == 0,
    )

    # --- serving: tail composition ----------------------------------------
    harness.check(
        "tail is placeholder plus security tail",
        RESPONSE_HEADER_TAIL.byte_length()
        == REQUEST_IDENTITY_PLACEHOLDER_LINE.byte_length()
        + HEADER_TAIL.byte_length(),
    )

    # --- serving: build_preformatted_json_response exact bytes ------------
    var expected_json = String(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11"
    ) + String(RESPONSE_HEADER_TAIL) + String(JSON_BODY)
    var json_response = build_preformatted_json_response(
        "200 OK", JSON_BODY
    )
    harness.check(
        "json prebuilt bytes exact",
        response_as_string(json_response) == expected_json,
    )

    # --- serving: build_preformatted_text_response exact bytes ------------
    var expected_text = String(
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 7"
    ) + String(RESPONSE_HEADER_TAIL) + String(TEXT_BODY)
    var text_response = build_preformatted_text_response(
        "404 Not Found", "text/plain; charset=utf-8", TEXT_BODY
    )
    harness.check(
        "text prebuilt bytes exact",
        response_as_string(text_response) == expected_text,
    )

    # --- serving: send_response borrows without ownership ------------------
    var borrowed_out = fresh_out()
    send_response(json_response, borrowed_out)
    harness.check(
        "send_response points at the prebuilt bytes",
        Int(borrowed_out.data) == Int(json_response.data)
        and borrowed_out.length == json_response.length,
    )
    harness.check(
        "send_response keeps ownership with the caller",
        not borrowed_out.owns and borrowed_out.static_route == -1,
    )

    # --- serving: send_response_taking_ownership_of_bytes ------------------
    var raw_bytes = make_cstr("HTTP/1.1 599 Rare\r\n\r\n")
    var raw_out = fresh_out()
    send_response_taking_ownership_of_bytes(raw_bytes, 21, raw_out)
    harness.check(
        "ownership send points at the raw bytes",
        Int(raw_out.data) == Int(raw_bytes) and raw_out.length == 21,
    )
    harness.check(
        "ownership send transfers ownership to the engine",
        raw_out.owns and raw_out.static_route == -1,
    )

    # --- serving: send_serde_buffer_as_json exact bytes ---------------------
    var serde_buffer = ByteBuf()
    serde_buffer.push_str(JSON_BODY)
    var serde_out = fresh_out()
    send_serde_buffer_as_json(serde_buffer, serde_out)
    var serde_wire = String(
        unsafe_from_utf8=Span[Byte](
            unsafe_ptr=serde_out.data, length=serde_out.length
        )
    )
    harness.check(
        "serde buffer framed as exact canonical json response",
        serde_wire == expected_json,
    )
    harness.check(
        "serde send transfers ownership",
        serde_out.owns and serde_out.static_route == -1,
    )

    # --- serving: send_buffered_response_as_text exact bytes ----------------
    var buffered_out = fresh_out()
    send_buffered_response_as_text(
        "404 Not Found", "text/plain; charset=utf-8", TEXT_BODY, buffered_out
    )
    var buffered_wire = String(
        unsafe_from_utf8=Span[Byte](
            unsafe_ptr=buffered_out.data, length=buffered_out.length
        )
    )
    harness.check(
        "buffered text send bytes exact",
        buffered_wire == expected_text,
    )
    harness.check(
        "buffered text send transfers ownership",
        buffered_out.owns and buffered_out.static_route == -1,
    )

    var failure_names = harness.failures.copy()
    var failure_count = len(failure_names)
    print("PASS", harness.passes, "/", harness.passes + failure_count)
    for failed_name in failure_names^:
        print("FAIL:", failed_name)
    if failure_count > 0:
        raise Error("mojoflask v0.8.5 selftest failures")
