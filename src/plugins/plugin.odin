package tk_plugins

// A plugin: what the interface's thread knows of it, its queue of messages, and the words its process's threads share
// with it (the program's sender and reader: channel.odin). The same struct is the plugin inside its process
// (child.odin), where `out` is set, the queue is read by the plugin's thread and `stop` is the engine's interrupt flag.
// Counted: the host's, each thread's, each post's.

import "base:runtime"
import "core:strings"
import "core:sync"
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
	suspended: bool,        // its process crashed CRASHES_TO_SUSPEND times: off until the person turns it on
	crashes:   int,         // its process's crashes in this run of the program
	granted:   [dynamic]string,   // the permissions the person granted it (owned; plugins.toml)
	picked:    [dynamic]string,   // the files and folders the person picked for it, granted until revoked (owned)
	asks_more: bool,        // its manifest asks what was not granted: off until the person grants it (grant dialog)
	data_dir:  string,      // its own data folder, no permission needed (owned; "" when the system has none)
	alive:     bool,        // its process runs (from plugin_start to its Ended post)
	dropped:   bool,        // the host let go of it (reload, close): its posts change nothing
	host:      ^Host,       // read only while !dropped
	serial:    u64,         // its process's: a post of an older process is dropped
	// set before its process starts, read by the sender (owned)
	folder:      string,    // its folder, absolute
	log_path:    string,
	memory_limit: i64,
	settings_start: []Setting_Now,   // its settings' values when its process starts (heap: the sender sends and frees them)
	link:        ^Host_Link,   // (counted while its process runs: the last of its threads lets go of it)
	ch:          ^Channel,     // its process now (nil: none started yet)
	// shared with its threads
	queue:      Queue,
	stop:       bool,       // (atomic) the program: a Stop was asked; the child: the engine's interrupt flag
	busy_since: i64,        // (atomic) now_ms since the oldest message no turn answered; 0: none
	ended:      bool,       // (atomic) its process ended and was read for good
	// the child's only: where its events go (nil in the program), and what its bridge lets through (the start's)
	out:        ^Child_Out,
	granted_caps: plugin_api.Capabilities,
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
	delete(p.folder); delete(p.log_path); delete(p.data_dir)
	for g in p.granted { delete(g) }
	delete(p.granted)
	for g in p.picked { delete(g) }
	delete(p.picked)
	for s in p.settings_start { setting_now_free(s) }
	delete(p.settings_start)
	if p.ch != nil { channel_release(p.ch) }
	queue_destroy(&p.queue)
	free(p)
}

// Its process and runtime, now (its first use): started by its sender's thread. Interface thread.
@(private)
plugin_start :: proc(h: ^Host, p: ^Plugin) {
	p.serial += 1
	sync.atomic_store(&p.stop, false)
	sync.atomic_store(&p.ended, false)
	sync.atomic_store(&p.busy_since, 0)
	queue_clear(&p.queue)
	sync.lock(&p.queue.lock)
	append(&p.queue.turns, false)   // (the start's turn: activate, no person's act)
	sync.unlock(&p.queue.lock)
	p.alive = true
	p.state = .Starting
	p.memory_limit = h.o.memory_limit
	p.settings_start = settings_snapshot(h, p)
	p.link = h.link
	sync.atomic_add(&h.link.refs, 1)
	if !channel_start(p) {
		// (no thread to be had: the plugin is said failed, as an activate that threw)
		p.alive = false
		for s in p.settings_start { setting_now_free(s) }
		delete(p.settings_start, runtime.heap_allocator())
		p.settings_start = nil
		p.state = .Failed
		delete(p.failure)
		p.failure = strings.clone("no thread could be started for its process")
		link_release(h.link)
	}
}

// Stop: the child's interrupt flag first (ahead of what waits in the queue), then Quit; a child still there after
// STOP_BOUND_MS is killed. Interface thread.
@(private)
plugin_stop :: proc(p: ^Plugin) {
	if !p.alive { return }
	sync.atomic_store(&p.stop, true)
	queue_push(p, {kind = .Stop}, front = true)
	queue_push(p, {kind = .Quit})
	stop_bound(p)
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
	Stop,         // the child's reader raises the interrupt flag at once (it is read while a script runs)
	Test_Crash,   // the child's runtime panics at this turn (test_crash)
	Test_Hang,    // the child's runtime waits for ever outside the engine, where no interrupt reaches it (test_hang)
	// the broker's answer to the request `serial` (broker.odin): `flag` ok; `is_flag` a value is there (files.pick:
	// none, the person picked nothing); `text` the value or the error's message; `key` the error's name; `number` a
	// response's status; `command` its address
	Answer,
	Rows,         // the rows `rows` of the lazy list `key` of `view` (lazy_list.odin)
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
	rows:    Rows_Ask, // a lazy list's ask
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
	// the program's: the turns pushed and not answered yet, oldest first, each true when it is a person's act (a
	// command, a node of a view used). The reader stamps each request of the process with the oldest: clipboard.read
	// and files.pick need one. Popped as busy_less is called (Started, Turn_Done, Failed).
	turns:    [dynamic]bool,
}

