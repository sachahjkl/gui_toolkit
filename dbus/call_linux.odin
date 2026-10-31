#+build linux
package dbus

// Method calls, signal subscription and the dispatch loop. The body of a call is marshalled by the caller into a
// Writer (the arg_* helpers wrap the common shapes); call() blocks until the reply (bounded), call_async() returns at
// once and runs a handler when the reply arrives through dispatch().

import "core:mem/virtual"
import "core:strings"
import "core:sys/posix"
import "core:time"

@(private = "file") NS_PER_MS :: 1_000_000
@(private = "file") RECV_CHUNK_BYTES :: 8192

// Sends a method call and waits for its reply (bounded by timeout_ms, 0 = a default). The returned Message is valid
// until the next call on this connection (it lives in a reply arena of the connection). ok = false on timeout or
// disconnect. `body` is the already-marshalled arguments (writer.buf[:]) for `signature`, or nil / "".
// A handler may call this while another call waits: each gets its own reply, in whatever order they come.
call :: proc(c: ^Conn, destination, path, iface, member, signature: string, body: []u8, timeout_ms := DEFAULT_CALL_TIMEOUT_MS) -> (msg: Message, ok: bool) {
	if !conn_alive_or_connecting(c) { return {}, false }
	serial := send_message(c, .Method_Call, 0, path, iface, member, destination, "", 0, signature, body)
	if serial == 0 { return {}, false }
	deadline := time.tick_now()
	limit := timeout_ms > 0 ? timeout_ms : DEFAULT_CALL_TIMEOUT_MS
	depth := len(c.waiters)
	if depth == len(c.reply_arenas) {
		a := new(virtual.Arena)
		_ = virtual.arena_init_growing(a)
		append(&c.reply_arenas, a)
	}
	virtual.arena_free_all(c.reply_arenas[depth])
	append(&c.waiters, Waiter{serial = serial})
	defer pop(&c.waiters)
	for {
		// (what an outer call read and had not routed yet, when this is a call in a handler: the socket has nothing more to say)
		route_buffered(c)
		// (an index: a call in a handler may have moved the list)
		if w := c.waiters[depth]; w.done { return w.msg, w.msg.type == .Method_Return }
		if c.disconnected { return {}, false }
		if remaining_ms(deadline, limit) <= 0 { return {}, false }
		pump(c, remaining_ms(deadline, limit))
	}
}

// Sends a method call and returns at once; `handler` runs from dispatch() when the reply arrives, or with a nil message
// on timeout or when the bus goes away. deadline_ms: 0 = no deadline. conn_close runs none of them.
call_async :: proc(c: ^Conn, destination, path, iface, member, signature: string, body: []u8, handler: Reply_Handler, user: rawptr, deadline_ms := DEFAULT_CALL_TIMEOUT_MS) -> bool {
	if !conn_alive_or_connecting(c) { return false }
	serial := send_message(c, .Method_Call, 0, path, iface, member, destination, "", 0, signature, body)
	if serial == 0 { return false }
	dl: i64 = 0
	if deadline_ms > 0 { dl = time.tick_now()._nsec + i64(deadline_ms) * NS_PER_MS }
	append(&c.pending, Pending{serial = serial, handler = handler, user = user, deadline = dl})
	return true
}

// Sends a method call expecting no reply (NO_REPLY_EXPECTED), fire and forget.
call_noreply :: proc(c: ^Conn, destination, path, iface, member, signature: string, body: []u8) -> bool {
	if !conn_alive_or_connecting(c) { return false }
	return send_message(c, .Method_Call, FLAG_NO_REPLY_EXPECTED, path, iface, member, destination, "", 0, signature, body) != 0
}

// Emits a signal from this connection (a service we export, such as the StatusNotifierItem's NewIcon).
emit_signal :: proc(c: ^Conn, path, iface, member, signature: string, body: []u8) -> bool {
	if !conn_alive_or_connecting(c) { return false }
	return send_message(c, .Signal, 0, path, iface, member, "", "", 0, signature, body) != 0
}

// Replies to a method call we received (a return with a body, or an error).
reply_return :: proc(c: ^Conn, to: ^Message, signature: string, body: []u8) -> bool {
	return send_message(c, .Method_Return, 0, "", "", "", to.sender, "", to.serial, signature, body) != 0
}
reply_error :: proc(c: ^Conn, to: ^Message, error_name, message: string) -> bool {
	w := writer_make(context.temp_allocator)
	w_string(&w, message)
	return send_message(c, .Error, 0, "", "", "", to.sender, error_name, to.serial, "s", w.buf[:]) != 0
}

@(private)
conn_alive_or_connecting :: proc(c: ^Conn) -> bool { return c != nil && c.fd >= 0 && !c.disconnected }

@(private)
send_message :: proc(c: ^Conn, type: Msg_Type, flags: u8, path, iface, member, destination, error_name: string, reply_serial: u32, signature: string, body: []u8) -> u32 {
	serial := c.serial
	c.serial += 1
	bytes := build_message(serial, type, flags, path, iface, member, destination, error_name, reply_serial, signature, body, context.temp_allocator)
	if !send_all(c.fd, bytes) { c.disconnected = true; return 0 }
	return serial
}

@(private)
remaining_ms :: proc(start: time.Tick, limit_ms: int) -> int {
	el := int(time.duration_milliseconds(time.tick_since(start)))
	r := limit_ms - el
	return r < 0 ? 0 : r
}

////////////////////////////////
// dispatch

