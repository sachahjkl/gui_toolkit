#+build linux
package dbus

import "core:mem/virtual"
import "core:sys/linux"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

// A call that fails at once, or is answered: a limit it never reaches.
@(private = "file") TEST_CALL_MS :: 2000
// What a peer that says nothing is waited for.
@(private = "file") TEST_SILENCE_MS :: 20
// More than one, and the list must shrink under the walk of it.
@(private = "file") TEST_EXPIRED :: 3

@(private = "file") TEST_SOCKET :: "/tmp/gui_toolkit_dbus_silent_test"

// A connection whose other end is the test: what the bus would send is written there beforehand (the serials are known: each
// call takes the next).
@(private = "file")
test_conn :: proc(t: ^testing.T) -> (c: ^Conn, peer: linux.Fd) {
	pair: [2]linux.Fd
	testing.expect_value(t, linux.socketpair(.UNIX, .STREAM, .HOPOPT, &pair), linux.Errno.NONE)
	c = new(Conn)
	c.fd, c.serial, c.state = i32(pair[0]), 1, .Ready
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

// An interactive call carries ALLOW_INTERACTIVE_AUTHORIZATION (4); an ordinary call no flag.
@(test)
an_interactive_call_lets_the_service_ask :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer { conn_close(c); linux.close(peer) }
	says(peer, 1, "first")
	_, ok1 := call(c, "d", "/p", "i.f", "m", "", nil, TEST_CALL_MS, interactive = true)
	// (a reply is routed only to a call that waits for it)
	says(peer, 2, "second")
	_, ok2 := call(c, "d", "/p", "i.f", "m", "", nil, TEST_CALL_MS)
	testing.expect(t, ok1 && ok2)
	buf: [4096]u8
	n, err := linux.recv(peer, buf[:], {})
	testing.expect_value(t, err, linux.Errno.NONE)
	first, used, parsed := parse_message(buf[:n], context.temp_allocator)
	testing.expect(t, parsed)
	testing.expect_value(t, first.flags, u8(FLAG_ALLOW_INTERACTIVE_AUTHORIZATION))
	second, _, parsed2 := parse_message(buf[used:n], context.temp_allocator)
	testing.expect(t, parsed2)
	testing.expect_value(t, second.flags, u8(0))
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

@(private = "file")
heard :: proc(user: rawptr, status: Call_Status, msg: ^Message) {
	x := (^Heard)(user)
	x.calls, x.status, x.nil_msg = x.calls + 1, status, msg == nil
}

// The bus goes away: a call waiting without a deadline hears of it.
@(test)
a_lost_bus_runs_what_waits :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer conn_close(c)
	h: Heard
	testing.expect(t, call_async(c, "d", "/p", "i.f", "m", "", nil, heard, &h, 0))
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
	// (nothing more is read: what would come now starts anywhere)
	testing.expect_value(t, conn_fd(c), -1)
}

// A socket at EOF stays readable: a lost connection gives its fd up, or the window loop's poll(2) never sleeps again.
@(test)
a_lost_bus_leaves_nothing_to_poll :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer conn_close(c)
	linux.close(peer)
	dispatch(c)
	testing.expect(t, !conn_alive(c))
	testing.expect_value(t, conn_fd(c), -1)
	dispatch(c)   // (what the loop does anyway)
	_, ok := call(c, "d", "/p", "i.f", "m", "", nil, TEST_CALL_MS)
	testing.expect(t, !ok, "no call on a lost connection")
	testing.expect(t, !call_noreply(c, "d", "/p", "i.f", "m", "", nil))
	to := Message{sender = ":1.2", serial = 1}
	testing.expect(t, !reply_return(c, &to, "", nil))
}

// A send that fails loses the connection, and what waits hears of it at the next dispatch: nothing will wake it otherwise.
@(test)
a_failed_send_runs_what_waits :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer conn_close(c)
	h: Heard
	testing.expect(t, call_async(c, "d", "/p", "i.f", "m", "", nil, heard, &h, 0))
	linux.close(peer)
	testing.expect(t, !call_noreply(c, "d", "/p", "i.f", "m", "", nil), "the peer is gone")
	testing.expect_value(t, conn_fd(c), -1)
	dispatch(c)
	testing.expect_value(t, h.calls, 1)
	testing.expect_value(t, h.status, Call_Status.Disconnected)
}

// What had arrived whole before the bus went is still routed, the rest is not kept.
@(test)
what_came_before_the_end_is_routed :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer conn_close(c)
	h: Heard
	testing.expect(t, call_async(c, "d", "/p", "i.f", "m", "", nil, heard, &h, 0))
	says(peer, 1, "the last reply")
	cut := [?]u8{'l', 2, 0, 1}
	linux.send(peer, cut[:], {.NOSIGNAL})
	linux.close(peer)
	dispatch(c)
	dispatch(c)   // (the first read stops short of the EOF)
	testing.expect_value(t, h.calls, 1)
	testing.expect_value(t, h.status, Call_Status.Ok)
	testing.expect(t, !conn_alive(c))
	testing.expect_value(t, len(c.in_buf), 0)
}

// The handshake runs on the window's thread: a peer that took the connection and says nothing is given up.
@(test)
a_silent_peer_is_given_up :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer { conn_close(c); linux.close(peer) }
	buf: [AUTH_LINE_BYTES]u8
	start := time.tick_now()
	testing.expect_value(t, read_line(c.fd, buf[:], TEST_SILENCE_MS), "")
	testing.expect(t, time.tick_since(start) < time.Second, "within its limit")
}

