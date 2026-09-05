"""mojoflask.incoming_request — the dynamic-handler request carrier.

Role
    One plain struct that hands a dynamic handler everything the engine
    already parsed: which route matched, which method arrived, and the raw
    (pointer, length) spans of the request head and body. Handlers receive
    it by value, so the serving hot path allocates nothing per request.

    FamilyResolverFn is the handler signature that answers for a whole
    route family (a group of routes one resolver dispatches over), and
    serve_family is the one-line trampoline the engine's ResolverFn
    adapters call: it forwards the carrier and the output slot to the
    comptime-resolved family resolver and returns its verdict. Keeping the
    generic here lets serve signatures reference the carrier without
    re-declaring the trampoline per application.

origin: alugue-mojo-api models/incoming_request.mojo
"""

from mojoflask.ffi import UntrackedBytePtr

from mojoflask.server import DynamicOut


@fieldwise_init
struct IncomingRequest(Copyable, Movable):
    var route_index: Int
    var method_code: UInt8
    var head: UntrackedBytePtr
    var head_length: Int
    var body: UntrackedBytePtr
    var body_length: Int


comptime FamilyResolverFn = def(IncomingRequest, mut DynamicOut) thin -> Bool


def serve_family[
    resolve_family: FamilyResolverFn
](request: IncomingRequest, mut out_buffer: DynamicOut,) -> Bool:
    return resolve_family(request, out_buffer)
