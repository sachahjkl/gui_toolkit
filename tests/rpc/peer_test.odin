// gt:rpc's peer driving a real child: this test program, started again in a child mode (child.odin). Requests and
// answers both ways, notifications, batches, bad messages, time limits, cancellation, back-pressure, the standard
// error's tail, the end by an exit code, a crash or a stop. Every wait is bounded and waits for a condition.
//   odin run tools/run_tests -- rpc
package rpc_test

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import tk_json "gt:json"
import process "gt:process"
import rpc "gt:rpc"

@(private = "file") BOUND :: 60 * time.Second
@(private = "file") WAIT :: 20 * time.Second

// What a test saw of a message (cloned: a message lives during its handler only).
@(private = "file")
Got :: struct {
	kind:   rpc.Kind,
	method: string,
	tag:    u64,
	ok:     bool,
	local:  rpc.Local,
	value:  string,   // the result, or the params, as JSON text
	code:   i64,
	bad:    rpc.Bad_Kind,
	size:   int,
	end:    rpc.End,
}

@(private = "file")
Box :: struct {
	sema:      sync.Sema,
	got:       [dynamic]Got,
	confirm:   string,   // the answer to the child's "confirm" request
	most_kept: int,      // the most messages seen waiting before a drain
}

@(private = "file")
child_env :: proc(mode: string) -> []string {
	parent, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, context.temp_allocator)
	for e in parent { if !strings.has_prefix(e, MODE_ENV + "=") { append(&env, e) } }
	append(&env, fmt.tprintf("%s=%s", MODE_ENV, mode))
	return env[:]
}

@(private = "file")
open :: proc(box: ^Box, mode: string, o := rpc.Options{}) -> ^rpc.Peer {
	box.got = make([dynamic]Got, context.temp_allocator)
	options := o
	if options.command == nil { options.command = {process.executable_path()} }
	options.env = child_env(mode)
	if mode == "lsp" { options.framing = .Content_Length }
	options.wake = proc(user: rawptr) { sync.sema_post(&(^Box)(user).sema) }
	options.wake_user = box
	return rpc.start(options)
}

@(private = "file")
collect :: proc(p: ^rpc.Peer, m: ^rpc.Message, user: rawptr) {
	box := (^Box)(user)
	g := Got{kind = m.kind, method = strings.clone(m.method, context.temp_allocator), tag = m.tag, ok = m.ok, local = m.local,
		code = m.error.code, bad = m.bad, size = m.size, end = m.end}
	#partial switch m.kind {
	case .Reply:
		if m.ok { g.value = tk_json.to_text(m.result, "", context.temp_allocator) }
	case .Request, .Notification:
		g.value = tk_json.to_text(m.params, "", context.temp_allocator)
	case .Ended:
		g.end.stderr = strings.clone(m.end.stderr, context.temp_allocator)
		g.end.why = strings.clone(m.end.why, context.temp_allocator)
	}
	if m.kind == .Request && m.method == "confirm" { _ = rpc.reply(p, m.id, box.confirm) }
	append(&box.got, g)
}

// Drains until `want` says yes, WAIT at most.
@(private = "file")
wait_for :: proc(p: ^rpc.Peer, box: ^Box, want: proc(box: ^Box, arg: u64) -> bool, arg: u64 = 0, budget := -1) -> bool {
	end := time.tick_add(time.tick_now(), WAIT)
	for {
		box.most_kept = max(box.most_kept, rpc.pending_messages(p))
		_ = rpc.drain(p, collect, box, budget)
		if want(box, arg) { return true }
		left := time.tick_diff(time.tick_now(), end)
		if left <= 0 { return false }
		_ = sync.sema_wait_with_timeout(&box.sema, left)
	}
}

@(private = "file")
reply_of :: proc(box: ^Box, tag: u64) -> (g: Got, ok: bool) {
	for x in box.got { if x.kind == .Reply && x.tag == tag { return x, true } }
	return
}

@(private = "file")
has_reply :: proc(box: ^Box, tag: u64) -> bool { _, ok := reply_of(box, tag); return ok }

@(private = "file")
has_end :: proc(box: ^Box, _: u64) -> bool {
	for x in box.got { if x.kind == .Ended { return true } }
	return false
}

@(private = "file")
end_of :: proc(box: ^Box) -> rpc.End {
	for x in box.got { if x.kind == .Ended { return x.end } }
	return {}
}

