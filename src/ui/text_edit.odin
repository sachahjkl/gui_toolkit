package ui

// Multi-line text editor. The caller owns the `Text_Edit` (text, caret, scroll, undo history) like any other value.
//
// Keys when focused:
//   typing, Enter (new line), Backspace / Delete (Ctrl = word), arrows (Ctrl = word), Up / Down keep the column,
//   Home / End (line), Ctrl+Home / Ctrl+End (document), Page Up / Page Down, Shift + any move selects,
//   Ctrl+A / C / X / V (Shift+Insert pastes too; the clipboard's text comes in a later build, paste.odin), Ctrl+Z undo, Ctrl+Y or Ctrl+Shift+Z redo, Ctrl+Enter = committed, Escape = leave the field.
//   With its options' `enter_commits`: Enter = committed (Ctrl+Enter too), Shift+Enter = a new line.
//   Tab moves the focus to the next widget, unless its options' `tab_indents` (then Tab inserts 4 spaces, Ctrl+Tab... leaves).
// Mouse: click places the caret, drag selects, Shift+click extends, double-click selects a word, wheel scrolls.

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "../draw"
import "../font"
import "../platform"

@(private="file") Mods :: platform.Modifiers

@(private="file") TEXT_EDIT_LINE_HEIGHT :: 1.15   // of the font's line height
@(private="file") TEXT_EDIT_GUTTER_FONT_SCALE :: 0.85
// Room kept past the longest line, so the caret at its end is seen.
@(private="file") TEXT_EDIT_END_SLACK_PX :: 4
@(private="file") end_slack :: proc() -> f32 { return TEXT_EDIT_END_SLACK_PX * gs().scale }
// What the selection shows of a line break.
@(private="file") TEXT_EDIT_BREAK_SELECTION_EM :: 0.35
@(private="file") TEXT_EDIT_GUTTER_BG_ALPHA_FACTOR :: 0.35
@(private="file") TEXT_EDIT_ERROR_COLOR :: Color{0.85, 0.25, 0.25, 1}
@(private="file") TEXT_EDIT_ERROR_LINE_DIVISOR :: 12   // the error underline's thickness: font size over this
@(private="file") LINE_NUMBER_MAX_BYTES :: 12

// A scrollbar of a text_edit, or none.
Text_Scrollbar :: enum u8 { None, Vertical, Horizontal }

Text_Edit :: struct {
	buf:        [dynamic]u8,
	cursor:     int,       // byte index of the caret
	mark:       int,       // other end of the selection
	scroll:     [2]f32,    // pixels
	pref_x:     f32,       // column kept by Up / Down (valid when has_pref: any other move or edit ends it, in text_edit)
	has_pref:   bool,
	edited_ms:  f64,
	history:    Edit_History,
	group:      Edit_Kind, // consecutive edits of one kind within a second form one undo step
	group_ms:   f64,
	sb_drag:    Text_Scrollbar,   // the scrollbar held
	sb_part:    Scrollbar_Part,   // and its part held
	bar_room:   Vec2,             // the room its text keeps for its bars, as a scroll box's layout does (edit_bar_room)
	sb_grab:    f32,
	ext_key:    u64,       // content size cache (measuring every line each frame is the editor's main cost)
	ext:        Vec2,
	upstream:   bool,      // the caret at the end of a wrapped line (not at the start of the next one, the same index)
	caret_rect: Rect,      // window coordinates of the caret and of the selection's other end, when last drawn
	mark_rect:  Rect,      // (text_edit_caret_rect)
	rects_ok:   bool,
	built:      u64,       // the build that last made it: the rects are of an editor still there
	word:       Word_Drag, // the word a double click took, while its button is held
}

// The caret and the other end of the selection of a text_edit as last drawn, in window coordinates (a line-tall bar
// each): where a completion popover or an input method window goes. false before the editor was first drawn, and once it
// is built no more.
text_edit_caret_rect :: proc(a: ^Text_Edit) -> (caret, mark: Rect, ok: bool) {
	s := gs()
	shown := a.built == s.build_index || (build_of == s && a.built + 1 == s.build_index)   // (in a build: the last one's)
	return a.caret_rect, a.mark_rect, a.rects_ok && shown
}

// Syntax colouring for text_edit. A classifier the caller provides, called per visible paragraph: the editor never knows a
// language, it only draws the coloured runs the classifier returns. It costs only what the visible lines cost (the editor
// calls `spans` for the lines it draws, not the whole document).
Text_Span :: struct {
	start, end: int,   // byte range within the paragraph's text (line_text)
	color:      Color, // the run's colour (a zero colour {0,0,0,0} falls back to the box's text colour)
}

Text_Highlight :: struct {
	user:  rawptr,
	// The coloured runs of one paragraph. `line_text` is its text (no trailing "\n"), `para` its number. Append spans
	// (byte ranges into line_text, in order, non-overlapping) to `out`; uncovered bytes use the text colour. Leave `out`
	// empty for a plain line.
	spans: proc(user: rawptr, line_text: string, para: int, out: ^[dynamic]Text_Span),
	// Whether the paragraph has a syntax error: it is underlined in `error`. nil: no line is marked.
	error_line: proc(user: rawptr, para: int) -> bool,
	error: Color,   // the underline colour (a zero colour falls back to a theme red)
}

// Scrollbar geometry of the editor (screen space): the toolkit's bars (scrollbar.odin), over the text at the right and
// bottom edges, `inset` from the ends of those edges (a rounded box's corners).
@(private="file")
Editor_Bars :: struct {
	v, h:         Scrollbar_Parts,
	has_v, has_h: bool,
}

