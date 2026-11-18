package tk_plugins

// A plugin's process (plugins.md, "As built: the plugin host in its own process"). The program starts its own
// executable again with CHILD_ARG; this package's @(init) sees it before the program's main runs, runs the one plugin
// the start frame names, and ends the process. So a program that imports gt:plugins needs nothing in its main, a test
// program is a plugin host as well, and there is no second binary to ship.
//
// Inside, the plugin runs as it did on a thread of the program: plugin_thread on this process's main thread, its
// messages from a reader of the standard input, its events written to the standard output.

import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"
import plugin_api "../plugin_api"
import "../ui"

// The hidden argument of a plugin's process: the program's executable, started again to host one plugin.
CHILD_ARG :: "--gt-plugin-host"

// Where a child's events go: its standard output, one frame at a time.
@(private)
Child_Out :: struct {
	lock: sync.Mutex,
	file: ^os.File,
}

@(init, private)
child_init :: proc "contextless" () {
	context = runtime.default_context()
	if len(os.args) < 2 || os.args[1] != CHILD_ARG { return }
	context.allocator = runtime.heap_allocator()
	os.exit(child_main())
}

// The child's life: its start, its plugin's runtime, the reader of its messages. The exit code says how it ended
// (the program reads it when the channel closes).
@(private)
child_main :: proc() -> int {
	kind, payload, ok := frame_read(os.stdin)
	if !ok || kind != .Start { return 2 }
	r := plugin_api.Wire_Reader{data = payload}
	p := start_decode(&r)
	if p == nil { return 2 }
	out := new(Child_Out)
	out.file = os.stdout
	p.out = out
	free_all(context.temp_allocator)
	c := runtime.default_context()
	c.allocator = runtime.heap_allocator()
	sync.atomic_add(&p.refs, 1)   // (the reader's)
	reader := thread.create_and_start_with_poly_data(p, child_reader, init_context = c, self_cleanup = true)
	if reader == nil { return 3 }
	// (its own main thread: the engine's stack is this thread's, which the system made large)
	sync.atomic_add(&p.refs, 1)
	plugin_thread(p)
	return 0
}

// The messages from the program. Stop is read here, while the plugin's thread may be inside a script: it raises the
// flag that the engine's interrupt hook reads. The program gone (the end of the input): the plugin stops.
@(private)
child_reader :: proc(p: ^Plugin) {
	defer plugin_release(p)
	for {
		kind, payload, ok := frame_read(os.stdin)
		if !ok || kind != .Message {
			sync.atomic_store(&p.stop, true)
			queue_push(p, {kind = .Quit})
			return
		}
		r := plugin_api.Wire_Reader{data = payload}
		m, good := message_decode(&r)
		free_all(context.temp_allocator)
		if !good {
			sync.atomic_store(&p.stop, true)
			queue_push(p, {kind = .Quit})
			return
		}
		if m.kind == .Stop {
			sync.atomic_store(&p.stop, true)
			message_free(m)
			queue_push(p, {kind = .Quit})
			continue
		}
		queue_push(p, m)
	}
}

// An event of the child's plugin, written to the program. A program gone: the plugin stops.
@(private)
child_event :: proc(p: ^Plugin, kind: Event_Kind, title, text: string, toast: ui.Toast_Kind, list: ^plugin_api.List, req: Request) {
	w := plugin_api.Wire_Writer{buf = make([dynamic]u8, context.temp_allocator)}
	event_encode(&w, kind, title, text, toast, list, req)
	plugin_api.list_free(list)
	sync.lock(&p.out.lock)
	ok := frame_write(p.out.file, .Event, w.buf[:])
	sync.unlock(&p.out.lock)
	if !ok { sync.atomic_store(&p.stop, true) }
}
