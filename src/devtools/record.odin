package devtools

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "../platform"
import "../ui"

// The recorder: what a person does in the window, as a script of tools/cdp.mjs to run again (Toolkit.startRecording,
// Toolkit.stopRecording). A click is written by what it clicked (its name, its text), not by where it was, so the script
// survives the layout moving; what names nothing, and a drag, is written with coordinates. Typed text is recorded as
// is: the recording is asked for, and is the asker's to keep. Its alone: another client can neither read it nor stop it, and
// when the asker goes the recording ends and what it held is dropped.

// The pointer's gesture: what its release will make of it.
@(private)
Rec_Gesture :: enum u8 {
	Idle,
	Pressed,    // a press, not far yet: a click if it ends here
	Dragging,   // `down` is written, and each move
}

@(private)
Recorder :: struct {
	on:       bool,
	owner:    ^Conn,              // who asked (while on)
	injected: bool,               // the events of the protocol too (a test of the recorder)
	seen:     u64,                // the last build read
	lines:    [dynamic]Rec_Line,  // (the server's heap)
	taken:    int,                // lines Toolkit.pollRecording has given
	text:     [dynamic]u8,        // characters typed, not yet a line
	text_at:  f64,
	scroll:   [2]f32,             // wheel notches, not yet a line
	scroll_ms: f64,
	touched:  f64,                // the last character or notch: a pause ends them
	scroll_at: [2]f32,
	gesture:  Rec_Gesture,
	press:    [2]f32,             // where it began
	last:     [2]f32,             // where the pointer last was in it
	button:   platform.Mouse_Button,   // its button: another pressed meanwhile is no part of it
	target:   string,             // what a click there means ("": only coordinates; the server's heap: the press and its release are frames apart)
}

@(private)
Rec_Line :: struct { text: string, at: f64 }   // at: ui.now_ms

// A pause this long ends the characters or wheel notches being gathered (Toolkit.pollRecording).
@(private)
REC_PAUSE_MS :: 400

// Further than this between press and release: a drag.
@(private)
DRAG_PX :: 4

@(private)
rec_line :: proc(r: ^Recorder, line: string) {
	rec_flush(r)
	append(&r.lines, Rec_Line{strings.clone(line, runtime.heap_allocator()), ui.now_ms()})
}

// What was accumulating (text, wheel notches) becomes its line.
@(private)
rec_flush :: proc(r: ^Recorder) {
	if len(r.text) > 0 {
		append(&r.lines, Rec_Line{fmt.aprintf("type %s", json_quote(string(r.text[:])), allocator = runtime.heap_allocator()), r.text_at})
		clear(&r.text)
	}
	if r.scroll != {} {
		h := runtime.heap_allocator()
		line := r.scroll.x != 0 ? fmt.aprintf("wheel %.0f %.0f %g %g", r.scroll_at.x, r.scroll_at.y, r.scroll.y, r.scroll.x, allocator = h) : fmt.aprintf("wheel %.0f %.0f %g", r.scroll_at.x, r.scroll_at.y, r.scroll.y, allocator = h)
		append(&r.lines, Rec_Line{line, r.scroll_ms})
		r.scroll = {}
	}
}

// Another client's, which is still there.
@(private)
rec_taken :: proc(srv: ^Server, to: Reply_To) -> bool {
	r := &srv.rec
	return r.on && r.owner != to.conn && !conn_gone(r.owner)
}

@(private)
rec_start :: proc(srv: ^Server, s: ^ui.State, to: Reply_To, p: json.Object) {
	r := &srv.rec
	rec_clear(r)
	r.on, r.owner, r.injected, r.seen = true, to.conn, bool_of(p["injected"]), s.build_index
}

@(private)
rec_clear :: proc(r: ^Recorder) {
	h := runtime.heap_allocator()
	for l in r.lines { delete(l.text, h) }
	clear(&r.lines)
	r.taken = 0
	clear(&r.text)
	r.scroll = {}
	r.gesture = .Idle
}

@(private)
rec_destroy :: proc(r: ^Recorder) {
	rec_clear(r)
	delete(r.lines)
	delete(r.text)
	delete(r.target, runtime.heap_allocator())
}