@(private = "file")
count :: proc(box: ^Box, kind: rpc.Kind, method := "") -> (n: int) {
	for x in box.got { if x.kind == kind && (method == "" || x.method == method) { n += 1 } }
	return
}

// Stops the child and waits for its end; then frees the peer.
@(private = "file")
close :: proc(t: ^testing.T, p: ^rpc.Peer, box: ^Box) {
	rpc.stop(p, time.Second)
	testing.expect(t, wait_for(p, box, has_end), "the peer ends")
	rpc.destroy(p)
}

@(test)
a_request_is_answered_by_its_tag :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	for mode in ([]string{"echo", "lsp"}) {
		box: Box
		p := open(&box, mode)
		_, err := rpc.call(p, "echo", "{\n  \"x\": [1, \"two\"]\n}", tag = 7)
		testing.expect_value(t, err, rpc.Send_Error.None)
		_, _ = rpc.call(p, "echo", "", tag = 8)
		if testing.expect(t, wait_for(p, &box, has_reply, 8), mode) {
			r, _ := reply_of(&box, 7)
			testing.expect(t, r.ok && r.local == .None)
			testing.expect_value(t, r.value, `{"x":[1,"two"]}`)
			r8, _ := reply_of(&box, 8)
			testing.expect_value(t, r8.value, "null")
		}
		close(t, p, &box)
		e := end_of(&box)
		testing.expect(t, e.how == .Exited && e.code == 0 && e.stopped, fmt.tprint(e))
	}
}

// The child sends notifications, then a request of its own, which the program answers from its handler.
@(test)
the_child_notifies_and_asks :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box := Box{confirm = `{"yes":true}`}
	p := open(&box, "echo")
	_, _ = rpc.call(p, "notify", `{"n":5}`, tag = 1)
	_, _ = rpc.call(p, "ask", "", tag = 2)
	if testing.expect(t, wait_for(p, &box, has_reply, 2)) {
		// (in their order, before the answer)
		i := 0
		for x in box.got {
			if x.kind != .Notification { continue }
			testing.expect_value(t, x.value, fmt.tprintf(`{{"i":%d}}`, i))
			i += 1
		}
		testing.expect_value(t, i, 5)
		testing.expect_value(t, count(&box, .Request, "confirm"), 1)
		r, _ := reply_of(&box, 2)
		testing.expect_value(t, r.value, `{"confirmed":{"yes":true},"id":"q-1"}`)
	}
	close(t, p, &box)
}

// A request that is never answered: its time limit gives the Reply, the child is told to cancel, a late answer is
// dropped. A request cancelled without a limit gets the child's own answer.
@(test)
time_limits_and_cancellation :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box: Box
	p := open(&box, "echo")
	_, _ = rpc.call(p, "never", "", tag = 1, timeout = 100 * time.Millisecond)
	if testing.expect(t, wait_for(p, &box, has_reply, 1)) {
		r, _ := reply_of(&box, 1)
		testing.expect(t, !r.ok && r.local == .Timed_Out, fmt.tprint(r))
	}
	// (the time limit's cancel and the late answer it brings: dropped, counted)
	_, _ = rpc.call(p, "cancels", "", tag = 2)
	if testing.expect(t, wait_for(p, &box, has_reply, 2)) {
		r, _ := reply_of(&box, 2)
		testing.expect_value(t, r.value, "1")
	}
	testing.expect_value(t, rpc.peer_stats(p).dropped, 1)
	id, _ := rpc.call(p, "never", "", tag = 3)
	testing.expect_value(t, rpc.cancel(p, id), rpc.Send_Error.None)
	if testing.expect(t, wait_for(p, &box, has_reply, 3)) {
		r, _ := reply_of(&box, 3)
		testing.expect(t, !r.ok && r.local == .None && r.code == rpc.REQUEST_CANCELLED, fmt.tprint(r))
	}
	close(t, p, &box)
}

