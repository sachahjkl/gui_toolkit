package tk_rpc

// The peer: its state under one lock, the program's calls (which queue and never wait), and its four threads (rpc.md,
// "The threads"): watch, reader, writer, errors.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import tk_json "../json"
import process "../process"

// How long the end waits for the pipes to close once the tree is gone; then the readers are let go (Linux: a process
// that left the tree holds them).
@(private = "file") ENDING_BOUND :: 2 * time.Second
@(private = "file") READ_BYTES :: 64 * mem.Kilobyte
// A message's arena: blocks of twice its text, within these bounds; an allocation larger than half a block (the text's
// copy of a large message) gets a block of its own size.
@(private = "file") ARENA_BLOCK_MIN :: 1024
@(private = "file") ARENA_BLOCK_MAX :: 1 * mem.Megabyte

Peer :: struct {
	// (every field is the peer's; the lock guards those that more than one thread reads)
	lock:         sync.Mutex,
	in_cond:      sync.Cond,   // the reader waits for room; destroy releases it
	out_cond:     sync.Cond,   // the writer waits for a message, a stop or the end
	state:        State,
	options:      Options,
	arena:        mem.Dynamic_Arena,   // the options' copies
	waker:        Waker,
	waker_ok:     bool,
	tree:         process.Tree,
	stdin:        ^os.File,
	stdout:       ^os.File,
	stderr:       ^os.File,
	inbound:      [dynamic]^Message,
	in_head:      int,
	in_bytes:     int,
	woken:        bool,                // the wake was called since the last drain
	abandon:      bool,                // destroy: the reader stops waiting for room
	outbound:     [dynamic][]u8,
	out_head:     int,
	out_bytes:    int,
	next_id:      i64,
	pending:      map[i64]Pending,
	stop_asked:   bool,
	stop_at:      time.Tick,
	grace:        time.Duration,
	stop_step:    int,                 // 0: input closed; 1: Terminate sent; 2: killed
	tail:         Tail,
	stats:        Stats,
	drain_thread: int,                 // (atomic) the thread that runs a handler in drain; 0: none
	destroy_asked: bool,               // destroy was called inside a handler: drain frees the peer when it returns
	reader_done:  bool,                // (atomic)
	errors_done:  bool,                // (atomic)
	watch:        ^thread.Thread,
	reader:       ^thread.Thread,
	writer:       ^thread.Thread,
	errors:       ^thread.Thread,
}

@(private)
Pending :: struct {
	tag:      u64,
	user:     rawptr,
	timed:    bool,
	deadline: time.Tick,
}

// Starts the child of `o` and the peer's threads. Never blocks: the spawn runs on the peer's watch thread, and a
// failed start is an Ended message (How.Not_Started). The peer is freed by destroy.
start :: proc(o: Options) -> ^Peer {
	p := new(Peer, runtime.heap_allocator())
	heap := runtime.heap_allocator()
	mem.dynamic_arena_init(&p.arena, heap, heap)
	a := mem.dynamic_arena_allocator(&p.arena)
	p.options = o
	p.options.command = clone_list(o.command, a)
	p.options.env = o.env != nil ? clone_list(o.env, a) : nil
	p.options.dir = strings.clone(o.dir, a)
	if p.options.message_max <= 0 { p.options.message_max = MESSAGE_MAX_DEFAULT }
	if p.options.inbound_max <= 0 { p.options.inbound_max = INBOUND_MAX_DEFAULT }
	if p.options.outbound_max <= 0 { p.options.outbound_max = OUTBOUND_MAX_DEFAULT }
	if p.options.stderr_tail <= 0 { p.options.stderr_tail = STDERR_TAIL_DEFAULT }
	p.inbound = make([dynamic]^Message, heap)
	p.outbound = make([dynamic][]u8, heap)
	p.pending = make(map[i64]Pending, heap)
	p.tail = tail_make(p.options.stderr_tail, heap)
	p.next_id = 1
	p.waker_ok = waker_make(&p.waker)
	p.watch = thread.create_and_start_with_poly_data(p, watch_main, peer_context())
	if p.watch == nil { end_not_started(p, "no thread for the peer") }
	return p
}