// `corner`: the box's drawn radius, which the bars keep clear of; `edge`: its border, which they stay inside; `room`:
// what the text keeps for them (edit_bar_room).
@(private="file")
editor_bars :: proc(r: Rect, gutter, pad, corner, edge: f32, room: Vec2, content: Vec2, scroll: Vec2, wrapped: bool) -> (e: Editor_Bars) {
	s := gs()
	view := editor_view(r, gutter, pad, room)
	e.has_v = content.y > view.y + SCROLLBAR_FIT_SLACK_PX
	e.has_h = !wrapped && content.x + end_slack() > view.x + SCROLLBAR_FIT_SLACK_PX   // (wrapped text never scrolls sideways: its width is the last layout's, which may be a pixel wider than this one)
	w := scrollbar_thickness(s)
	inset := max(corner, edge)
	if e.has_v {
		bar := Rect{{r.max.x - edge - w, r.min.y + inset}, {r.max.x - edge, r.max.y - (e.has_h ? edge + w : inset)}}
		e.v = scrollbar_layout(s, bar, .Y, view.y, content.y, clamp(scroll.y / max(1, content.y - view.y), 0, 1))
	}
	if e.has_h {
		bar := Rect{{r.min.x + gutter + (gutter > 0 ? 0 : inset), r.max.y - edge - w}, {r.max.x - (e.has_v ? edge + w : inset), r.max.y - edge}}
		e.h = scrollbar_layout(s, bar, .X, view.x, content.x + end_slack(), clamp(scroll.x / max(1, content.x + end_slack() - view.x), 0, 1))
	}
	return
}

// What an editor shows of its text: its box less the line numbers, its padding and the room of its bars.
@(private="file")
editor_view :: proc(r: Rect, gutter, pad: f32, room: Vec2) -> Vec2 {
	return {(r.max.x - r.min.x) - gutter - 2 * pad - room.x, (r.max.y - r.min.y) - 2 * pad - room.y}
}

// The bar of an editor that takes a press at `p`: the one shown, a little wider toward the text where it is over the text
// (no `room` kept for it) (.None: none).
@(private="file")
editor_bar_under :: proc(bars: Editor_Bars, room: Vec2, p: Vec2) -> Text_Scrollbar {
	grab_in, away := scrollbar_grab()
	toward_v := room.x > 0 ? 0 : grab_in
	toward_h := room.y > 0 ? 0 : grab_in
	if bars.has_v && contains(Rect{{bars.v.bar.min.x - toward_v, bars.v.bar.min.y}, {bars.v.bar.max.x + away, bars.v.bar.max.y}}, p) { return .Vertical }
	if bars.has_h && contains(Rect{{bars.h.bar.min.x, bars.h.bar.min.y - toward_h}, {bars.h.bar.max.x, bars.h.bar.max.y + away}}, p) { return .Horizontal }
	return .None
}

@(private="file")
content_extent :: proc(a: ^Text_Edit, text: string, b: ^Box, lh: f32, lines: []Visual_Line, wrap_w: f32) -> Vec2 {
	if wrap_w > 0 { return {wrap_w - end_slack(), f32(len(lines)) * lh} }   // wrapped: no horizontal scrolling
	key := hash_bytes(transmute([]u8)text) ~ (u64(transmute(u32)b.font_size) << 20) ~ u64(b.font) ~ u64(transmute(u32)lh)
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
		w = max(w, font.text_width(gs().fonts, b.font, b.font_size, text[start:end]))
		lines += 1
		if nl < 0 { break }
		start = end + 1
	}
	return {w, f32(lines) * lh}
}

text_edit_string :: proc(a: ^Text_Edit) -> string { return string(a.buf[:]) }

text_edit_set :: proc(a: ^Text_Edit, text: string) {
	clear(&a.buf)
	append(&a.buf, text)
	a.cursor, a.mark, a.scroll, a.has_pref = len(a.buf), len(a.buf), {}, false
	text_edit_clear_history(a)
}

text_edit_clear_history :: proc(a: ^Text_Edit) {
	edit_history_forget(&a.history)
	a.group = .None
}

text_edit_destroy :: proc(a: ^Text_Edit) {
	edit_history_destroy(&a.history)
	a.group = .None
	delete(a.buf)
}

text_edit_line_count :: proc(a: ^Text_Edit) -> int { return strings.count(text_edit_string(a), "\n") + 1 }

////////////////////////////////
// editing primitives

// Records an undo step before an edit (grouping same-kind edits made within Feel.undo_merge_ms of each other, as a field's).
@(private="file")
begin_edit :: proc(a: ^Text_Edit, kind: Edit_Kind, now: f64) {
	cfg := feel_now()
	merge := kind == a.group && kind != .Other && now - a.group_ms < f64(cfg.undo_merge_ms)
	edit_history_record(&a.history, a.buf[:], a.cursor, a.mark, cfg.undo_steps, merge)
	a.group, a.group_ms = kind, now
}

text_edit_undo :: proc(a: ^Text_Edit) -> bool {
	if !edit_history_step(&a.history, true, &a.buf, &a.cursor, &a.mark) { return false }
	a.group = .None
	return true
}

text_edit_redo :: proc(a: ^Text_Edit) -> bool {
	if !edit_history_step(&a.history, false, &a.buf, &a.cursor, &a.mark) { return false }
	a.group = .None
	return true
}

@(private="file")
sel :: proc(a: ^Text_Edit) -> (lo, hi: int) { return min(a.cursor, a.mark), max(a.cursor, a.mark) }

// Selects the whole text, as line_edit_select_all does a line's (a program that sets a text to be typed over).
text_edit_select_all :: proc(a: ^Text_Edit) { a.mark, a.cursor, a.upstream = 0, len(a.buf), false }

// The edits of the keys and of the field's menu (edit_menu), one of each: through the edit history, the clipboard the one
// given to begin_build. False: nothing to do (no selection, no clipboard).

