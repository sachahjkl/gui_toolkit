package tk_marks

// The geometry of the model: boxes, the view's two ways (window pixels, picture pixels), where a shape is, what a press
// touches, the handles.

import "core:math"
import "core:strings"
import turn "../turn"

box_of :: proc(a, b: Vec) -> Box {
	return {{min(a.x, b.x), min(a.y, b.y)}, {max(a.x, b.x), max(a.y, b.y)}}
}

box_size :: proc(r: Box) -> Vec { return r.max - r.min }

box_contains :: proc(r: Box, p: Vec) -> bool {
	return p.x >= r.min.x && p.x <= r.max.x && p.y >= r.min.y && p.y <= r.max.y
}

box_pad :: proc(r: Box, d: f32) -> Box { return {r.min - d, r.max + d} }

box_touches :: proc(r, s: Box) -> bool {
	return r.min.x <= s.max.x && s.min.x <= r.max.x && r.min.y <= s.max.y && s.min.y <= r.max.y
}

@(private)
length :: proc(v: Vec) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y) }

// The distance from p to the segment a-b.
@(private)
segment_distance :: proc(p, a, b: Vec) -> f32 {
	d := b - a
	l2 := d.x * d.x + d.y * d.y
	if l2 == 0 { return length(p - a) }
	t := clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2, 0, 1)
	return length(p - (a + d * t))
}

// p held to a square from a (Shift: a square, a circle).
square :: proc(a, p: Vec) -> Vec {
	d := p - a
	side := max(abs(d.x), abs(d.y))
	return a + {d.x < 0 ? -side : side, d.y < 0 ? -side : side}
}

// p turned around a to the nearest multiple of 45° (Shift: a line or an arrow straight or diagonal).
snap_45 :: proc(a, p: Vec) -> Vec {
	d := p - a
	l := length(d)
	if l == 0 { return p }
	step := f32(1.0 / 8)   // (turns)
	angle := math.round(turn.atan2(d.y, d.x) / step) * step
	s, c := turn.sincos(angle)
	return a + {c, s} * l
}

// Where each handle of a box is.
@(private)
box_handles :: proc(r: Box) -> (at: [Handle]Vec) {
	c := (r.min + r.max) * 0.5
	at[.Top_Left], at[.Top], at[.Top_Right] = r.min, {c.x, r.min.y}, {r.max.x, r.min.y}
	at[.Right], at[.Bottom_Right], at[.Bottom] = {r.max.x, c.y}, r.max, {c.x, r.max.y}
	at[.Bottom_Left], at[.Left] = {r.min.x, r.max.y}, {r.min.x, c.y}
	return
}

////////////////////////////////
// The view

to_picture :: proc(v: View, p: Vec) -> Vec { return (p - v.canvas.min - v.offset) / v.zoom }
to_window :: proc(v: View, p: Vec) -> Vec { return p * v.zoom + v.canvas.min + v.offset }

// The canvas box of this build (window pixels): a fitted picture is fitted again to it.
view_place :: proc(m: ^Model, canvas: Box) {
	if m.view.canvas != canvas { m.changes += 1 }
	m.view.canvas = canvas
	if m.view.fit { view_fit(m) }
}

// The whole picture in the canvas, centred, never enlarged past its own pixels.
view_fit :: proc(m: ^Model) {
	v := &m.view
	c := box_size(v.canvas)
	s := m.doc.size
	v.fit = true
	if s.x <= 0 || s.y <= 0 || c.x <= 0 || c.y <= 0 { return }
	v.zoom = clamp(min(c.x * FIT_MARGIN / s.x, c.y * FIT_MARGIN / s.y, 1), ZOOM_MIN, ZOOM_MAX)
	v.offset = (c - s * v.zoom) * 0.5
}

// Zooms by factor, keeping the picture's point under at (window pixels) where it is.
view_zoom :: proc(m: ^Model, factor: f32, at: Vec) {
	v := &m.view
	under := to_picture(v^, at)
	v.zoom = clamp(v.zoom * factor, ZOOM_MIN, ZOOM_MAX)
	v.offset = at - v.canvas.min - under * v.zoom
	v.fit = false
	m.changes += 1
}

