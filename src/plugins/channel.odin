package tk_plugins

// The program's end of a plugin's process (child.odin is the other). Two threads per running plugin, neither of them
// the interface's: a sender, which starts the process (a system call, and not thread-safe in core:os: one start at a
// time) and writes the plugin's queue to its input; a reader, which reads its events and posts them as the plugin's
// thread did, then waits for the process's end. The interface's thread only pushes messages and reads atomics.
//
// What the process does cannot reach the program: a crash, an abort, a hang, memory taken. The reader sees the end of
// the output, and the plugin is Failed (Crashed), its views say so; Stop raises the child's interrupt flag, and a child
// that has not ended STOP_BOUND_MS later is killed.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "../platform"
import plugin_api "../plugin_api"
import "../process"
import "../tasks"
import "../ui"

// After a Stop, how long the child's runtime has to end before its process is killed.
STOP_BOUND_MS :: 1000
// The crashes of one plugin's process in one run of the program, after which it is Suspended.
CRASHES_TO_SUSPEND :: 3

// os.process_start changes the inheritance of handles, and is not safe on two threads at once.
@(private) start_lock: sync.Mutex

// One process of a plugin, from its start to the read of its end. Counted: the sender's, the reader's, a kill's.
@(private)
Channel :: struct {
	refs:       i32,          // (atomic)
	lock:       sync.Mutex,   // guards process, started, reaped
	process:    os.Process,
	started:    bool,
	reaped:     bool,         // its end was read: the handle is gone, nothing may kill it any more
	input:      ^os.File,     // the program's end of the child's standard input (the sender's)
	output:     ^os.File,     // ... of its standard output (the reader's)
	closed:     bool,         // (atomic) the child's output ended: the sender stops
	ended_seen: bool,         // the child said Ended (the reader's)
	pending:    i32,          // (atomic) messages written that no turn answered yet: the bound counts from the oldest
}

@(private)
channel_release :: proc(ch: ^Channel) {
	if sync.atomic_sub(&ch.refs, 1) == 1 { free(ch, runtime.heap_allocator()) }
}

// A plugin's process, started on the sender's thread. Interface thread: no system call here.
@(private)
channel_start :: proc(p: ^Plugin) -> bool {
	ch := new(Channel, runtime.heap_allocator())
	ch.refs = 2   // (the sender's, and the plugin's until its next process or its end)
	if p.ch != nil { channel_release(p.ch) }
	p.ch = ch
	sync.atomic_add(&p.refs, 1)
	c := runtime.default_context()
	c.allocator = runtime.heap_allocator()
	if thread.create_and_start_with_poly_data2(p, ch, channel_send, init_context = c, self_cleanup = true) == nil {
		sync.atomic_sub(&p.refs, 1)
		channel_release(ch)
		channel_release(ch)
		p.ch = nil
		return false
	}
	return true
}

@(private)
channel_send :: proc(p: ^Plugin, ch: ^Channel) {
	defer plugin_release(p)
	defer channel_release(ch)
	serial := p.serial
	if why := channel_open(p, ch); why != "" {
		event_deliver(p, serial, .Failed, text = why)
		event_deliver(p, serial, .Ended)
		sync.atomic_store(&p.ended, true)
		link_release(p.link)
		return
	}
	w := plugin_api.Wire_Writer{buf = make([dynamic]u8, context.temp_allocator)}
	start_encode(&w, p)
	for s in p.settings_start { setting_now_free(s) }   // (the program's copy: the child has its own now)
	delete(p.settings_start)
	p.settings_start = nil
	busy_more(p, ch)   // (the start is a turn: activate)
	ok := frame_write(ch.input, .Start, w.buf[:])
	free_all(context.temp_allocator)
	for ok {
		m, have := sender_take(p, ch)
		if !have { break }
		quit := m.kind == .Quit
		if m.kind != .Quit && m.kind != .Stop { busy_more(p, ch) }
		w = {buf = make([dynamic]u8, context.temp_allocator)}
		message_encode(&w, m)
		message_free(m)
		ok = frame_write(ch.input, .Message, w.buf[:])
		free_all(context.temp_allocator)
		if quit { break }
	}
	// (the child's input ends: a child whose runtime waits on its queue stops; one that hangs is killed by Stop's bound)
	os.close(ch.input)
}

