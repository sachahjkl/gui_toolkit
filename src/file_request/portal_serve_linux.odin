#+build linux
package file_request

// The XDG portal's FileChooser backend (src/md/features/file-picker.md): a D-Bus adapter. It owns PORTAL_BUS_NAME,
// serves OpenFile, SaveFile and SaveFiles at PORTAL_OBJECT, and answers each call with a process of its own: `child`
// (gt-file-picker --json) gets the request as JSON on its stdin and prints the answer as JSON. The bus is driven by one
// thread (the one in portal_run); each call's process is fed and read by a thread of its own, which wakes the bus's
// thread through a pipe when its answer is there. Close on a call's Request object ends its process.

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import "../dbus"
import "../platform"

// RequestName's flag: fail when another process owns the name, rather than wait in its queue.
@(private = "file") NAME_DO_NOT_QUEUE :: 4

Portal_Server :: struct {
	conn:    ^dbus.Conn,
	child:   []string,              // the command that answers one request (heap)
	wake:    [2]linux.Fd,           // a call's thread writes a byte: its answer is there
	calls:   [dynamic]^Portal_Pending,
	stopped: bool,                  // (atomic) portal_stop
}

// One call on its way.
@(private)
Portal_Pending :: struct {
	server:  ^Portal_Server,
	arena:   virtual.Arena,         // the call, its request, its address (the bus thread's)
	call:    Portal_Call,
	sender:  string,
	serial:  u32,
	json:    string,                // the request, for the process's stdin
	process: os.Process,
	started: bool,
	input:   ^os.File,              // the write end of its stdin
	output:  ^os.File,              // the read end of its stdout
	worker:  ^thread.Thread,
	answer:  platform.Dialog_Result,   // (heap) set by the worker
	done:    bool,                     // (atomic) the worker ended
	lock:    sync.Mutex,               // the process, against Close
	closed:  bool,
}

// Connects to the bus (`address`: "" the session's), owns the backend's name, serves its object. `why` says what
// failed ("": it serves).
portal_open :: proc(s: ^Portal_Server, child: []string, address := "") -> (why: string) {
	a := runtime.heap_allocator()
	// (the connection allocates in the context's allocator as it goes: the heap's in every procedure of the server)
	context.allocator = a
	s^ = {}
	s.conn = address == "" ? dbus.connect_bus(.Session, a) : dbus.connect_bus_address(address, a)
	if s.conn == nil { return "no session bus" }
	if !dbus.request_name(s.conn, PORTAL_BUS_NAME, NAME_DO_NOT_QUEUE) {
		dbus.conn_close(s.conn)
		s.conn = nil
		return "another process serves " + PORTAL_BUS_NAME
	}
	// (a request's process may end before it read its request (Close kills it): the write then fails, it does not end
	// the server. A process-wide setting: a server's process serves, nothing else)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	s.child = make([]string, len(child), a)
	for c, i in child { s.child[i] = strings.clone(c, a) }
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC, .NONBLOCK}) != .NONE {
		portal_close(s)
		return "no pipe"
	}
	s.wake = fds
	s.calls = make([dynamic]^Portal_Pending, a)
	dbus.export_object(s.conn, PORTAL_OBJECT, portal_on_call, s)
	return ""
}

// Serves until portal_stop or the bus goes. The thread that calls it drives the bus.
portal_run :: proc(s: ^Portal_Server) {
	context.allocator = runtime.heap_allocator()
	for !sync.atomic_load(&s.stopped) && dbus.conn_alive(s.conn) {
		fds := [2]linux.Poll_Fd{{fd = linux.Fd(dbus.conn_fd(s.conn)), events = {.IN}}, {fd = s.wake[0], events = {.IN}}}
		_, _ = linux.poll(fds[:], -1)
		dbus.dispatch(s.conn)
		buf: [64]u8
		for {
			n, err := linux.read(s.wake[0], buf[:])
			if err != .NONE || n <= 0 { break }
		}
		portal_reply_done(s)
	}
}

// Ends portal_run, from any thread.
portal_stop :: proc(s: ^Portal_Server) {
	sync.atomic_store(&s.stopped, true)
	_, _ = linux.write(s.wake[1], {1})
}