// Reads whatever arrived on the socket (without blocking) and routes complete messages. Call it after poll(2) says the
// fd is readable, or any time to drain. Routes: method returns / errors to the synchronous waiter or an async handler;
// signals to subscribers; method calls to the exported-object handler (export_linux.odin).
dispatch :: proc(c: ^Conn) {
	if c == nil || c.fd < 0 { return }
	drain_socket(c)
	route_buffered(c)
	expire_pending(c)
}

// Blocks up to timeout_ms waiting for the socket to be readable, then dispatches once. Used by the synchronous call.
@(private)
pump :: proc(c: ^Conn, timeout_ms: int) {
	pfd := Pollfd_C{fd = c.fd, events = POLLIN_C}
	poll_c(&pfd, 1, i32(timeout_ms))
	dispatch(c)
}

@(private)
drain_socket :: proc(c: ^Conn) {
	buf: [RECV_CHUNK_BYTES]u8
	for {
		n := recv(c.fd, &buf[0], len(buf), 0)
		if n > 0 {
			append(&c.in_buf, ..buf[:n])
			if n < len(buf) { break }   // likely drained; a full read loops to catch backlog
			continue
		}
		if n == 0 { c.disconnected = true; break }
		#partial switch posix.errno() {
		case .EINTR:
			continue
		case .EAGAIN:   // on the non-blocking socket: nothing more right now
		case:           // (ECONNRESET: the bus went away with something of ours unread)
			c.disconnected = true
		}
		break
	}
}

@(private)
route_buffered :: proc(c: ^Conn) {
	for len(c.in_buf) >= MIN_MESSAGE_BYTES {
		// (back to where it was, not emptied: a handler that calls comes here again under its own message)
		temp := virtual.arena_temp_begin(&c.msg_arena)
		msg, total, ok := parse_message(c.in_buf[:], mem_arena_allocator(c))
		if !ok {
			virtual.arena_temp_end(temp)
			// no message can be told from the next in what follows: the connection is over
			if total < 0 { c.disconnected = true; clear(&c.in_buf) }
			break
		}
		// the consumed bytes go first: the message is a copy, and a handler that calls must not meet it again
		copy(c.in_buf[:], c.in_buf[total:])
		resize(&c.in_buf, len(c.in_buf) - total)
		route_one(c, &msg)
		virtual.arena_temp_end(temp)
	}
}

@(private)
route_one :: proc(c: ^Conn, msg: ^Message) {
	#partial switch msg.type {
	case .Method_Return, .Error:
		for &w, i in c.waiters {
			if w.done || w.serial != msg.reply_serial { continue }
			// a copy of its own (msg's memory goes back when it is routed)
			w.msg = message_clone(msg^, virtual.arena_allocator(c.reply_arenas[i]))
			w.done = true
			return
		}
		for &p, i in c.pending {
			if p.serial == msg.reply_serial {
				h, u := p.handler, p.user
				unordered_remove(&c.pending, i)
				if h != nil { h(u, msg.type == .Method_Return ? .Ok : .Error, msg) }
				return
			}
		}
	case .Signal:
		for &s in c.subs {
			if s.iface != "" && s.iface != msg.iface { continue }
			if s.member != "" && s.member != msg.member { continue }
			if s.path != "" && s.path != msg.path { continue }
			if s.handler != nil { s.handler(s.user, msg) }
		}
	case .Method_Call:
		export_handle_call(c, msg)
	}
}

@(private)
expire_pending :: proc(c: ^Conn) {
	now := time.tick_now()._nsec
	for i := len(c.pending) - 1; i >= 0; i -= 1 {
		p := c.pending[i]
		if c.disconnected || p.deadline != 0 && now >= p.deadline {
			unordered_remove(&c.pending, i)
			if p.handler != nil { p.handler(p.user, c.disconnected ? .Disconnected : .Timeout, nil) }
		}
	}
}

////////////////////////////////
// signals

// Subscribes to a signal: tells the bus to route matching signals here (AddMatch) and runs `handler` on each through
// dispatch(). Any of iface / member / path may be "" to match all of that kind. Returns a subscription id for
// unsubscribe (0 on failure).
subscribe :: proc(c: ^Conn, sender, path, iface, member: string, handler: Signal_Handler, user: rawptr) -> u32 {
	if !conn_alive_or_connecting(c) { return 0 }
	rule := match_rule(sender, path, iface, member)
	w := writer_make(context.temp_allocator)
	w_string(&w, rule)
	if !call_noreply(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", w.buf[:]) {
		return 0
	}
	c.next_sub_id += 1
	append(&c.subs, Subscription{
		rule = strings.clone(rule), iface = strings.clone(iface), member = strings.clone(member),
		path = strings.clone(path), handler = handler, user = user, id = c.next_sub_id,
	})
	return c.next_sub_id
}

unsubscribe :: proc(c: ^Conn, id: u32) {
	for &s, i in c.subs {
		if s.id != id { continue }
		w := writer_make(context.temp_allocator)
		w_string(&w, s.rule)
		call_noreply(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RemoveMatch", "s", w.buf[:])
		delete(s.rule); delete(s.iface); delete(s.member); delete(s.path)
		unordered_remove(&c.subs, i)
		return
	}
}

@(private)
match_rule :: proc(sender, path, iface, member: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "type='signal'")
	add :: proc(b: ^strings.Builder, key, val: string) {
		if val == "" { return }
		strings.write_byte(b, ',')
		strings.write_string(b, key)
		strings.write_string(b, "='")
		strings.write_string(b, val)
		strings.write_byte(b, '\'')
	}
	add(&b, "sender", sender)
	add(&b, "interface", iface)
	add(&b, "member", member)
	add(&b, "path", path)
	return strings.to_string(b)
}
