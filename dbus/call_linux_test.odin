#+build linux
package dbus

import "core:mem/virtual"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

// A connection whose other end is the test: what the bus would send is written there beforehand (the serials are known: each
// call takes the next).
@(private = "file")
test_conn :: proc(t: ^testing.T) -> (c: ^Conn, peer: linux.Fd) {
	pair: [2]linux.Fd
	testing.expect_value(t, linux.socketpair(.UNIX, .STREAM, .HOPOPT, &pair), linux.Errno.NONE)
	c = new(Conn)
	c.fd, c.serial, c.connected = i32(pair[0]), 1, true
	_ = virtual.arena_init_growing(&c.msg_arena)
	set_nonblocking(c.fd)
	return c, pair[1]
}

@(private = "file")
says :: proc(peer: linux.Fd, reply_to: u32, text: string) {
	w := writer_make(context.temp_allocator)
	w_string(&w, text)
	linux.send(peer, build_message(100 + reply_to, .Method_Return, 0, "", "", "", ":1.1", "", reply_to, "s", w.buf[:], context.temp_allocator), {.NOSIGNAL})
}

@(private = "file")
signal :: proc(peer: linux.Fd, member: string) {
	w := writer_make(context.temp_allocator)
	w_string(&w, "the signal's body, long enough to take the place of a reply's in the arena")
	linux.send(peer, build_message(900, .Signal, 0, "/p", "i.f", member, "", "", 0, "s", w.buf[:], context.temp_allocator), {.NOSIGNAL})
}

@(private = "file")
text_of :: proc(m: ^Message) -> string {
	r := msg_reader(m)
	return r_string(&r)
}

// Hello's reply and NameAcquired arrive in one read: the reply is still there when the call returns.
@(test)
a_reply_outlives_the_message_after_it :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer { conn_close(c); linux.close(peer) }
	says(peer, 1, "the reply")
	signal(peer, "NameAcquired")
	msg, ok := call(c, "d", "/p", "i.f", "m", "", nil, 2000)
	testing.expect(t, ok)
	testing.expect_value(t, text_of(&msg), "the reply")
	testing.expect_value(t, msg.destination, ":1.1")
}

@(private = "file")
Nested :: struct {
	c:     ^Conn,
	calls: int,
	inner: string,
	ok:    bool,
}

@(private = "file")
nested_handler :: proc(user: rawptr, msg: ^Message) {
	n := (^Nested)(user)
	n.calls += 1
	body := text_of(msg)
	m, ok := call(n.c, "d", "/p", "i.f", "inner", "", nil, 2000)
	n.ok = ok
	n.inner = text_of(&m)
	// (the message the handler was given has not moved under the call)
	if text_of(msg) != body { n.ok = false }
}

// A handler calls while a call waits, and the outer reply comes first: both get theirs, and no timeout; the handler is not run
// again on its own message.
@(test)
a_call_within_a_call :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer { conn_close(c); linux.close(peer) }
	n := Nested{c = c}
	append(&c.subs, Subscription{member = "Now", handler = nested_handler, user = &n})
	signal(peer, "Now")
	says(peer, 1, "for the outer call")
	says(peer, 2, "for the inner call")
	start := time.tick_now()
	msg, ok := call(c, "d", "/p", "i.f", "outer", "", nil, 2000)
	testing.expect(t, ok, "the outer call has its reply")
	testing.expect_value(t, text_of(&msg), "for the outer call")
	testing.expect(t, n.ok, "the inner call has its reply")
	testing.expect_value(t, n.inner, "for the inner call")
	testing.expect_value(t, n.calls, 1)
	testing.expect(t, time.tick_since(start) < time.Second, "no timeout")
	clear(&c.subs)
}

@(private = "file")
Drain :: struct { peer: linux.Fd, got: int, want: int }

// A socket full for a moment is waited for: the whole of a message goes.
@(test)
a_full_socket_is_waited_for :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer { conn_close(c); linux.close(peer) }
	big := make([]u8, 4 * 1024 * 1024)
	defer delete(big)
	d := Drain{peer = peer, want = len(big)}
	th := thread.create_and_start_with_poly_data(&d, proc(d: ^Drain) {
		time.sleep(100 * time.Millisecond)
		buf: [64 * 1024]u8
		for d.got < d.want {
			n, err := linux.recv(d.peer, buf[:], {})
			if err != .NONE || n <= 0 { return }
			d.got += n
		}
	})
	testing.expect(t, send_all(c.fd, big), "sent")
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, d.got, len(big))
}

@(private = "file")
Heard :: struct { calls: int, status: Call_Status, nil_msg: bool }

// The bus goes away: a call waiting without a deadline hears of it.
@(test)
a_lost_bus_runs_what_waits :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer conn_close(c)
	h: Heard
	testing.expect(t, call_async(c, "d", "/p", "i.f", "m", "", nil, proc(user: rawptr, status: Call_Status, msg: ^Message) {
		x := (^Heard)(user)
		x.calls, x.status, x.nil_msg = x.calls + 1, status, msg == nil
	}, &h, 0))
	linux.close(peer)
	dispatch(c)
	testing.expect_value(t, h.calls, 1)
	testing.expect_value(t, h.status, Call_Status.Disconnected)
	testing.expect(t, h.nil_msg)
}

// What cannot be a message ends the connection: the next message could never be found in what follows.
@(test)
a_broken_stream_ends_the_connection :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer { conn_close(c); linux.close(peer) }
	junk := make([]u8, 32, context.temp_allocator)
	for &b in junk { b = 'x' }
	linux.send(peer, junk, {.NOSIGNAL})
	dispatch(c)
	testing.expect(t, !conn_alive(c))
	testing.expect_value(t, len(c.in_buf), 0)
}
