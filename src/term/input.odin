package term

// The grid's input: the keys and the pointer turned into bytes for the program behind the screen, a selection, the
// scrollback, the zoom. The program routes each event to a view (event): the keys to the one with the keyboard, the
// pointer to the one that holds a press, else to the one under it. What needs the program (the clipboard, a menu,
// keeping a zoom) comes back as an Outcome.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "../draw"
import "../platform"
import "../ui"

// What became of an event.
Outcome :: enum u8 {
	Ignored,   // the interface sees it too (a press: the box takes the focus; a release, a move: whatever else they end)
	Taken,     // the grid's alone
	Copy,      // a copy key, with a selection: selection_text goes to the clipboard
	Paste,     // a paste key: the clipboard's text goes to paste
	Menu,      // a right click: the program's menu, at the event's position
	Zoomed,    // the zoom moved (zoom_set): the program may keep it, and needs a frame after ZOOM_REST_MS
}

// One event for this view. The program decides that it is this view's: see the head of this file.
event :: proc(v: ^View, e: platform.Event) -> Outcome {
	#partial switch e.kind {
	case .Key_Press:   return key_event(v, e)
	case .Key_Release: return typed(v) ? .Taken : .Ignored
	case .Text:
		if !typed(v) { return .Ignored }
		if e.text >= ' ' && e.text != 127 {
			b, n := utf8.encode_rune(e.text)
			send_typed(v, string(b[:n]))
		}
		return .Taken
	case .Scroll:
		if .Ctrl in e.mods {
			zoom_set(v, e.delta.y < 0 ? v.zoom * ZOOM_STEP : v.zoom / ZOOM_STEP)
			return .Zoomed
		}
		if tracks_mouse(v) {
			button := e.delta.y > 0 ? Mouse_Button.Wheel_Down : Mouse_Button.Wheel_Up
			mouse_send(v, .Press, button, e.pos, e.mods, false)
			mouse_send(v, .Release, button, e.pos, e.mods, false)
			return .Taken
		}
		n := platform.wheel_lines()   // (the lines the system says; where it says a page, a page less a line)
		if n <= 0 { n = f32(max(v.rows - 1, 1)) }
		scroll(v, int(math.round(e.delta.y * n)))
		return .Taken
	case .Mouse_Press:
		switch {
		case on_bar(v, e.pos):
			// (the scroll bar is the toolkit's: its press goes to the interface, whatever the program asks of the mouse)
		case e.button == .Right && (!tracks_mouse(v) || .Shift in e.mods):
			return .Menu
		case tracks_mouse(v) && .Shift not_in e.mods:
			mouse_send(v, .Press, mouse_button_of(e.button), e.pos, e.mods, true)
			if v.press == .None { v.press, v.press_button, v.press_pos = .Program, e.button, e.pos }
		case e.button == .Left && v.press == .None:
			v.press, v.press_button, v.press_pos = .Select, e.button, e.pos
			select_begin(v, cell_at(v, e.pos))
		}
	case .Mouse_Release:
		if v.press != .None && e.button == v.press_button {
			v.press_pos = e.pos
			press_end(v)
		} else if tracks_mouse(v) {
			mouse_send(v, .Release, mouse_button_of(e.button), e.pos, e.mods, false)
		}
	case .Mouse_Move:
		switch v.press {
		case .Select:
			select_to(v, cell_at(v, e.pos))
		case .Program:
			v.press_pos = e.pos
			mouse_send(v, .Motion, .None, e.pos, e.mods, true)
		case .None:
			if tracks_mouse(v) { mouse_send(v, .Motion, .None, e.pos, e.mods, e.buttons != {}) }
		}
	}
	return .Ignored
}

// (the keys a program types in: a read-only grid has none)
@(private)
typed :: proc(v: ^View) -> bool { return !v.read_only && v.source.write != nil }

