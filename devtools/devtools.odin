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
// Target discovery. The Toolkit domain reads the box tree and waits on it: Toolkit.getTree, find, click, waitFor,
// waitIdle, metrics, axAction, axAudit, startRecording. Listens on 127.0.0.1 only and refuses browsers' pages (server.odin);
// what runs as this user can still reach it and drive the window, so it is opt-in.
package devtools

import "base:runtime"
import "core:encoding/base64"
import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:net"
import "core:slice"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
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
	accepter: ^thread.Thread,
	lock:     sync.Mutex,
	inbox:    [dynamic]Message,   // commands from the connections (under lock)
	conns:    [dynamic]^Conn,     // (under lock)
	stopping: bool,
	ticking:  ^thread.Thread,
	waiting:  int,                // len(waits), for the ticker (atomic)
	cast_dirty: bool,             // the window changed since the last frame of the screencast (atomic)
	encoding: int,                // pictures being encoded on their own threads (atomic)
	// the UI thread's own
	captures: [dynamic]Reply_To,  // screenshots asked for, answered when the capture is ready
	later:    [dynamic]platform.Event,   // events for the next frame (a click's release)
	waits:    [dynamic]Wait,      // Toolkit.waitFor, waitIdle
	rec:      Recorder,           // Toolkit.startRecording
	screencast: Cast,               // Page.startScreencast
	dom:      Dom,                // the box tree as Chrome's DevTools sees it (dom.odin)
	samples:  [METRIC_RING]Metric_Sample,   // the last frames (Toolkit.metrics)
	sampled:  int,
	sample_build: u64,
	sample_at: time.Tick,
	shots:    int,
	sessions: int,
	captured: bool,               // the accessibility tree is asked of the ui (ui.a11y_capture)
}

// Where an answer goes: the connection, the command's id, its session (a client attached with Target.attachToTarget).
@(private)
Reply_To :: struct { conn: ^Conn, id: i64, session: string }

// To keep it past the command (a capture, a wait): the session is the command's text until then.
@(private)
hold :: proc(to: Reply_To) -> Reply_To {
	t := to
	t.session = strings.clone(to.session, runtime.heap_allocator())
	return t
}

@(private)
release :: proc(to: Reply_To) { delete(to.session, runtime.heap_allocator()) }

@(private)
reply :: proc(to: Reply_To, result: string) {
	if to.session == "" {
		send_text(to.conn, fmt.tprintf(`{{"id":%d,"result":%s}}`, to.id, result))
	} else {
		send_text(to.conn, fmt.tprintf(`{{"id":%d,"sessionId":%s,"result":%s}}`, to.id, json_quote(to.session), result))
	}
}

@(private)
conn_gone :: proc(c: ^Conn) -> bool { return sync.atomic_load(&c.done) }

// Listens on 127.0.0.1:port. nil when the port cannot be had.
start :: proc(win: ^platform.Window, port: int, title := "") -> ^Server {
	l, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil { fmt.eprintfln("devtools: cannot listen on 127.0.0.1:%d (%v)", port, err); return nil }
	srv := new(Server)
	srv.port, srv.win, srv.listener = port, win, l
	srv.title = strings.clone(title != "" ? title : "gui_toolkit window")
	// (not to be guessed: the WebSocket's path needs it, and what serves it to a browser's page is refused)
	raw: [16]u8
	crypto.rand_bytes(raw[:])
	srv.id = string(hex.encode(raw[:]))
	srv.accepter = thread.create_and_start_with_poly_data(srv, accept_loop)
	srv.ticking = thread.create_and_start_with_poly_data(srv, ticker)
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
	thread.join(srv.accepter)
	thread.destroy(srv.accepter)
	thread.join(srv.ticking)
	thread.destroy(srv.ticking)
	sync.lock(&srv.lock)
	conns := srv.conns[:]
	sync.unlock(&srv.lock)
	for sync.atomic_load(&srv.encoding) > 0 { time.sleep(time.Millisecond) }   // (they answer on the connections)
	// (shut down, not closed: the thread reading it closes it, and a closed socket's number can be another's by now)
	for c in conns {
		sync.lock(&c.write)
		if !c.closed { net.shutdown(c.sock, .Both) }
		sync.unlock(&c.write)
	}
	for c in conns { thread.join(c.thread); thread.destroy(c.thread); free(c, runtime.heap_allocator()) }
	delete(srv.conns)
	for m in srv.inbox { delete(m.text, runtime.heap_allocator()) }
	delete(srv.inbox)
	for w in srv.captures { release(w) }
	delete(srv.captures)
	for w in srv.waits { wait_free(w) }
	delete(srv.waits)
	cast_stop(srv)
	delete(srv.later)
	rec_destroy(&srv.rec)
	dom_destroy(srv)
	delete(srv.title)
	delete(srv.id)
	free(srv)
}

