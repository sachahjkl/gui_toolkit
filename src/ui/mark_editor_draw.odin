package ui

// The canvas of ui.Mark_Editor: the picture, the shapes as their figures (gt:marks: the same geometry the flattening
// fills), the texts' letters, the mosaics and blurred copies, then the crop, the selection and its handles. The figures
// are made again here, in the draw, when the model changed: the draw comes after every change of the build, so no
// figure points at a pen's ink that an undo of this build freed.

import "core:math"
import "core:mem/virtual"
import "core:strings"
import "../draw"
import "../font"
import marks "../marks"
import "../render"

@(private = "file") MARK_HANDLE_SIDE :: 8     // a handle's side, logical pixels
@(private = "file") MARK_CROP_DIM :: 0.55     // how dark the picture is outside the crop
// gt:draw's polygon fill takes this many points at most: a longer ink is drawn as its triangles
@(private = "file") MARK_FILL_POINTS_MOST :: 4000

// A figure's colour (straight sRGB) for gt:draw.
@(private = "file")
mark_draw_color :: proc(c: [4]f32) -> draw.Color { return draw.srgb(c[0], c[1], c[2], c[3]) }

@(private)
mark_editor_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	e := (^Mark_Editor)(user)
	if e.picture == nil { return }   // (destroyed in this build: its dialog answered)
	m := &e.model
	v := m.view
	mark_figures_follow(e)
	if dc.renderer != nil && e.renderer == nil { e.renderer = dc.renderer }
	// (the picture's texture at its first draw: the draw has the renderer, the build has not)
	if e.texture == 0 && !e.refused && dc.renderer != nil {
		mx := render.max_texture_size(dc.renderer)
		if e.size.x > mx || e.size.y > mx {
			e.refused = true
		} else {
			e.texture = render.create_texture_rgba(dc.renderer, e.size.x, e.size.y)
			if e.texture == 0 { e.refused = true } else { render.update_texture_rgba(dc.renderer, e.texture, 0, 0, e.size.x, e.size.y, e.picture.rgba) }
		}
	}
	origin := v.canvas.min + v.offset
	pr := draw.Rect{origin, origin + m.doc.size * v.zoom}
	if e.texture != 0 { draw.image(dc, e.texture, pr) } else { draw.rect(dc, pr, {0.5, 0.5, 0.5, 1}) }
	typing, is_typing := marks.typing_index(m)
	for &s, i in m.doc.shapes {
		if is_typing && i == typing { continue }   // (its field shows it)
		if i < len(e.ranges) {
			r := e.ranges[i]
			for &f in e.figures[r[0]:r[1]] { mark_draw_figure(dc, &f, v) }
		}
		#partial switch s.kind {
		case .Text:     mark_draw_text(dc, e, &s)
		case .Pixelate: mark_draw_mosaic(dc, e, &s)
		case .Blur:     mark_draw_blur(dc, e, &s)
		}
	}
	mark_draw_crop(dc, e)
	mark_draw_selection(dc, e)
}

// The figures of the shapes, made again when the model changed (its changes counter moved), in an arena of their own.
@(private = "file")
mark_figures_follow :: proc(e: ^Mark_Editor) {
	m := &e.model
	if e.figures_made && e.figures_changes == m.changes { return }
	e.figures_made, e.figures_changes = true, m.changes
	virtual.arena_free_all(&e.figure_arena)
	clear(&e.figures)
	clear(&e.ranges)
	a := virtual.arena_allocator(&e.figure_arena)
	for &s in m.doc.shapes {
		start := len(e.figures)
		marks.figures(&m.doc, &s, &e.figures, a)
		append(&e.ranges, [2]int{start, len(e.figures)})
	}
}

@(private = "file")
mark_draw_figure :: proc(dc: ^draw.Context, f: ^marks.Figure, v: marks.View) {
	color := mark_draw_color(f.color)
	if f.kind == .Fill && len(f.points) > MARK_FILL_POINTS_MOST && f.triangles != nil {
		for t in f.triangles { draw.triangle(dc, marks.to_window(v, t[0]), marks.to_window(v, t[1]), marks.to_window(v, t[2]), color) }
		return
	}
	path := draw.path_make(allocator = context.temp_allocator)
	for p, i in f.points {
		q := marks.to_window(v, p)
		if i == 0 { draw.path_move_to(&path, q) } else { draw.path_line_to(&path, q) }
	}
	switch f.kind {
	case .Fill:
		draw.path_close(&path)
		draw.path_fill(dc, &path, color)
	case .Stroke:
		if f.closed { draw.path_close(&path) }
		draw.path_stroke(dc, &path, max(f.width * v.zoom, 1), color)
	}
}

