// A Chrome DevTools Protocol endpoint for a toolkit window: tools drive the interface as they would a browser page,
// with the standard protocol, no mouse or keyboard of the machine involved (docs/devtools.md).
//
//   srv := devtools.start_from_env(win, "My app")   // TOOLKIT_DEVTOOLS=9222 in the environment, else nil (nothing)
//   defer devtools.stop(srv)
//   each frame, before poll_events and begin_build:
//   devtools.service(srv, &ui_state, &renderer)
//
// Standard domains: Input.dispatchMouseEvent / dispatchKeyEvent / insertText (injected into the window's queue),
// Page.captureScreenshot (the renderer's capture, PNG), Page.getLayoutMetrics, Accessibility.getFullAXTree, Browser /
// Target discovery. The Toolkit domain reads the box tree: Toolkit.getTree, Toolkit.find, Toolkit.click. Listens on
// 127.0.0.1 only; anything that can reach it drives the window, so it is opt-in.
package devtools

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"
import "../platform"
import "../render"
import "../ui"

VERSION :: ui.VERSION

Server :: struct {
	port:     int,
	win:      ^platform.Window,
	title:    string,
	id:       string,
	listener: net.TCP_Socket,
	thread:   ^thread.Thread,
	lock:     sync.Mutex,
	inbox:    [dynamic]Message,   // commands from the connections (under lock)
	conns:    [dynamic]^Conn,     // (under lock)
	stopping: bool,
	// the UI thread's own
	captures: [dynamic]Waiting,   // screenshots asked for, answered when the capture is ready
	later:    [dynamic]platform.Event,   // events for the next frame (a click's release)
	shots:    int,
}

@(private)
Waiting :: struct { conn: ^Conn, id: i64 }

// Listens on 127.0.0.1:port. nil when the port cannot be had.
start :: proc(win: ^platform.Window, port: int, title := "") -> ^Server {
	l, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil { fmt.eprintfln("devtools: cannot listen on 127.0.0.1:%d (%v)", port, err); return nil }
	srv := new(Server)
	srv.port, srv.win, srv.listener = port, win, l
	srv.title = strings.clone(title != "" ? title : "gui_toolkit window")
	srv.id = fmt.aprintf("%08X", u32(uintptr(win)) ~ u32(port) * 2654435761)
	srv.thread = thread.create_and_start_with_poly_data(srv, accept_loop)
	fmt.eprintfln("devtools: listening on ws://127.0.0.1:%d/devtools/page/%s (http://127.0.0.1:%d/json/list)", port, srv.id, port)
	return srv
}

// TOOLKIT_DEVTOOLS=<port> in the environment: start on it; else nil (service and stop do nothing with nil).
start_from_env :: proc(win: ^platform.Window, title := "") -> ^Server {
	v := os.get_env("TOOLKIT_DEVTOOLS", context.temp_allocator)
	if v == "" { return nil }
	port, ok := strconv.parse_int(v)
	if !ok || port <= 0 || port > 65535 { port = 9222 }
	return start(win, port, title)
}

stop :: proc(srv: ^Server) {
	if srv == nil { return }
	sync.atomic_store(&srv.stopping, true)
	net.close(srv.listener)
	// (accept may not return on a closed socket everywhere: a connection to ourselves unblocks it)
	if s, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = srv.port}); err == nil { net.close(s) }
	thread.join(srv.thread)
	thread.destroy(srv.thread)
	sync.lock(&srv.lock)
	conns := srv.conns[:]
	sync.unlock(&srv.lock)
	for c in conns { net.close(c.sock) }
	for c in conns { thread.join(c.thread); thread.destroy(c.thread); free(c, runtime.heap_allocator()) }
	delete(srv.conns)
	for m in srv.inbox { delete(m.text, runtime.heap_allocator()) }
	delete(srv.inbox)
	delete(srv.captures)
	delete(srv.later)
	delete(srv.title)
	delete(srv.id)
	free(srv)
}

// Each frame, before poll_events and begin_build (the tree read is the last build's, its memory still alive): the
// commands that came in are carried out, input injected into the window's queue for this frame.
service :: proc(srv: ^Server, s: ^ui.State, r: ^render.Renderer) {
	if srv == nil { return }
	for e in srv.later { platform.inject_event(srv.win, e) }
	clear(&srv.later)
	screenshots_poll(srv, r)
	sync.lock(&srv.lock)
	msgs := srv.inbox
	srv.inbox = {}
	sync.unlock(&srv.lock)
	defer delete(msgs)
	for m in msgs {
		handle(srv, s, r, m)
		delete(m.text, runtime.heap_allocator())
	}
	if len(srv.later) > 0 || len(srv.captures) > 0 { platform.wake(srv.win) }   // (the next frame carries them on)
}