@(private)
key_event :: proc(v: ^View, e: platform.Event) -> Outcome {
	if e.mods == {.Ctrl} {
		#partial switch e.key {
		case .Equal, .Num_Add:      zoom_set(v, v.zoom * ZOOM_STEP); return .Zoomed
		case .Minus, .Num_Subtract: zoom_set(v, v.zoom / ZOOM_STEP); return .Zoomed
		case .N0:                   zoom_set(v, 1); return .Zoomed
		}
	}
	switch {
	// (Ctrl+C alone is the program's: an interrupt. Ctrl+Insert: the terminals' other copy.)
	case (e.key == .C && (e.mods == {.Ctrl, .Shift} || (v.read_only && e.mods == {.Ctrl}))) || (e.key == .Insert && e.mods == {.Ctrl}):
		return has_selection(v) ? .Copy : .Taken
	// (Shift+Insert: the terminals' other paste)
	case ((e.key == .V && e.mods == {.Ctrl, .Shift}) || (e.key == .Insert && e.mods == {.Shift})) && typed(v):
		return .Paste
	case e.key == .Page_Up && e.mods == {.Shift}:
		scroll(v, -v.rows)
	case e.key == .Page_Down && e.mods == {.Shift}:
		scroll(v, v.rows)
	case !typed(v):
		return .Ignored
	case e.key == .Shift || e.key == .Ctrl || e.key == .Alt:
	case:
		if s := encode_key(v, {e.key, e.mods, e.repeat}); s != "" { send_typed(v, s) }
	}
	return .Taken
}

// What is typed goes to the program, and the view goes back to the last rows: what was selected is dropped.
@(private)
send_typed :: proc(v: ^View, s: string) {
	write(v, s)
	scroll_bottom(v)
	selection_drop(v)
}

// Bytes for the program behind the screen (nothing when it reads only).
write :: proc(v: ^View, s: string) {
	if len(s) == 0 || v.source.write == nil { return }
	v.source.write(v.source.data, s)
}

modes :: proc(v: ^View) -> Modes { return v.source.modes != nil ? v.source.modes(v.source.data) : {} }

// The keys whose character comes as a Text event, with the keyboard's layout.
key_printable :: proc(k: platform.Key) -> bool {
	#partial switch k {
	case .A ..= .Z, .N0 ..= .N9, .Space, .Comma, .Period, .Slash, .Minus, .Equal, .Num_Add, .Num_Subtract: return true
	}
	return false
}

// What the program gets for a key, in the temporary allocator ("": nothing). A printable key alone gives nothing: its Text
// event says the character. Ctrl and Alt together are AltGr on many keyboards: a character too.
encode_key :: proc(v: ^View, k: Key_Input) -> string {
	if key_printable(k.key) && (k.mods & {.Ctrl, .Alt} == {} || k.mods & {.Ctrl, .Alt} == {.Ctrl, .Alt}) { return "" }
	buf := make([]u8, KEY_BYTES, context.temp_allocator)
	n := 0
	if v.source.encode_key != nil {
		n = v.source.encode_key(v.source.data, k, buf)
	} else {
		n = len(xterm_key(k, .App_Cursor in modes(v), buf))
	}
	return string(buf[:clamp(n, 0, len(buf))])
}