@(private)
text_edit_copy :: proc(a: ^Text_Edit) -> bool {
	lo, hi := sel(a)
	if lo == hi || current == nil || current.clipboard_set == nil { return false }
	gs().clipboard_set(string(a.buf[lo:hi]))
	return true
}

// (with no clipboard, a cut still cuts: what was asked is that the text goes)
@(private)
text_edit_cut :: proc(a: ^Text_Edit) -> bool {
	_ = text_edit_copy(a)
	return text_edit_delete(a)
}

@(private)
text_edit_delete :: proc(a: ^Text_Edit) -> bool {
	lo, hi := sel(a)
	if lo == hi { return false }
	begin_edit(a, .Other, gs().time_ms)
	delete_range(a, lo, hi)
	a.upstream = false
	return true
}

@(private="file")
delete_range :: proc(a: ^Text_Edit, lo, hi: int) {
	if hi <= lo { return }
	remove_range(&a.buf, lo, hi)
	a.cursor, a.mark = lo, lo
}

@(private="file")
insert :: proc(a: ^Text_Edit, text: string) {
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
	return font.x_from_index(gs().fonts, b.font, b.font_size, text[l.start:l.end], clamp(index, l.start, l.end) - l.start)
}

////////////////////////////////
// widget

Text_Edit_Draw :: struct {
	area:        ^Text_Edit,   // the caret rectangles are written back (text_edit_caret_rect)
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
	room:        Vec2,                              // what the text keeps for its bars: nothing of it is drawn there
	bar_looks:   [Text_Scrollbar]Scrollbar_Look,   // the state each bar is drawn in
	highlight:   ^Text_Highlight,   // nil: plain text in b.text_color
	error_color: Color,
}

