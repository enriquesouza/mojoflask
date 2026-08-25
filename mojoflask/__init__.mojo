"""mojoflask — a readable, zero-per-request-allocation HTTP server library.

Public API
    App / app_from_env()          the high-level builder: app.get(...), app.run()
    RouteTable / route_table()   declare routes as pattern strings at startup
    ResponseBuffer / build_response()
                                 prebuild whole responses once, serve by pointer
    response_set()               route-indexed table of prebuilt responses
    WorkerConfig / worker_config_from_env()
    serve(config, routes, responses)
                                 bind + fork + poll event loop, never returns

Design notes and the Darwin quirks this encodes are documented per module;
start with mojoflask.server for the SO_REUSEPORT/SCM_RIGHTS story.
"""

from .app import App, app_from_env

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
    read_file_into,
    recv_fd,
    send_fd,
)

from .http import (
    ParsedHead,
    RequestHeaderKeys,
    ResponseBuffer,
    ResponseSet,
    build_response,
    parse_request_head,
    response_set,
    standard_header_keys,
)

from .router import (
    MAX_ROUTE_SEGS,
    MAX_ROUTES,
    RouteTable,
    route_table,
)

from .server import (
    DEFAULT_BUF_CAP,
    DEFAULT_MAX_CONNS,
    WorkerConfig,
    conn_table,
    serve,
    worker_config,
    worker_config_from_env,
)