// The whole of it: a listener whose backlog took the connection and that nobody serves.
@(test)
a_bus_that_never_answers_is_no_bus :: proc(t: ^testing.T) {
	listener, err := linux.socket(.UNIX, .STREAM, {}, .HOPOPT)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer linux.close(listener)
	linux.unlink(TEST_SOCKET)
	defer linux.unlink(TEST_SOCKET)
	sa: linux.Sock_Addr_Un
	sa.sun_family = .UNIX
	copy(sa.sun_path[:], string(TEST_SOCKET))
	testing.expect_value(t, linux.bind(listener, &sa), linux.Errno.NONE)
	testing.expect_value(t, linux.listen(listener, 1), linux.Errno.NONE)
	start := time.tick_now()
	testing.expect(t, connect_bus_address("unix:path=" + TEST_SOCKET) == nil)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 2 * HANDSHAKE_MS, "within the handshake's limit")
}

@(test)
a_line_of_the_handshake :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer conn_close(c)
	buf: [AUTH_LINE_BYTES]u8
	both := "OK 1234\r\nthe next line\r\n"
	linux.send(peer, transmute([]u8)both, {.NOSIGNAL})
	testing.expect_value(t, read_line(c.fd, buf[:], TEST_CALL_MS), "OK 1234")
	testing.expect_value(t, read_line(c.fd, buf[:], TEST_CALL_MS), "the next line")
	cut := "OK 12"
	linux.send(peer, transmute([]u8)cut, {.NOSIGNAL})
	linux.close(peer)
	testing.expect_value(t, read_line(c.fd, buf[:], TEST_CALL_MS), "")   // (a line cut short is no OK)
}

@(private = "file")
Reentry :: struct { c: ^Conn, calls: int }

// A handler of an expired call calls: that dispatches, and the expired calls left go from under the walk that ran it.
@(test)
a_timed_out_handler_that_calls :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer { conn_close(c); linux.close(peer) }
	re := Reentry{c = c}
	for i in 0 ..< TEST_EXPIRED {
		append(&c.pending, Pending{serial = u32(1000 + i), user = &re, deadline = 1, handler = proc(user: rawptr, status: Call_Status, msg: ^Message) {
			x := (^Reentry)(user)
			x.calls += 1
			call(x.c, "d", "/p", "i.f", "m", "", nil, TEST_SILENCE_MS)
		}})
	}
	dispatch(c)
	testing.expect_value(t, re.calls, TEST_EXPIRED)
	testing.expect_value(t, len(c.pending), 0)
}

// A descriptor goes with its call, in the ancillary data, the message saying how many; a connection that did not get the
// bus's agreement sends nothing.
@(test)
a_descriptor_goes_with_its_call :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer { conn_close(c); linux.close(peer) }
	pipe: [2]linux.Fd
	testing.expect_value(t, linux.pipe2(&pipe, {}), linux.Errno.NONE)
	defer { linux.close(pipe[0]); linux.close(pipe[1]) }
	w := writer_make(context.temp_allocator)
	w_u32(&w, 0)   // (the 'h': the first descriptor)
	fds := [1]i32{i32(pipe[1])}
	_, refused := call_with_fds(c, "d", "/p", "i.f", "m", "h", w.buf[:], fds[:], TEST_SILENCE_MS)
	testing.expect(t, !refused, "no agreement: nothing sent")

	c.unix_fds = true
	says(peer, 1, "ok")   // (its answer, ready: the call's serial is 1)
	_, ok := call_with_fds(c, "d", "/p", "i.f", "m", "h", w.buf[:], fds[:], TEST_CALL_MS)
	testing.expect(t, ok, "answered")

	buf: [512]u8
	control: [8]u64   // (8-byte words: a cmsghdr's alignment)
	iov := posix.iovec{iov_base = &buf[0], iov_len = len(buf)}
	msg := posix.msghdr{msg_iov = &iov, msg_iovlen = 1, msg_control = &control[0], msg_controllen = size_of(control)}
	n := posix.recvmsg(posix.FD(peer), &msg, {})
	if !testing.expect(t, n > 0, "the call came") { return }
	cmsg := (^posix.cmsghdr)(&control[0])
	testing.expect(t, msg.msg_controllen > 0 && cmsg.cmsg_level == posix.SOL_SOCKET && cmsg.cmsg_type == posix.SCM_RIGHTS, "a descriptor with it")
	got := (^i32)(posix.CMSG_DATA(cmsg))^
	testing.expect(t, got >= 0 && got != i32(pipe[1]), "the receiver's own copy")
	if got >= 0 { linux.close(linux.Fd(got)) }
	parsed, _, parsed_ok := parse_message(buf[:n], context.temp_allocator)
	testing.expect(t, parsed_ok && parsed.signature == "h", "the message reads")
}

// No message has serial 0: it is what a failed send answers, and the spec forbids it.
@(test)
the_serial_wraps_past_zero :: proc(t: ^testing.T) {
	c, peer := test_conn(t)
	defer { conn_close(c); linux.close(peer) }
	c.serial = max(u32)
	testing.expect(t, call_noreply(c, "d", "/p", "i.f", "m", "", nil))
	testing.expect(t, call_noreply(c, "d", "/p", "i.f", "m", "", nil), "the one after the last")
	testing.expect_value(t, c.serial, u32(2))
}
