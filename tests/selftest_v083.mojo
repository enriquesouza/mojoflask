"""Selftest for the v0.8.3 reqscan/text additions: case_insensitive_prefix_at,
host_header_value, request_accepts_brotli, query_parameter_value_as_string,
percent_encode_unreserved — each against the verbatim behavior of the origin
application twins they supersede (byte-exact expectations)."""

from mojoflask import (
    BytePtr,
    case_insensitive_prefix_at,
    host_header_value,
    percent_encode_unreserved,
    query_parameter_value_as_string,
    request_accepts_brotli,
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


def head_pointer(text: String) -> BytePtr:
    var text_bytes = text.as_bytes()
    return BytePtr(unsafe_from_address=Int(text_bytes.unsafe_ptr()))


def main() raises:
    var h = Harness()

    # --- case_insensitive_prefix_at --------------------------------------
    var head_text = "GET /x HTTP/1.1\r\nHost: Example.COM\r\n\r\n"
    var head = head_pointer(head_text)
    var head_len = len(head_text.as_bytes())
    h.check(
        "ci prefix host folded",
        case_insensitive_prefix_at(head, 17, 15, "host:"),
    )
    h.check(
        "ci prefix shorter haystack",
        not case_insensitive_prefix_at(head, 17, 4, "host:"),
    )
    h.check(
        "ci prefix exact case",
        not case_insensitive_prefix_at(head, 17, 15, "host:xyz"),
    )
    h.check(
        "ci prefix wrong literal",
        not case_insensitive_prefix_at(head, 17, 15, "accept:"),
    )

    # --- host_header_value ------------------------------------------------
    h.check(
        "host header value",
        host_header_value(head, head_len) == "Example.COM",
    )
    var plain_text = "GET /x HTTP/1.1\r\n\r\n"
    var plain = head_pointer(plain_text)
    h.check(
        "host header default sentinel",
        host_header_value(plain, len(plain_text.as_bytes()))
        == "www.alugue.se",
    )
    var spaced_text = "GET /x HTTP/1.1\r\nHost:   spaced.example  \r\n\r\n"
    var spaced = head_pointer(spaced_text)
    h.check(
        "host header skips leading spaces keeps tail",
        host_header_value(spaced, len(spaced_text.as_bytes()))
        == "spaced.example  ",
    )

    # --- request_accepts_brotli -------------------------------------------
    var br_text = "GET /x HTTP/1.1\r\nAccept-Encoding: gzip, br\r\n\r\n"
    var br_head = head_pointer(br_text)
    h.check(
        "brotli accepted",
        request_accepts_brotli(br_head, len(br_text.as_bytes())),
    )
    var gz_text = "GET /x HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n"
    var gz_head = head_pointer(gz_text)
    h.check(
        "brotli absent refused",
        not request_accepts_brotli(gz_head, len(gz_text.as_bytes())),
    )
    var upper_text = "GET /x HTTP/1.1\r\naccept-encoding: BR\r\n\r\n"
    var upper_head = head_pointer(upper_text)
    h.check(
        "brotli token raw-case sensitive (frozen port quirk)",
        not request_accepts_brotli(upper_head, len(upper_text.as_bytes())),
    )
    var br_upper_text = "GET /x HTTP/1.1\r\nACCEPT-ENCODING: br\r\n\r\n"
    var br_upper_head = head_pointer(br_upper_text)
    h.check(
        "brotli folded header",
        request_accepts_brotli(br_upper_head, len(br_upper_text.as_bytes())),
    )

    # --- query_parameter_value_as_string ----------------------------------
    var q_text = "GET /p?from=2026-09-01&to=&x=1 HTTP/1.1\r\n\r\n"
    var q_head = head_pointer(q_text)
    var q_len = len(q_text.as_bytes())
    h.check(
        "query string first value",
        query_parameter_value_as_string(q_head, q_len, "from")
        == "2026-09-01",
    )
    h.check(
        "query string empty value",
        query_parameter_value_as_string(q_head, q_len, "to") == "",
    )
    h.check(
        "query string absent",
        query_parameter_value_as_string(q_head, q_len, "zzz") == "",
    )

    # --- percent_encode_unreserved ----------------------------------------
    h.check(
        "percent alnum kept",
        percent_encode_unreserved("aZ09-_.~") == "aZ09-_.~",
    )
    h.check(
        "percent space and slash",
        percent_encode_unreserved("a b/c") == "a%20b%2Fc",
    )
    h.check(
        "percent empty",
        percent_encode_unreserved("") == "",
    )
    h.check(
        "percent multibyte",
        percent_encode_unreserved(String("São")) == "S%C3%A3o",
    )

    var failure_names = h.failures.copy()
    var failure_count = len(failure_names)
    print("PASS", h.passes, "/", h.passes + failure_count)
    for failed_name in failure_names^:
        print("FAIL:", failed_name)
    if failure_count > 0:
        raise Error("mojoflask v0.8.3 selftest failures")