package tk_rpc

// JSON-RPC 2.0's ids and errors as the program sees them (rpc.md). The wire's side is in wire.odin.

import "core:encoding/json"

// A string id's bytes at most, held inline in an Id: the program keeps an id without an allocation.
ID_TEXT_MAX :: 62
// The nesting of a message at most: the parser recurses once per level.
DEPTH_MAX :: 128

// JSON-RPC 2.0's error codes.
PARSE_ERROR :: -32700
INVALID_REQUEST :: -32600
METHOD_NOT_FOUND :: -32601
INVALID_PARAMS :: -32602
INTERNAL_ERROR :: -32603
// LSP's and ACP's code for a request cancelled by its sender.
REQUEST_CANCELLED :: -32800

Id_Kind :: enum u8 { Null, Number, Text }

// A request's id: ours are numbers; the child's may be a number, a string or null.
Id :: struct {
	kind:     Id_Kind,
	text_len: u8,
	number:   i64,
	text:     [ID_TEXT_MAX]u8,
}

id_of_number :: proc(n: i64) -> Id { return Id{kind = .Number, number = n} }

// A string id; ok false when it is longer than ID_TEXT_MAX.
id_of_text :: proc(s: string) -> (id: Id, ok: bool) {
	if len(s) > ID_TEXT_MAX { return }
	id.kind = .Text
	id.text_len = u8(len(s))
	copy(id.text[:], s)
	return id, true
}

// A string id's text (valid while `id` is).
id_text :: proc(id: ^Id) -> string { return string(id.text[:id.text_len]) }

// An answer's error.
Error_Object :: struct {
	code:    i64,
	message: string,
	data:    json.Value,   // nil when absent
}
