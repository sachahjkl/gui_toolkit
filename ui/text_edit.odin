package ui

// Multi-line text editor. The caller owns the `Text_Area` (text, caret, scroll, undo history) like any other value.
//
// Keys when focused:
//   typing, Enter (new line), Backspace / Delete (Ctrl = word), arrows (Ctrl = word), Up / Down keep the column,
//   Home / End (line), Ctrl+Home / Ctrl+End (document), Page Up / Page Down, Shift + any move selects,
//   Ctrl+A / C / X / V, Ctrl+Z undo, Ctrl+Y or Ctrl+Shift+Z redo, Ctrl+Enter = committed, Escape = leave the field.
//   Tab moves the focus to the next widget, unless `tab_indents` (then Tab inserts 4 spaces, Ctrl+Tab... leaves).
// Mouse: click places the caret, drag selects, Shift+click extends, double-click selects a word, wheel scrolls.

import "core:hash"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "../draw"
import "../font"
import "../platform"

@(private="file") Mods :: platform.Modifiers

TEXT_UNDO_MAX :: 200

Text_Area :: struct {
	buf:        [dynamic]u8,
	cursor:     int,       // byte index of the caret
	mark:       int,       // other end of the selection
	scroll:     [2]f32,    // pixels
	pref_x:     f32,       // column kept by Up / Down (valid when has_pref)
	has_pref:   bool,
	edited_ms:  f64,
	undo, redo: [dynamic]Text_Snapshot,
	group:      Edit_Kind, // consecutive edits of one kind within a second form one undo step
	group_ms:   f64,
	sb_drag:    u8,        // 0 none, 1 vertical scrollbar held, 2 horizontal
	sb_grab:    f32,
	ext_key:    u64,       // content size cache (measuring every line each frame is the editor's main cost)
	ext:        Vec2,
}

// Scrollbar geometry of the editor (screen space). The bars overlay the text at the right / bottom edges.
@(private="file")
Editor_Bars :: struct {
	vtrack, vthumb, htrack, hthumb: Rect,
	has_v, has_h: bool,
}

@(private="file")
editor_bars :: proc(r: Rect, gutter, pad, font_size: f32, content: Vec2, scroll: Vec2) -> (e: Editor_Bars) {
	view := Vec2{(r.max.x - r.min.x) - gutter - 2 * pad, (r.max.y - r.min.y) - 2 * pad}
	e.has_v = content.y > view.y + 0.5
	e.has_h = content.x + 4 > view.x + 0.5
	w := max(6, math.round(font_size * 0.5))
	m := math.round(w * 0.35)
	if e.has_v {
		e.vtrack = {{r.max.x - w - m, r.min.y + m}, {r.max.x - m, r.max.y - m - (e.has_h ? w + m : 0)}}
		len_ := e.vtrack.max.y - e.vtrack.min.y
		th := max(font_size * 1.6, len_ * view.y / content.y)
		t := clamp(scroll.y / max(1, content.y - view.y), 0, 1)
		y := e.vtrack.min.y + t * (len_ - th)
		e.vthumb = {{e.vtrack.min.x, y}, {e.vtrack.max.x, y + th}}
	}
	if e.has_h {
		e.htrack = {{r.min.x + gutter + m, r.max.y - w - m}, {r.max.x - m - (e.has_v ? w + m : 0), r.max.y - m}}
		len_ := e.htrack.max.x - e.htrack.min.x
		tw := max(font_size * 1.6, len_ * view.x / (content.x + 4))
		t := clamp(scroll.x / max(1, content.x + 4 - view.x), 0, 1)
		x := e.htrack.min.x + t * (len_ - tw)
		e.hthumb = {{x, e.htrack.min.y}, {x + tw, e.htrack.max.y}}
	}
	return
}

