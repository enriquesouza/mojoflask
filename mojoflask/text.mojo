"""mojoflask.text — ASCII text normalization and byte-range helpers.

Role
    String hygiene over exact byte classes: whitespace trims (the full
    32/9/10/13/11/12 set and the 32/9/10/13 subset), ASCII-only
    lowercasing, trailing-slash removal, the canonical
    lowercase-plus-space/tab-trim fold, StaticString literal comparison
    over raw BytePtr ranges, byte-range String materialization,
    single-byte Strings, and a validating UTF-8 rune decoder. Trims and
    materializations return views that alias the input's bytes;
    lowercasing, folding and ascii_char build fresh Strings.

origin: alugue-mojo-api extensions/string.mojo

Darwin quirks encoded here
    None — pure in-memory text machinery, identical on every platform.
"""

from mojoflask.ffi import BytePtr


def lowercase_ascii_letters_only(s: String) -> String:
    """New String with ASCII letters lowercased; every non-ASCII byte passes through untouched."""
    var out = List[UInt8](capacity=s.byte_length())
    for current_byte in s.bytes():
        var folded_value = Int(current_byte)
        if folded_value >= 65 and folded_value <= 90:
            folded_value += 32
        out.append(UInt8(folded_value))
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=out.unsafe_ptr(), length=len(out)
    ))


def trim_whitespace_characters_around(s: String) -> String:
    """View with leading/trailing whitespace removed; inner bytes untouched.

        The whitespace classes are space (32), tab (9), NL (10), CR (13),
        VT (11) and FF (12). The result aliases the input's bytes.
    """
    var text_bytes = s.as_bytes()
    var start_index = 0
    var text_length = len(text_bytes)
    while start_index < text_length:
        var c = Int(text_bytes[start_index])
        if c != 32 and c != 9 and c != 10 and c != 13 and c != 11 and c != 12:
            break
        start_index += 1
    var end_index = text_length
    while end_index > start_index:
        var c2 = Int(text_bytes[end_index - 1])
        if c2 != 32 and c2 != 9 and c2 != 10 and c2 != 13 and c2 != 11 and c2 != 12:
            break
        end_index -= 1
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=text_bytes.unsafe_ptr() + start_index,
        length=end_index - start_index,
    ))


def trim_space_tab_newline_carriage_return_around(s: String) -> String:
    """View with leading/trailing space, tab, NL and CR removed.

        Narrower than trim_whitespace_characters_around: VT (11) and FF (12)
        are NOT trimmed here. The result aliases the input's bytes.
    """
    var text_length = s.byte_length()
    var bytes = s.as_bytes()
    var start = 0
    var end = text_length
    while start < end:
        var c = Int(bytes[start])
        if c == 32 or c == 9 or c == 10 or c == 13:
            start += 1
        else:
            break
    while end > start:
        var c = Int(bytes[end - 1])
        if c == 32 or c == 9 or c == 10 or c == 13:
            end -= 1
        else:
            break
    return String(unsafe_from_utf8=Span(
        unsafe_ptr=bytes.unsafe_ptr() + start, length=end - start
    ))


def has_visible_content(s: String) -> Bool:
    """True when at least one byte falls outside the whitespace classes 32/9/10/13/11/12."""
    for current_byte in s.bytes():
        var c = Int(current_byte)
        if c != 32 and c != 9 and c != 10 and c != 13 and c != 11 and c != 12:
            return True
    return False


def contains_only_whitespace(s: String) -> Bool:
    """True when every byte (vacuously true when empty) is within 32/9/10/13/11/12."""
    var text_bytes = s.as_bytes()
    var scan_index = 0
    var text_length = len(text_bytes)
    while scan_index < text_length:
        var c = Int(text_bytes[scan_index])
        if c != 32 and c != 9 and c != 10 and c != 13 and c != 11 and c != 12:
            return False
        scan_index += 1
    return True