@(private="file")
text_edit_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Text_Edit_Draw)(user)
	s := gs()
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
	caret_w := max(1, math.round(b.font_size / CARET_WIDTH_DIVISOR))
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
	draw.push_clip(dc, {{r.min.x + d.gutter, r.min.y}, r.max - d.room})
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
				if newline && k == len(spans) - 1 { xb += b.font_size * TEXT_EDIT_BREAK_SELECTION_EM }
				draw.rect(dc, {{text_x0 + sp[0], y}, {xb, y + lh}}, d.selection)
			}
			if len(spans) == 0 && hi > l.end && !l.soft {   // an empty line inside the selection: just its break
				draw.rect(dc, {{text_x0, y}, {text_x0 + b.font_size * TEXT_EDIT_BREAK_SELECTION_EM, y + lh}}, d.selection)
			}
		}
		if d.highlight != nil {
			draw_highlighted_line(dc, d, b, s, l, line_text, text_x0, y, baseline_off, lh)
		} else {
			draw.text(dc, b.font, b.font_size, {math.round(text_x0), math.round(y + baseline_off)}, b.text_color, line_text)
		}
	}
	if d.focused && d.caret_on { draw.rect(dc, caret_rect, d.caret) }
	draw.pop_clip(dc)

	// scrollbars: the toolkit's (scrollbar_paint), at the editor's place: it scrolls itself
	if d.bars.has_v { scrollbar_paint(s, dc, b, d.bars.v, d.bar_looks[.Vertical]) }
	if d.bars.has_h { scrollbar_paint(s, dc, b, d.bars.h, d.bar_looks[.Horizontal]) }

	// line numbers (not scrolled horizontally): one per paragraph, on its first visual line
	if d.gutter > 0 {
		size := math.round(b.font_size * TEXT_EDIT_GUTTER_FONT_SCALE)
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

// One visual line with syntax colouring. The classifier works per paragraph; this draws the part of its coloured runs that
// falls on the visual line (so wrapping keeps working), then an error underline for a flagged paragraph.
@(private="file")
draw_highlighted_line :: proc(dc: ^draw.Context, d: ^Text_Edit_Draw, b: ^Box, s: ^State, l: Visual_Line, line_text: string, text_x0, y, baseline_off, lh: f32) {
	hl := d.highlight
	// the paragraph's text and its start offset in d.text
	para_start := strings.last_index_byte(d.text[:l.start], '\n') + 1
	pe := strings.index_byte(d.text[para_start:], '\n')
	para_end := pe < 0 ? len(d.text) : para_start + pe
	para_text := d.text[para_start:para_end]

	spans := make([dynamic]Text_Span, 0, 16, frame_allocator())
	if hl.spans != nil { hl.spans(hl.user, para_text, l.para, &spans) }

	// one left-to-right pass over the visual line: each byte that a span covers is drawn in the span's colour, the rest in
	// the text colour. Each run is positioned at the x of its first byte (caret_x_on keeps glyph advances exact), so this
	// is pixel-identical to the plain draw where no span applies, and it never overwrites the selection highlight.
	pos := l.start
	draw_run :: proc(dc: ^draw.Context, d: ^Text_Edit_Draw, b: ^Box, l: Visual_Line, text_x0, y, baseline_off: f32, lo, hi: int, col: Color) {
		if hi <= lo { return }
		x := text_x0 + caret_x_on(d.text, l, b, lo)
		draw.text(dc, b.font, b.font_size, {math.round(x), math.round(y + baseline_off)}, col, d.text[lo:hi])
	}
	for sp in spans {
		ds := clamp(para_start + sp.start, l.start, l.end)
		de := clamp(para_start + sp.end, l.start, l.end)
		if de <= ds { continue }
		if ds > pos { draw_run(dc, d, b, l, text_x0, y, baseline_off, pos, ds, b.text_color) }   // gap before the span
		col := sp.color == {} ? b.text_color : sp.color
		draw_run(dc, d, b, l, text_x0, y, baseline_off, ds, de, col)
		pos = de
	}
	if pos < l.end { draw_run(dc, d, b, l, text_x0, y, baseline_off, pos, l.end, b.text_color) }
	_ = line_text
	if hl.error_line != nil && l.first && hl.error_line(hl.user, l.para) {
		col := hl.error == {} ? d.error_color : hl.error
		x1 := text_x0 + font.text_width(s.fonts, b.font, b.font_size, line_text)
		uy := y + lh - max(1, math.round(b.font_size / TEXT_EDIT_ERROR_LINE_DIVISOR))
		draw.rect(dc, {{text_x0, uy}, {max(x1, text_x0 + b.font_size * 0.4), uy + max(1, math.round(b.font_size / TEXT_EDIT_ERROR_LINE_DIVISOR))}}, col)
	}
}

@(private="file")
fmt_int :: proc(v: int) -> string {
	buf := make([]u8, LINE_NUMBER_MAX_BYTES, frame_allocator())
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

Text_Edit_Options :: struct {
	placeholder:  string,          // shown, weak, while the editor is empty and has no keyboard
	line_numbers: bool,            // a gutter with the number of each paragraph
	tab_indents:  bool,            // Tab inserts 4 spaces (Ctrl+Tab... leaves); false: Tab moves the focus on
	// Long lines break at the box's width (at the backend's line break opportunities, between grapheme clusters for a
	// word wider than the box): no horizontal scrolling; Up / Down / Home / End and the mouse follow the visual lines.
	wrap:         bool,
	// The box is as tall as its (visual) lines, `min_lines` at least (0: 1) and `max_lines` at most (0: no limit); past
	// that it scrolls. (A wrapped editor lays out at the width it had in the last frame.)
	auto_height:  bool,
	min_lines, max_lines: int,
	highlight:    ^Text_Highlight, // syntax colouring; nil: plain text
	// The program builds its own menu on a right press (edit_menu); false: a right press opens edit_menu (Undo, Cut, Copy,
	// Paste...), as on a line_edit.
	own_menu:     bool,
	// Enter is `committed` and Shift+Enter breaks the line (a message, a caption typed in place); false: Enter breaks the
	// line and Ctrl+Enter is `committed`.
	enter_commits: bool,
	// What Ctrl+V, Shift+Insert and the menu's Paste ask for ({}: text). The editor takes the text; files or an image are
	// the program's, which takes them after the editor in the same build: paste_answer(res.box.key, {.Files, .Image}).
	// `paste_decode`: an image comes with its pixels, decoded on the chores (paste_request).
	paste:        Paste_Kinds,
	paste_decode: bool,
}

// Multi-line editor. Its size comes from the style stack or `next`; it scrolls when its content is larger.
// The caret's rectangle is in the result (`caret`, box coordinates) and, as drawn, from text_edit_caret_rect.
//
//   ui.text_edit("###notes", &app.notes, {placeholder = "Notes", wrap = true})
text_edit :: proc(id: string, a: ^Text_Edit, o := Text_Edit_Options{}) -> (res: Edit_Result) {
	s := gs()
	if tags("input") {
		b := build_box({.Clickable, .Focusable, .Text_Input, .Scroll_Self, .Clip, .Draw_Background, .Draw_Border, .Draw_Focus_Ring, .Sunken}, id)
		b.cursor = .Text
		b.text = ""
		res.signal = signal(b)
		res.hover_line = -1
		pad := b.text_pad
		mono := state_text_face(s, .Mono)
		if mono == 0 { mono = b.font }
		m := font.metrics(s.fonts, b.font, b.font_size)
		e := Edit_Build{s = s, a = a, b = b, res = &res, now = s.time_ms, pad = pad, lh = math.round(m.line_height * TEXT_EDIT_LINE_HEIGHT), paste = o.paste == {} ? Paste_Kinds{.Text} : o.paste, paste_decode = o.paste_decode}
		if o.line_numbers {
			digits := len(fmt_int(text_edit_line_count(a)))
			e.gutter = math.round(font.text_width(s.fonts, mono, math.round(b.font_size * TEXT_EDIT_GUTTER_FONT_SCALE), "0") * f32(max(digits, 2)) + pad * 1.8)
		}
		// the room kept for its bars: the last build's (edit_bar_room decides it again below)
		e.room = s.scrollbar_overlay ? Vec2{} : a.bar_room
		e.wrap = o.wrap
		// the width lines wrap at: the box's from the last layout (none yet in its first frame: one more frame)
		edit_wrap_width(&e)
		e.lines = edit_lines(&e)
		a.built = s.build_index
		before_hash := hash_bytes(a.buf[:])
		c0, m0 := a.cursor, a.mark
		edit_requests(&e)
		if a.cursor != c0 || hash_bytes(a.buf[:]) != before_hash { e.lines = edit_lines(&e) }
		edit_pointer(&e)
		if res.focused {
			edit_paste_answer(&e)
			edit_keys_typing(&e, o.tab_indents, o.enter_commits)
			edit_keys_moves(&e)
			edit_keys_deleting(&e)
			edit_keys_clipboard(&e)
			if key_press(.Z, {.Ctrl}) { text_edit_undo(a); a.upstream = false }
			if key_press(.Y, {.Ctrl}) || key_press(.Z, {.Ctrl, .Shift}) { text_edit_redo(a); a.upstream = false }
			if key_press(.Escape) { res.cancelled = true; s.focus_key = 0 }
			a.cursor = clamp(a.cursor, 0, len(a.buf))
			a.mark = clamp(a.mark, 0, len(a.buf))
		}
		res.changed = hash_bytes(a.buf[:]) != before_hash
		cursor_moved := e.moved || res.changed || a.cursor != c0 || a.mark != m0
		if cursor_moved { a.edited_ms = e.now }
		if cursor_moved && !e.vertical { a.has_pref = false }   // (the column holds from one Up or Down to the next)
		if cursor_moved && !res.changed { a.group = .None }     // (what is typed after a move of the caret is another step)
		if res.focused { caret_wake(s, e.now - a.edited_ms) }
		if res.changed || cursor_moved { e.lines = edit_lines(&e) }
		edit_bar_room(&e)

		// height: as tall as the lines, within the limits (the next layout uses it)
		if o.auto_height {
			n := len(e.lines)
			n = max(n, max(o.min_lines, 1))
			if o.max_lines > 0 { n = min(n, o.max_lines) }
			b.pref[.Y] = px(f32(n) * e.lh + 2 * pad + e.room.y)   // (and the room of a horizontal bar: no line under it)
		}
		content := edit_follow_caret(&e, o.auto_height, cursor_moved)
		edit_fill_draw(&e, content, o.placeholder, mono, o.highlight)
		if !o.own_menu { edit_context_menu(b, a, .Plain, e.paste, e.paste_decode) }
	}
	return
}

// What the parts of text_edit share in a build.
@(private="file")
Edit_Build :: struct {
	s:      ^State,
	a:      ^Text_Edit,
	b:      ^Box,
	res:    ^Edit_Result,
	now:    f64,
	pad, lh, gutter: f32,
	wrap:   bool,              // its lines wrap (Text_Edit_Options.wrap)
	wrap_w: f32,               // the width lines wrap at (0: they do not)
	room:   Vec2,              // what its text keeps for its bars (edit_bar_room)
	lines:  []Visual_Line,
	moved:  bool,              // the caret was placed, even where it was
	vertical: bool,            // Up, Down or a page moved it: the column stays
	paste:  Paste_Kinds,       // what its paste asks for (Text_Edit_Options.paste, never empty)
	paste_decode: bool,
}

// The width its lines wrap at: the box's from the last layout less the line numbers, the padding and the vertical bar's
// room (none yet in its first frame: one more frame).
@(private="file")
edit_wrap_width :: proc(e: ^Edit_Build) {
	if !e.wrap { return }
	s, b := e.s, e.b
	if b.size.x > 0 { e.wrap_w = max(TEXT_VIEW_MIN_PX * s.scale, b.size.x - e.gutter - 2 * e.pad - e.room.x) } else { wake_within(s, 1) }
}

// The room its text keeps for its bars, as a scroll box's layout keeps it (scrollbar_rooms_update, the same rule and the
// same hysteresis): measured with the room it had, a bar's room is taken where the text overflows and given back where it
// fits beside the bar. When the vertical room changes, wrapped lines are wrapped again at once: no line is drawn under
// the bar, not even for a frame.
@(private="file")
edit_bar_room :: proc(e: ^Edit_Build) {
	s, a, b := e.s, e.a, e.b
	room: Vec2
	if !s.scrollbar_overlay && b.size.x > 0 {
		content := content_extent(a, text_edit_string(a), b, e.lh, e.lines, e.wrap_w)
		view := editor_view(b.rect, e.gutter, e.pad, e.room)
		w := scrollbar_thickness(s)
		reserve := .Scrollbar_Reserve in b.flags   // (the room kept while it fits: text that grows past the view does not rewrap then)
		if reserve || content.y > view.y + SCROLLBAR_FIT_SLACK_PX { room.x = w }
		if e.wrap_w <= 0 && (reserve || content.x + end_slack() > view.x + SCROLLBAR_FIT_SLACK_PX) { room.y = w }
	}
	a.bar_room = room
	if room == e.room { return }
	x_changed := room.x != e.room.x
	e.room = room
	if x_changed && e.wrap {
		edit_wrap_width(e)
		e.lines = edit_lines(e)
	}
}

@(private="file")
edit_lines :: proc(e: ^Edit_Build) -> []Visual_Line {
	return text_visual_lines(gs().fonts, e.b.font, e.b.font_size, text_edit_string(e.a), e.wrap_w, context.temp_allocator)
}

// A screen reader sets the text, types over the selection, or moves the caret.
@(private="file")
edit_requests :: proc(e: ^Edit_Build) {
	a, b := e.a, e.b
	if r, ok := a11y_request(b.key, .Set_Value); ok && r.data == .Value {
		begin_edit(a, .Other, e.now)
		a.mark, a.cursor = 0, len(a.buf)
		insert(a, r.value)
	}
	if r, ok := a11y_request(b.key, .Replace_Selected_Text); ok && r.data == .Value {
		begin_edit(a, .Other, e.now)
		insert(a, r.value)
	}
	if r, ok := a11y_request(b.key, .Set_Text_Selection); ok && r.data == .Text_Selection {
		runs := a11y_text_lines(text_edit_string(a), edit_lines(e))
		a.mark = a11y_run_byte(text_edit_string(a), runs, b, r.sel[0], int(r.sel[1]))
		a.cursor = a11y_run_byte(text_edit_string(a), runs, b, r.sel[2], int(r.sel[3]))
		a.upstream = false
		e.moved = true
	}
}

// The visual line under the point, the nearest caret position on it (past a wrapped line's end: that end).
@(private="file")
edit_point_to_index :: proc(e: ^Edit_Build, p: Vec2) -> (int, bool) {
	a, b := e.a, e.b
	text := text_edit_string(a)
	li := clamp(int((p.y - e.pad + a.scroll.y) / e.lh), 0, len(e.lines) - 1)
	l := e.lines[li]
	i := l.start + font.index_from_x(gs().fonts, b.font, b.font_size, text[l.start:l.end], p.x - e.gutter - e.pad + a.scroll.x)
	return i, l.soft && i >= l.end
}

// Clicks, drags (the scrollbars own theirs: an arrow steps a line and repeats while held, a press on a track pages, a
// press on a thumb grabs it), the wheel.
@(private="file")
edit_pointer :: proc(e: ^Edit_Build) {
	s, a, b, res := e.s, e.a, e.b, e.res
	gutter, pad, lh, wrap_w := e.gutter, e.pad, e.lh, e.wrap_w
	text := text_edit_string(a)
	content := content_extent(a, text, b, lh, e.lines, wrap_w)
	bars := editor_bars(b.rect, gutter, pad, scrollbar_inset(s, b), border_inset(b), e.room, content, a.scroll, wrap_w > 0)
	view := editor_view(b.rect, gutter, pad, e.room)
	limit := Vec2{max(content.x + end_slack() - view.x, 0), max(content.y - view.y, 0)}
	mp := b.rect.min + res.mouse
	if !res.dragging && !res.pointer_pressed { a.sb_drag, a.sb_part = .None, .None }
	if res.pointer_pressed {
		a.sb_drag, a.sb_part = editor_bar_under(bars, e.room, mp), .None
		if a.sb_drag != .None {
			axis := a.sb_drag == .Vertical ? Axis.Y : Axis.X
			parts := a.sb_drag == .Vertical ? bars.v : bars.h
			ai := int(axis)
			a.sb_part = scrollbar_part_at(parts, mp)
			#partial switch a.sb_part {
			case .Start, .End:
				if scrollbar_repeat(s, scrollbar_key(b, axis), true, true) { a.scroll[ai] = clamp(a.scroll[ai] + (a.sb_part == .Start ? -lh : lh), 0, limit[ai]) }
			case .Thumb:
				a.sb_grab = mp[ai] - parts.thumb.min[ai]
			case .Track:
				a.scroll[ai] = clamp(a.scroll[ai] + (mp[ai] < parts.thumb.min[ai] ? -view[ai] : view[ai]), 0, limit[ai])
			}
		}
	} else if a.sb_drag != .None && res.dragging {
		axis := a.sb_drag == .Vertical ? Axis.Y : Axis.X
		parts := a.sb_drag == .Vertical ? bars.v : bars.h
		ai := int(axis)
		#partial switch a.sb_part {
		case .Start, .End:
			on := contains(a.sb_part == .Start ? parts.start : parts.end, mp)
			if scrollbar_repeat(s, scrollbar_key(b, axis), false, on) { a.scroll[ai] = clamp(a.scroll[ai] + (a.sb_part == .Start ? -lh : lh), 0, limit[ai]) }
		case .Thumb:
			// (no move since the press, no shift: the thumb's place is whole pixels)
			span := (parts.track.max[ai] - parts.track.min[ai]) - (parts.thumb.max[ai] - parts.thumb.min[ai])
			if span > 0 && mp[ai] != s.press_pos[.Left][ai] { a.scroll[ai] = clamp((mp[ai] - a.sb_grab - parts.track.min[ai]) / span, 0, 1) * limit[ai] }
		}
	}
	if a.sb_drag == .None && (res.pointer_pressed || res.dragging) {
		at := res.mouse
		if !res.pointer_pressed {
			// a selecting drag: near or past an edge the text scrolls (then the views around it), and the moving end
			// stays on the lines shown, so it reaches each line as it scrolls in
			text_view := Rect{b.rect.min + {gutter + pad, pad}, b.rect.min + {gutter + pad, pad} + view}
			_ = drag_autoscroll_own(b.key, text_view, &a.scroll, limit)
			at = drag_point_in(b, text_view, mp) - b.rect.min
		}
		idx, up := edit_point_to_index(e, at)
		if res.pointer_pressed { a.word.on = false }
		if a.word.on {
			a.mark, a.cursor = word_drag_to(a.word, text, idx)
		} else {
			a.cursor, a.upstream = idx, up
			if res.pointer_pressed && .Shift not_in res.mods { a.mark = idx }
		}
		e.moved = true
	}
	if res.double_clicked && a.sb_drag == .None {
		a.word = word_drag_at(text, a.cursor)
		a.mark, a.cursor = a.word.lo, a.word.hi
	}
	if res.scrolled != {} {
		a.scroll.y += res.scrolled.y * wheel_step(b, .Y)
		if wrap_w <= 0 { a.scroll.x += res.scrolled.x * wheel_step(b, .X) }
	}
}

