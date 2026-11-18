package tk_plugins

// The frames between a program and a plugin's process (channel.odin, child.odin): a magic word, a length, then a
// payload whose first byte says what it is. The program writes the start and the messages to the child's standard
// input; the child writes its events to its standard output. Everything that crosses was already a message or a
// display list (plugins.md, decision 2): this file only gives them bytes.

import "core:os"
import "core:strings"
import config "../config"
import plugin_api "../plugin_api"
import "../ui"

// "GTPL": a frame begins with it. Anything else on the child's output (a library that printed) is a broken channel,
// not a message read askew.
FRAME_MAGIC :: u32(0x4c505447)
// The largest frame: a display list of LIST_MAX_NODES nodes fits many times over.
FRAME_MAX_BYTES :: 64 << 20

@(private)
Frame_Kind :: enum u8 { Start = 1, Message, Event }

// Writes one frame. False: the other end is gone.
@(private)
frame_write :: proc(f: ^os.File, kind: Frame_Kind, payload: []u8) -> bool {
	head: [9]u8
	put32 :: proc(b: []u8, v: u32) { for i in 0 ..< 4 { b[i] = u8(v >> (8 * u32(i))) } }
	put32(head[0:4], FRAME_MAGIC)
	put32(head[4:8], u32(len(payload) + 1))
	head[8] = u8(kind)
	return write_all(f, head[:]) && write_all(f, payload)
}

// Reads one frame, its payload in the temporary memory. ok false: the other end is gone, or what came is no frame.
@(private)
frame_read :: proc(f: ^os.File) -> (kind: Frame_Kind, payload: []u8, ok: bool) {
	head: [9]u8
	if !read_all(f, head[:]) { return }
	get32 :: proc(b: []u8) -> u32 { v: u32; for i in 0 ..< 4 { v |= u32(b[i]) << (8 * u32(i)) }; return v }
	if get32(head[0:4]) != FRAME_MAGIC { return }
	n := int(get32(head[4:8]))
	if n < 1 || n > FRAME_MAX_BYTES || head[8] < u8(Frame_Kind.Start) || head[8] > u8(Frame_Kind.Event) { return }
	payload = make([]u8, n - 1, context.temp_allocator)
	if !read_all(f, payload) { return }
	return Frame_Kind(head[8]), payload, true
}

@(private)
write_all :: proc(f: ^os.File, data: []u8) -> bool {
	rest := data
	for len(rest) > 0 {
		n, err := os.write(f, rest)
		if err != nil || n <= 0 { return false }
		rest = rest[n:]
	}
	return true
}

@(private)
read_all :: proc(f: ^os.File, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		n, err := os.read(f, buf[got:])
		if err != nil || n <= 0 { return false }
		got += n
	}
	return true
}

////////////////////////////////
// The start: what the child's plugin needs of its manifest and of the host

@(private)
start_encode :: proc(w: ^plugin_api.Wire_Writer, p: ^Plugin) {
	m := &p.manifest
	plugin_api.put_u64(w, p.serial)
	plugin_api.put_i64(w, p.memory_limit)
	plugin_api.put_string(w, p.folder)
	plugin_api.put_u8(w, u8(p.sandbox))
	plugin_api.put_string(w, m.id)
	plugin_api.put_string(w, m.name)
	plugin_api.put_string(w, m.version)
	plugin_api.put_string(w, m.main)
	// (what its bridge lets through at once; the program's broker checks each request again)
	plugin_api.put_u64(w, u64(transmute(u8)capabilities_of(p.granted[:])))
	plugin_api.put_u64(w, u64(len(m.commands)))
	for c in m.commands { plugin_api.put_string(w, c.id) }
	plugin_api.put_u64(w, u64(len(m.views)))
	for v in m.views { plugin_api.put_string(w, v.id) }
	plugin_api.put_u64(w, u64(len(m.palette)))
	for d in m.palette { plugin_api.put_string(w, d.id) }
	// (the language now: context.language; a later change comes as a Language message)
	plugin_api.put_string(w, language_tag())
	plugin_api.put_u64(w, u64(len(p.settings_start)))
	for s in p.settings_start {
		plugin_api.put_string(w, s.id)
		plugin_api.put_u8(w, u8(s.kind))
		plugin_api.put_bool(w, s.value.b)
		plugin_api.put_i64(w, s.value.i)
		plugin_api.put_f64(w, s.value.f)
		plugin_api.put_string(w, s.value.s)
	}
	// (the program's module: names and typeids, which name the same types in the child, the program's own executable)
	app := p.app_module
	plugin_api.put_bool(w, app != nil)
	if app != nil {
		plugin_api.put_string(w, app.name)
		plugin_api.put_u64(w, u64(len(app.calls)))
		for c in app.calls {
			plugin_api.put_string(w, c.name)
			plugin_api.put_u64(w, transmute(u64)c.arguments)
			plugin_api.put_u64(w, transmute(u64)c.result)
		}
		plugin_api.put_u64(w, u64(len(app.events)))
		for e in app.events {
			plugin_api.put_string(w, e.name)
			plugin_api.put_u64(w, transmute(u64)e.payload)
		}
	}
}

