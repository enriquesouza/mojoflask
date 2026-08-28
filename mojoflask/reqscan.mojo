"""mojoflask.reqscan — zero-allocation request-head byte scanning.

Role
    Reads (BytePtr, head_len) spans of the raw request head — the same
    receive-buffer spans the serving engine hands out — and answers
    routing-shaped questions without copying the head: where the query
    substring of the request line starts and ends, where the first
    matching query-parameter value lives, which byte range holds the
    n-th '/'-separated path segment, and (pointer, length) views over a
    String's bytes for body-shaped spans. Offsets are absolute into the
    caller's buffer; Strings materialized here alias that buffer.

origin: alugue-mojo-api extensions/query.mojo

Darwin quirks encoded here
    None — pure in-memory byte machinery, identical on every platform.
"""

from mojoflask.ffi import BytePtr


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
