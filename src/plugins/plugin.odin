package tk_plugins

// A plugin: what the interface's thread knows of it, its queue of messages, and the words its thread shares (the stop
// flag the engine's interrupt hook reads, the time its message began). Counted: the host's, its thread's, each post's.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import config "../config"
import plugin_api "../plugin_api"
import "../ui"

Plugin :: struct {
	refs:      i32,         // (atomic)
	// the interface thread's
	manifest:  Manifest,
	refused:   string,      // why it cannot load (owned; "": it can)
	failure:   string,      // why it failed last (owned)
	state:     Plugin_State,
	enabled:   bool,        // plugins.toml says it is on
	suspended: bool,        // the program ended inside it: off until the person turns it on
	alive:     bool,        // its thread runs (from plugin_start to its Ended post)
	dropped:   bool,        // the host let go of it (reload, close): its posts change nothing
	host:      ^Host,       // read only while !dropped
	serial:    u64,         // its runtime's: a post of an older runtime is dropped
	// set before its thread starts, read by it (owned)
	folder:      string,    // its folder, absolute
	log_path:    string,
	marker_path: string,
	memory_limit: i64,
	settings_start: []Setting_Now,   // its settings' values when its thread starts (heap: the thread takes and frees them)
	link:        ^Host_Link,   // (counted while its thread runs: the thread lets go of it as it ends)
	// shared with its thread
	queue:      Queue,
	stop:       bool,       // (atomic) read by the engine's interrupt hook: true unwinds the script
	busy_since: i64,        // (atomic) now_ms when its thread took the message it runs; 0: waiting
	ended:      bool,       // (atomic) its thread left the engine for good
}

@(private)
plugin_new :: proc() -> ^Plugin {
	p := new(Plugin, runtime.heap_allocator())
	p.refs = 1
	return p
}

@(private)
plugin_release :: proc(p: ^Plugin) {
	if sync.atomic_sub(&p.refs, 1) != 1 { return }
	context.allocator = runtime.heap_allocator()
	manifest_destroy(&p.manifest)
	delete(p.refused); delete(p.failure)
	delete(p.folder); delete(p.log_path); delete(p.marker_path)
	queue_destroy(&p.queue)
	free(p)
}

// Its thread and runtime, now (its first use). Interface thread.
@(private)
plugin_start :: proc(h: ^Host, p: ^Plugin) {
	p.serial += 1
	sync.atomic_store(&p.stop, false)
	sync.atomic_store(&p.ended, false)
	sync.atomic_store(&p.busy_since, 0)
	queue_clear(&p.queue)
	p.alive = true
	p.state = .Starting
	p.memory_limit = h.o.memory_limit
	p.settings_start = settings_snapshot(h, p)
	p.link = h.link
	sync.atomic_add(&h.link.refs, 1)
	sync.atomic_add(&p.refs, 1)
	c := runtime.default_context()
	c.allocator = runtime.heap_allocator()
	t := thread.create_and_start_with_poly_data(p, plugin_thread, init_context = c, self_cleanup = true)
	if t == nil {
		// (no thread to be had: the plugin is said failed, as an activate that threw)
		p.alive = false
		for s in p.settings_start { setting_now_free(s) }
		delete(p.settings_start, runtime.heap_allocator())
		p.state = .Failed
		delete(p.failure)
		p.failure = strings.clone("no thread could be started for it")
		link_release(h.link)
		sync.atomic_sub(&p.refs, 1)
	}
}

// Stop: the flag for the interrupt hook, and Quit for a thread that waits on its queue. Interface thread.
@(private)
plugin_stop :: proc(p: ^Plugin) {
	if !p.alive { return }
	sync.atomic_store(&p.stop, true)
	queue_push(p, {kind = .Quit})
}

////////////////////////////////
// The queue

@(private)
Message_Kind :: enum u8 {
	Command,      // `command`
	Quit,
	View_Open,    // `view` is shown: its render runs
	View_Close,   // `view` is closed: no render until it opens again
	View_Event,   // a node of `view` was used: `key`, `event`, and `text`, `flag`, `serial` for a change
	Setting,      // the setting `key` changed: its kind in `setting`, its value in `flag`, `number` or `text`
}

// What happened to a node of a view: the name of the field of its kind's struct that is called (plugin_api's nodes).
@(private)
View_Event :: enum u8 { onClick, onChange, onSubmit }

