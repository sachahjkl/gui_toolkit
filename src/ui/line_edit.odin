package ui

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "../draw"
import "../font"
import lucide "../lucide"
import "../platform"

// Single-line text field state. The caller owns it (like any other value); the widget edits it in place.
Text_Field :: struct {
	buf:       [dynamic]u8,
	cursor:    int,           // byte index of the caret
	mark:      int,           // other end of the selection (== cursor when nothing is selected)
	scroll_x:  f32,           // horizontal scroll in pixels, keeps the caret visible
	edited_ms: f64,           // time of the last edit/move (caret stays solid right after)
	undo, redo: [dynamic]Edit_Snapshot,   // edit history (Ctrl+Z / Ctrl+Y, field_undo / field_redo)
	last_edit:  Field_Edit,   // what the last recorded edit was: consecutive typing is one undo step
	last_edit_ms: f64,
	word:       Word_Drag,    // the word a double click took, while its button is held
}

// A double click takes a word; until the button goes up the selection goes on by words from it, and a frame made
// meanwhile leaves it alone. `on` ends at the next press.
@(private)
Word_Drag :: struct {
	on:     bool,
	lo, hi: int,   // the word
}

@(private)
word_drag_at :: proc(text: string, at: int) -> Word_Drag {
	lo := word_left(text, min(at + 1, len(text)))
	return {on = true, lo = lo, hi = word_right(text, lo)}
}

// The selection with the pointer on byte `at`: the word held, up to the word under the pointer.
@(private)
word_drag_to :: proc(w: Word_Drag, text: string, at: int) -> (mark, cursor: int) {
	if at < w.lo { return w.hi, word_drag_at(text, at).lo }
	if at > w.hi { return w.lo, word_drag_at(text, at).hi }
	return w.lo, w.hi
}

Field_Snapshot :: Edit_Snapshot

Field_Edit :: enum u8 { None, Typing, Deleting, Other }

// Steps kept by the edit history of a field; typing within this many ms of the previous key is the same step.
FIELD_UNDO_STEPS :: 100
FIELD_UNDO_MERGE_MS :: 1000.0

// The caret of fields: solid this long after an edit, then on and off, a wake at each flip and none between. Its width is the
// font size over CARET_WIDTH_DIVISOR.
@(private) CARET_SOLID_MS :: 500
@(private) CARET_BLINK_MS :: 530
@(private) CARET_WIDTH_DIVISOR :: 12

// Asks for the wake of the caret's next flip, `since` ms after its last edit (none in a window in the back). A wake at every half
// phase drew each picture of the caret twice: 3.8 frames a second for 1.9 flips.
@(private)
caret_wake :: proc(s: ^State, since: f64) {
	if s.inactive { return }
	wake_within(s, CARET_BLINK_MS - int(since) % CARET_BLINK_MS + WAKE_MARGIN_MS)
}

// A field's text area is at least this wide (and tall), whatever its box.
@(private) TEXT_VIEW_MIN_PX :: 8

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
	edit_history_forget(&f.undo, &f.redo)
	f.last_edit = .None
}

// Records the state before an edit of kind `kind` (typing and deleting merge with the previous step of the same kind).
@(private)
field_checkpoint :: proc(f: ^Text_Field, kind: Field_Edit) {
	now := build_now_ms()
	merge := kind != .Other && kind == f.last_edit && now - f.last_edit_ms < FIELD_UNDO_MERGE_MS && len(f.undo) > 0
	f.last_edit, f.last_edit_ms = kind, now
	edit_history_record(&f.undo, &f.redo, f.buf[:], f.cursor, f.mark, FIELD_UNDO_STEPS, merge)
}