// After portal_run: the calls on their way are ended (their processes killed, their threads joined), the bus closed.
portal_close :: proc(s: ^Portal_Server) {
	a := runtime.heap_allocator()
	context.allocator = a   // (conn_close frees in the context's allocator: the connection is the heap's)
	for p in s.calls {
		portal_pending_close(p)
		thread.join(p.worker)
		thread.destroy(p.worker)
		portal_pending_free(p)
	}
	delete(s.calls)
	if s.conn != nil { dbus.conn_close(s.conn) }
	for c in s.child { delete(c, a) }
	delete(s.child, a)
	if s.wake[0] != 0 { linux.close(s.wake[0]); linux.close(s.wake[1]) }
	s^ = {}
}

// A call of the FileChooser interface: read, its process started, its Request object served; the reply comes when the
// process answers (portal_reply_done).
@(private = "file")
portal_on_call :: proc(user: rawptr, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	s := (^Portal_Server)(user)
	if msg.iface != PORTAL_INTERFACE { return false }
	a := runtime.heap_allocator()
	p := new(Portal_Pending, a)
	p.server = s
	pa := virtual.arena_allocator(&p.arena)
	r := dbus.msg_reader(msg)
	call, ok := portal_read_call(msg.member, &r, pa)
	if !ok {
		virtual.arena_destroy(&p.arena)
		free(p, a)
		return false   // (the connection answers UnknownMethod)
	}
	p.call = call
	p.sender = strings.clone(msg.sender, pa)
	p.serial = msg.serial
	p.json = request_json(call.request, pa)
	// (started on this thread: os.process_start is not safe while another thread starts one)
	in_r, in_w, err1 := os.pipe()
	out_r, out_w, err2 := os.pipe()
	if err1 == nil && err2 == nil {
		proc_, err := os.process_start({command = s.child, stdin = in_r, stdout = out_w, stderr = os.stderr})
		if err == nil { p.process, p.started = proc_, true }
	}
	if in_r != nil { os.close(in_r) }
	if out_w != nil { os.close(out_w) }
	p.input, p.output = in_w, out_r
	dbus.export_object(c, call.handle, portal_on_request, p)
	append(&s.calls, p)
	p.worker = thread.create_and_start_with_data(p, portal_pending_work, init_context = runtime.default_context())
	return true
}

// Close on a call's Request object: its process ends; the call is answered as ended.
@(private = "file")
portal_on_request :: proc(user: rawptr, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	p := (^Portal_Pending)(user)
	if msg.iface != PORTAL_REQUEST_INTERFACE || msg.member != "Close" { return false }
	portal_pending_close(p)
	dbus.reply_return(c, msg, "", nil)
	return true
}

@(private = "file")
portal_pending_close :: proc(p: ^Portal_Pending) {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	if p.closed { return }
	p.closed = true
	if p.started { _ = os.process_kill(p.process) }
}

// A call's thread: the request to the process, its answer read to the end, the process waited for.
@(private = "file")
portal_pending_work :: proc(data: rawptr) {
	p := (^Portal_Pending)(data)
	a := runtime.heap_allocator()
	if p.started {
		_, _ = os.write(p.input, transmute([]u8)p.json)
		os.close(p.input)
		p.input = nil
		out, _ := os.read_entire_file(p.output, a)
		_, _ = os.process_wait(p.process)
		sync.lock(&p.lock)
		closed := p.closed
		sync.unlock(&p.lock)
		p.answer = closed ? platform.Dialog_Result{status = .Cancelled} : parse_answer_json(string(out), a)
		delete(out, a)
	} else {
		p.answer = {status = .Failed}
	}
	sync.atomic_store(&p.done, true)
	_, _ = linux.write(p.server.wake[1], {1})
}

// The calls whose process answered: replied, their Request object gone.
@(private = "file")
portal_reply_done :: proc(s: ^Portal_Server) {
	for i := 0; i < len(s.calls); {
		p := s.calls[i]
		if !sync.atomic_load(&p.done) { i += 1; continue }
		thread.join(p.worker)
		thread.destroy(p.worker)
		w := dbus.body_writer()
		portal_write_reply(&w, p.call, p.answer)
		to := dbus.Message{sender = p.sender, serial = p.serial}
		dbus.reply_return(s.conn, &to, "ua{sv}", w.buf[:])
		dbus.export_remove(s.conn, p.call.handle)
		ordered_remove(&s.calls, i)
		portal_pending_free(p)
	}
}

@(private = "file")
portal_pending_free :: proc(p: ^Portal_Pending) {
	a := runtime.heap_allocator()
	if p.input != nil { os.close(p.input) }
	if p.output != nil { os.close(p.output) }
	platform.dialog_result_destroy(&p.answer, a)
	virtual.arena_destroy(&p.arena)
	free(p, a)
}
