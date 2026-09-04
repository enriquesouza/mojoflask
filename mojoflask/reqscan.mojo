"""mojoflask.reqscan — zero-allocation request-head byte scanning.

Role
    Reads (BytePtr, head_len) spans of the raw request head — the same
    receive-buffer spans the serving engine hands out — and answers
    routing-shaped questions without copying the head: where the query
    substring of the request line starts and ends, where the first
    matching query-parameter value lives, which byte range holds the
    n-th '/'-separated path segment, which value the Host header carries,
    whether Accept-Encoding advertises the br token, whether a byte range
    starts with a case-folded literal, and (pointer, length) views over a
    String's bytes for body-shaped spans. Offsets are absolute into the
    caller's buffer; Strings materialized here alias that buffer.

origin: alugue-mojo-api extensions/query.mojo handlers/client_reads/_request_headers.mojo handlers/search/nearby_handler.mojo handlers/admin_reads/support.mojo

Darwin quirks encoded here
    None — pure in-memory byte machinery, identical on every platform.
"""

from mojoflask.ffi import BytePtr
from mojoflask.text import materialize_byte_range_as_string_charwise


def _lit_eq(p: BytePtr, lit: StaticString) -> Bool:
    """Byte-compare p against a StaticString literal; True when all bytes match."""
    var literal_length = lit.byte_length()
    var literal_bytes = lit.as_bytes()
    for i in range(literal_length):
        if Int(p[i]) != Int(literal_bytes[i]):
            return False
    return True


def raw_query_text_from_request_line(req_head: BytePtr, head_len: Int) -> Tuple[Int, Int]:
    """(start, end) of the query substring inside the request line; (0, 0) when absent.

        The unspaced form is tried first: a '?' anywhere in the first line
        (which ends at the first space, CR or LF) splits path from query in
        place. Otherwise, when the line continues past a space, the URI token
        between the spaces is scanned for '?'. Offsets are absolute into
        req_head.
    """
    var i = 0
    while i < head_len and Int(req_head[i]) != 32 and Int(req_head[i]) != 13 and Int(req_head[i]) != 10:
        i += 1
    var line_end = i
    var question_mark_offset = 0
    while question_mark_offset < line_end:
        if Int(req_head[question_mark_offset]) == 63:
            break
        question_mark_offset += 1
    if question_mark_offset < line_end:
        return (question_mark_offset + 1, line_end)
    if i >= head_len or Int(req_head[i]) != 32:
        return (0, 0)
    var j = i + 1
    while j < head_len and Int(req_head[j]) != 32 and Int(req_head[j]) != 13 and Int(req_head[j]) != 10:
        j += 1
    var uri_end = j
    question_mark_offset = i + 1
    while question_mark_offset < uri_end:
        if Int(req_head[question_mark_offset]) == 63:
            break
        question_mark_offset += 1
    if question_mark_offset >= uri_end:
        return (0, 0)
    return (question_mark_offset + 1, uri_end)


def find_query_parameter_value(
    req_head: BytePtr, head_len: Int, key: StaticString
) -> Tuple[Int, Int]:
    """(start, length) of the first query-parameter value whose key matches; (0, 0) otherwise.

        Walks the '&' separated parameters of the query text (see
        raw_query_text_from_request_line). A parameter matches when it
        contains '=' before its end, the bytes before '=' equal `key`, and
        the value after '=' is non-empty. Duplicate keys resolve to the
        first occurrence; a trailing parameter without '=' never matches.
    """
    var query_range = raw_query_text_from_request_line(req_head, head_len)
    var query_start = query_range[0]
    var query_end = query_range[1]
    if query_start >= query_end:
        return (0, 0)
    var pos = query_start
    while pos < query_end:
        var ampersand_end = pos
        while ampersand_end < query_end and Int(req_head[ampersand_end]) != 38:
            ampersand_end += 1
        var equals_position = pos
        while equals_position < ampersand_end and Int(req_head[equals_position]) != 61:
            equals_position += 1
        if equals_position < ampersand_end and _lit_eq(req_head + pos, key):
            var value_start = equals_position + 1
            var value_length = ampersand_end - value_start
            if value_length > 0:
                return (value_start, value_length)
        if ampersand_end >= query_end:
            break
        pos = ampersand_end + 1
    return (0, 0)


