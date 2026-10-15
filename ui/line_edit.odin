package ui

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "../draw"
import "../font"
import "../platform"

// Single-line text field state. The caller owns it (like any other value); the widget edits it in place.
Text_Field :: struct {
	buf:       [dynamic]u8,
	cursor:    int,           // byte index of the caret
	mark:      int,           // other end of the selection (== cursor when nothing is selected)
	scroll_x:  f32,           // horizontal scroll in pixels, keeps the caret visible
	edited_ms: f64,           // time of the last edit/move (caret stays solid right after)
}

field_destroy :: proc(f: ^Text_Field) { delete(f.buf) }
field_string :: proc(f: ^Text_Field) -> string { return string(f.buf[:]) }

field_set :: proc(f: ^Text_Field, text: string) {
	clear(&f.buf)
	append(&f.buf, text)
	f.cursor, f.mark, f.scroll_x = len(f.buf), len(f.buf), 0
}

field_clear :: proc(f: ^Text_Field) { field_set(f, "") }

Edit_Result :: struct {
	using signal: Signal,
	changed:   bool,   // text was modified this frame
	committed: bool,   // Enter pressed while focused
	cancelled: bool,   // Escape pressed while focused
}

Line_Edit_Draw :: struct {
	text:        string,
	placeholder: string,
	cursor, mark: int,
	scroll_x:    f32,
	focused:     bool,
	caret_on:    bool,
	selection:   Color,
	caret:       Color,
	weak:        Color,
	pad:         f32,
}

@(private)
prev_index :: proc(s: string, i: int) -> int {
	i := i
	if i <= 0 { return 0 }
	i -= 1
	for i > 0 && (s[i] & 0xC0) == 0x80 { i -= 1 }
	return i
}

@(private)
next_index :: proc(s: string, i: int) -> int {
	if i >= len(s) { return len(s) }
	_, n := utf8.decode_rune_in_string(s[i:])
	return i + max(n, 1)
}

@(private)
is_word_rune :: proc(r: rune) -> bool {
	return r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r > 127
}

@(private)
word_left :: proc(s: string, i: int) -> int {
	i := i
	for i > 0 {
		j := prev_index(s, i)
		r, _ := utf8.decode_rune_in_string(s[j:])
		if is_word_rune(r) { break }
		i = j
	}
	for i > 0 {
		j := prev_index(s, i)
		r, _ := utf8.decode_rune_in_string(s[j:])
		if !is_word_rune(r) { break }
		i = j
	}
	return i
}

@(private)
word_right :: proc(s: string, i: int) -> int {
	i := i
	for i < len(s) {
		r, n := utf8.decode_rune_in_string(s[i:])
		if is_word_rune(r) { break }
		i += n
	}
	for i < len(s) {
		r, n := utf8.decode_rune_in_string(s[i:])
		if !is_word_rune(r) { break }
		i += n
	}
	return i
}

@(private)
sel_range :: proc(f: ^Text_Field) -> (lo, hi: int) { return min(f.cursor, f.mark), max(f.cursor, f.mark) }

@(private)
delete_selection :: proc(f: ^Text_Field) -> bool {
	lo, hi := sel_range(f)
	if lo == hi { return false }
	remove_range(&f.buf, lo, hi)
	f.cursor, f.mark = lo, lo
	return true
}

@(private)
insert_text :: proc(f: ^Text_Field, text: string) {
	delete_selection(f)
	inject_at_elems(&f.buf, f.cursor, ..transmute([]u8)text)
	f.cursor += len(text)
	f.mark = f.cursor
}

@(private)
line_edit_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Line_Edit_Draw)(user)
	s := g
	m := font.metrics(s.fonts, b.font, b.font_size)
	cy := (b.rect.min.y + b.rect.max.y) * 0.5
	baseline := math.round(cy + (m.ascent - m.descent) * 0.5)
	x0 := b.rect.min.x + d.pad - d.scroll_x
	if d.text == "" && !d.focused {
		draw.text(dc, b.font, b.font_size, {math.round(b.rect.min.x + d.pad), baseline}, d.weak, d.placeholder)
		return
	}
	lo, hi := min(d.cursor, d.mark), max(d.cursor, d.mark)
	if lo != hi && d.focused {
		xa := x0 + font.x_from_index(s.fonts, b.font, b.font_size, d.text, lo)
		xb := x0 + font.x_from_index(s.fonts, b.font, b.font_size, d.text, hi)
		draw.rect(dc, {{xa, cy - m.line_height * 0.5}, {xb, cy + m.line_height * 0.5}}, d.selection)
	}
	draw.text(dc, b.font, b.font_size, {x0, baseline}, b.text_color, d.text)
	if d.focused && d.caret_on {
		cx := math.round(x0 + font.x_from_index(s.fonts, b.font, b.font_size, d.text, d.cursor))
		draw.rect(dc, {{cx, cy - m.line_height * 0.5}, {cx + max(1, math.round(b.font_size / 12)), cy + m.line_height * 0.5}}, d.caret)
	}
}