////////////////////////////////
// commands

@(private)
handle :: proc(srv: ^Server, s: ^ui.State, r: ^render.Renderer, m: Message) {
	v, err := json.parse_string(m.text, parse_integers = true, allocator = context.temp_allocator)
	if err != nil { return }
	o, _ := v.(json.Object)
	id := i64(num(o["id"]))
	method := str(o["method"])
	p, _ := o["params"].(json.Object)
	sb := strings.builder_make(context.temp_allocator)
	ok := true
	switch method {
	case "Browser.getVersion":
		fmt.sbprintf(&sb, `{{"protocolVersion":"1.3","product":"gui_toolkit/%s","revision":"","userAgent":"gui_toolkit","jsVersion":""}}`, VERSION)
	case "Target.getTargets":
		fmt.sbprintf(&sb, `{{"targetInfos":[{{"targetId":"%s","type":"page","title":%s,"url":"toolkit://window","attached":true}}]}}`, srv.id, json_quote(srv.title))
	case "Target.getTargetInfo":
		fmt.sbprintf(&sb, `{{"targetInfo":{{"targetId":"%s","type":"page","title":%s,"url":"toolkit://window","attached":true}}}}`, srv.id, json_quote(srv.title))
	case "Input.dispatchMouseEvent":
		mouse_event(srv, p)
		strings.write_string(&sb, "{}")
	case "Input.dispatchKeyEvent":
		key_event(srv, p)
		strings.write_string(&sb, "{}")
	case "Input.insertText":
		insert_text(srv, str(p["text"]))
		strings.write_string(&sb, "{}")
	case "Page.captureScreenshot":
		if screenshot_ask(srv, r, m.conn, id, p) { return }   // answered when the capture is ready
		error_reply(m.conn, id, -32000, "the renderer cannot capture now")
		return
	case "Page.getLayoutMetrics":
		d := dpi(srv)
		w, h := f64(srv.win.size.x) / d, f64(srv.win.size.y) / d
		fmt.sbprintf(&sb, `{{"layoutViewport":{{"pageX":0,"pageY":0,"clientWidth":%.0f,"clientHeight":%.0f}},"visualViewport":{{"offsetX":0,"offsetY":0,"pageX":0,"pageY":0,"clientWidth":%.0f,"clientHeight":%.0f,"scale":1,"zoom":%g}},"contentSize":{{"x":0,"y":0,"width":%.0f,"height":%.0f}},"cssLayoutViewport":{{"pageX":0,"pageY":0,"clientWidth":%.0f,"clientHeight":%.0f}},"cssVisualViewport":{{"offsetX":0,"offsetY":0,"pageX":0,"pageY":0,"clientWidth":%.0f,"clientHeight":%.0f,"scale":1,"zoom":1}},"cssContentSize":{{"x":0,"y":0,"width":%.0f,"height":%.0f}}}}`, w, h, w, h, d, w, h, w, h, w, h, w, h)
	case "Accessibility.getFullAXTree":
		ax_tree(&sb, srv, s)
	case "Toolkit.getTree":
		strings.write_string(&sb, `{"root":`)
		write_node(&sb, srv, s, s.root, bool_of(p["all"]), true)
		strings.write_string(&sb, "}")
	case "Toolkit.find":
		find(&sb, srv, s, p)
	case "Toolkit.click":
		b := find_one(s, p)
		if b == nil { error_reply(m.conn, id, -32000, "no box with that name or text"); return }
		x, y := click(srv, b, p)
		fmt.sbprintf(&sb, `{{"x":%.1f,"y":%.1f,"key":"%x"}}`, x, y, u64(b.key))
	case "Toolkit.state":
		d := dpi(srv)
		fmt.sbprintf(&sb, `{{"build":%d,"focus":"%x","hot":"%x","width":%.0f,"height":%.0f,"dpi":%g}}`, s.build_index, u64(ui.focus_key_of(s)), u64(ui.hot_key_of(s)), f64(srv.win.size.x) / d, f64(srv.win.size.y) / d, d)
	case "Runtime.evaluate", "Runtime.callFunctionOn":
		error_reply(m.conn, id, -32000, "no JavaScript in a toolkit window: use the Toolkit domain (getTree, find, click)")
		return
	case:
		// what a client turns on before it starts (Page.enable, Runtime.enable, Target.setAutoAttach...): nothing to do
		dot := strings.index_byte(method, '.')
		name := dot >= 0 ? method[dot + 1:] : method
		if strings.has_prefix(name, "enable") || strings.has_prefix(name, "disable") || strings.has_prefix(name, "set") ||
		   method == "Runtime.runIfWaitingForDebugger" || method == "Page.getFrameTree" {
			strings.write_string(&sb, method == "Page.getFrameTree" ? fmt.tprintf(`{{"frameTree":{{"frame":{{"id":"%s","loaderId":"","url":"toolkit://window","securityOrigin":"","mimeType":"text/html"}}}}}}`, srv.id) : "{}")
		} else {
			ok = false
		}
	}
	if !ok { error_reply(m.conn, id, -32601, fmt.tprintf("'%s' wasn't found", method)); return }
	send_text(m.conn, fmt.tprintf(`{{"id":%d,"result":%s}}`, id, strings.to_string(sb)))
}