// `front`: before what waits (a Stop).
@(private)
queue_push :: proc(p: ^Plugin, m: Message, front := false) {
	context.allocator = runtime.heap_allocator()
	q := &p.queue
	sync.lock(&q.lock)
	if front { inject_at(&q.messages, 0, m) } else { append(&q.messages, m) }
	// (the program's only: the process's own queue has no requests to stamp)
	if p.out == nil && m.kind != .Quit && m.kind != .Stop { append(&q.turns, m.kind == .Command || m.kind == .View_Event) }
	sync.unlock(&q.lock)
	sync.broadcast(&q.came)
}

// Whether the turn running in the process is a person's act (the program's reader, at a request), and the turn's end.
@(private)
turn_is_gesture :: proc(p: ^Plugin) -> bool {
	q := &p.queue
	sync.lock(&q.lock)
	defer sync.unlock(&q.lock)
	return len(q.turns) > 0 && q.turns[0]
}

@(private)
turn_done :: proc(p: ^Plugin) {
	q := &p.queue
	sync.lock(&q.lock)
	defer sync.unlock(&q.lock)
	if len(q.turns) > 0 { ordered_remove(&q.turns, 0) }
}

// The next message, waiting for it (the plugin's thread, in its process).
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
	clear(&q.turns)
	sync.unlock(&q.lock)
}

@(private)
queue_destroy :: proc(q: ^Queue) {
	queue_clear(q)
	delete(q.messages)
	delete(q.turns)
}

////////////////////////////////
// What a plugin's process says

@(private)
Event_Kind :: enum u8 {
	Started,     // activate ended: Running
	Turn_Done,   // a message ran: back from Not_Responding
	Failed,      // activate threw, or the memory limit: `text`
	Toast,       // toast.show, or an uncaught exception's one toast: `title`, `text`, `toast`
	Ended,       // its runtime ended: Ready (or Off, or Failed stays)
	List,        // a view's new display list: `title` is the view's id, `list` the list
	Crashed,     // its process ended with no word of its runtime (the program's reader says it): `text`
	Request,     // a call for the broker (files, the network, the clipboard): `req`
	Rows,        // a lazy list's rows: `title` the view's id, `text` the list's key, `list` the rows, `rows` the ask
	Alive,       // its process read its start: the bound counts from here (the program's reader only)
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
	req:    Request,   // (owned)
	rows:   Rows_Ask,
}

// An event of the plugin's runtime (its thread, inside its process): written to the program. `serial` is the
// program's to set (the reader's).
@(private)
event_post :: proc(p: ^Plugin, serial: u64, kind: Event_Kind, title := "", text := "", toast := ui.Toast_Kind.Info, list: ^plugin_api.List = nil, req := Request{}, rows := Rows_Ask{}) {
	child_event(p, kind, title, text, toast, list, req, rows)
}

// An event of the plugin's process `serial`, posted to the interface's thread (the program's reader and sender).
// Lost when the host is closed. Takes `list`; copies `req`.
@(private)
event_deliver :: proc(p: ^Plugin, serial: u64, kind: Event_Kind, title := "", text := "", toast := ui.Toast_Kind.Info, list: ^plugin_api.List = nil, req := Request{}, rows := Rows_Ask{}) {
	context.allocator = runtime.heap_allocator()
	e := new(Event)
	e^ = {p = p, serial = serial, kind = kind, toast = toast, title = strings.clone(title), text = strings.clone(text), list = list, req = request_clone(req), rows = rows}
	sync.atomic_add(&p.refs, 1)
	if !link_post(p.link, event_run, e) { event_free(e) }
}

@(private)
event_free :: proc(e: ^Event) {
	context.allocator = runtime.heap_allocator()
	delete(e.title); delete(e.text)
	plugin_api.list_free(e.list)
	request_free(&e.req)
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
	case .Alive:   // (the reader's: never posted)
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
	case .Crashed:
		p.crashes += 1
		delete(p.failure)
		p.failure = strings.clone(e.text)
		h.source.version += 1
		if p.crashes >= CRASHES_TO_SUSPEND {
			// (it crashes each time it runs: it stays off until the person turns it on again, plugins.toml keeps it)
			p.state, p.suspended, p.enabled = .Suspended, true, false
			toml_write(h)
			say(h, .Bad, strings.concatenate({p.manifest.name, " is suspended"}, context.temp_allocator), "Its process crashed three times. Turn it on again in the settings' Plugins page.")
		} else {
			p.state = .Failed
			say(h, .Bad, fmt_failed(p.manifest.name), e.text)
		}
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
	case .Request:
		broker_request(h, p, e.serial, e.req)
	case .Rows:
		if r := view_record(h, p.manifest.id, e.title); r != nil && lazy_take(r, e.text, e.rows, e.list) { e.list = nil }
	}
}

@(private)
fmt_failed :: proc(name: string) -> string {
	return strings.concatenate({name, " failed"}, context.temp_allocator)
}
