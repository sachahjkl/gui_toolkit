package term

// The grid in a build: a box that takes the keyboard and scrolls over a space as tall as the scrollback (its scroll bar is
// the toolkit's, held and pressed in its track like every list's), and the rows drawn in it.

import "core:math"
import "../draw"
import "../font"
import "../ui"

// Builds the grid, all the room it is given. `take_focus`: the program asks that it has the keyboard (a press on it takes
// it anyway). Its id is "###term_box". The box is the zoom zone `v.zone`, showing `zoom_key` (a shell's id: with a
// memory in the zone, each shell keeps its zoom; "" its own).
build :: proc(v: ^View, style: Style, take_focus := false, zoom_key := "") -> (b: ^ui.Box, sig: ui.Signal) {
	v.style = style
	ui.zoom_zone(&v.zone, zoom_key)
	zoom_follow(v)
	// (the grid takes its new size once the zoom rests: a frame then, with no input to wake it)
	if s := ui.current_state(); s != nil && v.zoom_ms != 0 {
		if left := ZOOM_REST_MS - (ui.now_ms() - v.zoom_ms); left > 0 { ui.wake_within(s, int(math.ceil(left)) + 1) }
	}
	ui.next({width = ui.fill(), height = ui.fill(), cursor = .Text})
	b = ui.build_box({.Clickable, .Focusable, .Clip, .View_Scroll_Y, .View_Clamp_Y}, "###term_box")
	sig = ui.signal(b)
	if sig.pressed || take_focus { ui.set_focus(b.key) }
	v.box, v.rect, v.focused = b.key, b.rect, ui.focus_key() == b.key
	metrics_set(v)
	fit(v, b.rect)
	v.origin = grid_origin(v, b.rect)
	scroll_sync(v, b)
	// a selection's drag near or past the top or the bottom scrolls the scrollback, and reaches the rows that come
	if v.press == .Select {
		ui.drag_autoscroll(b.key, .Y)
		select_to(v, cell_at(v, ui.mouse_pos()))
	}
	// (the space the box scrolls over: the view its part, the bar's thumb)
	if ui.parent(b) {
		ui.next({width = ui.fill(), height = ui.px(scroll_height(v, b))})
		ui.build_box({}, "###term_space")
	}
	b.custom, b.custom_user = draw_view, v
	return
}

// (a face's size and the cell it makes: each build, a few measures of one letter)
@(private)
metrics_set :: proc(v: ^View) {
	st := &v.style
	m := &v.metrics
	m.font_size = math.round(st.font_size * v.zoom)
	if st.fonts == nil { return }
	advance := font.text_width(st.fonts, st.font, m.font_size, "M")
	m.cell_w = math.ceil(advance)
	m.spacing = m.cell_w - advance
	m.spacing_bold = m.cell_w - font.text_width(st.fonts, st.font_bold, m.font_size, "M")
	fm := font.metrics(st.fonts, st.font, m.font_size)
	m.cell_h = math.ceil(fm.line_height)
	m.ascent = fm.ascent
}

// The grid follows its box: as many cells as it holds. A zoom that moves keeps the size the grid has, drawn in the new
// cells, until it rests (ZOOM_REST_MS).
@(private)
fit :: proc(v: ^View, r: draw.Rect) {
	m := &v.metrics
	if m.cell_w <= 0 || r.max.x - r.min.x < 1 { return }
	if v.fitted && v.zoom_ms != 0 && ui.now_ms() - v.zoom_ms < ZOOM_REST_MS { return }
	pad := v.style.pad
	cols := int(clamp((r.max.x - r.min.x - 2 * pad) / m.cell_w, 2, 1000))
	rows := int(clamp((r.max.y - r.min.y - 2 * pad) / m.cell_h, 2, 1000))
	size_set(v, cols, rows, {int(m.cell_w), int(m.cell_h)})
}

// Where the cells start in `r`: the grid centered in it. The box holds whole cells; what is left of a cell, and the pad, goes
// half on each side, not all under the last row (an empty band at the bottom that the prompt never reached). Whole pixels:
// a cell's edges stay on the pixel grid.
grid_origin :: proc(v: ^View, r: draw.Rect) -> [2]f32 {
	m := &v.metrics
	w, h := f32(v.cols) * m.cell_w, f32(v.rows) * m.cell_h
	// (a grid larger than its box, a zoom that moves: from its top left, as the cells have no room to be centered in)
	x := max(math.floor((r.max.x - r.min.x - w) * 0.5), v.style.pad)
	y := max(math.floor((r.max.y - r.min.y - h) * 0.5), v.style.pad)
	if w + 2 * v.style.pad > r.max.x - r.min.x { x = v.style.pad }
	if h + 2 * v.style.pad > r.max.y - r.min.y { y = v.style.pad }
	return r.min + {x, y}
}