@(private)
error_reply :: proc(c: ^Conn, id: i64, code: int, msg: string) {
	send_text(c, fmt.tprintf(`{{"id":%d,"error":{{"code":%d,"message":%s}}}}`, id, code, json_quote(msg)))
}

@(private)
dpi :: proc(srv: ^Server) -> f64 { return srv.win.dpi_scale > 0 ? f64(srv.win.dpi_scale) : 1 }

////////////////////////////////
// input

// CDP modifiers: Alt 1, Ctrl 2, Meta 4, Shift 8.
@(private)
mods_of :: proc(p: json.Object) -> (m: platform.Modifiers) {
	bits := int(num(p["modifiers"]))
	if bits & 1 != 0 { m += {.Alt} }
	if bits & 2 != 0 { m += {.Ctrl} }
	if bits & 8 != 0 { m += {.Shift} }
	return
}

@(private)
button_of :: proc(name: string) -> (platform.Mouse_Button, bool) {
	switch name {
	case "left":   return .Left, true
	case "right":  return .Right, true
	case "middle": return .Middle, true
	}
	return .Left, false
}

@(private)
mouse_event :: proc(srv: ^Server, p: json.Object) {
	d := f32(dpi(srv))
	e := platform.Event{pos = {f32(num(p["x"])) * d, f32(num(p["y"])) * d}, mods = mods_of(p)}
	bits := int(num(p["buttons"]))
	if bits & 1 != 0 { e.buttons += {.Left} }
	if bits & 2 != 0 { e.buttons += {.Right} }
	if bits & 4 != 0 { e.buttons += {.Middle} }
	b, has := button_of(str(p["button"]))
	switch str(p["type"]) {
	case "mouseMoved":
		e.kind = .Mouse_Move
	case "mousePressed":
		if !has { return }
		e.kind, e.button = .Mouse_Press, b
		e.buttons += {b}
		platform.inject_event(srv.win, platform.Event{kind = .Mouse_Move, pos = e.pos, mods = e.mods, buttons = e.buttons - {b}})
	case "mouseReleased":
		if !has { return }
		e.kind, e.button = .Mouse_Release, b
		e.buttons -= {b}
	case "mouseWheel":
		// CSS pixels, 100 a notch (Chrome's); positive y scrolls the content down, as Event.delta
		e.kind = .Scroll
		e.delta = {f32(num(p["deltaX"])) / 100, f32(num(p["deltaY"])) / 100}
		platform.inject_event(srv.win, platform.Event{kind = .Mouse_Move, pos = e.pos, mods = e.mods})
	case:
		return
	}
	platform.inject_event(srv.win, e)
}

@(private)
key_event :: proc(srv: ^Server, p: json.Object) {
	k := key_of(str(p["key"]), str(p["code"]))
	m := mods_of(p)
	text := str(p["text"])
	switch str(p["type"]) {
	case "keyDown", "rawKeyDown":
		if k != .None { platform.inject_event(srv.win, platform.Event{kind = .Key_Press, key = k, mods = m, repeat = bool_of(p["autoRepeat"])}) }
		if str(p["type"]) == "keyDown" && .Ctrl not_in m { insert_text(srv, text) }
	case "keyUp":
		if k != .None { platform.inject_event(srv.win, platform.Event{kind = .Key_Release, key = k, mods = m}) }
	case "char":
		insert_text(srv, text)
	}
}