// Zooms around the canvas's centre (Ctrl+=, Ctrl+-).
view_zoom_centre :: proc(m: ^Model, factor: f32) {
	view_zoom(m, factor, (m.view.canvas.min + m.view.canvas.max) * 0.5)
}

// The zoom set to zoom (1: a picture's pixel a pixel of the screen), around the canvas's centre.
view_zoom_to :: proc(m: ^Model, zoom: f32) {
	if m.view.zoom <= 0 { return }
	view_zoom_centre(m, zoom / m.view.zoom)
}

////////////////////////////////
// Shapes

// The fill colour of a style, 0xRRGGBB; ok false: none.
fill_of :: proc(style: Style) -> (rgb: u32, ok: bool) {
	return style.fill_color & 0xFFFFFF, style.fill_color >> 24 != 0
}

// A stroke's width in the picture's pixels.
stroke_px :: proc(doc: ^Doc, s: ^Shape) -> f32 { return s.style.width * doc.scale }

text_px :: proc(doc: ^Doc, s: ^Shape) -> f32 { return s.style.text_size * doc.scale }

// How far a text's outline or box reaches past its letters, picture pixels.
text_pad :: proc(doc: ^Doc, s: ^Shape) -> f32 {
	switch s.style.text_look {
	case .Plain:      return 0
	case .Outline:    return text_px(doc, s) * TEXT_OUTLINE * 0.5
	case .Background: return text_px(doc, s) * TEXT_BOX_PAD
	}
	return 0
}

// The box a shape covers, without its stroke's width (a text's with its outline or its box).
shape_box :: proc(doc: ^Doc, s: ^Shape) -> Box {
	#partial switch s.kind {
	case .Pen:
		if len(s.samples) == 0 { return {s.a, s.a} }
		r := Box{s.samples[0].at, s.samples[0].at}
		for p in s.samples[1:] { r = {{min(r.min.x, p.at.x), min(r.min.y, p.at.y)}, {max(r.max.x, p.at.x), max(r.max.y, p.at.y)}} }
		return r
	case .Text:
		return box_pad(box_of(s.a, s.b), text_pad(doc, s))
	}
	return box_of(s.a, s.b)
}

// The size of a shape's text, line by line (an empty last line too: a line just begun with Shift+Enter has its room).
@(private)
text_size_of :: proc(doc: ^Doc, s: ^Shape) -> Vec {
	px := text_px(doc, s)
	size := Vec{1, 0}
	rest := s.text
	for {
		nl := strings.index_byte(rest, '\n')
		line := nl < 0 ? rest : rest[:nl]
		v := Vec{f32(len(line)) * px * 0.5, px}
		if doc.measure != nil { v = doc.measure(doc.user, line, px, s.style.bold) }
		size = {max(size.x, v.x), size.y + v.y}
		if nl < 0 { break }
		rest = rest[nl + 1:]
	}
	return {max(size.x, 1), max(size.y, 1)}
}

// Whether p (picture pixels) touches the shape, tolerance picture pixels around its stroke.
shape_hit :: proc(doc: ^Doc, s: ^Shape, p: Vec, tolerance: f32) -> bool {
	half := stroke_px(doc, s) * 0.5 + tolerance
	_, filled := fill_of(s.style)
	switch s.kind {
	case .Rectangle:
		r := box_of(s.a, s.b)
		if filled { return box_contains(box_pad(r, half), p) }
		return box_contains(box_pad(r, half), p) && !box_contains(box_pad(r, -half), p)
	case .Ellipse:
		r := box_of(s.a, s.b)
		c := (r.min + r.max) * 0.5
		radii := box_size(r) * 0.5
		if radii.x < 1 || radii.y < 1 { return segment_distance(p, r.min, r.max) <= half }
		d := length((p - c) / radii)
		if filled { return d <= 1 + half / min(radii.x, radii.y) }
		return abs(d - 1) * min(radii.x, radii.y) <= half
	case .Arrow, .Line:
		return segment_distance(p, s.a, s.b) <= half
	case .Pen:
		n := len(s.samples)
		if n == 1 { return length(p - s.samples[0].at) <= half }
		for i in 1 ..< n { if segment_distance(p, s.samples[i - 1].at, s.samples[i].at) <= half { return true } }
		return false
	case .Text, .Highlighter, .Pixelate, .Blur:
		return box_contains(box_pad(shape_box(doc, s), tolerance), p)
	}
	return false
}