// The process started, and its reader. "": done; else why it could not start.
@(private)
channel_open :: proc(p: ^Plugin, ch: ^Channel) -> string {
	exe := process.executable_path()
	if exe == "" { return "its process cannot start: the program's executable is not known" }
	// (the pipes are made under the start's lock too: on Windows the child's ends are inheritable until they are closed
	// below, and another plugin's process started meanwhile took them, so this child's end never came)
	sync.lock(&start_lock)
	in_r, in_w, e1 := os.pipe()
	if e1 != nil { sync.unlock(&start_lock); return fmt.tprintf("its process cannot start: no pipe (%v)", e1) }
	out_r, out_w, e2 := os.pipe()
	if e2 != nil {
		sync.unlock(&start_lock)
		os.close(in_r); os.close(in_w)
		return fmt.tprintf("its process cannot start: no pipe (%v)", e2)
	}
	pipe_not_inherited(in_w)
	pipe_not_inherited(out_r)
	// (a process that dies leaves its input closed: the sender's next write must be an error, not the program's end)
	platform.sigpipe_ignore()
	child, err := sandbox_spawn(exe, in_r, out_w)
	// (the child's ends are the child's: the program keeps the two it uses, and sees the end of the output when the
	// child's goes)
	os.close(in_r)
	os.close(out_w)
	sync.unlock(&start_lock)
	if err != nil {
		os.close(in_w); os.close(out_r)
		return fmt.tprintf("its process cannot start (%v)", err)
	}
	sync.lock(&ch.lock)
	ch.process, ch.started = child, true
	sync.unlock(&ch.lock)
	ch.input, ch.output = in_w, out_r
	sync.atomic_add(&ch.refs, 1)
	sync.atomic_add(&p.refs, 1)
	c := runtime.default_context()
	c.allocator = runtime.heap_allocator()
	if thread.create_and_start_with_poly_data2(p, ch, channel_read, init_context = c, self_cleanup = true) == nil {
		sync.atomic_sub(&p.refs, 1)
		sync.atomic_sub(&ch.refs, 1)
		_ = os.process_kill(child)
		os.close(in_w); os.close(out_r)
		return "its process cannot be read: no thread"
	}
	return ""
}

// The next message to write, or none once the child's output ended (its reader closed the channel).
@(private)
sender_take :: proc(p: ^Plugin, ch: ^Channel) -> (m: Message, ok: bool) {
	q := &p.queue
	sync.lock(&q.lock)
	defer sync.unlock(&q.lock)
	for len(q.messages) == 0 && !sync.atomic_load(&ch.closed) { sync.wait(&q.came, &q.lock) }
	// (a closed channel's child is gone: what waits in the queue is for the next process)
	if sync.atomic_load(&ch.closed) || len(q.messages) == 0 { return }
	return pop_front(&q.messages), true
}

// A message written: the plugin is busy from now on if it was not (Not_Responding's bound counts from here).
@(private)
busy_more :: proc(p: ^Plugin, ch: ^Channel) {
	if sync.atomic_add(&ch.pending, 1) == 0 { sync.atomic_store(&p.busy_since, now_ms()) }
}

// A turn answered: the bound starts again for the next message written, or stops.
@(private)
busy_less :: proc(p: ^Plugin, ch: ^Channel) {
	if sync.atomic_load(&ch.pending) <= 0 { return }
	left := sync.atomic_sub(&ch.pending, 1) - 1
	sync.atomic_store(&p.busy_since, left > 0 ? now_ms() : 0)
}

