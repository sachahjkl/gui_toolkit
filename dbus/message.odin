package dbus

// D-Bus messages: the fixed header, the header fields (an array of (code, variant)), then the body. message.odin
// builds an outgoing message and parses an incoming one; the type system itself is in marshal.odin.
//
// A caller does not build headers by hand: it fills a Message (the method call's destination, path, interface, member
// and the body signature + arguments written into a Writer) and send() frames it. On the way in, parse_message turns
// the bytes back into a Message whose reader is positioned at the body.

import "core:strings"

Msg_Type :: enum u8 { Invalid, Method_Call, Method_Return, Error, Signal }

// Header field codes (the ones used).
@(private) FIELD_PATH :: 1
@(private) FIELD_INTERFACE :: 2
@(private) FIELD_MEMBER :: 3
@(private) FIELD_ERROR_NAME :: 4
@(private) FIELD_REPLY_SERIAL :: 5
@(private) FIELD_DESTINATION :: 6
@(private) FIELD_SENDER :: 7
@(private) FIELD_SIGNATURE :: 8
@(private) FIELD_UNIX_FDS :: 9

// Flags.
@(private) FLAG_NO_REPLY_EXPECTED :: 1

// One message, in or out. On the way out, the caller sets type, destination, path, iface, member and writes the body
// into `body` with its `signature`. On the way in, parse_message fills the fields and a Reader positioned at the body.
Message :: struct {
	type:         Msg_Type,
	flags:        u8,
	serial:       u32,
	reply_serial: u32,
	path:         string,
	iface:        string,
	member:       string,
	error_name:   string,
	destination:  string,
	sender:       string,
	signature:    string,
	// outgoing: the marshalled body (a Writer the caller filled). incoming: a view of the body bytes + a reader.
	body_bytes:   []u8,
	big:          bool,
}

// A reader over an incoming message's body (the signature is in msg.signature).
msg_reader :: proc(msg: ^Message) -> Reader {
	return reader_make(msg.body_bytes, msg.big)
}

// Frames a method call / signal into bytes ready for the socket. `body` is the already-marshalled body (little-endian,
// base 0) with `signature`; nil body and "" signature for a call with no arguments. The serial is taken from the
// connection.
@(private)
build_message :: proc(serial: u32, type: Msg_Type, flags: u8, path, iface, member, destination, error_name: string, reply_serial: u32, signature: string, body: []u8, allocator := context.allocator) -> []u8 {
	w := writer_make(allocator)
	// fixed header: endianness 'l', type, flags, protocol version 1, body length (u32), serial (u32)
	w_u8(&w, 'l')
	w_u8(&w, u8(type))
	w_u8(&w, flags)
	w_u8(&w, 1)
	w_u32(&w, u32(len(body)))
	w_u32(&w, serial)
	// header fields: array of (y v) structs
	len_at, content_at := w_array_begin(&w, 8)   // struct alignment 8
	put_field_string :: proc(w: ^Writer, code: u8, type_sig: string, s: string) {
		w_struct(w)
		w_u8(w, code)
		w_signature(w, type_sig)   // the variant's signature
		if type_sig == "g" { w_signature(w, s) } else { w_string(w, s) }
	}
	put_field_u32 :: proc(w: ^Writer, code: u8, v: u32) {
		w_struct(w)
		w_u8(w, code)
		w_signature(w, "u")
		w_u32(w, v)
	}
	if path != ""        { put_field_string(&w, FIELD_PATH, "o", path) }
	if iface != ""       { put_field_string(&w, FIELD_INTERFACE, "s", iface) }
	if member != ""      { put_field_string(&w, FIELD_MEMBER, "s", member) }
	if error_name != ""  { put_field_string(&w, FIELD_ERROR_NAME, "s", error_name) }
	if reply_serial != 0 { put_field_u32(&w, FIELD_REPLY_SERIAL, reply_serial) }
	if destination != "" { put_field_string(&w, FIELD_DESTINATION, "s", destination) }
	if signature != ""   { put_field_string(&w, FIELD_SIGNATURE, "g", signature) }
	w_array_end(&w, len_at, content_at)
	// the body starts 8-aligned after the header
	w_align(&w, 8)
	append(&w.buf, ..body)
	return w.buf[:]
}

// Parses one message out of `buf`, starting at offset 0. Returns the message (with body_bytes a view into buf) and how
// many bytes the whole message took; ok = false (and total 0) when the buffer does not yet hold a complete message.
@(private)
parse_message :: proc(buf: []u8, allocator := context.allocator) -> (msg: Message, total: int, ok: bool) {
	if len(buf) < 16 { return {}, 0, false }
	big := buf[0] == 'B'
	r := reader_make(buf, big)
	r_u8(&r)                       // endianness
	msg.type = Msg_Type(r_u8(&r))
	msg.flags = r_u8(&r)
	r_u8(&r)                       // protocol version
	body_len := int(r_u32(&r))
	msg.serial = r_u32(&r)
	msg.big = big
	// header fields array
	fields_len := int(r_u32(&r))
	fields_start := r.pos
	fields_end := fields_start + fields_len
	if fields_end > len(buf) { return {}, 0, false }
	for r.pos < fields_end && !r.err {
		r_align(&r, 8)
		if r.pos >= fields_end { break }
		code := r_u8(&r)
		vsig := r_signature(&r)
		switch code {
		case FIELD_PATH:         msg.path = strings.clone(r_string(&r), allocator)
		case FIELD_INTERFACE:    msg.iface = strings.clone(r_string(&r), allocator)
		case FIELD_MEMBER:       msg.member = strings.clone(r_string(&r), allocator)
		case FIELD_ERROR_NAME:   msg.error_name = strings.clone(r_string(&r), allocator)
		case FIELD_REPLY_SERIAL: msg.reply_serial = r_u32(&r)
		case FIELD_DESTINATION:  msg.destination = strings.clone(r_string(&r), allocator)
		case FIELD_SENDER:       msg.sender = strings.clone(r_string(&r), allocator)
		case FIELD_SIGNATURE:    msg.signature = strings.clone(r_signature(&r), allocator)
		case FIELD_UNIX_FDS:     r_u32(&r)
		case:                    r_skip(&r, vsig)   // a field we do not use
		}
	}
	if r.err { return {}, 0, false }
	// the body starts 8-aligned after the fields
	r.pos = fields_end
	r_align(&r, 8)
	body_start := r.pos
	total = body_start + body_len
	if total > len(buf) { return {}, 0, false }   // the body has not all arrived
	// copy the body so it survives the receive buffer being reused
	bb := make([]u8, body_len, allocator)
	copy(bb, buf[body_start:body_start + body_len])
	msg.body_bytes = bb
	return msg, total, true
}