@(private)
insert_text :: proc(srv: ^Server, text: string) {
	for r in text {
		if r < 0x20 || r == 0x7f { continue }   // (Enter, Tab, Backspace are keys)
		platform.inject_event(srv.win, platform.Event{kind = .Text, text = r})
	}
}

// The DOM's KeyboardEvent.key (or .code) to the platform's key.
@(private)
key_of :: proc(key, code: string) -> platform.Key {
	if utf8.rune_count_in_string(key) == 1 {
		r, _ := utf8.decode_rune_in_string(key)
		switch r {
		case 'a' ..= 'z': return platform.Key(int(platform.Key.A) + int(r - 'a'))
		case 'A' ..= 'Z': return platform.Key(int(platform.Key.A) + int(r - 'A'))
		case '0' ..= '9': return platform.Key(int(platform.Key.N0) + int(r - '0'))
		case ' ': return .Space
		case ',': return .Comma
		case '.': return .Period
		case '/': return .Slash
		case '-': return .Minus
		case '=': return .Equal
		case '+': return .Num_Add
		}
	}
	switch key {
	case "Enter": return .Return
	case "Tab": return .Tab
	case "Escape": return .Escape
	case "Backspace": return .Backspace
	case "Delete": return .Delete
	case "Insert": return .Insert
	case "ArrowLeft": return .Left
	case "ArrowRight": return .Right
	case "ArrowUp": return .Up
	case "ArrowDown": return .Down
	case "Home": return .Home
	case "End": return .End
	case "PageUp": return .Page_Up
	case "PageDown": return .Page_Down
	case "Shift": return .Shift
	case "Control": return .Ctrl
	case "Alt": return .Alt
	case "ContextMenu": return .Menu
	}
	if len(key) >= 2 && key[0] == 'F' {
		if n, ok := strconv.parse_int(key[1:]); ok && n >= 1 && n <= 12 { return platform.Key(int(platform.Key.F1) + n - 1) }
	}
	if strings.has_prefix(code, "Key") && len(code) == 4 { return key_of(code[3:], "") }
	if strings.has_prefix(code, "Digit") && len(code) == 6 { return key_of(code[5:], "") }
	return .None
}

// A click on a box's middle: a move and a press now, the release at the next frame (the press is seen first, as a
// hand's would be). `count` 2: a double click.
@(private)
click :: proc(srv: ^Server, b: ^ui.Box, p: json.Object) -> (x, y: f64) {
	pos := [2]f32{math.round((b.rect.min.x + b.rect.max.x) * 0.5), math.round((b.rect.min.y + b.rect.max.y) * 0.5)}
	btn, has := button_of(str(p["button"]))
	if !has { btn = .Left }
	count := max(int(num(p["count"], 1)), 1)
	platform.inject_event(srv.win, platform.Event{kind = .Mouse_Move, pos = pos})
	for i in 0 ..< count {
		ev := platform.Event{kind = .Mouse_Press, button = btn, pos = pos, buttons = {btn}}
		up := platform.Event{kind = .Mouse_Release, button = btn, pos = pos}
		if i == 0 { platform.inject_event(srv.win, ev) } else { append(&srv.later, ev) }
		append(&srv.later, up)
	}
	d := dpi(srv)
	return f64(pos.x) / d, f64(pos.y) / d
}

////////////////////////////////
// the box tree

