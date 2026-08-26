"""mojoflask.bodyjson — EmberJson-backed request-body parsing.

Role
    Turns a flat JSON request body into a ParsedBody register struct. The
    raw request buffer is wrapped as an immutable byte span (no copy of the
    body itself) and handed to EmberJson's non-raising `try_parse`, so a
    malformed payload costs one failed parse instead of an exception path
    through the hot loop.

Accepted shapes
    - Flat JSON objects only: {"limit":300,"latitude":-23.5505,...}. A valid
      JSON value that is not an object yields ok=False, same as garbage.
    - Numbers may arrive as JSON strings ("latitude":"-23.5"); tiny ASCII
      scanners decode them so sloppy clients keep working.
    - Unknown keys are ignored; missing keys keep their defaults.
"""

from emberjson import Value, try_parse

from mojoflask.ffi import BytePtr


comptime KEY_LATITUDE = "latitude"
comptime KEY_LONGITUDE = "longitude"

comptime MINUS = UInt8(45)
comptime PLUS = UInt8(43)
comptime DOT = UInt8(46)
comptime DIGIT0 = UInt8(48)
comptime DIGIT9 = UInt8(57)
comptime LETTER_E = UInt8(101)
comptime LETTER_E_UPPER = UInt8(69)


@fieldwise_init
struct ParsedBody(RegisterPassable, ImplicitlyCopyable):
    """Flat request-body fields with safe defaults for partial payloads."""

    var limit: Int
    var page: Int
    var lat: Float64
    var lng: Float64
    var has_geo: Bool
    var ok: Bool

    def __init__(out self):
        self.limit = 12
        self.page = 1
        self.lat = 0
        self.lng = 0
        self.has_geo = False
        self.ok = False


def _scan_int(s: String, mut dst: Int) -> Bool:
    """Decode an optionally signed decimal digit run; False on any other byte."""
    var n = s.byte_length()
    if n == 0 or n > 18:
        return False
    var b = s.as_bytes()
    var i = 0
    var neg = False
    if b[0] == MINUS:
        neg = True
        i = 1
    elif b[0] == PLUS:
        i = 1
    if i == n:
        return False
    var acc = 0
    while i < n:
        var c = b[i]
        if c < DIGIT0 or c > DIGIT9:
            return False
        acc = acc * 10 + Int(c - DIGIT0)
        i += 1
    dst = -acc if neg else acc
    return True


def _scan_float(s: String, mut dst: Float64) -> Bool:
    """Decode [+-]digits[.digits][eE[+-]digits]; bounded to short values."""
    var n = s.byte_length()
    if n == 0 or n > 64:
        return False
    var b = s.as_bytes()
    var i = 0
    var neg = False
    if b[0] == MINUS:
        neg = True
        i = 1
    elif b[0] == PLUS:
        i = 1
    var acc = 0.0
    var seen_digit = False
    var seen_dot = False
    var frac_digits = 0
    while i < n:
        var c = b[i]
        if c == DOT:
            if seen_dot:
                return False
            seen_dot = True
            i += 1
        elif c >= DIGIT0 and c <= DIGIT9:
            acc = acc * 10 + Float64(c - DIGIT0)
            seen_digit = True
            if seen_dot:
                frac_digits += 1
            i += 1
        else:
            break
    if not seen_digit:
        return False
    var exp = 0
    var exp_neg = False
    if i < n and (b[i] == LETTER_E or b[i] == LETTER_E_UPPER):
        i += 1
        if i < n and b[i] == MINUS:
            exp_neg = True
            i += 1
        elif i < n and b[i] == PLUS:
            i += 1
        var e_start = i
        while i < n:
            var c = b[i]
            if c < DIGIT0 or c > DIGIT9:
                return False
            exp = exp * 10 + Int(c - DIGIT0)
            i += 1
            if i - e_start > 3:
                return False
        if i == e_start:
            return False
    if i != n:
        return False
    var shift = frac_digits
    if exp_neg:
        shift += exp
    else:
        shift -= exp
    var scale = 1.0
    if shift > 0:
        for _ in range(shift):
            scale *= 10.0
        acc /= scale
    elif shift < 0:
        for _ in range(-shift):
            scale *= 10.0
        acc *= scale
    dst = -acc if neg else acc
    return True


def _read_int(ref val: Value, mut dst: Int) -> Bool:
    """Fill dst from a JSON number or numeric string; leave it alone otherwise."""
    if val.is_int():
        dst = Int(val.int())
        return True
    if val.is_uint():
        dst = Int(val.uint())
        return True
    if val.is_float():
        dst = Int(val.float())
        return True
    if val.is_string():
        return _scan_int(String(val.string()), dst)
    return False


def _read_float(ref val: Value, mut dst: Float64) -> Bool:
    """Fill dst from a JSON number or numeric string; leave it alone otherwise."""
    if val.is_float():
        dst = val.float()
        return True
    if val.is_int():
        dst = Float64(val.int())
        return True
    if val.is_uint():
        dst = Float64(val.uint())
        return True
    if val.is_string():
        return _scan_float(String(val.string()), dst)
    return False


def _extract(ref v: Value) raises -> ParsedBody:
    """Walk the parsed object once, filling known keys and ignoring the rest."""
    var res = ParsedBody()
    res.ok = True
    var got_lat = False
    var got_lng = False
    if not v.is_object():
        res.ok = False
        return res
    for key in v.object():
        var k = String(key)
        if k == "limit":
            _ = _read_int(v[k], res.limit)
        elif k == "page":
            _ = _read_int(v[k], res.page)
        elif k == KEY_LATITUDE:
            if _read_float(v[k], res.lat):
                got_lat = True
        elif k == KEY_LONGITUDE:
            if _read_float(v[k], res.lng):
                got_lng = True
    res.has_geo = got_lat and got_lng
    return res


def parse_json_body(body: BytePtr, len_in: Int) -> ParsedBody:
    """Parse a flat JSON body from the request buffer.

    Args:
        body: pointer to the raw body bytes (not NUL-terminated).
        len_in: body length in bytes; values <= 0 return defaults with ok=False.

    Returns:
        ParsedBody with defaults for missing keys, decoded strings-as-numbers,
        has_geo set only when both latitude and longitude parsed, and ok=False
        for empty input, malformed JSON, or a non-object document.
    """
    var out = ParsedBody()
    if len_in <= 0:
        return out
    var text = String(unsafe_from_utf8=Span[Byte](unsafe_ptr=body, length=len_in))
    var parsed = try_parse(text)
    if not parsed:
        return out
    try:
        return _extract(parsed.value())
    except:
        return out