def remove_space_and_tab_only(s: String) -> String:
    """View with ONLY spaces and tabs trimmed from both ends; NL/CR/VT/FF survive.

        The result aliases the input's bytes.
    """
    var text_bytes = s.as_bytes()
    var start = 0
    var end = len(text_bytes)
    while start < end and (Int(text_bytes[start]) == 32 or Int(text_bytes[start]) == 9):
        start += 1
    while end > start and (
        Int(text_bytes[end - 1]) == 32 or Int(text_bytes[end - 1]) == 9
    ):
        end -= 1
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=BytePtr(unsafe_from_address=Int(text_bytes.unsafe_ptr())) + start,
        length=end - start,
    ))


def remove_trailing_slashes(s: String) -> String:
    """String with every trailing '/' removed; the input unchanged when none are present."""
    var text_length = s.byte_length()
    var end = text_length
    var text_bytes = s.as_bytes()
    while end > 0 and Int(text_bytes[end - 1]) == 47:
        end -= 1
    if end == text_length:
        return s
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=BytePtr(unsafe_from_address=Int(text_bytes.unsafe_ptr())),
        length=end,
    ))


def range_equals_literal(p: BytePtr, lit: StaticString) -> Bool:
    """Byte-compare p[0:literal_len) against a StaticString literal."""
    var literal_length = lit.byte_length()
    var literal_bytes = lit.as_bytes()
    for i in range(literal_length):
        if Int(p[i]) != Int(literal_bytes[i]):
            return False
    return True


def range_equals_literal_at_offset(p: BytePtr, pos: Int, lit: StaticString) -> Bool:
    """Byte-compare p[pos:pos+literal_len) against a StaticString literal."""
    var literal_bytes = lit.as_bytes()
    for i in range(len(literal_bytes)):
        if Int(p[pos + i]) != Int(literal_bytes[i]):
            return False
    return True


def range_equals_literal_precomputed_length(p: BytePtr, start: Int, n: Int, lit: StaticString) -> Bool:
    """Length-guarded compare: False immediately when n differs from the literal's byte length, else byte-compare p[start:start+n)."""
    var literal_length = lit.byte_length()
    if n != literal_length:
        return False
    var literal_bytes = lit.as_bytes()
    var i = 0
    while i < n:
        if Int(p[start + i]) != Int(literal_bytes[i]):
            return False
        i += 1
    return True


def materialize_byte_range_as_string_charwise(p: BytePtr, start: Int, n: Int) -> String:
    """String built by appending p[start:start+n) one byte at a time."""
    var out = String("")
    var i = 0
    while i < n:
        out += String(unsafe_from_utf8=Span[Byte](
            unsafe_ptr=p + start + i, length=1
        ))
        i += 1
    return out


def materialize_buffer_pointer_as_string(buf: BytePtr, size: Int) -> String:
    """String materialized over the byte range buf[0:size), aliasing those bytes."""
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=buf, length=size
    ))


def normalize_fold(s: String) -> String:
    """Canonical fold: remove_space_and_tab_only, then lowercase_ascii_letters_only."""
    return lowercase_ascii_letters_only(remove_space_and_tab_only(s))


def ascii_char(c: Int) -> String:
    """One-byte String holding the single byte c."""
    var byte_list = List[UInt8](capacity=1)
    byte_list.append(UInt8(c))
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=byte_list.unsafe_ptr(), length=1
    ))