// Typing, Enter (the indentation stays), Ctrl+Enter, Tab. `enter_commits`: Enter commits and Shift+Enter breaks the line.
@(private="file")
edit_keys_typing :: proc(e: ^Edit_Build, tab_indents, enter_commits: bool) {
	s, a := e.s, e.a
	if len(s.typed) > 0 {
		begin_edit(a, .Insert, e.now)
		for r in s.typed { insert(a, utf8.runes_to_string({r}, context.temp_allocator)) }
		a.upstream = false
	}
	breaks := false
	if enter_commits {
		if key_press(.Return) { e.res.committed = true }
		breaks = key_press(.Return, {.Shift})
	} else {
		breaks = key_press(.Return)
	}
	if breaks {
		begin_edit(a, .Other, e.now)
		// keep the indentation of the current line
		ls, _ := line_bounds(text_edit_string(a), a.cursor)
		indent := 0
		for ls + indent < len(a.buf) && a.buf[ls + indent] == ' ' && ls + indent < a.cursor { indent += 1 }
		insert(a, "\n")
		if indent > 0 { insert(a, strings.repeat(" ", indent, context.temp_allocator)) }
		a.upstream = false
	}
	if key_press(.Return, {.Ctrl}) { e.res.committed = true }
	if tab_indents && key_press(.Tab) { begin_edit(a, .Insert, e.now); insert(a, "    ") }
}