// Toolkit.stopRecording: the lines of the script.
@(private)
rec_stop :: proc(srv: ^Server, sb: ^strings.Builder) {
	r := &srv.rec
	// (a drag that goes on past the end: played again, what it pressed must come up)
	if r.gesture == .Dragging { rec_up(r, srv) }
	rec_flush(r)
	r.on = false
	strings.write_string(sb, `{"lines":[`)
	for l, i in r.lines {
		if i > 0 { strings.write_byte(sb, ',') }
		strings.write_string(sb, json_quote(l.text))
	}
	strings.write_string(sb, "]}")
	rec_clear(r)
}

// Toolkit.pollRecording: the lines since the last time, with when they happened. (What a timeline reads while it
// records, to take a picture after each.)
@(private)
rec_take :: proc(srv: ^Server, sb: ^strings.Builder) {
	r := &srv.rec
	if ui.now_ms() - r.touched > REC_PAUSE_MS { rec_flush(r) }
	fmt.sbprintf(sb, `{{"now":%.3f,"lines":[`, ui.now_ms())
	for l, i in r.lines[r.taken:] {
		if i > 0 { strings.write_byte(sb, ',') }
		fmt.sbprintf(sb, `{{"line":%s,"t":%.3f}}`, json_quote(l.text), l.at)
	}
	strings.write_string(sb, "]}")
	r.taken = len(r.lines)
}

// " --button right" for what is not the left one (a script's lines say left unless told).
@(private)
rec_button :: proc(r: ^Recorder) -> string { return r.button == .Right ? " --button right" : "" }

@(private)
rec_up :: proc(r: ^Recorder, srv: ^Server) {
	d := f32(dpi(srv))
	rec_line(r, fmt.tprintf("up %.0f %.0f%s", r.last.x / d, r.last.y / d, rec_button(r)))
	rec_line(r, "idle")
}

// Each frame: the input the last build took. Its tree is the one the press was made on (the click acts at the release).
@(private)
rec_poll :: proc(srv: ^Server, s: ^ui.State) {
	r := &srv.rec
	if r.on && conn_gone(r.owner) {   // (nobody will ask for it: what it holds, typed text too, goes now)
		r.on = false
		rec_clear(r)
	}
	if !r.on || s.build_index == r.seen { return }
	r.seen = s.build_index
	d := f32(dpi(srv))
	for e in ui.build_events(s) {
		if e.injected && !r.injected { continue }
		#partial switch e.kind {
		case .Mouse_Press:
			if e.button != .Left && e.button != .Right { continue }
			if r.gesture != .Idle { continue }   // (a second button: the first one's gesture goes on)
			rec_flush(r)
			r.press, r.last, r.gesture, r.button = e.pos, e.pos, .Pressed, e.button
			delete(r.target, runtime.heap_allocator())
			r.target = strings.clone(rec_target(s), runtime.heap_allocator())
		case .Mouse_Move:
			if r.gesture == .Idle { continue }
			r.last = e.pos
			if r.gesture == .Pressed && (abs(e.pos.x - r.press.x) > DRAG_PX * d || abs(e.pos.y - r.press.y) > DRAG_PX * d) {
				r.gesture = .Dragging
				rec_line(r, fmt.tprintf("down %.0f %.0f%s", r.press.x / d, r.press.y / d, rec_button(r)))
			}
			if r.gesture == .Dragging { rec_line(r, fmt.tprintf("move %.0f %.0f", e.pos.x / d, e.pos.y / d)) }
		case .Mouse_Release:
			if r.gesture == .Idle || e.button != r.button { continue }
			r.last = e.pos
			switch {
			case r.gesture == .Dragging:
				rec_up(r, srv)
			case r.target != "":
				rec_line(r, fmt.tprintf("click %s%s", r.target, rec_button(r)))
				rec_line(r, "idle")
			case:
				rec_line(r, fmt.tprintf("down %.0f %.0f%s", r.press.x / d, r.press.y / d, rec_button(r)))
				rec_up(r, srv)
			}
			r.gesture = .Idle
		case .Scroll:
			if len(r.text) > 0 { rec_flush(r) }
			if r.scroll == {} { r.scroll_ms = ui.now_ms() }
			r.touched = ui.now_ms()
			r.scroll += e.delta
			r.scroll_at = {e.pos.x / d, e.pos.y / d}
		case .Text:
			if r.scroll != {} { rec_flush(r) }
			if len(r.text) == 0 { r.text_at = ui.now_ms() }
			r.touched = ui.now_ms()
			buf, n := encode_rune(e.text)
			append(&r.text, ..buf[:n])
		case .Key_Press:
			if line := rec_key(e); line != "" {
				rec_line(r, line)
				rec_line(r, "idle")
			}
		}
	}
}

