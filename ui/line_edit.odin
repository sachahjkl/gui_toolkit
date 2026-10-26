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
	undo, redo: [dynamic]Field_Snapshot,   // edit history (Ctrl+Z / Ctrl+Y, field_undo / field_redo)
	last_edit:  Field_Edit,   // what the last recorded edit was: consecutive typing is one undo step
	last_edit_ms: f64,
}

// The text and selection before an edit. `text` is owned by the field.
Field_Snapshot :: struct {
	text:         string,
	cursor, mark: int,
}

Field_Edit :: enum u8 { None, Typing, Deleting, Other }

// Steps kept by the edit history of a field; typing within this many ms of the previous key is the same step.
FIELD_UNDO_STEPS :: 100
FIELD_UNDO_MERGE_MS :: 1000.0

field_destroy :: proc(f: ^Text_Field) {
	delete(f.buf)
	field_forget_history(f)
	delete(f.undo)
	delete(f.redo)
}

field_string :: proc(f: ^Text_Field) -> string { return string(f.buf[:]) }

// Replaces the text (caret at the end). The edit history starts over: the new text is not an edit of the old one.
field_set :: proc(f: ^Text_Field, text: string) {
	clear(&f.buf)
	append(&f.buf, text)
	f.cursor, f.mark, f.scroll_x = len(f.buf), len(f.buf), 0
	field_forget_history(f)
}

field_clear :: proc(f: ^Text_Field) { field_set(f, "") }

@(private)
field_forget_history :: proc(f: ^Text_Field) {
	for s in f.undo { delete(s.text) }
	for s in f.redo { delete(s.text) }
	clear(&f.undo)
	clear(&f.redo)
	f.last_edit = .None
}

// Records the state before an edit of kind `kind` (typing and deleting merge with the previous step of the same kind).
@(private)
field_checkpoint :: proc(f: ^Text_Field, kind: Field_Edit) {
	now := now_ms()
	merge := kind != .Other && kind == f.last_edit && now - f.last_edit_ms < FIELD_UNDO_MERGE_MS && len(f.undo) > 0
	f.last_edit, f.last_edit_ms = kind, now
	if merge { return }
	if len(f.undo) >= FIELD_UNDO_STEPS { delete(f.undo[0].text); ordered_remove(&f.undo, 0) }
	append(&f.undo, Field_Snapshot{text = strings.clone(string(f.buf[:])), cursor = f.cursor, mark = f.mark})
	for s in f.redo { delete(s.text) }
	clear(&f.redo)
}

@(private)
field_restore :: proc(f: ^Text_Field, from, to: ^[dynamic]Field_Snapshot) -> bool {
	if len(from) == 0 { return false }
	snap := pop(from)
	append(to, Field_Snapshot{text = strings.clone(string(f.buf[:])), cursor = f.cursor, mark = f.mark})
	clear(&f.buf)
	append(&f.buf, snap.text)
	f.cursor, f.mark = clamp(snap.cursor, 0, len(f.buf)), clamp(snap.mark, 0, len(f.buf))
	delete(snap.text)
	f.last_edit = .None
	return true
}

field_can_undo :: proc(f: ^Text_Field) -> bool { return len(f.undo) > 0 }
field_can_redo :: proc(f: ^Text_Field) -> bool { return len(f.redo) > 0 }
field_undo :: proc(f: ^Text_Field) -> bool { return field_restore(f, &f.undo, &f.redo) }
field_redo :: proc(f: ^Text_Field) -> bool { return field_restore(f, &f.redo, &f.undo) }

field_has_selection :: proc(f: ^Text_Field) -> bool { return f.cursor != f.mark }
field_selection :: proc(f: ^Text_Field) -> string { lo, hi := sel_range(f); return string(f.buf[lo:hi]) }
field_select_all :: proc(f: ^Text_Field) { f.mark, f.cursor = 0, len(f.buf) }

// Edit commands for menus (they go through the edit history; the clipboard is the one given to begin_build).
field_copy :: proc(f: ^Text_Field) -> bool {
	if !field_has_selection(f) || g == nil || g.clipboard_set == nil { return false }
	g.clipboard_set(field_selection(f))
	return true
}

field_cut :: proc(f: ^Text_Field) -> bool {
	if !field_copy(f) { return false }
	field_checkpoint(f, .Other)
	delete_selection(f)
	return true
}

field_delete :: proc(f: ^Text_Field) -> bool {
	if !field_has_selection(f) { return false }
	field_checkpoint(f, .Other)
	delete_selection(f)
	return true
}