// A request. `params` is JSON text ("": none); `timeout` 0: none. The Reply carries `tag` and `user`. Any thread.
call :: proc(p: ^Peer, method: string, params := "", tag: u64 = 0, user: rawptr = nil, timeout: time.Duration = 0) -> (id: i64, err: Send_Error) {
	sync.lock(&p.lock)
	if p.stop_asked || p.state >= .Stopping {
		sync.unlock(&p.lock)
		return 0, .Ended
	}
	id = p.next_id
	data := encode_request(p.options.framing, id, method, params, runtime.heap_allocator())
	if err = enqueue_locked(p, data); err != .None {
		sync.unlock(&p.lock)
		return 0, err
	}
	p.next_id += 1
	pend := Pending{tag = tag, user = user, timed = timeout > 0}
	if pend.timed { pend.deadline = time.tick_add(time.tick_now(), timeout) }
	p.pending[id] = pend
	sync.unlock(&p.lock)
	// (a new time limit: the watch counts it)
	if timeout > 0 { waker_wake(&p.waker) }
	return id, .None
}

// A notification. `params` is JSON text ("": none). Any thread.
notify :: proc(p: ^Peer, method: string, params := "") -> Send_Error {
	return send(p, encode_notification(p.options.framing, method, params, runtime.heap_allocator()))
}

// The answer to the child's request `id`: `result` is JSON text ("": null). Any thread, any time.
reply :: proc(p: ^Peer, id: Id, result: string) -> Send_Error {
	return send(p, encode_result(p.options.framing, id, result, runtime.heap_allocator()))
}

// An error for the child's request `id` (METHOD_NOT_FOUND for a method the program does not know); `data` is JSON
// text ("": none).
reply_error :: proc(p: ^Peer, id: Id, code: i64, message: string, data := "") -> Send_Error {
	return send(p, encode_error(p.options.framing, id, code, message, data, runtime.heap_allocator()))
}

// Asks the child to cancel the request `id`. The request stays pending: the child still answers it (a result, or
// REQUEST_CANCELLED), and its time limit still holds.
cancel :: proc(p: ^Peer, id: i64) -> Send_Error {
	data := cancel_bytes(p, id)
	if data == nil { return .None }
	return send(p, data)
}

// Ends the child: what is queued is written, then its input closes; after `grace` the tree gets Terminate, after a
// second `grace` it is killed. Any thread; never blocks. The end comes as the Ended message.
stop :: proc(p: ^Peer, grace := STOP_GRACE) {
	sync.lock(&p.lock)
	if p.stop_asked || p.state >= .Ending {
		sync.unlock(&p.lock)
		return
	}
	p.stop_asked = true
	p.stop_at = time.tick_now()
	p.grace = max(grace, 0)
	if p.state == .Running { p.state = .Stopping }
	sync.cond_broadcast(&p.out_cond)
	sync.unlock(&p.lock)
	waker_wake(&p.waker)
}