// A text, line by line: its letters alone, with an outline under them, or on its box (a figure, drawn before).
@(private = "file")
mark_draw_text :: proc(dc: ^draw.Context, e: ^Mark_Editor, s: ^marks.Shape) {
	if e.fonts == nil || e.face == 0 { return }
	m := &e.model
	size := marks.text_px(&m.doc, s) * m.view.zoom
	if size < 1 { return }
	face := mark_face(e, s.style.bold)
	color := mark_draw_color(marks.color_of(s.style.color))
	under := mark_draw_color(marks.text_under(s.style))
	fm := font.metrics(e.fonts, face, size)
	at := marks.to_window(m.view, s.a)
	y := at.y + fm.ascent
	rest := s.text
	for {
		nl := strings.index_byte(rest, '\n')
		line := nl < 0 ? rest : rest[:nl]
		if s.style.text_look == .Outline {
			sh := font.shape(e.fonts, face, size, line, {}, context.temp_allocator)
			draw.glyph_run_stroke(dc, size, {at.x, y}, under, sh.glyphs, size * marks.TEXT_OUTLINE)
			draw.glyph_run(dc, size, {at.x, y}, color, sh.glyphs)
		} else {
			draw.text(dc, face, size, {at.x, y}, color, line)
		}
		if nl < 0 { break }
		rest = rest[nl + 1:]
		y += fm.line_height
	}
}

// The box within the picture (a part outside it has nothing to hide); ok false: nothing of it is inside.
@(private = "file")
mark_picture_cut :: proc(m: ^marks.Model, box: marks.Box) -> (r: marks.Box, ok: bool) {
	r = {{max(box.min.x, 0), max(box.min.y, 0)}, {min(box.max.x, m.doc.size.x), min(box.max.y, m.doc.size.y)}}
	return r, r.max.x > r.min.x && r.max.y > r.min.y
}

@(private = "file")
mark_window_rect :: proc(v: marks.View, r: marks.Box) -> draw.Rect {
	return {marks.to_window(v, r.min), marks.to_window(v, r.max)}
}

// The cells of the mosaic that the box covers, each cut by the box; a flat grey until the mosaic is made.
@(private = "file")
mark_draw_mosaic :: proc(dc: ^draw.Context, e: ^Mark_Editor, s: ^marks.Shape) {
	m := &e.model
	r, inside := mark_picture_cut(m, marks.box_of(s.a, s.b))
	if !inside { return }
	cell := marks.pixel_cell(&m.doc, s.style)
	mos: ^marks.Mosaic
	for &f in e.filters { if !f.blur && f.amount == cell && len(f.mosaic.colors) > 0 { mos = &f.mosaic } }
	if mos == nil {
		draw.rect(dc, mark_window_rect(m.view, r), {0.5, 0.5, 0.5, 1})
		return
	}
	c := f32(mos.cell)
	x0, y0 := clamp(int(r.min.x / c), 0, mos.cols - 1), clamp(int(r.min.y / c), 0, mos.rows - 1)
	x1, y1 := clamp(int(math.ceil(r.max.x / c)), x0 + 1, mos.cols), clamp(int(math.ceil(r.max.y / c)), y0 + 1, mos.rows)
	// (each cell a hair larger on its right and bottom: no seam shows between two at a fractional zoom)
	seam := 0.5 / m.view.zoom
	for gy in y0 ..< y1 {
		for gx in x0 ..< x1 {
			cb := marks.Box{{f32(gx) * c, f32(gy) * c}, {f32(gx + 1) * c + seam, f32(gy + 1) * c + seam}}
			cut := marks.Box{{max(cb.min.x, r.min.x), max(cb.min.y, r.min.y)}, {min(cb.max.x, r.max.x), min(cb.max.y, r.max.y)}}
			if cut.max.x <= cut.min.x || cut.max.y <= cut.min.y { continue }
			k := mos.colors[gy * mos.cols + gx]
			draw.rect(dc, mark_window_rect(m.view, cut), draw.srgb(f32(k[0]) / 255, f32(k[1]) / 255, f32(k[2]) / 255))
		}
	}
}