// The grid's size in cells, told to the source (the build does it; a test, or a program that lays the grid out itself).
size_set :: proc(v: ^View, cols, rows: int, cell: [2]int) {
	changed := cols != v.cols || rows != v.rows
	v.cols, v.rows, v.fitted = cols, rows, true
	if v.source.resize != nil { v.source.resize(v.source.data, cols, rows, cell, changed) }
}

// How tall the space the box scrolls over is: the box as many times as the scrollback holds the rows shown.
@(private)
scroll_height :: proc(v: ^View, b: ^ui.Box) -> f32 {
	h := max(b.size.y, 1)
	bar, ok := scrollbar(v)
	if !ok || bar.total <= bar.len || bar.len == 0 { return h }
	return h * f32(bar.total) / f32(bar.len)
}

// The box's scroll and the rows shown, together: the bar moved (held, pressed in its track) moves the rows to where it
// says; else the rows (the wheel, what the program writes, Shift+Page Up) put the box's scroll where they are.
@(private)
scroll_sync :: proc(v: ^View, b: ^ui.Box) {
	bar, ok := scrollbar(v)
	if !ok || bar.total <= bar.len { v.bar_at = 0; return }
	limit := ui.view_limit(b)
	if limit <= 0 { return }
	room := f32(bar.total - bar.len)
	if abs(b.view_target.y - v.bar_at) > 0.5 {
		want := int(math.round(clamp(b.view_target.y / limit, 0, 1) * room))
		scroll(v, want - bar.offset)
		v.bar_at = b.view_target.y
		return
	}
	y := limit * f32(bar.offset) / room
	ui.view_jump(b, y)
	v.bar_at = y
}

@(private)
draw_view :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	v := (^View)(user)
	st := &v.style
	draw.rect(dc, b.rect, st.background)
	if !refresh(v) { return }
	origin := grid_origin(v, b.rect)   // (this frame's rect: the build's may be a layout old)
	v.draws += 1
	m := &v.metrics
	// (a row recorded within one pixel and replayed moved by whole pixels: its glyphs land on the sub-pixel positions a
	// direct draw gives them)
	whole := [2]f32{math.floor(origin.x), math.floor(origin.y)}
	frac := origin - whole
	look := row_look(v, frac)
	for &r, y in v.lines {
		if len(r.runs) == 0 && len(r.fills) == 0 && len(r.marks) == 0 { continue }
		at := draw.affine_translate({whole.x, whole.y + f32(y) * m.cell_h})
		pic := row_picture(v, dc, &r, sum_mix(look, r.sum), frac)
		// (an atlas page reused under it: recorded again, once; still stale, it is drawn under a scale, as a dialog grows
		// in: drawn directly rather than recorded at every frame of the animation)
		if draw.replay(dc, pic, at) == .Stale {
			row_record(v, dc, pic, &r, frac)
			if draw.replay(dc, pic, at) == .Stale { row_paint(v, dc, &r, origin + {0, f32(y) * m.cell_h}) }
		}
	}
	// (what no row showed goes: rows scrolled away, rows written over)
	gone := make([dynamic]u64, 0, 16, context.temp_allocator)
	for key, kept in v.pictures { if kept.used != v.draws { append(&gone, key) } }
	for key in gone {
		pic := v.pictures[key].pic
		delete_key(&v.pictures, key)
		if len(v.spare) < len(v.lines) {
			draw.picture_release(pic)
			append(&v.spare, pic)
		} else {
			picture_free(v, pic)
		}
	}
	draw_cursor(v, dc, origin)
}

// A row's picture kept between draws.
Row_Picture :: struct {
	pic:  ^draw.Picture,   // (on the heap: a context keeps its address while it holds its ranges)
	used: u64,             // View.draws when a row last showed it
}