@(private)
Message :: struct {
	kind:    Message_Kind,
	command: string,   // (heap, owned by the message; the same for the strings below)
	view:    string,
	key:     string,
	event:   View_Event,
	text:    string,   // a field's text
	flag:    bool,     // a check box's or a switch's state
	is_flag: bool,     // the change is a box's (`flag`), not a field's (`text`)
	serial:  u64,      // a change's: the person's changes of this key so far (the replay's Control.changes)
	setting: config.Kind,
	number:  f64,      // an Int or Float setting's value
}

@(private)
message_free :: proc(m: Message) {
	a := runtime.heap_allocator()
	delete(m.command, a); delete(m.view, a); delete(m.key, a); delete(m.text, a)
}

@(private)
Queue :: struct {
	lock:     sync.Mutex,
	came:     sync.Cond,
	messages: [dynamic]Message,
}

@(private)
queue_push :: proc(p: ^Plugin, m: Message) {
	context.allocator = runtime.heap_allocator()
	q := &p.queue
	sync.lock(&q.lock)
	append(&q.messages, m)
	sync.unlock(&q.lock)
	sync.signal(&q.came)
}

// The next message, waiting for it (the plugin's thread only).
@(private)
queue_take :: proc(p: ^Plugin) -> Message {
	q := &p.queue
	sync.lock(&q.lock)
	defer sync.unlock(&q.lock)
	for len(q.messages) == 0 { sync.wait(&q.came, &q.lock) }
	return pop_front(&q.messages)
}

@(private)
queue_clear :: proc(q: ^Queue) {
	sync.lock(&q.lock)
	for m in q.messages { message_free(m) }
	clear(&q.messages)
	sync.unlock(&q.lock)
}

@(private)
queue_destroy :: proc(q: ^Queue) {
	queue_clear(q)
	delete(q.messages)
}

////////////////////////////////
// What a plugin's thread posts

@(private)
Event_Kind :: enum u8 {
	Started,     // activate ended: Running
	Turn_Done,   // a message ran: back from Not_Responding
	Failed,      // activate threw, or the memory limit: `text`
	Toast,       // toast.show, or an uncaught exception's one toast: `title`, `text`, `toast`
	Ended,       // its thread left the engine: Ready (or Off, or Failed stays)
	List,        // a view's new display list: `title` is the view's id, `list` the list
}

@(private)
Event :: struct {
	p:      ^Plugin,   // (counted)
	serial: u64,
	kind:   Event_Kind,
	toast:  ui.Toast_Kind,
	title:  string,    // (heap, owned)
	text:   string,
	list:   ^plugin_api.List,   // (owned until a view's record takes it)
}

// Posts an event of `p`'s runtime `serial` (the plugin's thread). Lost when the host is closed.
@(private)
event_post :: proc(p: ^Plugin, serial: u64, kind: Event_Kind, title := "", text := "", toast := ui.Toast_Kind.Info, list: ^plugin_api.List = nil) {
	context.allocator = runtime.heap_allocator()
	e := new(Event)
	e^ = {p = p, serial = serial, kind = kind, toast = toast, title = strings.clone(title), text = strings.clone(text), list = list}
	sync.atomic_add(&p.refs, 1)
	if !link_post(p.link, event_run, e) { event_free(e) }
}

@(private)
event_free :: proc(e: ^Event) {
	context.allocator = runtime.heap_allocator()
	delete(e.title); delete(e.text)
	plugin_api.list_free(e.list)
	plugin_release(e.p)
	free(e)
}

// An event, on the interface's thread.
@(private)
event_run :: proc(data: rawptr, word: u64) {
	context.allocator = runtime.heap_allocator()
	e := (^Event)(data)
	defer event_free(e)
	p := e.p
	if p.dropped || e.serial != p.serial { return }
	h := p.host
	switch e.kind {
	case .Started:
		if p.state == .Starting { p.state = .Running }
	case .Turn_Done:
		if p.state == .Not_Responding || p.state == .Starting { p.state = .Running }
	case .Failed:
		p.state = .Failed
		delete(p.failure)
		p.failure = strings.clone(e.text)
		h.source.version += 1
		say(h, .Bad, fmt_failed(p.manifest.name), e.text)
	case .Toast:
		say(h, e.toast, e.title != "" ? e.title : e.text, e.title != "" ? e.text : "")
	case .Ended:
		p.alive = false
		queue_clear(&p.queue)   // (a command sent while it ended: dropped, as its Stop asked)
		if p.state != .Failed && p.state != .Suspended { p.state = p.enabled ? .Ready : .Off }
		views_ended(h, p)
	case .List:
		if r := view_record(h, p.manifest.id, e.title); r != nil {
			view_take_list(r, e.list)
			e.list = nil
		}
	}
}

@(private)
fmt_failed :: proc(name: string) -> string {
	return strings.concatenate({name, " failed"}, context.temp_allocator)
}