// Runs `handle` on the messages that wait (`budget` at most; negative: all), in their order, on this thread. A
// message is freed when its handler returns. Returns at once after Ended. A handler may call destroy: drain then frees
// the peer when that handler returns, and returns at once. A drain that stops at its budget calls the wake again.
drain :: proc(p: ^Peer, handle: Handler, user: rawptr = nil, budget := -1) -> int {
	me := sync.current_thread_id()
	sync.lock(&p.lock)
	p.woken = false
	sync.unlock(&p.lock)
	n := 0
	for budget < 0 || n < budget {
		sync.lock(&p.lock)
		m: ^Message
		if p.in_head < len(p.inbound) {
			m = p.inbound[p.in_head]
			p.in_head += 1
			p.in_bytes -= m.bytes
			if p.in_head == len(p.inbound) {
				clear(&p.inbound)
				p.in_head = 0
			}
			sync.cond_signal(&p.in_cond)
		}
		sync.unlock(&p.lock)
		if m == nil { return n }
		ended := m.kind == .Ended
		sync.atomic_store(&p.drain_thread, me)
		handle(p, m, user)
		sync.atomic_store(&p.drain_thread, 0)
		message_free(m)
		n += 1
		if p.destroy_asked {
			// (the handler's destroy: its free waited for the handler, which still had the peer)
			destroy_finish(p)
			return n
		}
		if ended { return n }
	}
	sync.lock(&p.lock)
	more := p.in_head < len(p.inbound) && !p.woken
	if more { p.woken = true }
	sync.unlock(&p.lock)
	if more { call_wake(p) }
	return n
}

// The messages that wait.
pending_messages :: proc(p: ^Peer) -> int {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	return len(p.inbound) - p.in_head
}

peer_state :: proc(p: ^Peer) -> State {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	return p.state
}

peer_stats :: proc(p: ^Peer) -> Stats {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	return p.stats
}

// The last bytes of the child's standard error so far, in `allocator`.
stderr_tail :: proc(p: ^Peer, allocator := context.allocator) -> string {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	return tail_text(&p.tail, allocator)
}

// Frees the peer. After Ended (its handler included) it returns at once. Before, it stops the child with no grace and
// waits for the tree's end (bounded by the kill). No wake is called once it began. A blocking call before Ended: not on
// the interface's thread then. Inside a handler (drain's thread) it stops the child and returns: drain frees the peer
// when the handler returns, so the handler may still use the peer until then.
destroy :: proc(p: ^Peer) {
	if p.destroy_asked { return }
	destroy_start(p)
	if sync.atomic_load(&p.drain_thread) == sync.current_thread_id() {
		p.destroy_asked = true
		return
	}
	destroy_finish(p)
}

// destroy's first half, which never blocks: no more wakes, the reader let go, the child stopped with no grace.
@(private = "file")
destroy_start :: proc(p: ^Peer) {
	sync.lock(&p.lock)
	p.options.wake = nil
	p.abandon = true
	sync.cond_broadcast(&p.in_cond)
	// (a stop asked before with a long grace: its steps are due now)
	if p.stop_asked { p.grace = 0 }
	sync.unlock(&p.lock)
	stop(p, 0)
	waker_wake(&p.waker)
}

// destroy's second half: the threads joined (bounded by the kill), everything freed.
@(private = "file")
destroy_finish :: proc(p: ^Peer) {
	if p.watch != nil {
		thread.join(p.watch)
		thread.destroy(p.watch)
	}
	for m in p.inbound[p.in_head:] { message_free(m) }
	delete(p.inbound)
	for d in p.outbound[p.out_head:] { delete(d, runtime.heap_allocator()) }
	delete(p.outbound)
	delete(p.pending)
	tail_destroy(&p.tail, runtime.heap_allocator())
	if p.waker_ok { waker_destroy(&p.waker) }
	mem.dynamic_arena_destroy(&p.arena)
	free(p, runtime.heap_allocator())
}

@(private = "file")
clone_list :: proc(list: []string, allocator: mem.Allocator) -> []string {
	out := make([]string, len(list), allocator)
	for s, i in list { out[i] = strings.clone(s, allocator) }
	return out
}

@(private = "file")
peer_context :: proc() -> runtime.Context {
	c := runtime.default_context()
	c.allocator = runtime.heap_allocator()
	return c
}

@(private = "file")
send :: proc(p: ^Peer, data: []u8) -> Send_Error {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	if p.stop_asked || p.state >= .Stopping {
		delete(data, runtime.heap_allocator())
		return .Ended
	}
	return enqueue_locked(p, data)
}