// The picture of a row of this content under this look: the one a row of the same cells had (the rows moved up a line,
// the same line again), else recorded now.
@(private)
row_picture :: proc(v: ^View, dc: ^draw.Context, r: ^Row, key: u64, frac: [2]f32) -> ^draw.Picture {
	if kept, ok := &v.pictures[key]; ok {
		kept.used = v.draws
		return kept.pic
	}
	pic := len(v.spare) > 0 ? pop(&v.spare) : new(draw.Picture, v.lines.allocator)
	row_record(v, dc, pic, r, frac)
	v.pictures[key] = {pic, v.draws}
	return pic
}

// What decides how a row's cells look, other than its cells: the faces, their size, the cell, the selection's colour,
// where the grid starts within a pixel.
@(private)
row_look :: proc(v: ^View, frac: [2]f32) -> u64 {
	m, st := &v.metrics, &v.style
	h: u64 = 0xcbf29ce484222325
	for x in ([?]f32{m.font_size, m.cell_w, m.cell_h, m.ascent, m.spacing, m.spacing_bold, frac.x, frac.y,
			st.selection.r, st.selection.g, st.selection.b, st.selection.a}) {
		h = sum_mix(h, u64(transmute(u32)x))
	}
	h = sum_mix(h, u64(uintptr(st.fonts)))
	return sum_mix(h, u64(st.font) | u64(st.font_bold) << 32)
}

@(private)
row_record :: proc(v: ^View, dc: ^draw.Context, pic: ^draw.Picture, r: ^Row, frac: [2]f32) {
	v.rows_recorded += 1
	draw.picture_begin(dc, pic)
	row_paint(v, dc, r, frac)
	draw.picture_end(dc)
}

// The row's fills, marks and runs, its top left at `pos`.
@(private)
row_paint :: proc(v: ^View, dc: ^draw.Context, r: ^Row, pos: [2]f32) {
	st, m := &v.style, &v.metrics
	at :: proc(origin: f32, col: u16, w: f32) -> f32 { return origin + f32(col) * w }
	top := pos.y
	for f in r.fills {
		draw.rect(dc, {{at(pos.x, f.from, m.cell_w), top}, {at(pos.x, f.to, m.cell_w), top + m.cell_h}}, f.selected ? st.selection : f.color)
	}
	for k in r.marks {
		lo := k.strike ? top + m.cell_h * 0.55 : top + m.ascent + 1
		draw.rect(dc, {{at(pos.x, k.from, m.cell_w), lo}, {at(pos.x, k.to, m.cell_w), lo + 1}}, k.color)
	}
	// (each letter a cell wide: at the face's own advance a run fell behind the grid, and the next run, at its cell,
	// left a gap after every change of colour)
	for run in r.runs {
		text := string(r.text[run.from:run.to])
		face := run.bold ? st.font_bold : st.font
		draw.text_ex(dc, face, m.font_size, {at(pos.x, run.col, m.cell_w), top + m.ascent}, run.color, text, {letter_spacing = run.bold ? m.spacing_bold : m.spacing})
	}
}

@(private)
picture_free :: proc(v: ^View, pic: ^draw.Picture) {
	draw.picture_destroy(pic)
	free(pic, v.lines.allocator)
}

// Solid with the keyboard (in the shape the program asked for), hollow without it.
@(private)
draw_cursor :: proc(v: ^View, dc: ^draw.Context, origin: [2]f32) {
	c := v.picture.cursor
	if !c.shown { return }
	m := &v.metrics
	left, top := origin.x + f32(c.x) * m.cell_w, origin.y + f32(c.y) * m.cell_h
	r := draw.Rect{{left, top}, {left + m.cell_w, top + m.cell_h}}
	color := c.color
	t1 := max(1, math.round(ui.scale()))   // (a device pixel)
	switch {
	case !v.focused:
		draw.rect(dc, {r.min, {r.max.x, r.min.y + t1}}, color)
		draw.rect(dc, {{r.min.x, r.max.y - t1}, r.max}, color)
		draw.rect(dc, {r.min, {r.min.x + t1, r.max.y}}, color)
		draw.rect(dc, {{r.max.x - t1, r.min.y}, r.max}, color)
	case c.shape == .Bar:       draw.rect(dc, {r.min, {r.min.x + 2 * t1, r.max.y}}, color)
	case c.shape == .Underline: draw.rect(dc, {{r.min.x, r.max.y - 2 * t1}, r.max}, color)
	case:
		color.a *= v.style.cursor_alpha
		draw.rect(dc, r, color)
	}
}