@(private)
field_restore :: proc(f: ^Text_Field, from, to: ^[dynamic]Edit_Snapshot) -> bool {
	if !edit_history_step(from, to, &f.buf, &f.cursor, &f.mark) { return false }
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

// Edit commands for menus (they go through the edit history; the clipboard is the one given to begin_build). A paste asks
// the clipboard for the field `owner` (field_paste): the text comes in a later build.
field_copy :: proc(f: ^Text_Field) -> bool {
	if !field_has_selection(f) || current == nil || current.clipboard_set == nil { return false }
	gs().clipboard_set(field_selection(f))
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

// Asks the clipboard's text for the field whose widget is `owner` (line_edit's box: its result's box.key). line_edit
// inserts it over its selection when it comes, if it still has the focus; a field the keyboard reaches another way
// takes it with field_paste_answer. False: there is no clipboard to ask.
field_paste :: proc(owner: Key) -> bool { return paste_request(owner) }

// Inserts the text a field_paste of `owner` asked for, in the build it came (one undo step). True: it was inserted.
field_paste_answer :: proc(f: ^Text_Field, owner: Key) -> bool {
	text, ok := paste_answer(owner)
	if !ok { return false }
	field_insert(f, text)
	return true
}

Edit_Result :: struct {
	using signal: Signal,
	changed:   bool,   // text was modified this frame
	committed: bool,   // Enter pressed while focused
	cancelled: bool,   // Escape pressed while focused
	caret:     Rect,   // text_edit: the caret, in the box's coordinates (from this build's layout)
	hover_line: int,   // text_edit: the paragraph under the pointer (for a per-line tooltip), or -1
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
	end:         f32,   // room kept at the right end (the reveal button): the text is cut before it
}

// The reveal button of a secret field (line_edit's `reveal`), in font sizes: its width.
REVEAL_EM :: 1.9

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
	s := gs()
	m := font.metrics(s.fonts, b.font, b.font_size)
	cy := (b.rect.min.y + b.rect.max.y) * 0.5
	baseline := math.round(cy + (m.ascent - m.descent) * 0.5)
	x0 := b.rect.min.x + d.pad - d.scroll_x
	if d.end > 0 { draw.push_clip(dc, {b.rect.min, {b.rect.max.x - d.end, b.rect.max.y}}) }
	defer if d.end > 0 { draw.pop_clip(dc) }
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
		draw.rect(dc, {{cx, cy - m.line_height * 0.5}, {cx + max(1, math.round(b.font_size / CARET_WIDTH_DIVISOR)), cy + m.line_height * 0.5}}, d.caret)
	}
}

// What a key does to a field, as every field of the toolkit does it: Left, Right, Home, End move the caret (Ctrl: by words;
// Shift: the selection with it); Backspace and Delete take a letter (Ctrl: a word) or the selection; Ctrl+A selects all;
// Ctrl+C, X, V copy, cut and paste (Ctrl+Insert, Shift+Delete, Shift+Insert too); Ctrl+Z undoes, Ctrl+Y and Ctrl+Shift+Z
// redo. True when the key is one of those (applied to `f`, whether it changed it or not): the caller takes it. Return,
// Escape and typed text are the caller's. `owner`: the key a paste is asked for (field_paste; its text comes in a later
// build, field_paste_answer). `masked`: a secret, neither copied nor cut. line_edit reads its keys with it; a field the
// keyboard reaches another way (a menu's search) gives it its own.
field_key :: proc(f: ^Text_Field, owner: Key, key: platform.Key, mods: platform.Modifiers, masked := false) -> bool {
	ctrl, shift, cs := platform.Modifiers{.Ctrl}, platform.Modifiers{.Shift}, platform.Modifiers{.Ctrl, .Shift}
	move :: proc(f: ^Text_Field, to: int, extend: bool) {
		f.cursor = to
		if !extend { f.mark = to }
	}
	deleting :: proc(f: ^Text_Field, back: bool) -> bool {
		can := f.cursor != f.mark || (back ? f.cursor > 0 : f.cursor < len(f.buf))
		if can { field_checkpoint(f, .Deleting) }
		return can
	}
	text := field_string(f)
	lo, hi := sel_range(f)
	#partial switch key {
	case .Left, .Right, .Home, .End:
		ext := mods == shift || mods == cs
		if mods == {} || mods == shift {
			#partial switch key {
			case .Left:  move(f, (lo != hi && !ext) ? lo : prev_index(text, f.cursor), ext)
			case .Right: move(f, (lo != hi && !ext) ? hi : next_index(text, f.cursor), ext)
			case .Home:  move(f, 0, ext)
			case .End:   move(f, len(f.buf), ext)
			}
		} else if (mods == ctrl || mods == cs) && (key == .Left || key == .Right) {
			move(f, key == .Left ? word_left(text, f.cursor) : word_right(text, f.cursor), ext)
		} else {
			return false
		}
	case .Backspace:
		switch mods {
		case {}:   if deleting(f, true) && !delete_selection(f) { at := prev_index(text, f.cursor); remove_range(&f.buf, at, f.cursor); f.cursor, f.mark = at, at }
		case ctrl: if deleting(f, true) && !delete_selection(f) { at := word_left(text, f.cursor); remove_range(&f.buf, at, f.cursor); f.cursor, f.mark = at, at }
		case: return false
		}
	case .Delete:
		switch mods {
		case {}:    if deleting(f, false) && !delete_selection(f) { remove_range(&f.buf, f.cursor, next_index(text, f.cursor)) }
		case ctrl:  if deleting(f, false) && !delete_selection(f) { remove_range(&f.buf, f.cursor, word_right(text, f.cursor)) }
		case shift: if masked { return false }; field_cut(f)
		case: return false
		}
	case .A:
		if mods != ctrl { return false }
		field_select_all(f)
	case .C, .X:
		if mods != ctrl || masked { return false }
		if key == .C { field_copy(f) } else { field_cut(f) }
	case .Insert:
		switch mods {
		case ctrl:  if masked { return false }; field_copy(f)
		case shift: field_paste(owner)
		case: return false
		}
	case .V:
		if mods != ctrl { return false }
		field_paste(owner)
	case .Z:
		switch mods {
		case ctrl: field_undo(f)
		case cs:   field_redo(f)
		case: return false
		}
	case .Y:
		if mods != ctrl { return false }
		field_redo(f)
	case:
		return false
	}
	f.cursor = clamp(f.cursor, 0, len(f.buf))
	f.mark = clamp(f.mark, 0, len(f.buf))
	return true
}