@(private)
write_node :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State, b: ^ui.Box, all: bool, top := false) -> bool {
	if b == nil || !ui.box_current(s, b) { if top { strings.write_string(sb, "null") }; return false }
	text := ui.box_text(b)
	d := f32(dpi(srv))
	fmt.sbprintf(sb, `{{"key":"%x","name":%s,"text":%s,"x":%.1f,"y":%.1f,"w":%.1f,"h":%.1f`, u64(b.key), json_quote(b.name), json_quote(text),
		b.rect.min.x / d, b.rect.min.y / d, (b.rect.max.x - b.rect.min.x) / d, (b.rect.max.y - b.rect.min.y) / d)
	if b.a11y != nil && b.a11y.role != .Unknown { fmt.sbprintf(sb, `,"role":"%v"`, b.a11y.role) }
	if b.a11y != nil && b.a11y.name != "" { fmt.sbprintf(sb, `,"label":%s`, json_quote(b.a11y.name)) }
	if b.key == ui.focus_key_of(s) { strings.write_string(sb, `,"focused":true`) }
	if b.key == ui.hot_key_of(s) { strings.write_string(sb, `,"hot":true`) }
	flags := [?]ui.Box_Flag{.Clickable, .Focusable, .Text_Input, .View_Scroll_Y, .View_Scroll_X, .Disabled, .Selectable}
	n := 0
	for f in flags {
		if f not_in b.flags { continue }
		strings.write_string(sb, n == 0 ? `,"flags":["` : `","`)
		fmt.sbprintf(sb, "%v", f)
		n += 1
	}
	if n > 0 { strings.write_string(sb, `"]`) }
	if .View_Scroll_Y in b.flags { fmt.sbprintf(sb, `,"scroll":%.1f,"scrollMax":%.1f`, b.view_off.y / d, max(0, b.view_bounds.y - b.size.y) / d) }
	first := true
	for c := b.first; c != nil; c = c.next {
		if !all && !worth(s, c) { continue }
		strings.write_string(sb, first ? `,"children":[` : ",")
		first = false
		write_node(sb, srv, s, c, all)
	}
	if !first { strings.write_string(sb, "]") }
	strings.write_string(sb, "}")
	return true
}

// A box worth showing in the tree (all = false): named, with text, or holding such a box.
@(private)
worth :: proc(s: ^ui.State, b: ^ui.Box) -> bool {
	if !ui.box_current(s, b) { return false }
	if b.name != "" || ui.box_text(b) != "" || b.flags & {.Clickable, .Text_Input, .View_Scroll_Y} != {} { return true }
	for c := b.first; c != nil; c = c.next { if worth(s, c) { return true } }
	return false
}

// Boxes whose name is `name` (exactly) or whose text contains `text` (ignoring case), in tree order.
@(private)
matches :: proc(s: ^ui.State, p: json.Object) -> [dynamic]^ui.Box {
	out := make([dynamic]^ui.Box, context.temp_allocator)
	name, text := str(p["name"]), str(p["text"])
	if name == "" && text == "" { return out }
	ltext := strings.to_lower(text, context.temp_allocator)
	walk :: proc(s: ^ui.State, b: ^ui.Box, name, ltext: string, out: ^[dynamic]^ui.Box) {
		if !ui.box_current(s, b) { return }
		ok := name == "" || b.name == name
		if ok && ltext != "" { ok = strings.contains(strings.to_lower(ui.box_text(b), context.temp_allocator), ltext) }
		if ok && b.rect.max.x > b.rect.min.x { append(out, b) }
		for c := b.first; c != nil; c = c.next { walk(s, c, name, ltext, out) }
	}
	walk(s, s.root, name, ltext, &out)
	return out
}

// The box to act on: the deepest clickable box around the first match (a label's button), else the match.
@(private)
find_one :: proc(s: ^ui.State, p: json.Object) -> ^ui.Box {
	ms := matches(s, p)
	idx := int(num(p["index"]))
	if idx < 0 || idx >= len(ms) { return nil }
	b := ms[idx]
	for a := b; a != nil; a = a.parent { if .Clickable in a.flags || .Text_Input in a.flags { return a } }
	return b
}

@(private)
find :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State, p: json.Object) {
	strings.write_string(sb, `{"nodes":[`)
	for b, i in matches(s, p) {
		if i > 0 { strings.write_byte(sb, ',') }
		d := f32(dpi(srv))
		fmt.sbprintf(sb, `{{"key":"%x","name":%s,"text":%s,"x":%.1f,"y":%.1f,"w":%.1f,"h":%.1f}}`, u64(b.key), json_quote(b.name), json_quote(ui.box_text(b)),
			b.rect.min.x / d, b.rect.min.y / d, (b.rect.max.x - b.rect.min.x) / d, (b.rect.max.y - b.rect.min.y) / d)
	}
	strings.write_string(sb, "]}")
}

