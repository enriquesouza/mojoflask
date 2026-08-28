"""mojoflask — a readable, zero-per-request-allocation HTTP server library.

Public API
    App / app_from_env()          the high-level builder: app.get(...), app.run()
    RouteTable / route_table()   declare routes as pattern strings at startup
    ResponseBuffer / build_response()
                                  prebuild whole responses once, serve by pointer
    response_set()               route-indexed table of prebuilt responses
    ParsedBody / parse_json_body()
                                  EmberJson-backed flat request-body decoding
    reqscan helpers               raw_query_text_from_request_line(),
                                  find_query_parameter_value(),
                                  url_path_segment_as_range/_as_string(),
                                  request_body_range()
    text helpers                  whitespace trims, ASCII lowercase, fold,
                                  literal compares over byte ranges,
                                  byte-range String materialization,
                                  utf8_rune_at() validating UTF-8 decode
    WorkerConfig / worker_config_from_env()
    serve(config, routes, responses)
                                  bind + fork + poll event loop, never returns

The search-cache substrate (FNV-1a keys, grid rounding, SlotTable) lives in
the standalone mojoka package: https://github.com/enriquesouza/mojoka

Design notes and the Darwin quirks this encodes are documented per module;
start with mojoflask.server for the SO_REUSEPORT/SCM_RIGHTS story.
"""

from .app import App, app_from_env

from .bodyjson import ParsedBody, parse_json_body

from .ffi import (
    BytePtr,
    Int32Ptr,
    PollFd,
    SockAddrIn,
    UntrackedBytePtr,
    errno_now,
    fatal,
    free_bytes,
    htons,
    make_cstr,
    malloc_bytes,
    null_bytes,
    read_file_into,
    recv_fd,
    retracked,
    send_fd,
    untrack,
)

from .http import (
    MAX_RESPONSES,
    ParsedHead,
    RequestHeaderKeys,
    ResponseBuffer,
    ResponseSet,
    build_response,
    parse_request_head,
    response_set,
    standard_header_keys,
)

from .reqscan import (
    find_query_parameter_value,
    raw_query_text_from_request_line,
    request_body_range,
    url_path_segment_as_range,
    url_path_segment_as_string,
)

from .router import (
    METHOD_ANY,
    METHOD_DELETE,
    METHOD_GET,
    METHOD_PATCH,
    METHOD_POST,
    METHOD_PUT,
    METHOD_QUERY,
    MAX_ROUTE_SEGS,
    MAX_ROUTES,
    ROUTE_DYNAMIC,
    ROUTE_STATIC,
    RouteTable,
    route_table,
)

from .server import (
    DEFAULT_BUF_CAP,
    DEFAULT_MAX_CONNS,
    DynamicOut,
    ResolverFn,
    WorkerConfig,
    conn_table,
    serve,
    serve_dynamic,
    worker_config,
    worker_config_from_env,
)

from .text import (
    ascii_char,
    contains_only_whitespace,
    has_visible_content,
    lowercase_ascii_letters_only,
    materialize_buffer_pointer_as_string,
    materialize_byte_range_as_string_charwise,
    normalize_fold,
    range_equals_literal,
    range_equals_literal_at_offset,
    range_equals_literal_precomputed_length,
    remove_space_and_tab_only,
    remove_trailing_slashes,
    trim_space_tab_newline_carriage_return_around,
    trim_whitespace_characters_around,
    utf8_rune_at,
)