def url_path_segment_as_range(req_head: BytePtr, head_len: Int, seg: Int) -> Tuple[Int, Int]:
    """(start, end) of the seg-th '/'-separated path segment; (0, 0) when it does not exist.

        The scan resumes after the method verb's space and requires a leading
        '/'. Each '/' advances the segment counter; '?', space, CR and LF end
        the path. A trailing slash yields an empty range (start == end), not
        (0, 0).
    """
    var i = 0
    while i < head_len and Int(req_head[i]) != 32:
        i += 1
    if i >= head_len or Int(req_head[i]) != 32:
        return (0, 0)
    if i + 1 >= head_len or Int(req_head[i + 1]) != 47:
        return (0, 0)
    var pos = i + 2
    var current_segment = 0
    var seg_start = pos
    while pos < head_len:
        var c = Int(req_head[pos])
        if c == 32 or c == 13 or c == 10 or c == 63:
            if current_segment == seg:
                return (seg_start, pos)
            return (0, 0)
        if c == 47:
            if current_segment == seg:
                return (seg_start, pos)
            current_segment += 1
            seg_start = pos + 1
        pos += 1
    if current_segment == seg:
        return (seg_start, pos)
    return (0, 0)


def url_path_segment_as_string(req_head: BytePtr, head_len: Int) -> String:
    """First path segment as a String read straight out of the request buffer.

        Bytes run from just past the leading '/' to the next '/', '?' or
        space. Malformed heads (no space-delimited URI, no leading '/')
        return the empty String. The result aliases the request buffer —
        copy anything kept past the request.
    """
    var i = 0
    while i < head_len and Int(req_head[i]) != 32:
        i += 1
    if i >= head_len or Int(req_head[i]) != 32:
        return String("")
    if i + 1 >= head_len or Int(req_head[i + 1]) != 47:
        return String("")
    var start = i + 2
    var end = start
    while end < head_len:
        var c = Int(req_head[end])
        if c == 47 or c == 32 or c == 63:
            break
        end += 1
    return String(unsafe_from_utf8=Span(
        unsafe_ptr=req_head + start, length=end - start
    ))


def request_body_range(s: String) -> Tuple[BytePtr, Int]:
    """(pointer, length) over a String's bytes, shaped like a request-body span."""
    var text_bytes = s.as_bytes()
    return (BytePtr(unsafe_from_address=Int(text_bytes.unsafe_ptr())), len(text_bytes))


def case_insensitive_prefix_at(
    bytes_pointer: BytePtr, offset: Int, length: Int, literal: StaticString
) -> Bool:
    """True when bytes_pointer[offset..offset+length) starts with `literal`
    under ASCII case-folding (only A-Z folds; the literal must already be
    lowercase). Longer haystacks match; shorter ones never do.

    origin: alugue-mojo-api handlers/client_reads/_request_headers.mojo
    """
    var literal_length = literal.byte_length()
    if length < literal_length:
        return False
    var literal_bytes = literal.as_bytes()
    for byte_offset in range(literal_length):
        var candidate_byte = Int(bytes_pointer[offset + byte_offset])
        if candidate_byte >= 65 and candidate_byte <= 90:
            candidate_byte += 32
        if candidate_byte != Int(literal_bytes[byte_offset]):
            return False
    return True


