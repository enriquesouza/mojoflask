"""mojoflask.statemod — the setenv-published pointer pattern for boot state.

Role
    Globals do not exist under the compiler pin (`mojo =1.0.0`), yet a
    forked worker needs to reach state prepared in the parent before the
    fork (connection pools, caches, routing tables). The pattern: copy the
    state bytes into a malloc'd block that is never freed, render the
    block's address as 16-digit lowercase hex, and `setenv` it under a
    well-known key. Any code — including code running after a fork that
    inherited the environment — parses the address back out and rebuilds a
    typed pointer onto the very same block. The block is leaked on purpose:
    it is process-lifetime wiring, not garbage.

    Everything here is format and mechanism only: publish an address, find
    an address, view an address as a typed slot. Callers choose the
    environment key and the state type, so no application vocabulary
    belongs in this module.

origin: alugue-mojo-api utils/statemod.mojo
"""

from std.ffi import c_int, external_call
from std.os import getenv
from std.sys import size_of

from mojoflask.ffi import BytePtr, free_bytes, make_cstr, malloc_bytes


comptime StateSlot[T: AnyType] = Pointer[T=T, mut=True, origin=MutAnyOrigin]


def hash_name_to_hex64(name_value: UInt64) -> String:
    """Render a 64-bit value as exactly 16 lowercase hex digits.

    Zero-padded, so every published address prints at a fixed width and the
    finder can reject anything longer outright.
    """
    var digits = List[UInt8]()
    var value = name_value
    if value == 0:
        digits.append(UInt8(48))
    while value > 0:
        var digit = UInt8(value % 16)
        if digit < 10:
            digits.append(UInt8(48 + digit))
        else:
            digits.append(UInt8(87 + digit))
        value //= 16
    var hex_digits = List[UInt8]()
    var padding_count = 16 - len(digits)
    for _ in range(padding_count):
        hex_digits.append(UInt8(48))
    var index = len(digits) - 1
    while index >= 0:
        hex_digits.append(digits[index])
        index -= 1
    return String(
        unsafe_from_utf8=Span[Byte](
            unsafe_ptr=hex_digits.unsafe_ptr(), length=len(hex_digits)
        )
    )


def allocate_string_that_is_never_freed(text: String) -> String:
    """Copy `text` into a malloc'd block that is never freed and return a
    String viewing it.

    For strings a long-lived struct (boot-built state, a signing key) must
    reference forever: the returned String's bytes outlive any scope, so
    storing it inside state that workers reach through a published slot is
    safe.
    """
    var length = text.byte_length()
    var block = malloc_bytes(length)
    var offset = 0
    for byte in text.bytes():
        block[offset] = byte
        offset += 1
    return String(unsafe_from_utf8=Span[Byte](unsafe_ptr=block, length=length))


def publish_state_address[
    T: AnyType
](state_address: Int, environment_key: StaticString) -> Bool:
    """Copy `state_size[T]` bytes from `state_address` into a fresh never-
    freed block and publish the block's address as hex under
    `environment_key` via setenv. True when setenv accepted the value."""
    var state_size = size_of[T]()
    var block = malloc_bytes(state_size)
    var source_bytes = BytePtr(unsafe_from_address=Int(state_address))
    var offset = 0
    while offset < state_size:
        block[offset] = source_bytes[offset]
        offset += 1
    var block_address = UInt64(Int(block))
    var key_copy = make_cstr(String(environment_key))
    var value_copy = make_cstr(hash_name_to_hex64(block_address))
    var setenv_result = external_call["setenv", c_int](
        key_copy, value_copy, c_int(1)
    )
    free_bytes(key_copy)
    free_bytes(value_copy)
    return setenv_result == 0


def publish_state_slot[
    T: AnyType
](mut state: T, environment_key: StaticString) -> Bool:
    """Publish a copy of `state` under `environment_key`; True on success.

    The copy — not the caller's `state` — is the block later readers reach,
    so callers publish from the boot path and then treat their local as
    disposable.
    """
    return publish_state_address[T](Int(Pointer(to=state)), environment_key)


def find_published_state_address(environment_key: StaticString) -> Int:
    """Parse the hex address published under `environment_key`; 0 when the
    variable is absent, longer than 16 characters, or carries any
    non-lowercase-hex character.

    An Int is returned rather than a typed pointer because the caller names
    the type: pair with `state_slot_as_type` to recover a typed view.
    """
    var published_text = getenv(String(environment_key), "")
    var text_length = published_text.byte_length()
    if text_length == 0 or text_length > 16:
        return 0
    var parsed_address: UInt64 = 0
    for byte in published_text.bytes():
        var character_value = Int(byte)
        var digit: Int
        if character_value >= 48 and character_value <= 57:
            digit = character_value - 48
        elif character_value >= 97 and character_value <= 102:
            digit = character_value - 87
        else:
            return 0
        parsed_address = parsed_address * 16 + UInt64(digit)
    return Int(parsed_address)


def state_slot_as_type[T: AnyType](address: Int) -> StateSlot[T]:
    """Rebuild a typed mutable pointer onto the block published at
    `address` (the Int that `find_published_state_address` returned).

    The address must come from a publish in this process tree — a stale or
    fabricated address is undefined behavior, exactly like any raw pointer
    rebuild."""
    return StateSlot[T](unsafe_from_address=address)