// Single-line editor. Tags used: "input" (+ whatever the caller pushed, e.g. "bad" for an invalid value).
// Supports: typing, selection (shift, mouse drag, double-click word), Home/End, ctrl+arrows (words),
// Backspace/Delete (ctrl = word), ctrl+A/C/X/V, Enter (committed), Escape (cancelled, drops focus).
// `secret`: a password: bullets are shown in place of the characters, and it is neither copied nor cut. With `reveal`, a button
// at its end (an eye) shows it as text and hides it again; `reveal^` says which, and is the caller's to keep.
// A right press on it opens its menu (field_menu: Undo, Cut, Copy, Paste...); `menu` false: the program has its own.
// `clearable`: while it holds text, a cross at its end empties it (a search's field; Undo brings the text back).
line_edit :: proc(id: string, f: ^Text_Field, placeholder := "", secret := false, reveal: ^bool = nil, menu := true, clearable := false) -> (res: Edit_Result) {
	s := gs()
	revealable := secret && reveal != nil
	clears := clearable && !revealable && len(f.buf) > 0
	// (revealed, it is text: shown, copied, its words selected; the person chose to see it)
	masked := secret && !(revealable && reveal^)
	if tags("input") {
		b := build_box({.Clickable, .Focusable, .Text_Input, .Clip, .Draw_Background, .Draw_Border, .Draw_Focus_Ring, .Sunken}, id)
		b.cursor = .Text
		b.text = ""
		res.signal = signal(b)
		now := s.time_ms
		focused := res.focused
		before := len(f.buf)
		before_hash := hash_bytes(f.buf[:])
		c0, m0 := f.cursor, f.mark
		pad := b.text_pad
		end: f32 = revealable || clears ? math.round(b.font_size * REVEAL_EM) : 0

		// a screen reader sets the text, types over the selection, or moves the caret
		if r, ok := a11y_request(b.key, .Set_Value); ok && r.data == .Value {
			field_checkpoint(f, .Other)
			field_select_all(f)
			insert_text(f, r.value)
		}
		if r, ok := a11y_request(b.key, .Replace_Selected_Text); ok && r.data == .Value {
			field_checkpoint(f, .Other)
			insert_text(f, r.value)
		}
		if r, ok := a11y_request(b.key, .Set_Text_Selection); ok && r.data == .Text_Selection {
			f.mark = a11y_run_byte(field_string(f), nil, b, r.sel[0], int(r.sel[1]))
			f.cursor = a11y_run_byte(field_string(f), nil, b, r.sel[2], int(r.sel[3]))
			f.edited_ms = now
		}
		text := field_string(f)

		// mouse: click places the caret, drag selects, double-click selects the word
		if res.pointer_pressed || res.dragging {
			x := res.mouse.x - pad + f.scroll_x
			idx := font.index_from_x(s.fonts, b.font, b.font_size, masked ? secret_mask(text) : text, x)
			if masked { idx = secret_unmask_index(text, idx) }
			if res.pointer_pressed { f.word.on = false }
			if f.word.on {
				f.mark, f.cursor = word_drag_to(f.word, text, idx)
			} else {
				f.cursor = idx
				if res.pointer_pressed && .Shift not_in res.mods { f.mark = idx }
			}
			f.edited_ms = now
		}
		if res.double_clicked {
			// (a secret's words are not shown: all of it)
			f.word = masked ? Word_Drag{on = true, hi = len(text)} : word_drag_at(text, f.cursor)
			f.mark, f.cursor = f.word.lo, f.word.hi
		}

		if focused {
			// (a paste asked in an earlier build: before what was typed since)
			field_paste_answer(f, b.key)
			for r in s.typed {
				field_checkpoint(f, .Typing)
				insert_text(f, utf8.runes_to_string({r}, context.temp_allocator))
			}
			// (the keys in the order they came; a dialog open over the field holds them)
			if !keys_held_by_dialog(s) {
				for e, i in s.events.list {
					if !s.events.consumed[i] && field_key(f, b.key, e.key, e.mods, masked) { s.events.consumed[i] = true }
				}
			}
			if key_press(.Return) { res.committed = true }
			if key_press(.Escape) { res.cancelled = true; s.focus_key = 0 }
			f.cursor = clamp(f.cursor, 0, len(f.buf))
			f.mark = clamp(f.mark, 0, len(f.buf))
		}
		after_hash := hash_bytes(f.buf[:])
		res.changed = before != len(f.buf) || before_hash != after_hash
		moved := f.cursor != c0 || f.mark != m0
		if res.changed || moved { f.edited_ms = now }
		if moved && !res.changed { f.last_edit = .None }   // (what is typed after a move of the caret is another step)
		if focused { caret_wake(s, now - f.edited_ms) }
		text = field_string(f)
		// what is shown, and where the caret and the selection's end are in it
		shown, cursor, mark := text, f.cursor, f.mark
		if masked { shown, cursor, mark = secret_mask(text), secret_index(text, f.cursor), secret_index(text, f.mark) }

		// keep the caret visible
		inner := max(TEXT_VIEW_MIN_PX * s.scale, (b.rect.max.x - b.rect.min.x) - 2 * pad - end)
		cx := font.x_from_index(s.fonts, b.font, b.font_size, shown, cursor)
		total := font.text_width(s.fonts, b.font, b.font_size, shown)
		if cx - f.scroll_x > inner { f.scroll_x = cx - inner }
		if cx - f.scroll_x < 0 { f.scroll_x = cx }
		f.scroll_x = clamp(f.scroll_x, 0, max(0, total - inner + 2 * s.scale))

		d := frame_new(Line_Edit_Draw)
		d.text = strings.clone(shown, frame_allocator())
		d.placeholder = placeholder
		d.cursor, d.mark, d.scroll_x = cursor, mark, f.scroll_x
		d.focused = focused
		since := now - f.edited_ms
		d.caret_on = !s.inactive && (since < CARET_SOLID_MS || (int(since) / CARET_BLINK_MS) % 2 == 0)
		d.selection = color("selection")
		d.caret = color("cursor")
		if tags("weak") { d.weak = color("text") }
		d.pad, d.end = pad, end
		b.custom = line_edit_draw
		b.custom_user = d
		if s.a11y.wanted {
			lh := font.metrics(s.fonts, b.font, b.font_size).line_height
			t := frame_new(A11y_Text)
			t^ = {text = d.text, cursor = cursor, mark = mark, font = b.font, size = b.font_size, line_height = lh,
				origin = {b.rect.min.x + pad, (b.rect.min.y + b.rect.max.y - lh) * 0.5}, scroll = {f.scroll_x, 0}, password = masked}
			a11y_default(b, {role = .Text_Input, placeholder = placeholder, text = t})
		} else {
			a11y_default(b, {role = .Text_Input, placeholder = placeholder})
		}
		if revealable { reveal_button(b, reveal, end) }
		if clears && clear_button(b, f, end) { res.changed = true }
		if menu {
			key := key_from_string(b.key, "field_menu")
			if s.pressed_any[.Right] && s.pressed_key[.Right] == b.key && !ctx_menu_any_open() {
				s.focus_key = b.key
				ctx_menu_open(key, s.mouse)
			}
			field_menu(key, f, b.key, masked)
		}
	}
	return
}