// Each frame, before poll_events and begin_build (the tree read is the last build's, its memory still alive): the
// commands that came in are carried out, input injected into the window's queue for this frame.
service :: proc(srv: ^Server, s: ^ui.State, r: ^render.Renderer) {
	if srv == nil { return }
	if len(srv.later) > 0 { cast_touch(srv) }
	for e in srv.later { platform.inject_event(srv.win, e) }
	clear(&srv.later)
	screenshots_poll(srv, s, r)
	if s != nil {
		cast_poll(srv, s, r)
		if !srv.captured { ui.a11y_capture(s, true); srv.captured = true }
		metrics_sample(srv, s)
		rec_poll(srv, s)
		waits_poll(srv, s)
		dom_sync(srv, s)
	}
	sync.lock(&srv.lock)
	msgs := srv.inbox
	srv.inbox = {}
	sync.unlock(&srv.lock)
	defer delete(msgs)
	for m in msgs {
		handle(srv, s, r, m)
		delete(m.text, runtime.heap_allocator())
	}
	// What needs another frame. Through the ticker: a wake sent from here is taken by the poll_events of the frame about to be
	// built, and the window would then sleep until its next timer (a real window's; an offscreen one keeps it).
	sync.atomic_store(&srv.waiting, len(srv.waits) + len(srv.later) + len(srv.captures) + (srv.screencast.owed || srv.screencast.pending ? 1 : 0))
	sync.atomic_store(&srv.cast_dirty, s != nil && srv.screencast.on && s.build_index + 1 != srv.screencast.last_build)
	conns_reap(srv)
}

// Connections that ended, once nothing is left to answer on them. (Each tool's run is a connection or two, for as long
// as the program lives.)
@(private)
conns_reap :: proc(srv: ^Server) {
	if sync.atomic_load(&srv.encoding) > 0 { return }   // (a picture on its way answers on one of them)
	sync.lock(&srv.lock)
	defer sync.unlock(&srv.lock)
	outer: #reverse for c, i in srv.conns {
		if !conn_gone(c) { continue }
		for m in srv.inbox { if m.conn == c { continue outer } }
		for w in srv.captures { if w.conn == c { continue outer } }
		for w in srv.waits { if w.to.conn == c { continue outer } }
		if srv.screencast.on && srv.screencast.to.conn == c { continue }
		if srv.dom.to.conn == c { continue }   // (dom_sync sees it gone, and takes its edits back)
		thread.join(c.thread)
		thread.destroy(c.thread)
		free(c, runtime.heap_allocator())
		unordered_remove(&srv.conns, i)
	}
}

////////////////////////////////
// commands