// Queues bytes for the writer (one message always goes in: a large answer cannot be refused for ever).
@(private = "file")
enqueue_locked :: proc(p: ^Peer, data: []u8) -> Send_Error {
	if p.out_bytes > 0 && p.out_bytes + len(data) > p.options.outbound_max {
		delete(data, runtime.heap_allocator())
		return .Full
	}
	append(&p.outbound, data)
	p.out_bytes += len(data)
	sync.cond_signal(&p.out_cond)
	return .None
}

@(private = "file")
cancel_bytes :: proc(p: ^Peer, id: i64) -> []u8 {
	method, key: string
	switch p.options.cancel {
	case .ACP:  method, key = "$/cancel_request", "requestId"
	case .LSP:  method, key = "$/cancelRequest", "id"
	case .None: return nil
	}
	params := fmt.tprintf(`{{"%s":%d}}`, key, id)
	return encode_notification(p.options.framing, method, params, runtime.heap_allocator())
}

@(private = "file")
call_wake :: proc(p: ^Peer) {
	sync.lock(&p.lock)
	wake, user := p.options.wake, p.options.wake_user
	sync.unlock(&p.lock)
	if wake != nil { wake(user) }
}

// A message with an arena for `text_bytes` of text and its values.
@(private = "file")
message_new :: proc(kind: Kind, text_bytes: int) -> ^Message {
	heap := runtime.heap_allocator()
	m := new(Message, heap)
	m.kind = kind
	block := clamp(2 * text_bytes, ARENA_BLOCK_MIN, ARENA_BLOCK_MAX)
	mem.dynamic_arena_init(&m.arena, heap, heap, block, block / 2)
	m.bytes = text_bytes + size_of(Message)
	return m
}

@(private = "file")
message_free :: proc(m: ^Message) {
	mem.dynamic_arena_destroy(&m.arena)
	free(m, runtime.heap_allocator())
}

@(private = "file")
push_locked :: proc(p: ^Peer, m: ^Message) -> (wake: bool) {
	append(&p.inbound, m)
	p.in_bytes += m.bytes
	if m.kind == .Bad { p.stats.bad += 1 }
	if p.woken { return false }
	p.woken = true
	return true
}

// Queues a message read from the child: the reader waits while inbound_max bytes wait already (one always goes in).
@(private = "file")
push :: proc(p: ^Peer, m: ^Message) {
	sync.lock(&p.lock)
	for p.in_bytes > 0 && p.in_bytes + m.bytes > p.options.inbound_max && !p.abandon {
		sync.cond_wait(&p.in_cond, &p.lock)
	}
	wake := push_locked(p, m)
	sync.unlock(&p.lock)
	if wake { call_wake(p) }
}

@(private = "file")
end_not_started :: proc(p: ^Peer, why: string) {
	sync.lock(&p.lock)
	wake := end_locked(p, {how = .Not_Started, why = why})
	sync.unlock(&p.lock)
	if wake { call_wake(p) }
}

// The last messages: a Reply with local = .Ended for each pending request, then Ended. Under the lock.
@(private = "file")
end_locked :: proc(p: ^Peer, end: End) -> (wake: bool) {
	for id, pend in p.pending {
		m := message_new(.Reply, 0)
		m.id = id_of_number(id)
		m.local = .Ended
		m.tag, m.user = pend.tag, pend.user
		wake |= push_locked(p, m)
	}
	clear(&p.pending)
	m := message_new(.Ended, len(end.why) + len(end.stderr))
	a := mem.dynamic_arena_allocator(&m.arena)
	m.end = end
	m.end.why = strings.clone(end.why, a)
	m.end.stderr = strings.clone(end.stderr, a)
	wake |= push_locked(p, m)
	p.state = .Ended
	return
}

// ---- the watch: the spawn, the time limits, the stop's steps, the end

