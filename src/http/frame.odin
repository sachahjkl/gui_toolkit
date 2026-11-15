package tk_http

// RFC 6455's frames: the one codec of the toolkit. Linux's WebSocket speaks them over libcurl's raw connection
// (socket_linux.odin): distributions build libcurl without its WebSocket API. Windows' WinHTTP has its own.

// The opcodes a client meets.
@(private) WS_CONTINUATION :: 0x0
@(private) WS_TEXT         :: 0x1
@(private) WS_BINARY       :: 0x2
@(private) WS_CLOSE        :: 0x8
@(private) WS_PING         :: 0x9
@(private) WS_PONG         :: 0xA
// A frame's head at most: 2 bytes, a 64-bit length, a mask.
@(private) WS_HEAD_MAX :: 14
// (a length field past this is a frame no limit admits: clamped, so that sums stay in an int)
@(private) WS_LENGTH_CLAMP :: 1 << 62

// One whole frame of a client: masked, as the protocol wants it.
@(private)
ws_encode :: proc(opcode: u8, payload: []u8, mask: [4]u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(payload) + WS_HEAD_MAX, allocator)
	append(&out, 0x80 | opcode)
	n := len(payload)
	switch {
	case n < 126:
		append(&out, 0x80 | u8(n))
	case n < 65536:
		append(&out, 0x80 | 126, u8(n >> 8), u8(n))
	case:
		append(&out, 0x80 | 127)
		for shift := 56; shift >= 0; shift -= 8 { append(&out, u8(u64(n) >> uint(shift))) }
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for b, i in payload { append(&out, b ~ mask[i % 4]) }
	return out[:]
}

// The first frame of `buf`, a server's (not masked: a masked one is the caller's to refuse). complete: `payload` and
// `used` (the frame's bytes) are there. !complete: more bytes are needed; `used` is then the frame's whole size once its
// head is known (0 before), so that a caller can refuse one too large before it comes.
@(private)
ws_decode :: proc(buf: []u8) -> (opcode: u8, fin: bool, payload: []u8, used: int, complete: bool) {
	if len(buf) < 2 { return }
	op, last := buf[0] & 0x0f, buf[0] & 0x80 != 0
	n := int(buf[1] & 0x7f)
	at := 2
	switch n {
	case 126:
		if len(buf) < 4 { return }
		n = int(buf[2]) << 8 | int(buf[3])
		at = 4
	case 127:
		if len(buf) < 10 { return }
		length: u64
		for i in 2 ..< 10 { length = length << 8 | u64(buf[i]) }
		n = int(min(length, WS_LENGTH_CLAMP))
		at = 10
	}
	if n > len(buf) - at { return op, last, nil, at + n, false }
	return op, last, buf[at:at + n], at + n, true
}