@(private="file")
content_extent :: proc(a: ^Text_Area, text: string, b: ^Box, lh: f32) -> Vec2 {
	key := hash.fnv64a(transmute([]u8)text) ~ (u64(transmute(u32)b.font_size) << 20) ~ u64(b.font) ~ u64(transmute(u32)lh)
	if key != a.ext_key || key == 0 {
		a.ext = content_extent_measure(text, b, lh)
		a.ext_key = key
	}
	return a.ext
}

@(private="file")
content_extent_measure :: proc(text: string, b: ^Box, lh: f32) -> Vec2 {
	w: f32
	lines := 0
	start := 0
	for {
		nl := strings.index_byte(text[start:], '\n')
		end := nl < 0 ? len(text) : start + nl
		w = max(w, font.text_width(g.fonts, b.font, b.font_size, text[start:end]))
		lines += 1
		if nl < 0 { break }
		start = end + 1
	}
	return {w, f32(lines) * lh}
}

Text_Snapshot :: struct {
	text:           string,   // heap copy
	cursor, mark:   int,
}

Edit_Kind :: enum u8 { None, Insert, Delete, Other }

area_string :: proc(a: ^Text_Area) -> string { return string(a.buf[:]) }

area_set :: proc(a: ^Text_Area, text: string) {
	clear(&a.buf)
	append(&a.buf, text)
	a.cursor, a.mark, a.scroll, a.has_pref = len(a.buf), len(a.buf), {}, false
	area_clear_history(a)
}

area_clear_history :: proc(a: ^Text_Area) {
	for s in a.undo { delete(s.text) }
	for s in a.redo { delete(s.text) }
	clear(&a.undo); clear(&a.redo)
	a.group = .None
}

area_destroy :: proc(a: ^Text_Area) {
	area_clear_history(a)
	delete(a.undo); delete(a.redo); delete(a.buf)
}

area_line_count :: proc(a: ^Text_Area) -> int { return strings.count(area_string(a), "\n") + 1 }

////////////////////////////////
// editing primitives

@(private="file")
snapshot :: proc(a: ^Text_Area) -> Text_Snapshot {
	return {text = strings.clone(area_string(a)), cursor = a.cursor, mark = a.mark}
}

@(private="file")
restore :: proc(a: ^Text_Area, s: Text_Snapshot) {
	clear(&a.buf)
	append(&a.buf, s.text)
	a.cursor, a.mark = clamp(s.cursor, 0, len(a.buf)), clamp(s.mark, 0, len(a.buf))
	delete(s.text)
}

// Records an undo step before an edit (grouping same-kind edits made within a second of each other).
@(private="file")
begin_edit :: proc(a: ^Text_Area, kind: Edit_Kind, now: f64) {
	if kind != a.group || kind == .Other || now - a.group_ms > 1000 {
		if len(a.undo) >= TEXT_UNDO_MAX { delete(a.undo[0].text); ordered_remove(&a.undo, 0) }
		append(&a.undo, snapshot(a))
	}
	for s in a.redo { delete(s.text) }
	clear(&a.redo)
	a.group, a.group_ms = kind, now
}

area_undo :: proc(a: ^Text_Area) -> bool {
	if len(a.undo) == 0 { return false }
	append(&a.redo, snapshot(a))
	restore(a, pop(&a.undo))
	a.group = .None
	return true
}

area_redo :: proc(a: ^Text_Area) -> bool {
	if len(a.redo) == 0 { return false }
	append(&a.undo, snapshot(a))
	restore(a, pop(&a.redo))
	a.group = .None
	return true
}

@(private="file")
sel :: proc(a: ^Text_Area) -> (lo, hi: int) { return min(a.cursor, a.mark), max(a.cursor, a.mark) }

@(private="file")
delete_range :: proc(a: ^Text_Area, lo, hi: int) {
	if hi <= lo { return }
	remove_range(&a.buf, lo, hi)
	a.cursor, a.mark = lo, lo
}

@(private="file")
insert :: proc(a: ^Text_Area, text: string) {
	lo, hi := sel(a)
	delete_range(a, lo, hi)
	inject_at_elems(&a.buf, a.cursor, ..transmute([]u8)text)
	a.cursor += len(text)
	a.mark = a.cursor
}