@(private = "file")
watch_main :: proc(p: ^Peer) {
	if !p.waker_ok {
		end_not_started(p, "this system cannot run a peer")
		return
	}
	in_r, in_w, e1 := process.pipe()
	if e1 != nil { end_not_started(p, fmt.tprintf("no pipe (%v)", e1)); return }
	out_r, out_w, e2 := process.pipe()
	if e2 != nil {
		os.close(in_r); os.close(in_w)
		end_not_started(p, fmt.tprintf("no pipe (%v)", e2))
		return
	}
	err_r, err_w, e3 := process.pipe()
	if e3 != nil {
		os.close(in_r); os.close(in_w); os.close(out_r); os.close(out_w)
		end_not_started(p, fmt.tprintf("no pipe (%v)", e3))
		return
	}
	o := &p.options
	tree, serr := process.tree_start({command = o.command, working_dir = o.dir, env = o.env, stdin = in_r, stdout = out_w, stderr = err_w})
	os.close(in_r); os.close(out_w); os.close(err_w)
	if serr != nil {
		os.close(in_w); os.close(out_r); os.close(err_r)
		name := len(o.command) > 0 ? o.command[0] : ""
		end_not_started(p, fmt.tprintf("%s cannot start: %v", name, serr))
		return
	}
	p.tree = tree
	writer_prepare(in_w)
	p.stdin, p.stdout, p.stderr = in_w, out_r, err_r
	sync.lock(&p.lock)
	p.state = p.stop_asked ? .Stopping : .Running
	sync.unlock(&p.lock)
	ctx := peer_context()
	p.reader = thread.create_and_start_with_poly_data(p, reader_main, ctx)
	p.errors = thread.create_and_start_with_poly_data(p, errors_main, ctx)
	p.writer = thread.create_and_start_with_poly_data(p, writer_main, ctx)
	if p.reader == nil { sync.atomic_store(&p.reader_done, true) }
	if p.errors == nil { sync.atomic_store(&p.errors_done, true) }
	if p.reader == nil || p.errors == nil || p.writer == nil { process.tree_kill(&p.tree) }

	for {
		free_all(context.temp_allocator)
		next := watch_step(p)
		if waker_wait(&p.waker, p.tree.process.handle, next) == .Ended { break }
	}
	end, ended := process.tree_wait(&p.tree, ENDING_BOUND)
	// (what the child left running: its group, its job)
	process.tree_kill(&p.tree)
	// (a wait woken by something other than the end, a poll's error: the kill ends it, and its status is the true one)
	if !ended { end, ended = process.tree_wait(&p.tree, process.TREE_CLOSE_BOUND) }
	sync.lock(&p.lock)
	p.state = .Ending
	sync.cond_broadcast(&p.out_cond)
	sync.unlock(&p.lock)
	// (the tree is gone, so the pipes close; past the bound, what holds them is not the tree's: the readers go)
	bound := time.tick_add(time.tick_now(), ENDING_BOUND)
	for !sync.atomic_load(&p.reader_done) || !sync.atomic_load(&p.errors_done) {
		left := time.tick_diff(time.tick_now(), bound)
		if left <= 0 {
			pipes_stop(&p.waker)
			break
		}
		_ = waker_wait(&p.waker, 0, left)
	}
	// (the tree is gone: a write still waiting has no reader of the tree left, only one that left it, which may never
	// read. The writer goes too)
	pipes_stop(&p.waker)
	for th in ([]^thread.Thread{p.reader, p.errors, p.writer}) {
		if th == nil { continue }
		thread.join(th)
		thread.destroy(th)
	}
	p.reader, p.errors, p.writer = nil, nil, nil
	if p.stdin != nil {
		// (the writer closes it; with no writer, here)
		sync.lock(&p.lock)
		stdin := p.stdin
		p.stdin = nil
		sync.unlock(&p.lock)
		if stdin != nil { os.close(stdin) }
	}
	os.close(p.stdout)
	os.close(p.stderr)

	sync.lock(&p.lock)
	tail := tail_text(&p.tail, context.temp_allocator)
	how: How = !ended ? .Unknown : end.signaled ? .Signaled : .Exited
	wake := end_locked(p, {how = how, code = ended ? end.code : 0, stopped = p.stop_asked, stderr = tail})
	sync.unlock(&p.lock)
	process.tree_close(&p.tree)
	if wake { call_wake(p) }
}