// A line beyond message_max is a Bad message with its size, and what follows it is read; no JSON, no JSON-RPC, too
// deep: each a Bad message; a batch comes apart.
@(test)
bad_messages_are_values :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box: Box
	p := open(&box, "echo", {message_max = 4096})
	_, _ = rpc.call(p, "huge", `{"size":100000}`, tag = 1)
	if testing.expect(t, wait_for(p, &box, has_reply, 1)) {
		testing.expect_value(t, count(&box, .Bad), 1)
		for x in box.got { if x.kind == .Bad { testing.expect(t, x.bad == .Too_Long && x.size > 100000, fmt.tprint(x)) } }
		testing.expect_value(t, count(&box, .Notification, "after"), 1)
	}
	_, _ = rpc.call(p, "garbage", "", tag = 2)
	if testing.expect(t, wait_for(p, &box, has_reply, 2)) {
		kinds: [rpc.Bad_Kind]int
		for x in box.got { if x.kind == .Bad { kinds[x.bad] += 1 } }
		testing.expect_value(t, kinds[.Not_Json], 1)
		testing.expect_value(t, kinds[.Not_Rpc], 2)
		testing.expect_value(t, kinds[.Too_Deep], 1)
		testing.expect_value(t, count(&box, .Notification, "b"), 2)
	}
	// (the peer still serves)
	_, _ = rpc.call(p, "echo", "3", tag = 3)
	testing.expect(t, wait_for(p, &box, has_reply, 3))
	close(t, p, &box)
}

// A thousand notifications of a kilobyte with 8 KiB of room: the reader waits for the drains, the child for the reader,
// and every message comes, in order.
@(test)
back_pressure_bounds_what_waits :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box: Box
	p := open(&box, "echo", {inbound_max = 8 * 1024})
	N :: 1000
	_, _ = rpc.call(p, "flood", fmt.tprintf(`{{"n":%d}}`, N), tag = 1)
	testing.expect(t, wait_for(p, &box, has_reply, 1, budget = 1))
	testing.expect_value(t, count(&box, .Notification, "flood"), N)
	testing.expect(t, box.most_kept <= 9, fmt.tprintf("at most 9 messages waited (%d)", box.most_kept))
	close(t, p, &box)
}

// Megabytes on the standard error never block the child; the tail keeps the last bytes.
@(test)
a_flood_of_errors_keeps_its_tail :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box: Box
	p := open(&box, "echo", {stderr_tail = 1024})
	_, _ = rpc.call(p, "stderr", `{"bytes":4194304}`, tag = 1)
	testing.expect(t, wait_for(p, &box, has_reply, 1))
	close(t, p, &box)
	tail := end_of(&box).stderr
	testing.expect_value(t, len(tail), 1024)
	testing.expect(t, strings.has_suffix(tail, "END-MARK"), tail[max(0, len(tail) - 16):])
}

// The child exits with a code: the requests it left get local = .Ended, then Ended says the code and its last words.
@(test)
the_end_says_the_code_and_the_last_words :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box: Box
	p := open(&box, "echo")
	_, _ = rpc.call(p, "never", "", tag = 1)
	_, _ = rpc.call(p, "exit", `{"code":3}`, tag = 2)
	testing.expect(t, wait_for(p, &box, has_end))
	e := end_of(&box)
	testing.expect(t, e.how == .Exited && e.code == 3 && !e.stopped, fmt.tprint(e))
	testing.expect_value(t, e.stderr, "bye\n")
	for tag in ([]u64{1, 2}) {
		r, ok := reply_of(&box, tag)
		testing.expect(t, ok && r.local == .Ended, "each pending request is told")
	}
	testing.expect_value(t, box.got[len(box.got) - 1].kind, rpc.Kind.Ended)
	_, err := rpc.call(p, "echo")
	testing.expect_value(t, err, rpc.Send_Error.Ended)
	rpc.destroy(p)
}

@(test)
a_crash_is_an_end :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box: Box
	p := open(&box, "echo")
	_, _ = rpc.call(p, "crash")
	testing.expect(t, wait_for(p, &box, has_end))
	e := end_of(&box)
	when ODIN_OS == .Linux {
		testing.expect(t, e.how == .Signaled && e.code != 0, fmt.tprint(e))
	} else {
		testing.expect(t, e.how == .Exited && e.code != 0, fmt.tprint(e))
	}
	rpc.destroy(p)
}

// A child that ignores the end of its input and SIGTERM: the stop's last step kills it, within its graces.
@(test)
a_stop_is_bounded :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box: Box
	p := open(&box, "stubborn")
	_, _ = rpc.call(p, "echo", "1", tag = 1)
	testing.expect(t, wait_for(p, &box, has_reply, 1), "it runs")
	rpc.stop(p, 200 * time.Millisecond)
	testing.expect_value(t, rpc.notify(p, "late"), rpc.Send_Error.Ended)
	testing.expect(t, wait_for(p, &box, has_end))
	e := end_of(&box)
	testing.expect(t, e.stopped, fmt.tprint(e))
	when ODIN_OS == .Linux { testing.expect(t, e.how == .Signaled && e.code == 9, fmt.tprint(e)) }
	rpc.destroy(p)
}