// What the start frame says of the program's module (start_encode). False: what came is not one.
@(private)
app_decode :: proc(r: ^plugin_api.Wire_Reader, p: ^Plugin) -> bool {
	p.app_given = plugin_api.get_bool(r)
	if !p.app_given { return !r.bad }
	p.app_name = plugin_api.get_string(r)
	calls := make([]plugin_api.App_Spec, plugin_api.get_count(r, 24))
	p.app_calls = calls
	for &c in calls {
		c.name = plugin_api.get_string(r)
		c.types[0] = transmute(typeid)plugin_api.get_u64(r)
		c.types[1] = transmute(typeid)plugin_api.get_u64(r)
		// (a type this executable does not have: the frame is not its program's)
		if !plugin_api.typeid_known(c.types[0]) || !plugin_api.typeid_known(c.types[1]) || strings.index_byte(c.name, '.') <= 0 { return false }
	}
	events := make([]plugin_api.App_Spec, plugin_api.get_count(r, 16))
	p.app_events = events
	for &e in events {
		e.name = plugin_api.get_string(r)
		e.types[0] = transmute(typeid)plugin_api.get_u64(r)
		if !plugin_api.typeid_known(e.types[0]) { return false }
	}
	return !r.bad
}

// The child's plugin from the start's bytes (heap). nil: what came is not a start.
@(private)
start_decode :: proc(r: ^plugin_api.Wire_Reader) -> ^Plugin {
	p := plugin_new()
	p.serial = plugin_api.get_u64(r)
	p.memory_limit = plugin_api.get_i64(r)
	p.folder = plugin_api.get_string(r)
	sandbox := plugin_api.get_u8(r)
	// (a mode it does not know: the strictest, never none)
	p.sandbox = sandbox <= u8(max(Sandbox_Mode)) ? Sandbox_Mode(sandbox) : .Required
	m := &p.manifest
	m.id = plugin_api.get_string(r)
	m.name = plugin_api.get_string(r)
	m.version = plugin_api.get_string(r)
	m.main = plugin_api.get_string(r)
	m.api = plugin_api.PLUGIN_API_LEVEL
	p.granted_caps = transmute(plugin_api.Capabilities)u8(plugin_api.get_u64(r))
	commands := make([]Command_Decl, plugin_api.get_count(r, 8))
	for &c in commands { c.id = plugin_api.get_string(r) }
	m.commands = commands
	views := make([]View_Decl, plugin_api.get_count(r, 8))
	for &v in views { v.id = plugin_api.get_string(r) }
	m.views = views
	sources := make([]Palette_Decl, plugin_api.get_count(r, 8))
	for &d in sources { d.id = plugin_api.get_string(r) }
	m.palette = sources
	p.language = plugin_api.get_string(r)
	settings := make([]Setting_Now, plugin_api.get_count(r, 34))
	for &s in settings {
		s.id = plugin_api.get_string(r)
		kind := plugin_api.get_u8(r)
		if kind > u8(config.Kind.String) { r.bad = true; break }
		s.kind = config.Kind(kind)
		s.value.b = plugin_api.get_bool(r)
		s.value.i = plugin_api.get_i64(r)
		s.value.f = plugin_api.get_f64(r)
		s.value.s = plugin_api.get_string(r)
	}
	p.settings_start = settings
	if !r.bad && !app_decode(r, p) { r.bad = true }
	if r.bad {
		for s in p.settings_start { setting_now_free(s) }
		delete(p.settings_start)
		p.settings_start = nil
		plugin_release(p)
		return nil
	}
	return p
}

////////////////////////////////
// The messages (program to child) and the events (child to program)

@(private)
message_encode :: proc(w: ^plugin_api.Wire_Writer, m: Message) {
	plugin_api.put_u8(w, u8(m.kind))
	plugin_api.put_string(w, m.command)
	plugin_api.put_string(w, m.view)
	plugin_api.put_string(w, m.key)
	plugin_api.put_u8(w, u8(m.event))
	plugin_api.put_string(w, m.text)
	plugin_api.put_bool(w, m.flag)
	plugin_api.put_bool(w, m.is_flag)
	plugin_api.put_u64(w, m.serial)
	plugin_api.put_u8(w, u8(m.setting))
	plugin_api.put_f64(w, m.number)
	rows_encode(w, m.rows)
}