// An action sent by Toolkit.axAction, as the press that does it again: by the role and the name of its node, with the index when
// others come first. (The recorder sees it here: it is no event of the window's.)
@(private)
rec_press :: proc(srv: ^Server, u: ^platform.A11y_Update, node: int, action: platform.A11y_Action, p: json.Object) {
	r := &srv.rec
	if !r.on || !r.injected { return }
	role, name := ax_role_name(platform.A11y_Role(u.nodes[node].role)), ax_name_of(u, node)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "press %s --role %s", json_quote(name), role)
	if action != .Click { fmt.sbprintf(&sb, " --action %v", action) }
	for m, i in ax_matching(u, role, name, false) { if m == node { if i > 0 { fmt.sbprintf(&sb, " --index %d", i) }; break } }
	if v, has := p["value"]; has {
		#partial switch x in v {
		case json.String:           fmt.sbprintf(&sb, " --value %s", json_quote(x))
		case json.Integer, json.Float: fmt.sbprintf(&sb, " --number %g", num(v))
		}
	}
	rec_line(r, strings.to_string(sb))
	rec_line(r, "idle")
}

// The words that find what is under the pointer: a name, else a text, with the index when others come first; "" when
// neither finds that very box.
@(private)
rec_target :: proc(s: ^ui.State) -> string {
	b := ui.box_of(s, ui.hot_key_of(s))
	if b == nil || .Clickable not_in b.flags && .Text_Input not_in b.flags { return "" }
	try :: proc(s: ^ui.State, b: ^ui.Box, name, text, words: string) -> string {
		for m, i in matches_of(s, name, text) {
			if act_on(m) == b { return i == 0 ? words : fmt.tprintf("%s --index %d", words, i) }
		}
		return ""
	}
	if b.name != "" {
		if w := try(s, b, b.name, "", fmt.tprintf("--name %s", json_quote(b.name))); w != "" { return w }
	}
	text :: proc(b: ^ui.Box) -> string {
		if t := ui.box_text(b); t != "" { return t }
		for c := b.first; c != nil; c = c.next { if t := text(c); t != "" { return t } }
		return ""
	}
	if t := text(b); t != "" {
		if w := try(s, b, "", t, json_quote(t)); w != "" { return w }
	}
	return ""
}

// A key press worth a line: not a character (Text says those), not a modifier alone.
@(private)
rec_key :: proc(e: platform.Event) -> string {
	combo := e.mods & {.Ctrl, .Alt} != {}
	name := key_name(e.key)
	if name == "" { return "" }
	if len(name) == 1 && !combo { return "" }
	sb := strings.builder_make(context.temp_allocator)
	if .Ctrl in e.mods { strings.write_string(&sb, "ctrl+") }
	if .Alt in e.mods { strings.write_string(&sb, "alt+") }
	if .Shift in e.mods { strings.write_string(&sb, "shift+") }
	strings.write_string(&sb, name)
	return fmt.tprintf("key %s", strings.to_string(sb))
}

// The DOM's name of a key (key_of the other way); "" for a modifier alone and what has no name there.
@(private)
key_name :: proc(k: platform.Key) -> string {
	#partial switch k {
	case .Return: return "Enter"
	case .Tab: return "Tab"
	case .Escape: return "Escape"
	case .Backspace: return "Backspace"
	case .Delete: return "Delete"
	case .Insert: return "Insert"
	case .Left: return "ArrowLeft"
	case .Right: return "ArrowRight"
	case .Up: return "ArrowUp"
	case .Down: return "ArrowDown"
	case .Home: return "Home"
	case .End: return "End"
	case .Page_Up: return "PageUp"
	case .Page_Down: return "PageDown"
	case .Menu: return "ContextMenu"
	case .Space: return " "
	case .Comma: return ","
	case .Period: return "."
	case .Slash: return "/"
	case .Minus: return "-"
	case .Equal: return "="
	}
	v := int(k)
	if v >= int(platform.Key.A) && v <= int(platform.Key.Z) { return fmt.tprintf("%c", 'a' + rune(v - int(platform.Key.A))) }
	if v >= int(platform.Key.N0) && v <= int(platform.Key.N9) { return fmt.tprintf("%c", '0' + rune(v - int(platform.Key.N0))) }
	if v >= int(platform.Key.F1) && v <= int(platform.Key.F12) { return fmt.tprintf("F%d", v - int(platform.Key.F1) + 1) }
	return ""
}