// The topmost shape under p (picture pixels), or -1.
hit :: proc(doc: ^Doc, p: Vec, tolerance: f32) -> int {
	#reverse for &s, i in doc.shapes[:] { if shape_hit(doc, &s, p, tolerance) { return i } }
	return -1
}

// The handles a shape has, and where each is (picture pixels).
handles :: proc(doc: ^Doc, s: ^Shape) -> (at: [Handle]Vec, has: Handles) {
	switch s.kind {
	case .Rectangle, .Ellipse, .Highlighter, .Pixelate, .Blur:
		at = box_handles(box_of(s.a, s.b))
		has = BOX_HANDLES
	case .Arrow, .Line:
		at[.Start], at[.End] = s.a, s.b
		has = LINE_HANDLES
	case .Text, .Pen:
		at[.Scale] = shape_box(doc, s).max
		has = {.Scale}
	}
	return
}

// The handle of the selected shape under p (picture pixels), within tolerance: when one shape is picked (the handles
// of several would be in each other's way).
handle_hit :: proc(doc: ^Doc, p: Vec, tolerance: f32) -> Handle {
	if doc.selected < 0 || doc.selected >= len(doc.shapes) || doc.picked_count != 1 { return .None }
	at, has := handles(doc, &doc.shapes[doc.selected])
	for h in Handle {
		if h in has && abs(p.x - at[h].x) <= tolerance && abs(p.y - at[h].y) <= tolerance { return h }
	}
	return .None
}

// The crop's handles (with the Crop tool, the crop drawn: they adjust it).
crop_handles :: proc(doc: ^Doc) -> (at: [Handle]Vec, has: Handles) {
	if !doc.has_crop { return }
	return box_handles(doc.crop), BOX_HANDLES
}

crop_handle_hit :: proc(doc: ^Doc, p: Vec, tolerance: f32) -> Handle {
	at, has := crop_handles(doc)
	for h in Handle {
		if h in has && abs(p.x - at[h].x) <= tolerance && abs(p.y - at[h].y) <= tolerance { return h }
	}
	return .None
}

// The part of the picture that is kept, in whole pixels: the crop, else all of it.
output_box :: proc(doc: ^Doc) -> (x, y, w, h: int) {
	return crop_pixels(doc.size, doc.crop, doc.has_crop)
}

// The crop of a picture of size in whole pixels (all of it when there is none, or when it keeps less than a pixel).
crop_pixels :: proc(size: Vec, crop: Box, has_crop: bool) -> (x, y, w, h: int) {
	if !has_crop { return 0, 0, int(size.x), int(size.y) }
	x0 := clamp(int(math.round(crop.min.x)), 0, int(size.x))
	y0 := clamp(int(math.round(crop.min.y)), 0, int(size.y))
	x1 := clamp(int(math.round(crop.max.x)), x0, int(size.x))
	y1 := clamp(int(math.round(crop.max.y)), y0, int(size.y))
	if x1 - x0 < 1 || y1 - y0 < 1 { return 0, 0, int(size.x), int(size.y) }
	return x0, y0, x1 - x0, y1 - y0
}

@(private)
picture_clamp :: proc(doc: ^Doc, p: Vec) -> Vec {
	return {clamp(p.x, 0, doc.size.x), clamp(p.y, 0, doc.size.y)}
}