// Inserts text over the selection (line breaks become spaces: the field is one line).
field_insert :: proc(f: ^Text_Field, text: string) {
	clean, _ := strings.replace_all(text, "\r\n", " ", context.temp_allocator)
	clean, _ = strings.replace_all(clean, "\n", " ", context.temp_allocator)
	clean, _ = strings.replace_all(clean, "\r", " ", context.temp_allocator)
	field_checkpoint(f, .Other)
	insert_text(f, clean)
}

field_paste :: proc(f: ^Text_Field) -> bool {
	if g == nil || g.clipboard_get == nil { return false }
	clip := g.clipboard_get()
	if clip == "" { return false }
	field_insert(f, clip)
	return true
}

Edit_Result :: struct {
	using signal: Signal,
	changed:   bool,   // text was modified this frame
	committed: bool,   // Enter pressed while focused
	cancelled: bool,   // Escape pressed while focused
	caret:     Rect,   // text_edit: the caret, in the box's coordinates (from this build's layout)
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

// The caret position before / after the grapheme cluster at `i` (an emoji sequence, a flag, a letter with its marks
// are one): arrows, Backspace and Delete move and remove whole clusters.
@(private)
prev_index :: proc(s: string, i: int) -> int { return font.grapheme_prev(s, i) }

@(private)
next_index :: proc(s: string, i: int) -> int { return font.grapheme_next(s, i) }

// The same by code point (word movement does not need clusters).
@(private)
prev_rune_index :: proc(s: string, i: int) -> int {
	i := i
	if i <= 0 { return 0 }
	i -= 1
	for i > 0 && (s[i] & 0xC0) == 0x80 { i -= 1 }
	return i
}

@(private)
is_word_rune :: proc(r: rune) -> bool {
	return r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r > 127
}

@(private)
word_left :: proc(s: string, i: int) -> int {
	i := i
	for i > 0 {
		j := prev_rune_index(s, i)
		r, _ := utf8.decode_rune_in_string(s[j:])
		if is_word_rune(r) { break }
		i = j
	}
	for i > 0 {
		j := prev_rune_index(s, i)
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
		for sp in font.x_spans_of_range(s.fonts, b.font, b.font_size, d.text, lo, hi) {   // (several in bidirectional text)
			draw.rect(dc, {{x0 + sp[0], cy - m.line_height * 0.5}, {x0 + sp[1], cy + m.line_height * 0.5}}, d.selection)
		}
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
			for r in s.typed {
				field_checkpoint(f, .Typing)
				insert_text(f, utf8.runes_to_string({r}, context.temp_allocator))
			}
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
			deleting :: proc(f: ^Text_Field) -> bool {
				can := f.cursor != f.mark || len(f.buf) > 0
				if can { field_checkpoint(f, .Deleting) }
				return can
			}
			if key_press(.Backspace) && deleting(f) { if !delete_selection(f) { lo := prev_index(field_string(f), f.cursor); remove_range(&f.buf, lo, f.cursor); f.cursor, f.mark = lo, lo } }
			if key_press(.Delete) && deleting(f)    { if !delete_selection(f) { hi := next_index(field_string(f), f.cursor); remove_range(&f.buf, f.cursor, hi) } }
			if key_press(.Backspace, ctrl) && deleting(f) { if !delete_selection(f) { lo := word_left(field_string(f), f.cursor); remove_range(&f.buf, lo, f.cursor); f.cursor, f.mark = lo, lo } }
			if key_press(.Delete, ctrl) && deleting(f)    { if !delete_selection(f) { hi := word_right(field_string(f), f.cursor); remove_range(&f.buf, f.cursor, hi) } }
			if key_press(.A, ctrl) { field_select_all(f) }
			if key_press(.C, ctrl) || key_press(.Insert, ctrl) { field_copy(f) }
			if key_press(.X, ctrl) || key_press(.Delete, shift) { field_cut(f) }
			if key_press(.V, ctrl) || key_press(.Insert, shift) { field_paste(f) }
			if key_press(.Z, ctrl) { field_undo(f) }
			if key_press(.Y, ctrl) || key_press(.Z, cs) { field_redo(f) }
			if key_press(.Return) { res.committed = true }
			if key_press(.Escape) { res.cancelled = true; s.focus_key = 0 }
			f.cursor = clamp(f.cursor, 0, len(f.buf))
			f.mark = clamp(f.mark, 0, len(f.buf))
			wake_within(s, 265)   // caret blink
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