@(private="file")
line_bounds :: proc(s: string, idx: int) -> (start, end: int) {
	start = strings.last_index_byte(s[:idx], '\n') + 1
	e := strings.index_byte(s[idx:], '\n')
	end = e < 0 ? len(s) : idx + e
	return
}

@(private="file")
line_of :: proc(s: string, idx: int) -> int { return strings.count(s[:idx], "\n") }

////////////////////////////////
// widget

Text_Edit_Draw :: struct {
	text:        string,
	placeholder: string,
	cursor, mark: int,
	scroll:      [2]f32,
	focused:     bool,
	caret_on:    bool,
	gutter:      f32,
	pad:         f32,
	line_h:      f32,
	selection, caret, weak, gutter_bg, gutter_line: Color,
	mono:        font.Font_Id,
	bars:        Editor_Bars,
	bar_color:   Color,
	bar_hot:     u8,        // 1 vertical, 2 horizontal: hovered or held
}

@(private="file")
text_edit_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Text_Edit_Draw)(user)
	s := g
	r := b.rect
	m := font.metrics(s.fonts, b.font, b.font_size)
	lh := d.line_h
	text_x0 := r.min.x + d.gutter + d.pad - d.scroll.x
	top := r.min.y + d.pad - d.scroll.y
	baseline_off := math.round((lh + m.ascent - m.descent) * 0.5)

	if d.gutter > 0 {
		draw.rect(dc, {r.min, {r.min.x + d.gutter, r.max.y}}, d.gutter_bg)
		draw.rect(dc, {{r.min.x + d.gutter - 1, r.min.y}, {r.min.x + d.gutter, r.max.y}}, d.gutter_line)
	}
	if d.text == "" && !d.focused {
		draw.text(dc, b.font, b.font_size, {math.round(r.min.x + d.gutter + d.pad), math.round(top + baseline_off)}, d.weak, d.placeholder)
	}

	lo, hi := min(d.cursor, d.mark), max(d.cursor, d.mark)
	first := max(0, int(d.scroll.y / lh) - 1)
	last := int((d.scroll.y + (r.max.y - r.min.y)) / lh) + 1
	draw.push_clip(dc, {{r.min.x + d.gutter, r.min.y}, r.max})
	line_start := 0
	for line := 0; line_start <= len(d.text); line += 1 {
		nl := strings.index_byte(d.text[line_start:], '\n')
		line_end := nl < 0 ? len(d.text) : line_start + nl
		if line >= first && line <= last {
			y := top + f32(line) * lh
			line_text := d.text[line_start:line_end]
			// selection
			if d.focused && lo != hi && lo <= line_end && hi >= line_start {
				a := max(lo, line_start) - line_start
				z := min(hi, line_end) - line_start
				xa := text_x0 + font.x_from_index(s.fonts, b.font, b.font_size, line_text, a)
				xb := text_x0 + font.x_from_index(s.fonts, b.font, b.font_size, line_text, z)
				if hi > line_end { xb += b.font_size * 0.35 }   // the line break itself is selected
				draw.rect(dc, {{xa, y}, {xb, y + lh}}, d.selection)
			}
			draw.text(dc, b.font, b.font_size, {math.round(text_x0), math.round(y + baseline_off)}, b.text_color, line_text)
			// caret
			if d.focused && d.caret_on && d.cursor >= line_start && d.cursor <= line_end {
				cx := math.round(text_x0 + font.x_from_index(s.fonts, b.font, b.font_size, line_text, d.cursor - line_start))
				draw.rect(dc, {{cx, y}, {cx + max(1, math.round(b.font_size / 12)), y + lh}}, d.caret)
			}
		}
		if nl < 0 || line > last { break }
		line_start = line_end + 1
	}
	draw.pop_clip(dc)

	// scrollbars
	for which in 1 ..= 2 {
		has := which == 1 ? d.bars.has_v : d.bars.has_h
		if !has { continue }
		track := which == 1 ? d.bars.vtrack : d.bars.htrack
		thumb := which == 1 ? d.bars.vthumb : d.bars.hthumb
		w := which == 1 ? track.max.x - track.min.x : track.max.y - track.min.y
		c := d.bar_color
		hot := d.bar_hot == u8(which)
		if hot { tc := c; tc.a = 0.06; draw.rect(dc, track, tc, w * 0.5 * s.rounding) }
		c.a = hot ? 0.45 : 0.22
		draw.rect(dc, thumb, c, w * 0.5 * s.rounding)
	}

	// line numbers (not scrolled horizontally)
	if d.gutter > 0 {
		size := math.round(b.font_size * 0.85)
		mm := font.metrics(s.fonts, d.mono, size)
		count := strings.count(d.text, "\n") + 1
		cur_line := strings.count(d.text[:d.cursor], "\n")
		for line in first ..= min(last, count - 1) {
			label := fmt_int(line + 1)
			w := font.text_width(s.fonts, d.mono, size, label)
			y := top + f32(line) * lh
			col := line == cur_line && d.focused ? b.text_color : d.weak
			draw.text(dc, d.mono, size, {math.round(r.min.x + d.gutter - d.pad * 0.8 - w), math.round(y + (lh + mm.ascent - mm.descent) * 0.5)}, col, label)
		}
	}
}