// Single-line editor. Tags used: "input" (+ whatever the caller pushed, e.g. "bad" for an invalid value).
// Supports: typing, selection (shift, mouse drag, double-click word), Home/End, ctrl+arrows (words),
// Backspace/Delete (ctrl = word), ctrl+A/C/X/V, Enter (committed), Escape (cancelled, drops focus).
line_edit :: proc(id: string, f: ^Text_Field, placeholder := "") -> (res: Edit_Result) {
	s := g
	if tags("input") {
		b := build_box({.Clickable, .Focusable, .Text_Input, .Clip, .Draw_Background, .Draw_Border, .Draw_Focus_Ring}, id)
		b.cursor = .Text
		b.text = ""
		res.signal = signal(b)
		now := s.time_ms
		focused := res.focused
		before := len(f.buf)
		before_hash := hash_bytes(f.buf[:])
		pad := b.text_pad
		text := field_string(f)

		// mouse: click places the caret, drag selects, double-click selects the word
		if res.pressed || res.dragging {
			x := res.mouse.x - pad + f.scroll_x
			idx := font.index_from_x(s.fonts, b.font, b.font_size, text, x)
			f.cursor = idx
			if res.pressed && .Shift not_in res.mods { f.mark = idx }
			f.edited_ms = now
		}
		if res.double_clicked {
			f.mark = word_left(text, min(f.cursor + 1, len(text)))
			f.cursor = word_right(text, f.mark)
		}

		if focused {
			ctrl := platform.Modifiers{.Ctrl}
			shift := platform.Modifiers{.Shift}
			cs := platform.Modifiers{.Ctrl, .Shift}
			move :: proc(f: ^Text_Field, to: int, extend: bool) {
				f.cursor = to
				if !extend { f.mark = to }
			}
			for r in s.typed { insert_text(f, utf8.runes_to_string({r}, context.temp_allocator)) }
			for mods in ([?]platform.Modifiers{{}, shift}) {
				ext := mods == shift
				lo, hi := sel_range(f)
				if key_press(.Left, mods)  { move(f, (lo != hi && !ext) ? lo : prev_index(field_string(f), f.cursor), ext) }
				if key_press(.Right, mods) { move(f, (lo != hi && !ext) ? hi : next_index(field_string(f), f.cursor), ext) }
				if key_press(.Home, mods)  { move(f, 0, ext) }
				if key_press(.End, mods)   { move(f, len(f.buf), ext) }
			}
			for mods in ([?]platform.Modifiers{ctrl, cs}) {
				ext := mods == cs
				if key_press(.Left, mods)  { move(f, word_left(field_string(f), f.cursor), ext) }
				if key_press(.Right, mods) { move(f, word_right(field_string(f), f.cursor), ext) }
			}
			if key_press(.Backspace) { if !delete_selection(f) { lo := prev_index(field_string(f), f.cursor); remove_range(&f.buf, lo, f.cursor); f.cursor, f.mark = lo, lo } }
			if key_press(.Delete)    { if !delete_selection(f) { hi := next_index(field_string(f), f.cursor); remove_range(&f.buf, f.cursor, hi) } }
			if key_press(.Backspace, ctrl) { if !delete_selection(f) { lo := word_left(field_string(f), f.cursor); remove_range(&f.buf, lo, f.cursor); f.cursor, f.mark = lo, lo } }
			if key_press(.Delete, ctrl)    { if !delete_selection(f) { hi := word_right(field_string(f), f.cursor); remove_range(&f.buf, f.cursor, hi) } }
			if key_press(.A, ctrl) { f.mark = 0; f.cursor = len(f.buf) }
			if key_press(.C, ctrl) {
				lo, hi := sel_range(f)
				if lo != hi && s.clipboard_set != nil { s.clipboard_set(string(f.buf[lo:hi])) }
			}
			if key_press(.X, ctrl) {
				lo, hi := sel_range(f)
				if lo != hi && s.clipboard_set != nil { s.clipboard_set(string(f.buf[lo:hi])) }
				delete_selection(f)
			}
			if key_press(.V, ctrl) && s.clipboard_get != nil {
				clip := s.clipboard_get()
				clean, _ := strings.replace_all(clip, "\n", " ", context.temp_allocator)
				clean, _ = strings.replace_all(clean, "\r", "", context.temp_allocator)
				insert_text(f, clean)
			}
			if key_press(.Return) { res.committed = true }
			if key_press(.Escape) { res.cancelled = true; s.focus_key = 0 }
			f.cursor = clamp(f.cursor, 0, len(f.buf))
			f.mark = clamp(f.mark, 0, len(f.buf))
			s.wake_ms = 265   // caret blink
		}
		after_hash := hash_bytes(f.buf[:])
		res.changed = before != len(f.buf) || before_hash != after_hash
		if res.changed { f.edited_ms = now }
		text = field_string(f)

		// keep the caret visible
		inner := max(8, (b.rect.max.x - b.rect.min.x) - 2 * pad)
		cx := font.x_from_index(s.fonts, b.font, b.font_size, text, f.cursor)
		total := font.text_width(s.fonts, b.font, b.font_size, text)
		if cx - f.scroll_x > inner { f.scroll_x = cx - inner }
		if cx - f.scroll_x < 0 { f.scroll_x = cx }
		f.scroll_x = clamp(f.scroll_x, 0, max(0, total - inner + 2))

		d := frame_new(Line_Edit_Draw)
		d.text = strings.clone(text, frame_allocator())
		d.placeholder = placeholder
		d.cursor, d.mark, d.scroll_x = f.cursor, f.mark, f.scroll_x
		d.focused = focused
		since := now - f.edited_ms
		d.caret_on = since < 500 || (int(since) / 530) % 2 == 0
		d.selection = color("selection")
		d.caret = color("cursor")
		if tags("weak") { d.weak = color("text") }
		d.pad = pad
		b.custom = line_edit_draw
		b.custom_user = d
	}
	return
}

@(private)
hash_bytes :: proc(b: []u8) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for c in b { h = (h ~ u64(c)) * 0x100000001b3 }
	return h
}