@(private)
rows_encode :: proc(w: ^plugin_api.Wire_Writer, a: Rows_Ask) {
	plugin_api.put_u64(w, a.seq)
	plugin_api.put_i64(w, a.version)
	for v in ([4]int{a.from, a.to, a.keep_from, a.keep_to}) { plugin_api.put_i64(w, i64(v)) }
}

// (each side checks what the range means where it is used: lazy_take, rows_message)
@(private)
rows_decode :: proc(r: ^plugin_api.Wire_Reader) -> (a: Rows_Ask) {
	a.seq = plugin_api.get_u64(r)
	a.version = plugin_api.get_i64(r)
	a.from = int(plugin_api.get_i64(r))
	a.to = int(plugin_api.get_i64(r))
	a.keep_from = int(plugin_api.get_i64(r))
	a.keep_to = int(plugin_api.get_i64(r))
	return
}

// A message (its strings in the heap, message_free's). ok false: not a message.
@(private)
message_decode :: proc(r: ^plugin_api.Wire_Reader) -> (m: Message, ok: bool) {
	a := context.allocator
	kind := plugin_api.get_u8(r)
	m.command = plugin_api.get_string(r, a)
	m.view = plugin_api.get_string(r, a)
	m.key = plugin_api.get_string(r, a)
	event := plugin_api.get_u8(r)
	m.text = plugin_api.get_string(r, a)
	m.flag = plugin_api.get_bool(r)
	m.is_flag = plugin_api.get_bool(r)
	m.serial = plugin_api.get_u64(r)
	setting := plugin_api.get_u8(r)
	m.number = plugin_api.get_f64(r)
	m.rows = rows_decode(r)
	if r.bad || kind > u8(max(Message_Kind)) || event > u8(max(View_Event)) || setting > u8(config.Kind.String) {
		message_free(m)
		return {}, false
	}
	m.kind, m.event, m.setting = Message_Kind(kind), View_Event(event), config.Kind(setting)
	return m, true
}

@(private)
event_encode :: proc(w: ^plugin_api.Wire_Writer, kind: Event_Kind, title, text: string, toast: ui.Toast_Kind, list: ^plugin_api.List, req: Request, rows: Rows_Ask) {
	plugin_api.put_u8(w, u8(kind))
	plugin_api.put_u8(w, u8(toast))
	plugin_api.put_string(w, title)
	plugin_api.put_string(w, text)
	plugin_api.put_bool(w, list != nil)
	if list != nil { plugin_api.list_encode(w, list) }
	if kind == .Request {
		// (the gesture is not sent: the program knows which turn runs, the process could say anything)
		plugin_api.put_u64(w, req.call)
		plugin_api.put_u8(w, u8(req.op))
		for a in req.args { plugin_api.put_string(w, a) }
	}
	if kind == .Rows || kind == .Palette_Rows { rows_encode(w, rows) }
}

// An event as the child wrote it: its kind, words, list and request (heap; the list's own arena). ok false: not an
// event.
@(private)
event_decode :: proc(r: ^plugin_api.Wire_Reader) -> (kind: Event_Kind, toast: ui.Toast_Kind, title, text: string, list: ^plugin_api.List, req: Request, rows: Rows_Ask, ok: bool) {
	k := plugin_api.get_u8(r)
	t := plugin_api.get_u8(r)
	title = plugin_api.get_string(r)
	text = plugin_api.get_string(r)
	if plugin_api.get_bool(r) {
		list = plugin_api.list_decode(r)
		if list == nil { r.bad = true }
	}
	if k == u8(Event_Kind.Request) {
		req.call = plugin_api.get_u64(r)
		op := plugin_api.get_u8(r)
		if op > u8(max(Broker_Op)) { r.bad = true }
		req.op = Broker_Op(op)
		for &a in req.args { a = plugin_api.get_string(r) }
	}
	if k == u8(Event_Kind.Rows) || k == u8(Event_Kind.Palette_Rows) { rows = rows_decode(r) }
	if r.bad || k > u8(max(Event_Kind)) || t > u8(max(ui.Toast_Kind)) {
		delete(title); delete(text)
		plugin_api.list_free(list)
		request_free(&req)
		return {}, {}, "", "", nil, {}, {}, false
	}
	return Event_Kind(k), ui.Toast_Kind(t), title, text, list, req, rows, true
}