// The keys as xterm says them, without any of its later protocols: what a source without an encoder of its own sends.
// `app_cursor`: the arrows, Home and End say ESC O (DECCKM). Returns the bytes written in `buf`.
xterm_key :: proc(k: Key_Input, app_cursor: bool, buf: []u8) -> string {
	m := 1   // (xterm's modifier parameter: 1 + Shift 1, Alt 2, Ctrl 4)
	if .Shift in k.mods { m += 1 }
	if .Alt in k.mods { m += 2 }
	if .Ctrl in k.mods { m += 4 }
	alt := .Alt in k.mods ? "\x1b" : ""
	letter :: proc(final: rune, m: int, app_cursor: bool, buf: []u8) -> string {
		if m > 1 { return fmt.bprintf(buf, "\x1b[1;%d%c", m, final) }
		return fmt.bprintf(buf, "%s%c", app_cursor ? "\x1bO" : "\x1b[", final)
	}
	tilde :: proc(n, m: int, buf: []u8) -> string {
		if m > 1 { return fmt.bprintf(buf, "\x1b[%d;%d~", n, m) }
		return fmt.bprintf(buf, "\x1b[%d~", n)
	}
	#partial switch k.key {
	case .Return:    return fmt.bprintf(buf, "%s\r", alt)
	case .Backspace: return fmt.bprintf(buf, "%s%s", alt, .Ctrl in k.mods ? "\x08" : "\x7f")
	case .Tab:       return .Shift in k.mods ? fmt.bprintf(buf, "\x1b[Z") : fmt.bprintf(buf, "%s\t", alt)
	case .Escape:    return fmt.bprintf(buf, "%s\x1b", alt)
	case .Up:        return letter('A', m, app_cursor, buf)
	case .Down:      return letter('B', m, app_cursor, buf)
	case .Right:     return letter('C', m, app_cursor, buf)
	case .Left:      return letter('D', m, app_cursor, buf)
	case .Home:      return letter('H', m, app_cursor, buf)
	case .End:       return letter('F', m, app_cursor, buf)
	case .F1 ..= .F4:
		final := rune('P' + int(k.key) - int(platform.Key.F1))
		if m > 1 { return fmt.bprintf(buf, "\x1b[1;%d%c", m, final) }
		return fmt.bprintf(buf, "\x1bO%c", final)
	case .F5 ..= .F12:
		NUMBERS := [8]int{15, 17, 18, 19, 20, 21, 23, 24}
		return tilde(NUMBERS[int(k.key) - int(platform.Key.F5)], m, buf)
	case .Insert:    return tilde(2, m, buf)
	case .Delete:    return tilde(3, m, buf)
	case .Page_Up:   return tilde(5, m, buf)
	case .Page_Down: return tilde(6, m, buf)
	case .A ..= .Z:
		c := rune('a' + int(k.key) - int(platform.Key.A))
		if .Ctrl in k.mods { return fmt.bprintf(buf, "%s%c", alt, c - 'a' + 1) }
		if .Shift in k.mods { c -= 'a' - 'A' }
		return fmt.bprintf(buf, "%s%c", alt, c)
	case .N0 ..= .N9:
		if .Ctrl in k.mods { return "" }
		return fmt.bprintf(buf, "%s%c", alt, rune('0' + int(k.key) - int(platform.Key.N0)))
	case .Space:
		if .Ctrl in k.mods { return fmt.bprintf(buf, "%s\x00", alt) }
		return fmt.bprintf(buf, "%s ", alt)
	}
	return ""
}

// What is pasted, as the program asked for it. Without the brackets, a line break in a paste runs what comes before it:
// line ends are then returns, as typed.
paste_text :: proc(v: ^View, s: string, allocator := context.temp_allocator) -> string {
	if .Bracketed_Paste in modes(v) { return fmt.aprintf("\x1b[200~%s\x1b[201~", s, allocator = allocator) }
	flat, _ := strings.replace_all(s, "\r\n", "\r", allocator)
	flat, _ = strings.replace_all(flat, "\n", "\r", allocator)
	return flat
}

// The clipboard's text, typed in (Outcome.Paste).
paste :: proc(v: ^View, s: string) {
	if !typed(v) || s == "" { return }
	write(v, paste_text(v, s))
}

////////////////////////////////
// The scrollback

scroll :: proc(v: ^View, delta: int) {
	if v.source.scroll != nil && delta != 0 { v.source.scroll(v.source.data, delta, false) }
}

scroll_bottom :: proc(v: ^View) {
	if v.source.scroll != nil { v.source.scroll(v.source.data, 0, true) }
}

scrollbar :: proc(v: ^View) -> (bar: Scrollbar, ok: bool) {
	if v.source.scrollbar == nil { return }
	return v.source.scrollbar(v.source.data)
}

// The last rows are shown.
at_bottom :: proc(v: ^View) -> bool {
	bar, ok := scrollbar(v)
	return !ok || bar.offset + bar.len >= bar.total
}

////////////////////////////////
// The selection

has_selection :: proc(v: ^View) -> bool {
	return v.source.select != nil && v.source.select(v.source.data, .Has, {})
}

// The text selected, wherever it is now (out of the rows shown too). "": none.
selection_text :: proc(v: ^View, allocator := context.temp_allocator) -> string {
	if v.source.selection_text == nil || !has_selection(v) { return "" }
	return v.source.selection_text(v.source.data, allocator)
}

// No selection, and no drag making one.
selection_drop :: proc(v: ^View) {
	if v.press == .Select { v.press = .None }
	if v.source.select != nil { v.source.select(v.source.data, .Drop, {}) }
}

select_all :: proc(v: ^View) {
	if v.press == .Select { press_end(v) }
	if v.source.select != nil { v.source.select(v.source.data, .All, {}) }
}