@(private)
handle :: proc(srv: ^Server, s: ^ui.State, r: ^render.Renderer, m: Message) {
	v, err := json.parse_string(m.text, parse_integers = true, allocator = context.temp_allocator)
	if err != nil { return }
	o, _ := v.(json.Object)
	to := Reply_To{conn = m.conn, id = i64(num(o["id"])), session = str(o["sessionId"])}
	method := str(o["method"])
	p, _ := o["params"].(json.Object)
	if s != nil && dom_handle(srv, s, to, method, p) { return }
	sb := strings.builder_make(context.temp_allocator)
	ok := true
	switch method {
	case "Browser.getVersion":
		fmt.sbprintf(&sb, `{{"protocolVersion":"1.3","product":"gui_toolkit/%s","revision":"","userAgent":"gui_toolkit","jsVersion":""}}`, VERSION)
	case "Target.getTargets":
		fmt.sbprintf(&sb, `{{"targetInfos":[%s]}}`, target_info(srv))
	case "Target.getTargetInfo":
		fmt.sbprintf(&sb, `{{"targetInfo":%s}}`, target_info(srv))
	case "Target.setDiscoverTargets":
		strings.write_string(&sb, "{}")
		reply(to, strings.to_string(sb))
		if bool_of(p["discover"]) { event(to.conn, "", "Target.targetCreated", fmt.tprintf(`{{"targetInfo":%s}}`, target_info(srv))) }
		return
	case "Target.setAutoAttach":
		strings.write_string(&sb, "{}")
		reply(to, strings.to_string(sb))
		// (a connection to the browser's endpoint gets the page; the page, on its own endpoint or in its session, has nothing under it)
		if to.session == "" && !to.conn.page && bool_of(p["autoAttach"]) { attached(srv, to, new_session(srv)) }
		return
	case "Target.attachToTarget":
		session := new_session(srv)
		attached(srv, to, session)   // (before the answer, as Chrome: a client makes the session on the event)
		fmt.sbprintf(&sb, `{{"sessionId":"%s"}}`, session)
	case "Target.attachToBrowserTarget":
		fmt.sbprintf(&sb, `{{"sessionId":"%s"}}`, new_session(srv))
	case "Target.getBrowserContexts":
		strings.write_string(&sb, `{"browserContextIds":[]}`)
	case "Target.detachFromTarget", "Target.activateTarget", "Target.closeTarget":
		strings.write_string(&sb, "{}")
	case "Browser.getWindowForTarget":
		fmt.sbprintf(&sb, `{{"windowId":1,"bounds":{{"left":0,"top":0,"width":%d,"height":%d,"windowState":"normal"}}}}`, srv.win.size.x, srv.win.size.y)
	case "Page.getNavigationHistory":
		strings.write_string(&sb, `{"currentIndex":0,"entries":[{"id":1,"url":"toolkit://window","userTypedURL":"toolkit://window","title":"","transitionType":"other"}]}`)
	case "Page.addScriptToEvaluateOnNewDocument":
		strings.write_string(&sb, `{"identifier":"1"}`)   // (there is no document: it never runs)
	case "Page.createIsolatedWorld":
		strings.write_string(&sb, `{"executionContextId":2}`)
	case "Runtime.enable":
		strings.write_string(&sb, "{}")
		reply(to, strings.to_string(sb))
		event(to.conn, to.session, "Runtime.executionContextCreated", fmt.tprintf(`{{"context":{{"id":1,"origin":"toolkit://window","name":"","auxData":{{"isDefault":true,"type":"default","frameId":"%s"}}}}}}`, srv.id))
		return
	case "Input.dispatchMouseEvent", "Input.emulateTouchFromMouseEvent":   // (the second: DevTools' picture of the window, clicked)
		cast_touch(srv)
		mouse_event(srv, p)
		strings.write_string(&sb, "{}")
	case "Input.dispatchKeyEvent":
		cast_touch(srv)
		key_event(srv, p)
		strings.write_string(&sb, "{}")
	case "Input.insertText":
		cast_touch(srv)
		insert_text(srv, str(p["text"]))
		strings.write_string(&sb, "{}")
	case "Page.captureScreenshot":
		if screenshot_ask(srv, r, to, p) { return }   // answered when the capture is ready
		error_reply(to, -32000, "the renderer cannot capture now")
		return
	case "Page.getLayoutMetrics":
		d := dpi(srv)
		w, h := f64(srv.win.size.x) / d, f64(srv.win.size.y) / d
		fmt.sbprintf(&sb, `{{"layoutViewport":{{"pageX":0,"pageY":0,"clientWidth":%.0f,"clientHeight":%.0f}},"visualViewport":{{"offsetX":0,"offsetY":0,"pageX":0,"pageY":0,"clientWidth":%.0f,"clientHeight":%.0f,"scale":1,"zoom":%g}},"contentSize":{{"x":0,"y":0,"width":%.0f,"height":%.0f}},"cssLayoutViewport":{{"pageX":0,"pageY":0,"clientWidth":%.0f,"clientHeight":%.0f}},"cssVisualViewport":{{"offsetX":0,"offsetY":0,"pageX":0,"pageY":0,"clientWidth":%.0f,"clientHeight":%.0f,"scale":1,"zoom":1}},"cssContentSize":{{"x":0,"y":0,"width":%.0f,"height":%.0f}}}}`, w, h, w, h, d, w, h, w, h, w, h, w, h)
	case "Accessibility.getFullAXTree":
		ax_write_nodes(&sb, srv, ui.a11y_tree(s), nil, true)
	case "Accessibility.queryAXTree":
		ax_write_nodes(&sb, srv, ui.a11y_tree(s), ax_matches(ui.a11y_tree(s), p)[:], false)
	case "Toolkit.axAction":
		if e := ax_action(&sb, srv, s, p); e != "" { error_reply(to, -32000, e); return }
		cast_touch(srv)
	case "Toolkit.axAudit":
		ax_audit(&sb, srv, s)
	case "Toolkit.waitFor":
		if str(p["name"]) == "" && str(p["text"]) == "" { error_reply(to, -32602, "waitFor: a name or a text"); return }
		wait_add(srv, s, to, .Box, p)
		return
	case "Toolkit.waitIdle":
		wait_add(srv, s, to, .Idle, p)
		return
	case "Toolkit.metrics":
		metrics_write(&sb, srv, s, r, p)
	case "Toolkit.warnings":
		strings.write_string(&sb, `{"layout":[`)
		for w, i in ui.layout_warnings() {
			if i > 0 { strings.write_byte(&sb, ',') }
			strings.write_string(&sb, json_quote(w))
		}
		strings.write_string(&sb, "]}")
	case "Toolkit.frames":
		frames_write(&sb, srv, p)
	case "Toolkit.startRecording":
		rec_start(srv, s, p)
		fmt.sbprintf(&sb, `{{"now":%.3f}}`, ui.now_ms())
	case "Toolkit.pollRecording":
		rec_take(srv, &sb)
	case "Toolkit.stopRecording":
		rec_stop(srv, &sb)
	case "Page.startScreencast":
		cast_start(srv, to, p)
		strings.write_string(&sb, "{}")
	case "Page.stopScreencast":
		cast_stop(srv)
		strings.write_string(&sb, "{}")
	case "Page.screencastFrameAck":
		cast_ack(srv, s)
		strings.write_string(&sb, "{}")
	case "Browser.close":
		platform.inject_event(srv.win, platform.Event{kind = .Close})
		strings.write_string(&sb, "{}")
	case "Toolkit.getTree":
		strings.write_string(&sb, `{"root":`)
		write_node(&sb, srv, s, s.root, bool_of(p["all"]), true)
		strings.write_string(&sb, "}")
	case "Toolkit.find":
		find(&sb, srv, s, p)
	case "Toolkit.click":
		b := find_one(s, p)
		if b == nil { error_reply(to, -32000, "no box with that name or text"); return }
		cast_touch(srv)
		x, y := click(srv, b, p)
		fmt.sbprintf(&sb, `{{"x":%.1f,"y":%.1f,"key":"%x"}}`, x, y, u64(b.key))
	case "Toolkit.state":
		d := dpi(srv)
		fmt.sbprintf(&sb, `{{"build":%d,"focus":"%x","hot":"%x","width":%.0f,"height":%.0f,"dpi":%g}}`, s.build_index, u64(ui.focus_key_of(s)), u64(ui.hot_key_of(s)), f64(srv.win.size.x) / d, f64(srv.win.size.y) / d, d)
	// (what Chrome's DevTools asks on attaching and cannot do without; there is nothing behind them)
	case "Page.getResourceTree":
		fmt.sbprintf(&sb, `{{"frameTree":{{"frame":{{"id":"%s","loaderId":"","url":"toolkit://window","securityOrigin":"toolkit://window","mimeType":"text/html"}},"resources":[]}}}}`, srv.id)
	case "Runtime.getIsolateId":
		strings.write_string(&sb, `{"id":"toolkit"}`)
	case "Log.startViolationsReport", "Network.configureDurableMessages", "Network.overrideNetworkState", "Runtime.addBinding", "Runtime.releaseObject", "Runtime.releaseObjectGroup":
		strings.write_string(&sb, "{}")
	case "Network.emulateNetworkConditionsByRule":
		strings.write_string(&sb, `{"ruleIds":[]}`)
	case "Runtime.evaluate", "Runtime.callFunctionOn":
		error_reply(to, -32000, "no JavaScript in a toolkit window: use the Toolkit domain (getTree, find, click)")
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
	if !ok { error_reply(to, -32601, fmt.tprintf("'%s' wasn't found", method)); return }
	reply(to, strings.to_string(sb))
}

// A client attached to the window (the browser's endpoint, as Playwright and Puppeteer use). A session is only a name
// to answer under: they all see the one window.
@(private)
new_session :: proc(srv: ^Server) -> string {
	srv.sessions += 1
	return fmt.tprintf("session-%d", srv.sessions)
}

@(private)
target_info :: proc(srv: ^Server) -> string {
	return fmt.tprintf(`{{"targetId":"%s","type":"page","title":%s,"url":"toolkit://window","attached":true,"canAccessOpener":false,"browserContextId":"default"}}`, srv.id, json_quote(srv.title))
}

@(private)
attached :: proc(srv: ^Server, to: Reply_To, session: string) {
	event(to.conn, to.session, "Target.attachedToTarget", fmt.tprintf(`{{"sessionId":"%s","targetInfo":%s,"waitingForDebugger":false}}`, session, target_info(srv)))
}

// An event of the protocol (no id), to a session or to the connection.
@(private)
event :: proc(c: ^Conn, session, method, params: string) {
	if session == "" {
		send_text(c, fmt.tprintf(`{{"method":"%s","params":%s}}`, method, params))
	} else {
		send_text(c, fmt.tprintf(`{{"sessionId":%s,"method":"%s","params":%s}}`, json_quote(session), method, params))
	}
}

@(private)
error_reply :: proc(to: Reply_To, code: int, msg: string) {
	if to.session == "" {
		send_text(to.conn, fmt.tprintf(`{{"id":%d,"error":{{"code":%d,"message":%s}}}}`, to.id, code, json_quote(msg)))
	} else {
		send_text(to.conn, fmt.tprintf(`{{"id":%d,"sessionId":%s,"error":{{"code":%d,"message":%s}}}}`, to.id, json_quote(to.session), code, json_quote(msg)))
	}
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
matches :: proc(s: ^ui.State, p: json.Object) -> [dynamic]^ui.Box { return matches_of(s, str(p["name"]), str(p["text"])) }

@(private)
matches_of :: proc(s: ^ui.State, name, text: string) -> [dynamic]^ui.Box {
	out := make([dynamic]^ui.Box, context.temp_allocator)
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
	return act_on(ms[idx])
}

// The box a match stands for: the deepest clickable box around it (a label's button), else itself.
@(private)
act_on :: proc(b: ^ui.Box) -> ^ui.Box {
	for a := b; a != nil; a = a.parent { if .Clickable in a.flags || .Text_Input in a.flags { return a } }
	return b
}

@(private)
find :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State, p: json.Object) { write_matches(sb, srv, matches(s, p)) }

@(private)
write_matches :: proc(sb: ^strings.Builder, srv: ^Server, ms: [dynamic]^ui.Box) {
	strings.write_string(sb, `{"nodes":[`)
	for b, i in ms {
		if i > 0 { strings.write_byte(sb, ',') }
		d := f32(dpi(srv))
		fmt.sbprintf(sb, `{{"key":"%x","name":%s,"text":%s,"x":%.1f,"y":%.1f,"w":%.1f,"h":%.1f}}`, u64(b.key), json_quote(b.name), json_quote(ui.box_text(b)),
			b.rect.min.x / d, b.rect.min.y / d, (b.rect.max.x - b.rect.min.x) / d, (b.rect.max.y - b.rect.min.y) / d)
	}
	strings.write_string(sb, "]}")
}

////////////////////////////////
// screenshots

@(private)
screenshot_ask :: proc(srv: ^Server, r: ^render.Renderer, to: Reply_To, p: json.Object) -> bool {
	if len(srv.captures) == 0 {
		// (a frame of the screencast on its way gives way: it asks again; this one may want a part of the window)
		if srv.screencast.pending { render.capture_cancel(r); srv.screencast.pending = false }
		rect: [4]int
		if clip, ok := p["clip"].(json.Object); ok {
			d := dpi(srv)
			rect = {int(num(clip["x"]) * d), int(num(clip["y"]) * d), int(num(clip["width"]) * d), int(num(clip["height"]) * d)}
		}
		if !render.capture_request(r, rect) { return false }
	}
	append(&srv.captures, hold(to))
	return true
}

@(private)
screenshots_poll :: proc(srv: ^Server, s: ^ui.State, r: ^render.Renderer) {
	if srv.screencast.pending {
		pixels, size, status := render.capture_poll(r, runtime.heap_allocator())
		#partial switch status {
		case .Ready: cast_frame(srv, s, pixels, size)
		case .None, .Failed: srv.screencast.pending = false
		}
		return
	}
	if len(srv.captures) == 0 { return }
	pixels, size, status := render.capture_poll(r, runtime.heap_allocator())
	switch status {
	case .Pending:
		return
	case .Ready:
		srv.shots += 1
		encode_start(Encode_Job{srv = srv, pixels = pixels, size = size, replies = slice.clone(srv.captures[:], runtime.heap_allocator())})
	case .None, .Failed:
		for w in srv.captures {
			error_reply(w, -32000, "the capture failed")
			release(w)
		}
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

// A picture read back goes to a thread of its own: even at a high rate, encoding the pixels of a large window is more than
// a frame, which on the UI thread would show in the frame times being measured.
@(private)
Encode_Job :: struct {
	srv:     ^Server,
	pixels:  []u8,         // (the heap's: the job's now)
	size:    [2]int,
	replies: []Reply_To,   // (held: the job's now)
	frame:   bool,         // a frame of the screencast: an event to `to`, with this text after its data
	to:      Reply_To,     // (held)
	meta:    string,       // (the heap's)
}

@(private)
encode_start :: proc(j: Encode_Job) {
	job := new_clone(j, runtime.heap_allocator())
	sync.atomic_add(&j.srv.encoding, 1)
	thread.create_and_start_with_poly_data(job, encode_run, self_cleanup = true)
}

@(private)
encode_run :: proc(j: ^Encode_Job) {
	h := runtime.heap_allocator()
	png := png_encode(j.pixels, j.size.x, j.size.y, h)
	data := base64.encode(png, allocator = h)
	if j.frame {
		event(j.to.conn, j.to.session, "Page.screencastFrame", fmt.tprintf(`{{"data":"%s",%s}}`, data, j.meta))
		release(j.to)
		delete(j.meta, h)
	}
	for w in j.replies {
		reply(w, fmt.tprintf(`{{"data":"%s"}}`, data))
		release(w)
	}
	delete(j.replies, h)
	delete(data, h)
	delete(png, h)
	delete(j.pixels, h)
	srv := j.srv
	free(j, h)
	free_all(context.temp_allocator)
	sync.atomic_sub(&srv.encoding, 1)
}

@(private)
encode_rune :: proc(r: rune) -> ([4]u8, int) { return utf8.encode_rune(r) }