// The menu of a text field, `key` its menu (ctx_menu_open opens it): the edits of field_undo, field_cut, field_copy,
// field_paste, field_delete and field_select_all, each with its keys and its icon (Lucide's: lucide_icons). `owner`: the
// field's widget, which a paste's text comes to (field_paste). A secret is neither copied nor cut.
field_menu :: proc(key: Key, f: ^Text_Field, owner: Key, secret := false) {
	if ctx_menu(key) {
		ico := lucide_icons()
		sel := field_has_selection(f)
		if menu_item("Undo", "Ctrl+Z", icon = lucide.UNDO_2, icon_font = ico, enabled = field_can_undo(f)).clicked { field_undo(f) }
		if menu_item("Redo", "Ctrl+Y", icon = lucide.REDO_2, icon_font = ico, enabled = field_can_redo(f)).clicked { field_redo(f) }
		menu_separator()
		if menu_item("Cut", "Ctrl+X", icon = lucide.SCISSORS, icon_font = ico, enabled = sel && !secret).clicked { field_cut(f) }
		if menu_item("Copy", "Ctrl+C", icon = lucide.COPY, icon_font = ico, enabled = sel && !secret).clicked { field_copy(f) }
		if menu_item("Paste", "Ctrl+V", icon = lucide.CLIPBOARD_PASTE, icon_font = ico).clicked { field_paste(owner) }
		if menu_item("Delete", "Del", icon = lucide.TRASH_2, icon_font = ico, enabled = sel).clicked { field_delete(f) }
		menu_separator()
		if menu_item("Select all", "Ctrl+A", icon = lucide.TEXT_CURSOR_INPUT, icon_font = ico, enabled = len(f.buf) > 0).clicked { field_select_all(f) }
	}
}