// The time limits that passed and the stop's step that is due; the time until the next one (negative: none).
@(private = "file")
watch_step :: proc(p: ^Peer) -> time.Duration {
	now := time.tick_now()
	next := time.Duration(-1)
	soonest :: proc(next: ^time.Duration, d: time.Duration) { if next^ < 0 || d < next^ { next^ = d } }
	wake := false
	sync.lock(&p.lock)
	expired := make([dynamic]i64, context.temp_allocator)
	for id, pend in p.pending {
		if !pend.timed { continue }
		left := time.tick_diff(now, pend.deadline)
		if left <= 0 { append(&expired, id) } else { soonest(&next, left) }
	}
	for id in expired {
		pend := p.pending[id]
		delete_key(&p.pending, id)
		m := message_new(.Reply, 0)
		m.id = id_of_number(id)
		m.local = .Timed_Out
		m.tag, m.user = pend.tag, pend.user
		wake |= push_locked(p, m)
		// (the child may stop the work; its late answer is dropped)
		if !p.stop_asked && p.state < .Ending {
			if data := cancel_bytes(p, id); data != nil { _ = enqueue_locked(p, data) }
		}
	}
	if p.stop_asked && p.state < .Ending {
		since := time.tick_since(p.stop_at)
		if p.stop_step == 0 && since >= p.grace {
			_ = process.tree_signal(&p.tree, .Terminate)
			p.stop_step = 1
		}
		if p.stop_step == 1 && since >= 2 * p.grace {
			process.tree_kill(&p.tree)
			p.stop_step = 2
		}
		switch p.stop_step {
		case 0: soonest(&next, p.grace - since)
		case 1: soonest(&next, 2 * p.grace - since)
		}
	}
	sync.unlock(&p.lock)
	if wake { call_wake(p) }
	return next
}

// ---- the writer

@(private = "file")
writer_main :: proc(p: ^Peer) {
	for {
		sync.lock(&p.lock)
		for p.out_head == len(p.outbound) && p.state < .Ending && !p.stop_asked {
			sync.cond_wait(&p.out_cond, &p.lock)
		}
		if p.out_head == len(p.outbound) || p.state >= .Ending {
			sync.unlock(&p.lock)
			break
		}
		data := p.outbound[p.out_head]
		p.out_head += 1
		p.out_bytes -= len(data)
		if p.out_head == len(p.outbound) {
			clear(&p.outbound)
			p.out_head = 0
		}
		sync.unlock(&p.lock)
		ok := write_pipe(&p.waker, p.stdin, data)
		delete(data, runtime.heap_allocator())
		if !ok { break }
		sync.lock(&p.lock)
		p.stats.sent += 1
		sync.unlock(&p.lock)
	}
	// (the end of the child's input: an ACP agent ends there)
	sync.lock(&p.lock)
	stdin := p.stdin
	p.stdin = nil
	sync.unlock(&p.lock)
	if stdin != nil { os.close(stdin) }
}

// ---- the readers

@(private = "file")
errors_main :: proc(p: ^Peer) {
	buf := make([]u8, READ_BYTES)
	defer delete(buf)
	for {
		n := read_pipe(&p.waker, p.stderr, buf)
		if n <= 0 { break }
		sync.lock(&p.lock)
		tail_write(&p.tail, buf[:n])
		sync.unlock(&p.lock)
	}
	sync.atomic_store(&p.errors_done, true)
	waker_wake(&p.waker)
}

@(private = "file")
reader_main :: proc(p: ^Peer) {
	f := framer_make(p.options.framing, p.options.message_max)
	defer framer_destroy(&f)
	buf := make([]u8, READ_BYTES)
	defer delete(buf)
	for {
		n := read_pipe(&p.waker, p.stdout, buf)
		if n <= 0 { break }
		framer_feed(&f, buf[:n], on_frame, p)
		free_all(context.temp_allocator)
	}
	framer_finish(&f, on_frame, p)
	sync.atomic_store(&p.reader_done, true)
	waker_wake(&p.waker)
}

