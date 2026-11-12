package term

// The grid in a build: a box that takes the keyboard and scrolls over a space as tall as the scrollback (its scroll bar is
// the toolkit's, held and pressed in its track like every list's), and the rows drawn in it.

import "core:math"
import "../draw"
import "../font"
import "../ui"

// Builds the grid, all the room it is given. `take_focus`: the program asks that it has the keyboard (a press on it takes
// it anyway). Its id is "###term_box".
build :: proc(v: ^View, style: Style, take_focus := false) -> (b: ^ui.Box, sig: ui.Signal) {
	v.style = style
	ui.next({width = ui.fill(), height = ui.fill(), cursor = .Text})
	b = ui.build_box({.Clickable, .Focusable, .Clip, .View_Scroll_Y, .View_Clamp_Y}, "###term_box")
	sig = ui.signal(b)
	if sig.pressed || take_focus { ui.set_focus(b.key) }
	v.box, v.rect, v.focused = b.key, b.rect, ui.focus_key() == b.key
	metrics_set(v)
	fit(v, b.rect)
	v.origin = grid_origin(v, b.rect)
	scroll_sync(v, b)
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
	m := &v.metrics
	at :: proc(origin: f32, col: u16, w: f32) -> f32 { return origin + f32(col) * w }
	for &r, y in v.lines {
		top := origin.y + f32(y) * m.cell_h
		for f in r.fills {
			draw.rect(dc, {{at(origin.x, f.from, m.cell_w), top}, {at(origin.x, f.to, m.cell_w), top + m.cell_h}}, f.selected ? st.selection : f.color)
		}
		for k in r.marks {
			lo := k.strike ? top + m.cell_h * 0.55 : top + m.ascent + 1
			draw.rect(dc, {{at(origin.x, k.from, m.cell_w), lo}, {at(origin.x, k.to, m.cell_w), lo + 1}}, k.color)
		}
		// (each letter a cell wide: at the face's own advance a run fell behind the grid, and the next run, at its cell,
		// left a gap after every change of colour)
		for run in r.runs {
			text := string(r.text[run.from:run.to])
			face := run.bold ? st.font_bold : st.font
			draw.text_ex(dc, face, m.font_size, {at(origin.x, run.col, m.cell_w), top + m.ascent}, run.color, text, {letter_spacing = run.bold ? m.spacing_bold : m.spacing})
		}
	}
	draw_cursor(v, dc, origin)
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
