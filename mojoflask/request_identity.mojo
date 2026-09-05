from std.os import getenv

from mojoflask.ffi import (
    malloc_bytes,
    monotonic_ms,
    publish_environment_value,
    wall_clock_nanoseconds,
)


comptime REQUEST_ID_HEADER_LINE_PREFIX = "x-request-id: "

comptime REQUEST_IDENTITY_DIGIT_WIDTH = 13

comptime REQUEST_IDENTITY_PLACEHOLDER_LINE = "\r\nx-request-id: 0000000000000-0000000000000"

comptime REQUEST_IDENTITY_KEY = "x-request-id: "

comptime SEQUENCE_SLOT_ENV = "MOJOFLASK_IDENTITY_SEQUENCE_SLOT"

comptime SEQUENCE_SLOT_BYTES = 8

comptime HEX_DIGITS = "0123456789abcdef"


def hexadecimal_of(value: Int) -> String:
    """Lowercase hexadecimal without prefix, matching the reference `{:x}`
    formatting for zero and positive integers."""
    var digit_table = HEX_DIGITS.as_bytes()
    if value == 0:
        return String(
            unsafe_from_utf8=Span[Byte](
                unsafe_ptr=digit_table.unsafe_ptr(), length=1
            )
        )
    var remaining = value
    var digit_count = 0
    while remaining > 0:
        remaining >>= 4
        digit_count += 1
    var encoded_digits = List[UInt8](capacity=digit_count)
    remaining = value
    var nibble_index = digit_count
    while nibble_index > 0:
        nibble_index -= 1
        encoded_digits.append(digit_table[(remaining >> (nibble_index * 4)) & 15])
    return String(
        unsafe_from_utf8=Span[Byte](
            unsafe_ptr=encoded_digits.unsafe_ptr(), length=len(encoded_digits)
        )
    )


def zero_padded_hexadecimal(value: Int, width: Int) -> String:
    """Lowercase hexadecimal left-padded with zeros to exactly `width`
    digits (a wider value keeps all its digits)."""
    var digit_table = HEX_DIGITS.as_bytes()
    var encoded_digits = List[UInt8](capacity=width)
    var digit_index = 0
    while digit_index < width:
        encoded_digits.append(digit_table[0])
        digit_index += 1
    digit_index = width - 1
    var remaining = value
    while digit_index >= 0 and remaining > 0:
        encoded_digits[digit_index] = digit_table[remaining & 15]
        remaining >>= 4
        digit_index -= 1
    return String(
        unsafe_from_utf8=Span[Byte](
            unsafe_ptr=encoded_digits.unsafe_ptr(), length=len(encoded_digits)
        )
    )


def identity_sequence_slot() -> BytePtr:
    """The leaked eight-byte sequence counter for this process, allocated on
    first use and remembered through the environment the same way the
    application's state slots are (globals do not exist under this compiler
    pin). Workers that inherit the environment from one boot share the slot
    address until their first write splits it copy-on-write. Environment
    failure degrades to a null slot, and the mint falls back to a clock mix.
    """
    var published = "0"
    try:
        published = getenv(SEQUENCE_SLOT_ENV, "0")
    except:
        published = "0"
    if published != "0":
        var address = Int(0)
        try:
            address = Int(published)
        except:
            address = 0
        if address != 0:
            return BytePtr(unsafe_from_address=address)
    var slot = malloc_bytes(SEQUENCE_SLOT_BYTES)
    var byte_index = 0
    while byte_index < SEQUENCE_SLOT_BYTES:
        slot[byte_index] = 0
        byte_index += 1
    try:
        publish_environment_value(SEQUENCE_SLOT_ENV, String(Int(slot)))
    except:
        pass
    return slot


def identity_sequence_next() -> Int:
    """Read-increment-write the leaked counter; one worker accept loop runs
    single-threaded, so the plain load and store sequence is race-free."""
    var slot = identity_sequence_slot()
    var counter = Int(0)
    var byte_index = 0
    while byte_index < SEQUENCE_SLOT_BYTES:
        counter |= Int(slot[byte_index]) << (8 * byte_index)
        byte_index += 1
    counter += 1
    byte_index = 0
    while byte_index < SEQUENCE_SLOT_BYTES:
        slot[byte_index] = UInt8((counter >> (8 * byte_index)) & 255)
        byte_index += 1
    return counter


def issue_request_identity() -> String:
    """Mint one request identity shaped `<epoch-milliseconds-hex>-<counter-hex>`.

    The reference server derives the same shape from a boot wall-clock stamp
    plus an in-process atomic counter. Workers each own their counter after
    fork, so identities never repeat within one worker; across workers the
    counter restarts, which the wire treats as a volatile per-request value.
    """
    var sequence_value = Int(0)
    try:
        sequence_value = identity_sequence_next()
    except:
        sequence_value = (
            wall_clock_nanoseconds() % 1000000000 + monotonic_ms() * 1000000007
        )
    return hexadecimal_of(wall_clock_nanoseconds() // 1000000) + "-" + hexadecimal_of(
        sequence_value
    )


def fixed_width_request_identity() -> String:
    """One zero-padded identity of exactly 2*REQUEST_IDENTITY_DIGIT_WIDTH
    digits plus the dash: epoch milliseconds and the sequence counter, both
    as lowercase hex — the byte width that lets callers overwrite prebuilt
    placeholders in place."""
    var sequence_value = Int(0)
    try:
        sequence_value = identity_sequence_next()
    except:
        sequence_value = (
            wall_clock_nanoseconds() % 1000000000 + monotonic_ms() * 1000000007
        )
    var wall_nanoseconds = wall_clock_nanoseconds()
    return zero_padded_hexadecimal(
        wall_nanoseconds // 1000000, REQUEST_IDENTITY_DIGIT_WIDTH
    ) + "-" + zero_padded_hexadecimal(
        sequence_value, REQUEST_IDENTITY_DIGIT_WIDTH
    )