def request_accepts_brotli(request_head: BytePtr, head_length: Int) -> Bool:
    """True when the Accept-Encoding header advertises the `br` token.

        Scans every head line for a case-folded `accept-encoding:` prefix,
        then walks its value up to CR watching for `b` followed by `r`
        followed by a token terminator (`,` CR LF `;` `=` ` `). The first
        accept-encoding line decides; a head without one answers False.

    origin: alugue-mojo-api handlers/search/nearby_handler.mojo
    """
    var accept_encoding_lower = ("accept-encoding:".as_bytes())
    var header_scan_index = 0
    var header_scan_limit = head_length - 16
    while header_scan_index < header_scan_limit:
        var literal_matched = True
        var literal_index = 0
        while literal_index < 16:
            var header_byte = Int(
                request_head[unsafe_offset=header_scan_index + literal_index]
            )
            if header_byte >= 65 and header_byte <= 90:
                header_byte += 32
            var literal_byte = Int(accept_encoding_lower[literal_index])
            if header_byte != literal_byte:
                literal_matched = False
                break
            literal_index += 1
        if literal_matched:
            var value_index = header_scan_index + 16
            while value_index < head_length:
                var value_byte = Int(request_head[unsafe_offset=value_index])
                if value_byte == 13:
                    break
                if value_byte == 98 and value_index + 2 < head_length:
                    var next_byte = Int(
                        request_head[unsafe_offset=value_index + 1]
                    )
                    var after_byte = Int(
                        request_head[unsafe_offset=value_index + 2]
                    )
                    if next_byte == 114 and (
                        after_byte == 44
                        or after_byte == 13
                        or after_byte == 10
                        or after_byte == 59
                        or after_byte == 32
                        or after_byte == 61
                    ):
                        return True
                value_index += 1
            return False
        header_scan_index += 1
    return False


def host_header_value(request_head: BytePtr, head_length: Int) -> String:
    """Host header value materialized from the request head, case-insensitive
    `host:` prefix, leading spaces skipped; "www.alugue.se" when absent.

        Walks the head line-by-line (CR trimmed), folds the `host:` prefix,
        skips the 0x20 run after the colon and aliases the rest of the line
        into a String. When no Host line exists the origin app's default
        host literal is returned — that sentinel is part of the ported
        wire contract, kept verbatim.

    origin: alugue-mojo-api handlers/client_reads/_request_headers.mojo
    """
    var line_position = 0
    while line_position < head_length:
        var line_end = line_position
        while line_end < head_length and Int(request_head[line_end]) != 10:
            line_end += 1
        var trimmed_line_end = line_end
        if (
            trimmed_line_end > line_position
            and Int(request_head[trimmed_line_end - 1]) == 13
        ):
            trimmed_line_end -= 1
        if trimmed_line_end > line_position:
            if case_insensitive_prefix_at(
                request_head,
                line_position,
                trimmed_line_end - line_position,
                "host:",
            ):
                var header_value_start = line_position + 5
                while (
                    header_value_start < trimmed_line_end
                    and Int(request_head[header_value_start]) == 32
                ):
                    header_value_start += 1
                return String(
                    unsafe_from_utf8=Span[Byte](
                        unsafe_ptr=request_head + header_value_start,
                        length=trimmed_line_end - header_value_start,
                    )
                )
        if line_end >= head_length:
            break
        line_position = line_end + 1
    return String("www.alugue.se")


def query_parameter_value_as_string(
    request_head: BytePtr, head_length: Int, key: StaticString
) -> String:
    """First matching query-parameter value materialized as a String;
    empty String when the parameter is absent or holds an empty value.

        Thin materializing twin over find_query_parameter_value's
        (start, length) range — the bytes alias the request head, so copy
        anything kept past the request.

    origin: alugue-mojo-api handlers/admin_reads/support.mojo
    """
    var byte_range = find_query_parameter_value(request_head, head_length, key)
    if byte_range[1] <= 0:
        return String("")
    return materialize_byte_range_as_string_charwise(
        request_head, byte_range[0], byte_range[1]
    )