// The eye at the end of a secret field: the field's child, over its right end (the text stops before it).
@(private)
reveal_button :: proc(field: ^Box, reveal: ^bool, w: f32) {
	field.layout_axis = .X
	push_parent(field)
	defer pop_parent()
	spacer(fill())
	shown := reveal^
	if !shown { push_tags("weak") }
	next({width = px(w), height = pct(1), font = lucide_icons(), text_align = .Center, text_pad = 0})
	eye := build_box({.Clickable, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###reveal", shown ? lucide.EYE_OFF : lucide.EYE))
	if !shown { pop_tags() }
	eye.cursor = .Hand
	a11y_default(eye, {role = .Button, name = shown ? "Hide the password" : "Show the password"})
	// (the field keeps the keyboard: one looks at what was typed, then goes on typing)
	if signal(eye).clicked { reveal^ = !shown; gs().focus_key = field.key }
}

// The cross at the end of a clearable field: its child, over its right end. True: it emptied the field.
@(private)
clear_button :: proc(field: ^Box, f: ^Text_Field, w: f32) -> bool {
	field.layout_axis = .X
	push_parent(field)
	defer pop_parent()
	spacer(fill())
	next({width = px(w), height = pct(1), font = lucide_icons(), text_align = .Center, text_pad = 0})
	push_tags("weak")
	x := build_box({.Clickable, .Draw_Text, .No_Text_Trunc, .Draw_Hot_Effects}, fmt.tprintf("%s###clear", lucide.X))
	pop_tags()
	x.cursor = .Hand
	a11y_default(x, {role = .Button, name = "Clear"})
	if !signal(x).clicked { return false }
	// (through the edit history: Undo brings it back; the field keeps the keyboard, to type the next search)
	field_select_all(f)
	field_delete(f)
	gs().focus_key = field.key
	return true
}

SECRET_BULLET :: "•"

// A secret field's text as shown: a bullet per character.
@(private)
secret_mask :: proc(text: string) -> string {
	return strings.repeat(SECRET_BULLET, utf8.rune_count_in_string(text), context.temp_allocator)
}

// The byte index in the shown bullets of byte index `i` of the text, and back.
@(private)
secret_index :: proc(text: string, i: int) -> int {
	return utf8.rune_count_in_string(text[:clamp(i, 0, len(text))]) * len(SECRET_BULLET)
}

@(private)
secret_unmask_index :: proc(text: string, shown_i: int) -> int {
	n := shown_i / len(SECRET_BULLET)
	k := 0
	for _, i in text {
		if k == n { return i }
		k += 1
	}
	return len(text)
}

@(private)
hash_bytes :: proc(b: []u8) -> u64 {
	h: u64 = FNV64_OFFSET_BASIS
	fnv64_mix(&h, b)
	return h
}