@(test)
a_command_that_cannot_start_ends_at_once :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box: Box
	p := open(&box, "echo", {command = {"no-such-agent-gt-rpc", "--acp"}})
	_, _ = rpc.call(p, "initialize", "{}", tag = 1)
	testing.expect(t, wait_for(p, &box, has_end))
	e := end_of(&box)
	testing.expect(t, e.how == .Not_Started && strings.contains(e.why, "no-such-agent-gt-rpc"), fmt.tprint(e))
	r, ok := reply_of(&box, 1)
	testing.expect(t, ok && r.local == .Ended, "the call made before the start is told")
	rpc.destroy(p)
}

// destroy before the end: the child is stopped and the call returns, bounded by the kill, even after a stop with a
// long grace (the test's own time limit is shorter than two of them).
@(test)
destroy_before_the_end_stops_the_child :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	for asked in ([]bool{false, true}) {
		box: Box
		p := open(&box, "stubborn")
		_, _ = rpc.call(p, "echo", "1", tag = 1)
		testing.expect(t, wait_for(p, &box, has_reply, 1))
		if asked { rpc.stop(p, BOUND) }
		rpc.destroy(p)
	}
}

// destroy inside a handler that is not Ended's (a tab closed while its message is handled): the handler still uses the
// peer after the call, drain frees the peer when the handler returns and handles nothing more. (Built with
// -sanitize:address, an early free is a use after free here.)
@(test)
destroy_inside_a_handler_waits_for_its_end :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	box: Box
	p := open(&box, "echo")
	_, _ = rpc.call(p, "notify", `{"n":5}`, tag = 1)
	// (several messages wait: the wake says only the first, so the count is asked)
	end := time.tick_add(time.tick_now(), WAIT)
	for rpc.pending_messages(p) < 3 && time.tick_diff(time.tick_now(), end) > 0 { time.sleep(5 * time.Millisecond) }
	testing.expect(t, rpc.pending_messages(p) >= 3, "messages wait")
	Destroying :: struct { handled: int, after: rpc.Send_Error, state: rpc.State }
	d: Destroying
	n := rpc.drain(p, proc(p: ^rpc.Peer, m: ^rpc.Message, user: rawptr) {
		d := (^Destroying)(user)
		d.handled += 1
		rpc.destroy(p)
		rpc.destroy(p)   // (twice: the second is nothing)
		d.after = rpc.notify(p, "late")
		d.state = rpc.peer_state(p)
	}, &d)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, d.handled, 1)
	testing.expect_value(t, d.after, rpc.Send_Error.Ended)
	testing.expect(t, d.state >= .Stopping, fmt.tprint(d.state))
}

// A process that left the tree (its own setsid) keeps the child's input and never reads it, and a call larger than the
// pipe waits to be written: destroy still returns, bounded, whether that process keeps the output too or not. (Linux:
// on Windows no process leaves the job.)
@(test)
a_write_held_by_a_process_that_left_the_tree_lets_go :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	testing.set_fail_timeout(t, BOUND)
	// (the holder outlives the bound, so a destroy that waits for it fails the test instead of passing late)
	HOLD :: 20
	for keeps_output in ([]bool{false, true}) {
		box: Box
		redirect := keeps_output ? "" : ">/dev/null 2>&1"
		script := fmt.tprintf("setsid -f sleep %d %s; echo '{{\"jsonrpc\":\"2.0\",\"method\":\"ready\"}}'; exec sleep %d", HOLD, redirect, HOLD)
		p := open(&box, "echo", {command = {"sh", "-c", script}})
		ready :: proc(box: ^Box, _: u64) -> bool { return count(box, .Notification, "ready") > 0 }
		testing.expect(t, wait_for(p, &box, ready), "the holder runs")
		big := strings.concatenate({"\"", strings.repeat("a", 1 << 20, context.temp_allocator), "\""}, context.temp_allocator)
		_, err := rpc.call(p, "x", big)
		testing.expect_value(t, err, rpc.Send_Error.None)
		start := time.tick_now()
		rpc.destroy(p)
		took := time.tick_since(start)
		testing.expect(t, took < 10 * time.Second, fmt.tprintf("destroy took %v (keeps the output: %v)", took, keeps_output))
	}
}

@(private = "file")
_ :: json.Value