@(private="file")
edit_move :: proc(a: ^Text_Edit, to: int, extend: bool, upstream := false) {
	a.cursor = to
	a.upstream = upstream
	a.has_pref = false   // (edit_vertical sets it again)
	if !extend { a.mark = to }
}

// Up / Down by visual lines, keeping the column.
@(private="file")
edit_vertical :: proc(e: ^Edit_Build, lines: int, extend: bool) {
	a, b := e.a, e.b
	text := text_edit_string(a)
	vl := edit_lines(e)
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
		idx = l.start + font.index_from_x(gs().fonts, b.font, b.font_size, text[l.start:l.end], x)
		up = l.soft && idx >= l.end
	}
	edit_move(a, idx, extend, up)
	a.pref_x, a.has_pref = x, true
	e.vertical = true
}

// The moves: arrows, pages, the line's ends (with Shift they select), words and the document's ends (Ctrl).
@(private="file")
edit_keys_moves :: proc(e: ^Edit_Build) {
	a, b := e.a, e.b
	page := max(1, int((b.rect.max.y - b.rect.min.y - 2 * e.pad) / e.lh) - 1)
	shift := Mods{.Shift}
	for mods in ([?]Mods{{}, shift}) {
		ext := mods == shift
		t := text_edit_string(a)
		lo, hi := sel(a)
		if key_press(.Left, mods)  { edit_move(a, (lo != hi && !ext) ? lo : prev_index(t, a.cursor), ext) }
		if key_press(.Right, mods) { edit_move(a, (lo != hi && !ext) ? hi : next_index(t, a.cursor), ext) }
		if key_press(.Up, mods)    { edit_vertical(e, -1, ext) }
		if key_press(.Down, mods)  { edit_vertical(e, 1, ext) }
		if key_press(.Page_Up, mods)   { edit_vertical(e, -page, ext) }
		if key_press(.Page_Down, mods) { edit_vertical(e, page, ext) }
		home, end := key_press(.Home, mods), key_press(.End, mods)   // (a key_press takes its event)
		if home || end {
			// the visual line's ends; Home on a paragraph's first line: its first non-blank character, then its start
			vl := edit_lines(e)
			l := vl[visual_line_of(vl, a.cursor, a.upstream)]
			if home {
				nb := l.start
				if l.first { for nb < l.end && t[nb] == ' ' { nb += 1 } }
				edit_move(a, a.cursor == nb ? l.start : nb, ext)
			} else {
				edit_move(a, l.end, ext, l.soft)
			}
		}
	}
	cs := Mods{.Ctrl, .Shift}
	for mods in ([?]Mods{{.Ctrl}, cs}) {
		ext := mods == cs
		t := text_edit_string(a)
		if key_press(.Left, mods)  { edit_move(a, word_left(t, a.cursor), ext) }
		if key_press(.Right, mods) { edit_move(a, word_right(t, a.cursor), ext) }
		if key_press(.Home, mods)  { edit_move(a, 0, ext) }
		if key_press(.End, mods)   { edit_move(a, len(a.buf), ext) }
	}
}