// Accessibility.getFullAXTree: the boxes a reader would meet (a role, a name, something to click or type in, text),
// each the child of the nearest such box above it.
@(private)
ax_tree :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State) {
	strings.write_string(sb, `{"nodes":[`)
	count := 0
	node :: proc(sb: ^strings.Builder, s: ^ui.State, b: ^ui.Box, parent: ui.Key, count: ^int) {
		if !ui.box_current(s, b) { return }
		text := ui.box_text(b)
		role := ""
		name := text
		if b.a11y != nil && b.a11y.role != .Unknown { role = fmt.tprintf("%v", b.a11y.role) }
		if b.a11y != nil && b.a11y.name != "" { name = b.a11y.name }
		if role == "" {
			switch {
			case .Text_Input in b.flags: role = "textbox"
			case .Clickable in b.flags:  role = "button"
			case .View_Scroll_Y in b.flags: role = "scrollable"
			case text != "": role = "StaticText"
			}
		}
		me := parent
		if role != "" || b == s.root {
			if b == s.root { role, name = "RootWebArea", "" }
			if count^ > 0 { strings.write_byte(sb, ',') }
			count^ += 1
			fmt.sbprintf(sb, `{{"nodeId":"%x","ignored":false,"role":{{"type":"role","value":%s}},"name":{{"type":"computedString","value":%s}},"backendDOMNodeId":%d`, u64(b.key), json_quote(role), json_quote(name), count^)
			if parent != 0 { fmt.sbprintf(sb, `,"parentId":"%x"`, u64(parent)) }
			strings.write_string(sb, `,"childIds":[`)
			first := true
			kids :: proc(sb: ^strings.Builder, s: ^ui.State, b: ^ui.Box, first: ^bool) {
				for c := b.first; c != nil; c = c.next {
					if !ui.box_current(s, c) { continue }
					if is_ax(s, c) {
						if !first^ { strings.write_byte(sb, ',') }
						first^ = false
						fmt.sbprintf(sb, `"%x"`, u64(c.key))
					} else {
						kids(sb, s, c, first)
					}
				}
			}
			kids(sb, s, b, &first)
			strings.write_string(sb, "]}")
			me = b.key
		}
		for c := b.first; c != nil; c = c.next { node(sb, s, c, me, count) }
	}
	node(sb, s, s.root, 0, &count)
	strings.write_string(sb, "]}")
}

@(private)
is_ax :: proc(s: ^ui.State, b: ^ui.Box) -> bool {
	return (b.a11y != nil && b.a11y.role != .Unknown) || b.flags & {.Text_Input, .Clickable, .View_Scroll_Y} != {} || ui.box_text(b) != ""
}

////////////////////////////////
// screenshots

@(private)
screenshot_ask :: proc(srv: ^Server, r: ^render.Renderer, c: ^Conn, id: i64, p: json.Object) -> bool {
	if len(srv.captures) == 0 {
		rect: [4]int
		if clip, ok := p["clip"].(json.Object); ok {
			d := dpi(srv)
			rect = {int(num(clip["x"]) * d), int(num(clip["y"]) * d), int(num(clip["width"]) * d), int(num(clip["height"]) * d)}
		}
		if !render.capture_request(r, rect) { return false }
	}
	append(&srv.captures, Waiting{conn = c, id = id})
	platform.wake(srv.win)
	return true
}

@(private)
screenshots_poll :: proc(srv: ^Server, r: ^render.Renderer) {
	if len(srv.captures) == 0 { return }
	pixels, size, status := render.capture_poll(r, context.temp_allocator)
	switch status {
	case .Pending:
		return
	case .Ready:
		png := png_encode(pixels, size.x, size.y, context.temp_allocator)
		data := base64.encode(png, allocator = context.temp_allocator)
		for w in srv.captures { send_text(w.conn, fmt.tprintf(`{{"id":%d,"result":{{"data":"%s"}}}}`, w.id, data)) }
		srv.shots += 1
	case .None, .Failed:
		for w in srv.captures { error_reply(w.conn, w.id, -32000, "the capture failed") }
	}
	clear(&srv.captures)
}

////////////////////////////////
// JSON

@(private)
num :: proc(v: json.Value, def: f64 = 0) -> f64 {
	#partial switch x in v {
	case json.Integer: return f64(x)
	case json.Float:   return f64(x)
	}
	return def
}

@(private)
str :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}

@(private)
bool_of :: proc(v: json.Value) -> bool {
	b, _ := v.(json.Boolean)
	return b
}

@(private)
json_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&sb, `\"`)
		case '\\': strings.write_string(&sb, `\\`)
		case '\n': strings.write_string(&sb, `\n`)
		case '\r': strings.write_string(&sb, `\r`)
		case '\t': strings.write_string(&sb, `\t`)
		case:
			if r < 0x20 { fmt.sbprintf(&sb, `\u%04x`, int(r)) } else { strings.write_rune(&sb, r) }
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}
