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
	upstream:   bool,      // the caret at the end of a wrapped line (not at the start of the next one, the same index)
	caret_rect: Rect,      // window coordinates of the caret and of the selection's other end, when last drawn
	mark_rect:  Rect,      // (text_edit_caret_rect)
	rects_ok:   bool,
}

// The caret and the other end of the selection of a text_edit as last drawn, in window coordinates (a line-tall bar
// each): where a completion popover or an input method window goes. false before the editor was first drawn.
text_edit_caret_rect :: proc(a: ^Text_Area) -> (caret, mark: Rect, ok: bool) {
	return a.caret_rect, a.mark_rect, a.rects_ok
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
content_extent :: proc(a: ^Text_Area, text: string, b: ^Box, lh: f32, lines: []Visual_Line, wrap_w: f32) -> Vec2 {
	if wrap_w > 0 { return {wrap_w - 4, f32(len(lines)) * lh} }   // wrapped: no horizontal scrolling
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

// Caret x of byte `index` on visual line `l` (pixels from the line's start).
@(private="file")
caret_x_on :: proc(text: string, l: Visual_Line, b: ^Box, index: int) -> f32 {
	return font.x_from_index(g.fonts, b.font, b.font_size, text[l.start:l.end], clamp(index, l.start, l.end) - l.start)
}

////////////////////////////////
// widget

Text_Edit_Draw :: struct {
	area:        ^Text_Area,   // the caret rectangles are written back (text_edit_caret_rect)
	text:        string,
	lines:       []Visual_Line,
	placeholder: string,
	cursor, mark: int,
	upstream:    bool,
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

	// where the caret and the selection's other end are, drawn or not (popovers, input methods)
	caret_w := max(1, math.round(b.font_size / 12))
	end_rect :: proc(d: ^Text_Edit_Draw, b: ^Box, index: int, upstream: bool, x0, top, lh, w: f32) -> Rect {
		li := visual_line_of(d.lines, index, upstream)
		x := math.round(x0 + caret_x_on(d.text, d.lines[li], b, index))
		y := top + f32(li) * lh
		return {{x, y}, {x + w, y + lh}}
	}
	caret_rect := end_rect(d, b, d.cursor, d.upstream, text_x0, top, lh, caret_w)
	if d.area != nil {
		d.area.caret_rect = caret_rect
		d.area.mark_rect = end_rect(d, b, d.mark, false, text_x0, top, lh, caret_w)
		d.area.rects_ok = true
	}

	lo, hi := min(d.cursor, d.mark), max(d.cursor, d.mark)
	first := max(0, int(d.scroll.y / lh) - 1)
	last := min(len(d.lines) - 1, int((d.scroll.y + (r.max.y - r.min.y)) / lh) + 1)
	draw.push_clip(dc, {{r.min.x + d.gutter, r.min.y}, r.max})
	for li in first ..= last {
		l := d.lines[li]
		y := top + f32(li) * lh
		line_text := d.text[l.start:l.end]
		// selection: what the line shows of it, and its break (a "\n" or a wrap) when the selection goes on
		if d.focused && lo != hi && lo <= l.end && hi >= l.start {
			a := max(lo, l.start) - l.start
			z := min(hi, l.end) - l.start
			spans := font.x_spans_of_range(s.fonts, b.font, b.font_size, line_text, a, z)
			newline := !l.soft && hi > l.end   // the "\n" itself is selected (a wrap has no character of its own)
			for sp, k in spans {
				xb := text_x0 + sp[1]
				if newline && k == len(spans) - 1 { xb += b.font_size * 0.35 }
				draw.rect(dc, {{text_x0 + sp[0], y}, {xb, y + lh}}, d.selection)
			}
			if len(spans) == 0 && hi > l.end && !l.soft {   // an empty line inside the selection: just its break
				draw.rect(dc, {{text_x0, y}, {text_x0 + b.font_size * 0.35, y + lh}}, d.selection)
			}
		}
		draw.text(dc, b.font, b.font_size, {math.round(text_x0), math.round(y + baseline_off)}, b.text_color, line_text)
	}
	if d.focused && d.caret_on { draw.rect(dc, caret_rect, d.caret) }
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
		if hot { tc := c; tc.a = 0.06; draw.rect(dc, track, tuned(tc), w * 0.5 * s.rounding) }
		c.a = hot ? 0.45 : 0.22
		draw.rect(dc, thumb, tuned(c), w * 0.5 * s.rounding)
	}

	// line numbers (not scrolled horizontally): one per paragraph, on its first visual line
	if d.gutter > 0 {
		size := math.round(b.font_size * 0.85)
		mm := font.metrics(s.fonts, d.mono, size)
		cur_para := d.lines[visual_line_of(d.lines, d.cursor, d.upstream)].para
		for li in first ..= last {
			l := d.lines[li]
			if !l.first { continue }
			label := fmt_int(l.para + 1)
			w := font.text_width(s.fonts, d.mono, size, label)
			y := top + f32(li) * lh
			col := l.para == cur_para && d.focused ? b.text_color : d.weak
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

// Multi-line editor. Its size comes from the style stack or `next`; it scrolls when its content is larger.
//   wrap:        long lines break at the box's width (at the backend's line break opportunities, between grapheme
//                clusters for a word wider than the box): no horizontal scrolling; Up / Down / Home / End and the mouse
//                follow the visual lines.
//   auto_height: the box is as tall as its (visual) lines, `min_lines` at least and `max_lines` at most (0: no
//                limit); past that it scrolls. (A wrapped editor lays out at the width it had in the last frame.)
// The caret's rectangle is in the result (`caret`, box coordinates) and, as drawn, from text_edit_caret_rect.
text_edit :: proc(id: string, a: ^Text_Area, placeholder := "", line_numbers := false, tab_indents := false,
	wrap := false, auto_height := false, min_lines := 1, max_lines := 0) -> (res: Edit_Result) {
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
		// the width lines wrap at: the box's from the last layout (none yet in its first frame: one more frame)
		wrap_w: f32 = 0
		if wrap {
			if b.size.x > 0 { wrap_w = max(8, b.size.x - gutter - 2 * pad) } else { wake_within(s, 1) }
		}
		layout :: proc(a: ^Text_Area, b: ^Box, wrap_w: f32) -> []Visual_Line {
			return text_visual_lines(g.fonts, b.font, b.font_size, area_string(a), wrap_w, context.temp_allocator)
		}
		lines := layout(a, b, wrap_w)
		before_hash := hash_bytes(a.buf[:])
		c0, m0 := a.cursor, a.mark
		moved := false
		// a screen reader sets the text, types over the selection, or moves the caret
		if r, ok := a11y_request(b.key, .Set_Value); ok && r.data == .Value {
			begin_edit(a, .Other, now)
			area_set(a, r.value)
		}
		if r, ok := a11y_request(b.key, .Replace_Selected_Text); ok && r.data == .Value {
			begin_edit(a, .Other, now)
			insert(a, r.value)
		}
		if r, ok := a11y_request(b.key, .Set_Text_Selection); ok && r.data == .Text_Selection {
			runs := a11y_text_lines(area_string(a), lines)
			a.mark = a11y_run_byte(area_string(a), runs, b, r.sel[0], int(r.sel[1]))
			a.cursor = a11y_run_byte(area_string(a), runs, b, r.sel[2], int(r.sel[3]))
			a.upstream, a.has_pref = false, false
			moved = true
		}
		if a.cursor != c0 || hash_bytes(a.buf[:]) != before_hash { lines = layout(a, b, wrap_w) }
		ctrl := Mods{.Ctrl}
		shift := Mods{.Shift}
		cs := Mods{.Ctrl, .Shift}
		text := area_string(a)

		// mouse: the visual line under the point, the nearest caret position on it (past a wrapped line's end: that end)
		point_to_index :: proc(a: ^Text_Area, b: ^Box, lines: []Visual_Line, p: Vec2, gutter, pad, lh: f32) -> (int, bool) {
			text := area_string(a)
			li := clamp(int((p.y - pad + a.scroll.y) / lh), 0, len(lines) - 1)
			l := lines[li]
			i := l.start + font.index_from_x(g.fonts, b.font, b.font_size, text[l.start:l.end], p.x - gutter - pad + a.scroll.x)
			return i, l.soft && i >= l.end
		}
		// scrollbars: press on a thumb grabs it, press on a track jumps there; while held they own the drag
		bars := editor_bars(b.rect, gutter, pad, b.font_size, content_extent(a, text, b, lh, lines, wrap_w), a.scroll)
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
			content := content_extent(a, text, b, lh, lines, wrap_w)
			view := Vec2{(b.rect.max.x - b.rect.min.x) - gutter - 2 * pad, (b.rect.max.y - b.rect.min.y) - 2 * pad}
			if a.sb_drag == 1 {
				span := (bars.vtrack.max.y - bars.vtrack.min.y) - (bars.vthumb.max.y - bars.vthumb.min.y)
				if span > 0 { a.scroll.y = clamp((mp.y - a.sb_grab - bars.vtrack.min.y) / span, 0, 1) * (content.y - view.y) }
			} else {
				span := (bars.htrack.max.x - bars.htrack.min.x) - (bars.hthumb.max.x - bars.hthumb.min.x)
				if span > 0 { a.scroll.x = clamp((mp.x - a.sb_grab - bars.htrack.min.x) / span, 0, 1) * (content.x + 4 - view.x) }
			}
		} else if res.pressed || res.dragging {
			idx, up := point_to_index(a, b, lines, res.mouse, gutter, pad, lh)
			a.cursor, a.upstream = idx, up
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
			if wrap_w <= 0 { a.scroll.x += res.scrolled.x * lh * 3 }
		}

		if res.focused {
			move :: proc(a: ^Text_Area, to: int, extend: bool, upstream := false) {
				a.cursor = to
				a.upstream = upstream
				if !extend { a.mark = to }
			}
			// Up / Down by visual lines, keeping the column
			vertical :: proc(a: ^Text_Area, b: ^Box, wrap_w: f32, lines: int, extend: bool) {
				text := area_string(a)
				vl := text_visual_lines(g.fonts, b.font, b.font_size, text, wrap_w, context.temp_allocator)
				li := visual_line_of(vl, a.cursor, a.upstream)
				x := a.pref_x
				if !a.has_pref { x = caret_x_on(text, vl[li], b, a.cursor) }
				target := li + lines
				idx: int
				up := false
				switch {
				case target < 0:            idx = 0
				case target >= len(vl):     idx = len(text)
				case:
					l := vl[target]
					idx = l.start + font.index_from_x(g.fonts, b.font, b.font_size, text[l.start:l.end], x)
					up = l.soft && idx >= l.end
				}
				move(a, idx, extend, up)
				a.pref_x, a.has_pref = x, true
			}
			page := max(1, int((b.rect.max.y - b.rect.min.y - 2 * pad) / lh) - 1)

			// typing
			if len(s.typed) > 0 {
				begin_edit(a, .Insert, now)
				for r in s.typed { insert(a, utf8.runes_to_string({r}, context.temp_allocator)) }
				a.has_pref, a.upstream = false, false
			}
			if key_press(.Return) {
				begin_edit(a, .Other, now)
				// keep the indentation of the current line
				ls, _ := line_bounds(area_string(a), a.cursor)
				indent := 0
				for ls + indent < len(a.buf) && a.buf[ls + indent] == ' ' && ls + indent < a.cursor { indent += 1 }
				insert(a, "\n")
				if indent > 0 { insert(a, strings.repeat(" ", indent, context.temp_allocator)) }
				a.has_pref, a.upstream = false, false
			}
			if key_press(.Return, ctrl) { res.committed = true }
			if tab_indents && key_press(.Tab) { begin_edit(a, .Insert, now); insert(a, "    "); a.has_pref = false }
			for mods in ([?]Mods{{}, shift}) {
				ext := mods == shift
				t := area_string(a)
				lo, hi := sel(a)
				if key_press(.Left, mods)  { move(a, (lo != hi && !ext) ? lo : prev_index(t, a.cursor), ext); a.has_pref = false }
				if key_press(.Right, mods) { move(a, (lo != hi && !ext) ? hi : next_index(t, a.cursor), ext); a.has_pref = false }
				if key_press(.Up, mods)    { vertical(a, b, wrap_w, -1, ext) }
				if key_press(.Down, mods)  { vertical(a, b, wrap_w, 1, ext) }
				if key_press(.Page_Up, mods)   { vertical(a, b, wrap_w, -page, ext) }
				if key_press(.Page_Down, mods) { vertical(a, b, wrap_w, page, ext) }
				home, end := key_press(.Home, mods), key_press(.End, mods)   // (a key_press takes its event)
				if home || end {
					// the visual line's ends; Home on a paragraph's first line: its first non-blank character, then its start
					vl := text_visual_lines(s.fonts, b.font, b.font_size, t, wrap_w, context.temp_allocator)
					l := vl[visual_line_of(vl, a.cursor, a.upstream)]
					if home {
						nb := l.start
						if l.first { for nb < l.end && t[nb] == ' ' { nb += 1 } }
						move(a, a.cursor == nb ? l.start : nb, ext)
					} else {
						move(a, l.end, ext, l.soft)
					}
					a.has_pref = false
				}
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
				a.has_pref, a.upstream = false, false
			}
			if key_press(.Delete) {
				lo, hi := sel(a)
				begin_edit(a, .Delete, now)
				if lo != hi { delete_range(a, lo, hi) } else { n := next_index(area_string(a), a.cursor); delete_range(a, a.cursor, n) }
				a.has_pref, a.upstream = false, false
			}
			if key_press(.Backspace, ctrl) {
				lo, hi := sel(a)
				begin_edit(a, .Other, now)
				if lo != hi { delete_range(a, lo, hi) } else { delete_range(a, word_left(area_string(a), a.cursor), a.cursor) }
				a.upstream = false
			}
			if key_press(.Delete, ctrl) {
				lo, hi := sel(a)
				begin_edit(a, .Other, now)
				if lo != hi { delete_range(a, lo, hi) } else { delete_range(a, a.cursor, word_right(area_string(a), a.cursor)) }
				a.upstream = false
			}
			if key_press(.A, ctrl) { a.mark = 0; a.cursor = len(a.buf); a.upstream = false }
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
					a.upstream = false
				}
			}
			if key_press(.V, ctrl) && s.clipboard_get != nil {
				clip := s.clipboard_get()
				clean, _ := strings.replace_all(clip, "\r\n", "\n", context.temp_allocator)
				clean, _ = strings.replace_all(clean, "\r", "\n", context.temp_allocator)
				clean, _ = strings.replace_all(clean, "\t", "    ", context.temp_allocator)
				if clean != "" { begin_edit(a, .Other, now); insert(a, clean); a.upstream = false }
			}
			if key_press(.Z, ctrl) { area_undo(a); a.upstream = false }
			if key_press(.Y, ctrl) || key_press(.Z, cs) { area_redo(a); a.upstream = false }
			if key_press(.Escape) { res.cancelled = true; s.focus_key = 0 }
			a.cursor = clamp(a.cursor, 0, len(a.buf))
			a.mark = clamp(a.mark, 0, len(a.buf))
			wake_within(s, 265)   // caret blink
		}
		text = area_string(a)
		res.changed = hash_bytes(a.buf[:]) != before_hash
		cursor_moved := moved || res.changed || a.cursor != c0 || a.mark != m0
		if cursor_moved { a.edited_ms = now }
		if res.changed || cursor_moved { lines = layout(a, b, wrap_w) }
		cur_line := visual_line_of(lines, a.cursor, a.upstream)
		if !(lines[cur_line].soft && lines[cur_line].end == a.cursor) { a.upstream = false }   // only the end of a wrapped line has two places

		// height: as tall as the lines, within the limits (the next layout uses it)
		if auto_height {
			n := len(lines)
			n = max(n, max(min_lines, 1))
			if max_lines > 0 { n = min(n, max_lines) }
			b.pref[.Y] = px(f32(n) * lh + 2 * pad)
		}

		// content size and scrolling
		view_w := max(8, (b.rect.max.x - b.rect.min.x) - gutter - 2 * pad)
		view_h := max(8, (b.rect.max.y - b.rect.min.y) - 2 * pad)
		if auto_height { view_h = max(8, b.pref[.Y].value - 2 * pad) }   // the height this build asks for, not last frame's
		ext := content_extent(a, text, b, lh, lines, wrap_w)
		content_w, content_h := ext.x, ext.y
		cx := caret_x_on(text, lines[cur_line], b, a.cursor)
		cy := f32(cur_line) * lh
		res.caret = {{gutter + pad + cx - a.scroll.x, pad + cy - a.scroll.y}, {gutter + pad + cx - a.scroll.x + 1, pad + cy - a.scroll.y + lh}}
		if cursor_moved {
			if wrap_w <= 0 {
				if cx - a.scroll.x > view_w - 4 { a.scroll.x = cx - view_w + 4 }
				if cx - a.scroll.x < 0 { a.scroll.x = cx }
			}
			if cy - a.scroll.y < 0 { a.scroll.y = cy }
			if cy + lh - a.scroll.y > view_h { a.scroll.y = cy + lh - view_h }
		}
		a.scroll.x = wrap_w > 0 ? 0 : clamp(a.scroll.x, 0, max(0, content_w + 4 - view_w))
		a.scroll.y = clamp(a.scroll.y, 0, max(0, content_h - view_h))

		d := frame_new(Text_Edit_Draw)
		d.area = a
		d.text = strings.clone(text, frame_allocator())
		d.lines = make([]Visual_Line, len(lines), frame_allocator())
		copy(d.lines, lines)
		d.placeholder = placeholder
		d.cursor, d.mark, d.upstream, d.scroll = a.cursor, a.mark, a.upstream, a.scroll
		d.focused = res.focused
		since := now - a.edited_ms
		d.caret_on = since < 500 || (int(since) / 530) % 2 == 0
		d.gutter, d.pad, d.line_h = gutter, pad, lh
		d.selection = color("selection")
		d.caret = color("cursor")
		if tags("weak") { d.weak = color("text") }
		d.gutter_bg = color("background")
		d.gutter_bg.a *= 0.35
		d.gutter_bg = tuned(d.gutter_bg)
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
		if s.a11y.wanted {
			t := frame_new(A11y_Text)
			t^ = {text = d.text, cursor = a.cursor, mark = a.mark, lines = a11y_text_lines(d.text, d.lines, frame_allocator()),
				origin = {b.rect.min.x + gutter + pad, b.rect.min.y + pad}, line_height = lh, scroll = a.scroll, font = b.font, size = b.font_size}
			a11y_default(b, {role = .Multiline_Text_Input, placeholder = placeholder, text = t})
		} else {
			a11y_default(b, {role = .Multiline_Text_Input, placeholder = placeholder})
		}
	}
	return
}

// The text runs of an editor: its visual lines, each with the line break that ends it.
@(private)
a11y_text_lines :: proc(text: string, lines: []Visual_Line, allocator := context.temp_allocator) -> [][2]int {
	out := make([][2]int, len(lines), allocator)
	for l, i in lines {
		end := l.end
		if end < len(text) && text[end] == '\n' && (i + 1 == len(lines) || lines[i + 1].start > end) { end += 1 }
		out[i] = {l.start, end}
	}
	return out
}