// Backspace and Delete: the selection, else a cluster, or a word with Ctrl. Nothing to delete is no edit.
@(private="file")
edit_keys_deleting :: proc(e: ^Edit_Build) {
	a := e.a
	if (key_press(.Backspace) || key_press(.Backspace, {.Shift})) && (a.cursor != a.mark || a.cursor > 0) {
		lo, hi := sel(a)
		begin_edit(a, .Delete, e.now)
		if lo != hi { delete_range(a, lo, hi) } else { p := prev_index(text_edit_string(a), a.cursor); delete_range(a, p, a.cursor) }
		a.upstream = false
	}
	if key_press(.Delete) && (a.cursor != a.mark || a.cursor < len(a.buf)) {
		lo, hi := sel(a)
		begin_edit(a, .Delete, e.now)
		if lo != hi { delete_range(a, lo, hi) } else { n := next_index(text_edit_string(a), a.cursor); delete_range(a, a.cursor, n) }
		a.upstream = false
	}
	if key_press(.Backspace, {.Ctrl}) && (a.cursor != a.mark || a.cursor > 0) {
		lo, hi := sel(a)
		begin_edit(a, .Other, e.now)
		if lo != hi { delete_range(a, lo, hi) } else { delete_range(a, word_left(text_edit_string(a), a.cursor), a.cursor) }
		a.upstream = false
	}
	if key_press(.Delete, {.Ctrl}) && (a.cursor != a.mark || a.cursor < len(a.buf)) {
		lo, hi := sel(a)
		begin_edit(a, .Other, e.now)
		if lo != hi { delete_range(a, lo, hi) } else { delete_range(a, a.cursor, word_right(text_edit_string(a), a.cursor)) }
		a.upstream = false
	}
}

// Select all, copy, cut, paste (line ends and tabs made the editor's). Copy, cut and paste have their IBM chords too
// (Ctrl+Insert, Shift+Delete, Shift+Insert), as a line edit and a terminal have: one set of keys wherever text is typed.
@(private="file")
edit_keys_clipboard :: proc(e: ^Edit_Build) {
	a := e.a
	ctrl := Mods{.Ctrl}
	shift := Mods{.Shift}
	if key_press(.A, ctrl) { text_edit_select_all(a) }
	if key_press(.C, ctrl) || key_press(.Insert, ctrl) { _ = text_edit_copy(a) }
	if key_press(.X, ctrl) || key_press(.Delete, shift) { _ = text_edit_cut(a) }
	// (the text comes in a later build: edit_paste_answer)
	if key_press(.V, ctrl) || key_press(.Insert, {.Shift}) { paste_request(e.b.key, e.paste, e.paste_decode) }
}