// A drag's first press, on `cell` (of the rows shown): nothing is selected until the pointer leaves it.
select_begin :: proc(v: ^View, cell: [2]int) {
	v.press_cell = cell
	if v.source.select != nil { v.source.select(v.source.data, .Begin, cell_clamp(v, cell)) }
}

// The drag is over `cell`: from where it began to there, once it has left the cell it began on.
select_to :: proc(v: ^View, cell: [2]int) {
	if v.source.select == nil { return }
	if cell == v.press_cell && !has_selection(v) { return }
	v.source.select(v.source.data, .Extend, cell_clamp(v, cell))
}

// What the button held on the grid stops, wherever it was let go or whatever took it away: the selection is what it is
// by now, and a program told of a press is told of its release.
press_end :: proc(v: ^View) {
	press := v.press
	v.press = .None
	switch press {
	case .None:
	case .Select:
		if v.source.select != nil { v.source.select(v.source.data, .End, {}) }
	case .Program:
		mouse_send(v, .Release, mouse_button_of(v.press_button), v.press_pos, {}, false)
	}
}

// The cell under `p` (window pixels), in the rows shown: past the grid's left or top edge, the first.
cell_at :: proc(v: ^View, p: [2]f32) -> [2]int {
	x := int((p.x - v.origin.x) / max(v.metrics.cell_w, 1))
	y := int((p.y - v.origin.y) / max(v.metrics.cell_h, 1))
	return {max(x, 0), max(y, 0)}
}

// (a cell past the grid's edge is none of its cells: the nearest that is)
@(private)
cell_clamp :: proc(v: ^View, cell: [2]int) -> [2]int {
	return {clamp(cell.x, 0, max(v.cols - 1, 0)), clamp(cell.y, 0, max(v.rows - 1, 0))}
}

////////////////////////////////
// The mouse, for a program that asks for it

tracks_mouse :: proc(v: ^View) -> bool {
	return typed(v) && v.source.encode_mouse != nil && .Mouse_Tracking in modes(v)
}

@(private)
mouse_button_of :: proc(b: platform.Mouse_Button) -> Mouse_Button {
	#partial switch b {
	case .Left:   return .Left
	case .Right:  return .Right
	case .Middle: return .Middle
	}
	return .None
}

@(private)
mouse_send :: proc(v: ^View, action: Mouse_Action, button: Mouse_Button, at: [2]f32, mods: platform.Modifiers, held: bool) {
	if v.source.encode_mouse == nil { return }
	r := v.rect
	// (a position outside the grid is not one an encoder can say: the nearest in it)
	pos := [2]f32{clamp(at.x, r.min.x, r.max.x - 1), clamp(at.y, r.min.y, r.max.y - 1)}
	m := Mouse_Input{
		action = action, button = button, mods = mods, held = held,
		pos = pos - r.min, size = r.max - r.min, cell = {v.metrics.cell_w, v.metrics.cell_h},
		pad_lo = v.origin - r.min, pad_hi = r.max - v.origin - {f32(v.cols) * v.metrics.cell_w, f32(v.rows) * v.metrics.cell_h},
	}
	buf: [KEY_BYTES]u8
	n := v.source.encode_mouse(v.source.data, m, buf[:])
	if n > 0 { write(v, string(buf[:min(n, len(buf))])) }
}

// Whether `p` is on the grid's scroll bar (where the toolkit takes a press on it): that press is the interface's.
on_bar :: proc(v: ^View, p: [2]f32) -> bool {
	if v.box == 0 { return false }
	b := ui.box_from_key(v.box)
	if b == nil { return false }
	_, on := ui.scrollbar_under(b, p)
	return on
}

// Whether `p` is on the grid.
contains :: proc(v: ^View, p: [2]f32) -> bool { return draw.rect_contains(v.rect, p) }

////////////////////////////////
// The zoom

// Its own zoom, within ZOOM_MIN and ZOOM_MAX. The grid keeps its size until the zoom rests (ZOOM_REST_MS): the program
// asks for a frame then.
zoom_set :: proc(v: ^View, zoom: f32) {
	v.zoom = clamp(zoom, ZOOM_MIN, ZOOM_MAX)
	if abs(v.zoom - 1) < 0.01 { v.zoom = 1 }   // (steps back and forth come back near 1, not to it)
	v.zoom_ms = ui.now_ms()
}
