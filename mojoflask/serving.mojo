"""mojoflask.serving — the send helpers that hand canonical responses to
the engine.

Role
    The last mile of a dynamic handler: turn a finished body (a JSON text,
    a plain text, or a mojoserde ByteBuf) into a fully serialized
    ResponseBuffer or a DynamicOut hand-back, with ownership transferred so
    the serving hot path allocates nothing. Byte layout of every emitted
    response: status line, optional Content-Type, Content-Length, the
    request-identity placeholder line, the fixed security-header tail, the
    body — the canonical wire the response builders bake.

    The status and content-type constants are the plain HTTP vocabulary
    handlers reach for; the security-header tail composes the two generic
    exports (identity placeholder + HEADER_TAIL) so library and application
    tails can never drift apart.

origin: alugue-mojo-api utils/serving.mojo
"""

from mojoflask.ffi import (
    BytePtr,
    free_bytes,
    make_cstr,
    malloc_bytes,
    retracked,
    untrack,
)

from mojoflask.http import (
    HEADER_TAIL,
    ResponseBuffer,
    build_response_exact,
)

from mojoflask.request_identity import REQUEST_IDENTITY_PLACEHOLDER_LINE

from mojoflask.server import DynamicOut

from mojoserde import ByteBuf
from mojoserde import free_bytes as serde_free_bytes
from mojoserde import retracked as serde_retracked


comptime STATUS_OK = "200 OK"

comptime STATUS_BAD_REQUEST = "400 Bad Request"

comptime CONTENT_TYPE_JSON = "application/json"

comptime CONTENT_TYPE_TEXT_UTF8 = "text/plain; charset=utf-8"

comptime RESPONSE_HEADER_TAIL = REQUEST_IDENTITY_PLACEHOLDER_LINE + HEADER_TAIL


def build_preformatted_json_response(
    status: String, body: String
) -> ResponseBuffer:
    """Serialize one response whose JSON body is already the exact wire
    bytes (the caller formatted it, the builder only frames it)."""
    var body_c_string = make_cstr(body)
    var prebuilt_response = build_response_exact(
        status, body_c_string, body.byte_length(), CONTENT_TYPE_JSON, False
    )
    free_bytes(body_c_string)
    return prebuilt_response


def build_preformatted_text_response(
    status: String, content_type: String, body: String
) -> ResponseBuffer:
    """Serialize one response head by hand into a single malloc'd block:
    status line, Content-Type, Content-Length, the identity placeholder and
    security tail, then the body — byte-for-byte the canonical layout."""
    var head_prefix = (
        "HTTP/1.1 "
        + status
        + "\r\nContent-Type: "
        + content_type
        + "\r\nContent-Length: "
    )
    var security_tail = String(RESPONSE_HEADER_TAIL)
    var body_length = body.byte_length()
    var length_digits = String(body_length)
    var total_length = (
        head_prefix.byte_length()
        + length_digits.byte_length()
        + body_length
        + security_tail.byte_length()
    )
    var block = malloc_bytes(total_length)
    var offset = 0
    for byte in head_prefix.bytes():
        block[offset] = byte
        offset += 1
    for byte in length_digits.bytes():
        block[offset] = byte
        offset += 1
    for byte in security_tail.bytes():
        block[offset] = byte
        offset += 1
    for byte in body.bytes():
        block[offset] = byte
        offset += 1
    return ResponseBuffer(data=untrack(block), length=total_length)


def send_response(
    prebuilt_response: ResponseBuffer, mut out_buffer: DynamicOut
):
    """Point `out_buffer` at a prebuilt response WITHOUT transferring
    ownership: the engine writes the bytes but never frees them (the
    buffer lives for the whole process)."""
    out_buffer.data = prebuilt_response.data
    out_buffer.length = prebuilt_response.length
    out_buffer.owns = False
    out_buffer.static_route = -1


def send_response_taking_ownership_of_bytes(
    response_bytes: BytePtr, length: Int, mut out_buffer: DynamicOut
):
    """Point `out_buffer` at raw response bytes the engine must free after
    the write finishes or the connection dies."""
    out_buffer.data = untrack(response_bytes)
    out_buffer.length = length
    out_buffer.owns = True
    out_buffer.static_route = -1


def send_serde_buffer_as_json(
    mut buffer: ByteBuf, mut out_buffer: DynamicOut
):
    """Frame a mojoserde ByteBuf as a 200 OK JSON response and hand the
    engine ownership of the framed bytes; the body block is freed once the
    response builder has copied it."""
    var body = serde_retracked(buffer.ptr)
    var prebuilt_response = build_response_exact(
        STATUS_OK, body, buffer.size, CONTENT_TYPE_JSON, False
    )
    serde_free_bytes(body)
    send_response_taking_ownership_of_bytes(
        retracked(prebuilt_response.data), prebuilt_response.length, out_buffer
    )


def send_buffered_response_as_text(
    status: String,
    content_type: String,
    body: String,
    mut out_buffer: DynamicOut,
):
    """Build one preformatted text response and hand the engine ownership
    of its bytes."""
    var prebuilt_response = build_preformatted_text_response(
        status, content_type, body
    )
    send_response_taking_ownership_of_bytes(
        retracked(prebuilt_response.data), prebuilt_response.length, out_buffer
    )