@(private="file")
fmt_int :: proc(v: int) -> string {
	buf := make([]u8, 12, frame_allocator())
	n := v
	i := len(buf)
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 { break }
	}
	return string(buf[i:])
}

// Multi-line editor. Size comes from the style stack or `next` (it does not grow with its content: it scrolls).
text_edit :: proc(id: string, a: ^Text_Area, placeholder := "", line_numbers := false, tab_indents := false) -> (res: Edit_Result) {
	s := g
	if tags("input") {
		b := build_box({.Clickable, .Focusable, .Text_Input, .Scroll_Self, .Clip, .Draw_Background, .Draw_Border, .Draw_Focus_Ring}, id)
		b.cursor = .Text
		b.text = ""
		res.signal = signal(b)
		now := s.time_ms
		pad := b.text_pad
		mono := s.mono_font != 0 ? s.mono_font : b.font
		m := font.metrics(s.fonts, b.font, b.font_size)
		lh := math.round(m.line_height * 1.15)
		gutter: f32 = 0
		if line_numbers {
			digits := len(fmt_int(area_line_count(a)))
			gutter = math.round(font.text_width(s.fonts, mono, math.round(b.font_size * 0.85), "0") * f32(max(digits, 2)) + pad * 1.8)
		}
		before_hash := hash_bytes(a.buf[:])
		c0, m0 := a.cursor, a.mark
		moved := false
		ctrl := Mods{.Ctrl}
		shift := Mods{.Shift}
		cs := Mods{.Ctrl, .Shift}
		text := area_string(a)

		// mouse
		point_to_index :: proc(a: ^Text_Area, b: ^Box, p: Vec2, gutter, pad, lh: f32) -> int {
			text := area_string(a)
			line := max(0, int((p.y - pad + a.scroll.y) / lh))
			start := 0
			for _ in 0 ..< line {
				nl := strings.index_byte(text[start:], '\n')
				if nl < 0 { break }
				start += nl + 1
			}
			_, end := line_bounds(text, start)
			return start + font.index_from_x(g.fonts, b.font, b.font_size, text[start:end], p.x - gutter - pad + a.scroll.x)
		}
		// scrollbars: press on a thumb grabs it, press on a track jumps there; while held they own the drag
		bars := editor_bars(b.rect, gutter, pad, b.font_size, content_extent(a, text, b, lh), a.scroll)
		mp := b.rect.min + res.mouse
		if res.pressed {
			a.sb_drag = 0
			vgrab := Rect{{bars.vtrack.min.x - 4, bars.vtrack.min.y}, {bars.vtrack.max.x + 2, bars.vtrack.max.y}}
			hgrab := Rect{{bars.htrack.min.x, bars.htrack.min.y - 4}, {bars.htrack.max.x, bars.htrack.max.y + 2}}
			if bars.has_v && contains(vgrab, mp) {
				a.sb_drag = 1
				a.sb_grab = (mp.y >= bars.vthumb.min.y && mp.y < bars.vthumb.max.y) ? mp.y - bars.vthumb.min.y : (bars.vthumb.max.y - bars.vthumb.min.y) * 0.5
			} else if bars.has_h && contains(hgrab, mp) {
				a.sb_drag = 2
				a.sb_grab = (mp.x >= bars.hthumb.min.x && mp.x < bars.hthumb.max.x) ? mp.x - bars.hthumb.min.x : (bars.hthumb.max.x - bars.hthumb.min.x) * 0.5
			}
		}
		if !res.dragging && !res.pressed { a.sb_drag = 0 }
		if a.sb_drag != 0 && (res.pressed || res.dragging) {
			content := content_extent(a, text, b, lh)
			view := Vec2{(b.rect.max.x - b.rect.min.x) - gutter - 2 * pad, (b.rect.max.y - b.rect.min.y) - 2 * pad}
			if a.sb_drag == 1 {
				span := (bars.vtrack.max.y - bars.vtrack.min.y) - (bars.vthumb.max.y - bars.vthumb.min.y)
				if span > 0 { a.scroll.y = clamp((mp.y - a.sb_grab - bars.vtrack.min.y) / span, 0, 1) * (content.y - view.y) }
			} else {
				span := (bars.htrack.max.x - bars.htrack.min.x) - (bars.hthumb.max.x - bars.hthumb.min.x)
				if span > 0 { a.scroll.x = clamp((mp.x - a.sb_grab - bars.htrack.min.x) / span, 0, 1) * (content.x + 4 - view.x) }
			}
		} else if res.pressed || res.dragging {
			idx := point_to_index(a, b, res.mouse, gutter, pad, lh)
			a.cursor = idx
			if res.pressed && .Shift not_in res.mods { a.mark = idx }
			a.has_pref = false
			moved = true
		}
		if res.double_clicked && a.sb_drag == 0 {
			a.mark = word_left(text, min(a.cursor + 1, len(text)))
			a.cursor = word_right(text, a.mark)
		}
		if res.scrolled != {} {
			a.scroll.y += res.scrolled.y * lh * 3
			a.scroll.x += res.scrolled.x * lh * 3
		}

		if res.focused {
			move :: proc(a: ^Text_Area, to: int, extend: bool) {
				a.cursor = to
				if !extend { a.mark = to }
			}
			vertical :: proc(a: ^Text_Area, b: ^Box, lines: int, extend: bool) {
				text := area_string(a)
				start, _ := line_bounds(text, a.cursor)
				x := a.pref_x
				if !a.has_pref { x = font.x_from_index(g.fonts, b.font, b.font_size, text[start:a.cursor], a.cursor - start) }
				idx := a.cursor
				for _ in 0 ..< abs(lines) {
					ls, le := line_bounds(text, idx)
					if lines < 0 {
						if ls == 0 { idx = 0; break }
						ps, pe := line_bounds(text, ls - 1)
						idx = ps + font.index_from_x(g.fonts, b.font, b.font_size, text[ps:pe], x)
					} else {
						if le == len(text) { idx = len(text); break }
						ns, ne := line_bounds(text, le + 1)
						idx = ns + font.index_from_x(g.fonts, b.font, b.font_size, text[ns:ne], x)
					}
				}
				move(a, idx, extend)
				a.pref_x, a.has_pref = x, true
			}
			page := max(1, int((b.rect.max.y - b.rect.min.y - 2 * pad) / lh) - 1)

			// typing
			if len(s.typed) > 0 {
				begin_edit(a, .Insert, now)
				for r in s.typed { insert(a, utf8.runes_to_string({r}, context.temp_allocator)) }
				a.has_pref = false
			}
			if key_press(.Return) {
				begin_edit(a, .Other, now)
				// keep the indentation of the current line
				ls, _ := line_bounds(area_string(a), a.cursor)
				indent := 0
				for ls + indent < len(a.buf) && a.buf[ls + indent] == ' ' && ls + indent < a.cursor { indent += 1 }
				insert(a, "\n")
				if indent > 0 { insert(a, strings.repeat(" ", indent, context.temp_allocator)) }
				a.has_pref = false
			}
			if key_press(.Return, ctrl) { res.committed = true }
			if tab_indents && key_press(.Tab) { begin_edit(a, .Insert, now); insert(a, "    "); a.has_pref = false }
			for mods in ([?]Mods{{}, shift}) {
				ext := mods == shift
				t := area_string(a)
				lo, hi := sel(a)
				if key_press(.Left, mods)  { move(a, (lo != hi && !ext) ? lo : prev_index(t, a.cursor), ext); a.has_pref = false }
				if key_press(.Right, mods) { move(a, (lo != hi && !ext) ? hi : next_index(t, a.cursor), ext); a.has_pref = false }
				if key_press(.Up, mods)    { vertical(a, b, -1, ext) }
				if key_press(.Down, mods)  { vertical(a, b, 1, ext) }
				if key_press(.Page_Up, mods)   { vertical(a, b, -page, ext) }
				if key_press(.Page_Down, mods) { vertical(a, b, page, ext) }
				ls, le := line_bounds(t, a.cursor)
				if key_press(.Home, mods) {
					// first non-blank character, then the true line start
					nb := ls
					for nb < le && t[nb] == ' ' { nb += 1 }
					move(a, a.cursor == nb ? ls : nb, ext); a.has_pref = false
				}
				if key_press(.End, mods)   { move(a, le, ext); a.has_pref = false }
			}
			for mods in ([?]Mods{ctrl, cs}) {
				ext := mods == cs
				t := area_string(a)
				if key_press(.Left, mods)  { move(a, word_left(t, a.cursor), ext); a.has_pref = false }
				if key_press(.Right, mods) { move(a, word_right(t, a.cursor), ext); a.has_pref = false }
				if key_press(.Home, mods)  { move(a, 0, ext); a.has_pref = false }
				if key_press(.End, mods)   { move(a, len(a.buf), ext); a.has_pref = false }
			}
			if key_press(.Backspace) || key_press(.Backspace, shift) {
				lo, hi := sel(a)
				begin_edit(a, .Delete, now)
				if lo != hi { delete_range(a, lo, hi) } else { p := prev_index(area_string(a), a.cursor); delete_range(a, p, a.cursor) }
				a.has_pref = false
			}
			if key_press(.Delete) {
				lo, hi := sel(a)
				begin_edit(a, .Delete, now)
				if lo != hi { delete_range(a, lo, hi) } else { n := next_index(area_string(a), a.cursor); delete_range(a, a.cursor, n) }
				a.has_pref = false
			}
			if key_press(.Backspace, ctrl) {
				lo, hi := sel(a)
				begin_edit(a, .Other, now)
				if lo != hi { delete_range(a, lo, hi) } else { delete_range(a, word_left(area_string(a), a.cursor), a.cursor) }
			}
			if key_press(.Delete, ctrl) {
				lo, hi := sel(a)
				begin_edit(a, .Other, now)
				if lo != hi { delete_range(a, lo, hi) } else { delete_range(a, a.cursor, word_right(area_string(a), a.cursor)) }
			}
			if key_press(.A, ctrl) { a.mark = 0; a.cursor = len(a.buf) }
			if key_press(.C, ctrl) {
				lo, hi := sel(a)
				if lo != hi && s.clipboard_set != nil { s.clipboard_set(string(a.buf[lo:hi])) }
			}
			if key_press(.X, ctrl) {
				lo, hi := sel(a)
				if lo != hi {
					if s.clipboard_set != nil { s.clipboard_set(string(a.buf[lo:hi])) }
					begin_edit(a, .Other, now)
					delete_range(a, lo, hi)
				}
			}
			if key_press(.V, ctrl) && s.clipboard_get != nil {
				clip := s.clipboard_get()
				clean, _ := strings.replace_all(clip, "\r\n", "\n", context.temp_allocator)
				clean, _ = strings.replace_all(clean, "\r", "\n", context.temp_allocator)
				clean, _ = strings.replace_all(clean, "\t", "    ", context.temp_allocator)
				if clean != "" { begin_edit(a, .Other, now); insert(a, clean) }
			}
			if key_press(.Z, ctrl) { area_undo(a) }
			if key_press(.Y, ctrl) || key_press(.Z, cs) { area_redo(a) }
			if key_press(.Escape) { res.cancelled = true; s.focus_key = 0 }
			a.cursor = clamp(a.cursor, 0, len(a.buf))
			a.mark = clamp(a.mark, 0, len(a.buf))
			s.wake_ms = 265   // caret blink
		}
		text = area_string(a)
		res.changed = hash_bytes(a.buf[:]) != before_hash
		cursor_moved := moved || res.changed || a.cursor != c0 || a.mark != m0
		if cursor_moved { a.edited_ms = now }

		// content size and scrolling
		view_w := max(8, (b.rect.max.x - b.rect.min.x) - gutter - 2 * pad)
		view_h := max(8, (b.rect.max.y - b.rect.min.y) - 2 * pad)
		ext := content_extent(a, text, b, lh)
		content_w, content_h := ext.x, ext.y
		if cursor_moved {
			ls, _ := line_bounds(text, a.cursor)
			cx := font.x_from_index(s.fonts, b.font, b.font_size, text[ls:a.cursor], a.cursor - ls)
			cy := f32(line_of(text, a.cursor)) * lh
			if cx - a.scroll.x > view_w - 4 { a.scroll.x = cx - view_w + 4 }
			if cx - a.scroll.x < 0 { a.scroll.x = cx }
			if cy - a.scroll.y < 0 { a.scroll.y = cy }
			if cy + lh - a.scroll.y > view_h { a.scroll.y = cy + lh - view_h }
		}
		a.scroll.x = clamp(a.scroll.x, 0, max(0, content_w + 4 - view_w))
		a.scroll.y = clamp(a.scroll.y, 0, max(0, content_h - view_h))

		d := frame_new(Text_Edit_Draw)
		d.text = strings.clone(text, frame_allocator())
		d.placeholder = placeholder
		d.cursor, d.mark, d.scroll = a.cursor, a.mark, a.scroll
		d.focused = res.focused
		since := now - a.edited_ms
		d.caret_on = since < 500 || (int(since) / 530) % 2 == 0
		d.gutter, d.pad, d.line_h = gutter, pad, lh
		d.selection = color("selection")
		d.caret = color("cursor")
		if tags("weak") { d.weak = color("text") }
		d.gutter_bg = color("background")
		d.gutter_bg.a *= 0.35
		d.gutter_line = color("border")
		d.mono = mono
		d.bars = editor_bars(b.rect, gutter, pad, b.font_size, {content_w, content_h}, a.scroll)
		d.bar_color = color("text")
		mpos := b.rect.min + res.mouse
		if a.sb_drag != 0 { d.bar_hot = a.sb_drag } else if res.hovering {
			if d.bars.has_v && contains(Rect{{d.bars.vtrack.min.x - 4, d.bars.vtrack.min.y}, d.bars.vtrack.max}, mpos) { d.bar_hot = 1 }
			if d.bars.has_h && contains(Rect{{d.bars.htrack.min.x, d.bars.htrack.min.y - 4}, d.bars.htrack.max}, mpos) { d.bar_hot = 2 }
		}
		if d.bar_hot != 0 { s.cursor_request = .Arrow }
		b.custom = text_edit_draw
		b.custom_user = d
	}
	return
}