@(private)
channel_read :: proc(p: ^Plugin, ch: ^Channel) {
	defer plugin_release(p)
	defer channel_release(ch)
	serial := p.serial
	broken := ""
	for {
		kind, payload, ok := frame_read(ch.output)
		if !ok { break }
		if kind != .Event { broken = "it wrote something that is not an event"; break }
		r := plugin_api.Wire_Reader{data = payload}
		ek, toast, title, text, list, req, rows, good := event_decode(&r)
		free_all(context.temp_allocator)
		if !good { broken = "it wrote an event that cannot be read"; break }
		#partial switch ek {
		case .Alive:
			// (the bound of the start counted the system's start of the process, slow on a busy machine: it counts
			// again from the child's first word, as the plugin's code begins)
			if sync.atomic_load(&ch.pending) > 0 { sync.atomic_store(&p.busy_since, now_ms()) }
			request_free(&req)
			delete(title); delete(text)
			plugin_api.list_free(list)
			continue
		case .Log:
			// (this thread is the program's and not the interface's: a file's write may wait here)
			log_append(p.log_path, text)
			request_free(&req)
			delete(title); delete(text)
			plugin_api.list_free(list)
			continue
		case .Started, .Turn_Done, .Failed:
			busy_less(p, ch)
			turn_done(p)
		case .Ended:
			ch.ended_seen = true
		case .Request:
			// (stamped here, while its turn runs: by the interface's thread the turn may be over)
			req.gesture = turn_is_gesture(p)
		}
		event_deliver(p, serial, ek, title = title, text = text, toast = toast, list = list, req = req, rows = rows)
		request_free(&req)
		delete(title); delete(text)
	}
	os.close(ch.output)
	// (a channel that broke: the child goes; one whose output ended: it went, or is going)
	if broken != "" { channel_kill(ch) }
	state, _ := os.process_wait(ch.process)
	sync.lock(&ch.lock)
	ch.reaped = true
	sync.unlock(&ch.lock)
	sync.atomic_store(&ch.pending, 0)
	sync.atomic_store(&p.busy_since, 0)
	// (the sender stops before the interface hears of the end: once it has, a restart pushes the next process's
	// messages to the same queue, which this sender must not take to a dead pipe)
	sync.atomic_store(&ch.closed, true)
	sync.lock(&p.queue.lock)
	sync.broadcast(&p.queue.came)
	sync.unlock(&p.queue.lock)
	if !ch.ended_seen {
		// (the runtime did not say it ended: the process crashed, was killed, or broke its channel)
		if !sync.atomic_load(&p.stop) || broken != "" {
			why := broken != "" ? broken : fmt.tprintf("its process ended without a word (%s)", exit_words(state))
			event_deliver(p, serial, .Crashed, text = why)
		}
		event_deliver(p, serial, .Ended)
	}
	sync.atomic_store(&p.ended, true)
	link_release(p.link)
}

@(private)
exit_words :: proc(s: os.Process_State) -> string {
	if !s.exited { return "it did not exit" }
	return fmt.tprintf("exit code %d", s.exit_code)
}

// Kills the child, unless its end was read already (its handle gone).
@(private)
channel_kill :: proc(ch: ^Channel) {
	sync.lock(&ch.lock)
	defer sync.unlock(&ch.lock)
	if ch.started && !ch.reaped { _ = os.process_kill(ch.process) }
}

// Stop's bound: the child of `ch` is killed when its runtime has not ended (a chore, STOP_BOUND_MS after the Stop).
@(private)
stop_bound :: proc(p: ^Plugin) {
	ch := p.ch
	if ch == nil { return }
	context.allocator = runtime.heap_allocator()   // (the chores' queue is the process's)
	sync.atomic_add(&ch.refs, 1)
	if !tasks.add(ui.chores(), proc(data: rawptr) {
		ch := (^Channel)(data)
		if !sync.atomic_load(&ch.closed) { channel_kill(ch) }
		channel_release(ch)
	}, ch, {after_ms = STOP_BOUND_MS}) {
		channel_release(ch)
	}
}

// Ends a plugin's process, a test's way to see a crash of the engine (an abort inside the child): its next turn
// panics there. The program goes on; the plugin is Failed. Interface thread.
test_crash :: proc(h: ^Host, id: string) {
	if p := find(h, id); p != nil && p.alive { queue_push(p, {kind = .Test_Crash}) }
}

// Makes a plugin's process try what its sandbox must stop, a test's way to see it: read the file `read_path`, create
// a file in the folder `create_dir`, open a TCP socket. Its next turn tries them, then a toast says "escaped: none",
// or which it could ("escaped: read, create, socket"). Interface thread.
test_escape :: proc(h: ^Host, id: string, read_path, create_dir: string) {
	context.allocator = runtime.heap_allocator()   // (the message's strings are freed by the sender: the heap's)
	if p := find(h, id); p != nil && p.alive {
		queue_push(p, {kind = .Test_Escape, text = strings.clone(read_path), command = strings.clone(create_dir)})
	}
}

// Makes a plugin's process hang where its interrupt flag is not read, a test's way to see Stop's kill: its next turn
// waits for ever. Interface thread.
test_hang :: proc(h: ^Host, id: string) {
	if p := find(h, id); p != nil && p.alive { queue_push(p, {kind = .Test_Hang}) }
}