// The text a paste asked for in an earlier build came: over the selection, in one undo step, before what was typed since.
@(private="file")
edit_paste_answer :: proc(e: ^Edit_Build) {
	a := e.a
	clip, ok := paste_answer(e.b.key, {.Text})
	if !ok { return }
	clean, _ := strings.replace_all(clip.text, "\r\n", "\n", context.temp_allocator)
	clean, _ = strings.replace_all(clean, "\r", "\n", context.temp_allocator)
	clean, _ = strings.replace_all(clean, "\t", "    ", context.temp_allocator)
	begin_edit(a, .Other, e.now)
	insert(a, clean)
	a.upstream = false
}

// The caret's rectangle, the scroll that keeps it in view, the scroll in range. Returns the content's size.
@(private="file")
edit_follow_caret :: proc(e: ^Edit_Build, auto_height, cursor_moved: bool) -> Vec2 {
	a, b, s := e.a, e.b, e.s
	gutter, pad, lh, wrap_w := e.gutter, e.pad, e.lh, e.wrap_w
	lines := e.lines
	text := text_edit_string(a)
	cur_line := visual_line_of(lines, a.cursor, a.upstream)
	if !(lines[cur_line].soft && lines[cur_line].end == a.cursor) { a.upstream = false }   // only the end of a wrapped line has two places
	view_w := max(TEXT_VIEW_MIN_PX * s.scale, (b.rect.max.x - b.rect.min.x) - gutter - 2 * pad - e.room.x)
	view_h := max(TEXT_VIEW_MIN_PX * s.scale, (b.rect.max.y - b.rect.min.y) - 2 * pad - e.room.y)
	if auto_height { view_h = max(TEXT_VIEW_MIN_PX * s.scale, b.pref[.Y].value - 2 * pad - e.room.y) }   // the height this build asks for, not last frame's
	ext := content_extent(a, text, b, lh, lines, wrap_w)
	cx := caret_x_on(text, lines[cur_line], b, a.cursor)
	cy := f32(cur_line) * lh
	e.res.caret = {{gutter + pad + cx - a.scroll.x, pad + cy - a.scroll.y}, {gutter + pad + cx - a.scroll.x + 1, pad + cy - a.scroll.y + lh}}
	if cursor_moved {
		if wrap_w <= 0 {
			if cx - a.scroll.x > view_w - end_slack() { a.scroll.x = cx - view_w + end_slack() }
			if cx - a.scroll.x < 0 { a.scroll.x = cx }
		}
		if cy - a.scroll.y < 0 { a.scroll.y = cy }
		if cy + lh - a.scroll.y > view_h { a.scroll.y = cy + lh - view_h }
	}
	a.scroll.x = wrap_w > 0 ? 0 : clamp(a.scroll.x, 0, max(0, ext.x + end_slack() - view_w))
	a.scroll.y = clamp(a.scroll.y, 0, max(0, ext.y - view_h))
	return ext
}

// What text_edit_draw reads, the paragraph under the pointer, what screen readers read.
@(private="file")
edit_fill_draw :: proc(e: ^Edit_Build, content: Vec2, placeholder: string, mono: font.Font_Id, highlight: ^Text_Highlight) {
	s, a, b, res := e.s, e.a, e.b, e.res
	gutter, pad, lh := e.gutter, e.pad, e.lh
	lines := e.lines
	d := frame_new(Text_Edit_Draw)
	d.area = a
	d.text = strings.clone(text_edit_string(a), frame_allocator())
	d.lines = make([]Visual_Line, len(lines), frame_allocator())
	copy(d.lines, lines)
	d.placeholder = placeholder
	d.cursor, d.mark, d.upstream, d.scroll = a.cursor, a.mark, a.upstream, a.scroll
	d.focused = res.focused
	since := e.now - a.edited_ms
	d.caret_on = !s.inactive && (since < CARET_SOLID_MS || (int(since) / CARET_BLINK_MS) % 2 == 0)
	d.gutter, d.pad, d.line_h = gutter, pad, lh
	d.selection = color("selection")
	d.caret = color("cursor")
	if tags("weak") { d.weak = color("text") }
	d.gutter_bg = color("background")
	d.gutter_bg.a *= TEXT_EDIT_GUTTER_BG_ALPHA_FACTOR
	d.gutter_bg = tuned(d.gutter_bg)
	d.gutter_line = color("border")
	d.mono = mono
	d.highlight = highlight
	d.error_color = tuned(TEXT_EDIT_ERROR_COLOR)
	if highlight != nil && res.hovering && a.sb_drag == .None {
		li := int((res.mouse.y - pad + a.scroll.y) / lh)
		if li >= 0 && li < len(lines) { res.hover_line = lines[li].para }
	}
	d.bars = editor_bars(b.rect, gutter, pad, scrollbar_inset(s, b), border_inset(b), e.room, content, a.scroll, e.wrap_w > 0)
	d.room = e.room
	// each bar's state: lit under the pointer or held (also with the pointer gone off it), its part under the pointer
	mpos := b.rect.min + res.mouse
	under := res.hovering ? editor_bar_under(d.bars, e.room, mpos) : Text_Scrollbar.None
	for which in ([2]Text_Scrollbar{.Vertical, .Horizontal}) {
		held := a.sb_drag == which
		hot := under == which && (a.sb_drag == .None || held)
		look := &d.bar_looks[which]
		look.lit = hot || held
		if held { look.held = a.sb_part }
		if hot { look.hot = scrollbar_part_at(which == .Vertical ? d.bars.v : d.bars.h, mpos) }
	}
	if under != .None || a.sb_drag != .None { s.cursor_request = .Arrow }
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