@(private = "file")
on_frame :: proc(user: rawptr, text: []u8, fault: Frame_Fault, size: int) {
	p := (^Peer)(user)
	switch fault {
	case .Too_Long:  push_bad(p, .Too_Long, nil, size)
	case .No_Length: push_bad(p, .No_Length, nil, size)
	case .None:      handle_text(p, text, true)
	}
}

@(private = "file")
push_bad :: proc(p: ^Peer, kind: Bad_Kind, text: []u8, size: int) {
	keep := text[:min(len(text), BAD_TEXT_MAX)]
	m := message_new(.Bad, len(keep))
	m.bad = kind
	m.size = size
	m.text = strings.clone(string(keep), mem.dynamic_arena_allocator(&m.arena))
	push(p, m)
}

// An error answer from the peer itself (a message it cannot pass on).
@(private = "file")
answer_error :: proc(p: ^Peer, id: Id, code: i64, message: string) {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	if p.stop_asked || p.state >= .Ending { return }
	_ = enqueue_locked(p, encode_error(p.options.framing, id, code, message, "", runtime.heap_allocator()))
}

// One message's text (`top`: not an element of a batch).
@(private = "file")
handle_text :: proc(p: ^Peer, text: []u8, top: bool) {
	if !depth_ok(text) {
		push_bad(p, .Too_Deep, text, len(text))
		return
	}
	m := message_new(.Bad, len(text))
	a := mem.dynamic_arena_allocator(&m.arena)
	m.text = strings.clone(string(text), a)
	m.size = len(text)
	v, err := json.parse_string(m.text, .JSON, true, a)
	if err != .None {
		message_free(m)
		push_bad(p, .Not_Json, text, len(text))
		answer_error(p, {}, PARSE_ERROR, "Parse error")
		return
	}
	if batch, is_batch := v.(json.Array); is_batch && top {
		// (each element on its own: a batch is no protocol's in view, its cost does not matter)
		if len(batch) == 0 {
			answer_error(p, {}, INVALID_REQUEST, "Invalid Request")
		}
		elements := make([dynamic]string, context.temp_allocator)
		for e in batch { append(&elements, tk_json.to_text(e, "", context.temp_allocator)) }
		message_free(m)
		if len(batch) == 0 { push_bad(p, .Not_Rpc, text, len(text)) }
		for e in elements { handle_text(p, transmute([]u8)e, false) }
		return
	}
	sync.lock(&p.lock)
	p.stats.received += 1
	sync.unlock(&p.lock)
	r := read_message(v)
	switch r.shape {
	case .Invalid:
		message_free(m)
		push_bad(p, .Not_Rpc, text, len(text))
	case .Invalid_With_Id:
		message_free(m)
		answer_error(p, r.id, INVALID_REQUEST, "Invalid Request")
		push_bad(p, .Not_Rpc, text, len(text))
	case .Request, .Notification:
		m.kind = r.shape == .Request ? .Request : .Notification
		m.method, m.params, m.id = r.method, r.params, r.id
		push(p, m)
	case .Answer:
		found := false
		pend: Pending
		if r.id.kind == .Number {
			sync.lock(&p.lock)
			pend, found = p.pending[r.id.number]
			if found { delete_key(&p.pending, r.id.number) }
			sync.unlock(&p.lock)
		}
		if !found {
			sync.lock(&p.lock)
			p.stats.dropped += 1
			sync.unlock(&p.lock)
			message_free(m)
			return
		}
		m.kind = .Reply
		m.id = r.id
		m.ok = r.has_result
		m.result, m.error = r.result, r.error
		m.tag, m.user = pend.tag, pend.user
		push(p, m)
	}
}