def percent_encode_unreserved(text: String) -> String:
    """RFC 3986 unreserved-reserved percent-encoding over the raw bytes.

        Every byte that is an ASCII letter, digit, or one of `-_.~`
        passes through as itself; EVERY other byte (including UTF-8
        continuations and `/`) emits uppercase `%XX`. The scan walks the
        String's raw bytes, so multibyte characters encode byte-at-a-time.

    origin: alugue-mojo-api services/client_reads/_market_url.mojo
    """
    var percent_encoded_text = String()
    for raw_byte in text.bytes():
        var byte_value = Int(raw_byte)
        if (
            (byte_value >= 65 and byte_value <= 90)
            or (byte_value >= 97 and byte_value <= 122)
            or (byte_value >= 48 and byte_value <= 57)
            or byte_value == 45
            or byte_value == 95
            or byte_value == 46
            or byte_value == 126
        ):
            percent_encoded_text += ascii_char(byte_value)
        else:
            var high_nibble_value = byte_value >> 4
            var low_nibble_value = byte_value & 15
            percent_encoded_text += "%"
            percent_encoded_text += ascii_char(
                (48 + high_nibble_value) if high_nibble_value
                < 10 else (55 + high_nibble_value)
            )
            percent_encoded_text += ascii_char(
                (48 + low_nibble_value) if low_nibble_value
                < 10 else (55 + low_nibble_value)
            )
    return percent_encoded_text


def utf8_rune_at(bytes_ptr: BytePtr, pos: Int, remaining: Int) -> Tuple[Int, Int]:
    """(codepoint, width) of the UTF-8 sequence at bytes_ptr[pos], or (-1, width) on rejection.

        `remaining` counts the readable bytes from pos inclusive. Accepts
        1-4 byte well-formed sequences; rejects leads below 0xC2 (which
        covers the 2-byte overlongs 0xC0/0xC1), broken continuation bytes,
        3-byte decodes below U+0800 (overlong), 4-byte decodes outside
        U+10000..U+10FFFF (overlong and out-of-range), and truncated
        sequences. On rejection the width reports the byte width of the
        rejected form (1 for bad leads and truncations). Surrogates have no
        explicit exclusion and decode as themselves.
    """
    var leading_byte = Int(bytes_ptr[unsafe_offset=pos])
    if leading_byte < 0x80:
        return (leading_byte, 1)
    if leading_byte >= 0xC2 and leading_byte <= 0xDF:
        if remaining < 2:
            return (-1, 1)
        var second_byte = Int(bytes_ptr[unsafe_offset=pos + 1])
        if second_byte & 0xC0 != 0x80:
            return (-1, 1)
        return ((leading_byte & 0x1F) << 6 | (second_byte & 0x3F), 2)
    if leading_byte >= 0xE0 and leading_byte <= 0xEF:
        if remaining < 3:
            return (-1, 1)
        var second_byte = Int(bytes_ptr[unsafe_offset=pos + 1])
        var third_byte = Int(bytes_ptr[unsafe_offset=pos + 2])
        if second_byte & 0xC0 != 0x80 or third_byte & 0xC0 != 0x80:
            return (-1, 1)
        var codepoint_value = (
            (leading_byte & 0x0F) << 12
            | (second_byte & 0x3F) << 6
            | (third_byte & 0x3F)
        )
        if codepoint_value < 0x800:
            return (-1, 3)
        return (codepoint_value, 3)
    if leading_byte >= 0xF0 and leading_byte <= 0xF4:
        if remaining < 4:
            return (-1, 1)
        var second_byte = Int(bytes_ptr[unsafe_offset=pos + 1])
        var third_byte = Int(bytes_ptr[unsafe_offset=pos + 2])
        var fourth_byte = Int(bytes_ptr[unsafe_offset=pos + 3])
        if (
            second_byte & 0xC0 != 0x80
            or third_byte & 0xC0 != 0x80
            or fourth_byte & 0xC0 != 0x80
        ):
            return (-1, 1)
        var codepoint_value = (
            (leading_byte & 0x07) << 18
            | (second_byte & 0x3F) << 12
            | (third_byte & 0x3F) << 6
            | (fourth_byte & 0x3F)
        )
        if codepoint_value < 0x10000 or codepoint_value > 0x10FFFF:
            return (-1, 4)
        return (codepoint_value, 4)
    return (-1, 1)