// The blurred copy under the box, stretched back to the picture's pixels; a flat grey until it is made.
@(private = "file")
mark_draw_blur :: proc(dc: ^draw.Context, e: ^Mark_Editor, s: ^marks.Shape) {
	m := &e.model
	r, inside := mark_picture_cut(m, marks.box_of(s.a, s.b))
	if !inside { return }
	radius := marks.blur_px(&m.doc, s.style)
	for &f in e.filters {
		if !f.blur || f.amount != radius || len(f.blurred.pixels) == 0 { continue }
		if f.texture == 0 && dc.renderer != nil {
			w, h := f.blurred.size.x, f.blurred.size.y
			f.texture = render.create_texture_rgba(dc.renderer, w, h)
			if f.texture != 0 { render.update_texture_rgba(dc.renderer, f.texture, 0, 0, w, h, f.blurred.pixels) }
		}
		if f.texture == 0 { break }
		c := f32(f.blurred.cell)
		draw.image(dc, f.texture, mark_window_rect(m.view, r), {r.min / c, r.max / c})
		return
	}
	draw.rect(dc, mark_window_rect(m.view, r), {0.5, 0.5, 0.5, 1})
}

// Outside the crop, the picture darker; with the Crop tool, the crop's handles.
@(private = "file")
mark_draw_crop :: proc(dc: ^draw.Context, e: ^Mark_Editor) {
	m := &e.model
	if !m.doc.has_crop { return }
	v := m.view
	pic := mark_window_rect(v, {{0, 0}, m.doc.size})
	cr := mark_window_rect(v, m.doc.crop)
	dim := draw.Color{0, 0, 0, MARK_CROP_DIM}
	draw.rect(dc, {pic.min, {pic.max.x, cr.min.y}}, dim)
	draw.rect(dc, {{pic.min.x, cr.max.y}, pic.max}, dim)
	draw.rect(dc, {{pic.min.x, cr.min.y}, {cr.min.x, cr.max.y}}, dim)
	draw.rect(dc, {{cr.max.x, cr.min.y}, {pic.max.x, cr.max.y}}, dim)
	draw.rect(dc, draw.rect_pad(cr, 0.5), {1, 1, 1, 0.9}, 0, max(e.ui_scale, 1))
	if m.tool == .Crop {
		at, has := marks.crop_handles(&m.doc)
		mark_draw_handles(dc, e, at, has)
	}
}

// The selection: a frame around each shape picked, and the handles of one alone; the box of a box selection.
@(private = "file")
mark_draw_selection :: proc(dc: ^draw.Context, e: ^Mark_Editor) {
	m := &e.model
	v := m.view
	k := max(e.ui_scale, 1)
	accent := e.accent
	if box, ok := marks.selecting_shown(m); ok {
		r := mark_window_rect(v, box)
		fill := accent
		fill.a = 0.15
		draw.rect(dc, r, fill)
		draw.rect(dc, r, accent, 0, k)
	}
	if !marks.idle(m) && !marks.has_selection(m) { return }
	if _, typing := m.mode.(marks.Typing); typing { return }
	for &s in m.doc.shapes {
		if !s.picked { continue }
		if m.doc.picked_count == 1 { break }
		r := mark_window_rect(v, marks.box_pad(marks.shape_box(&m.doc, &s), marks.stroke_px(&m.doc, &s) * 0.5))
		draw.rect(dc, draw.rect_pad(r, 2 * k), accent, 0, k)
	}
	if sel := marks.selected_shape(m); sel != nil && m.doc.picked_count == 1 && m.tool != .Crop {
		at, has := marks.handles(&m.doc, sel)
		mark_draw_handles(dc, e, at, has)
	}
}

@(private = "file")
mark_draw_handles :: proc(dc: ^draw.Context, e: ^Mark_Editor, at: [marks.Handle]marks.Vec, has: marks.Handles) {
	v := e.model.view
	k := max(e.ui_scale, 1)
	half := MARK_HANDLE_SIDE * k * 0.5
	for h in marks.Handle {
		if h not_in has { continue }
		c := marks.to_window(v, at[h])
		r := draw.Rect{c - half, c + half}
		draw.rect(dc, r, {1, 1, 1, 1}, half * 0.4)
		draw.rect(dc, r, e.accent, half * 0.4, k)
	}
}
