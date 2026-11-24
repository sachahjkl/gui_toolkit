package tk_marks

// The geometry of each shape as figures: polylines to stroke and polygons to fill, in the picture's pixels. The screen
// (ui.Mark_Editor, with gt:draw) and the flattening (flatten.odin, with gt:paint) both draw them: the file looks as the
// canvas did. A text's letters and the boxes of Pixelate and Blur are not figures: each painter draws them its way.

import "core:math"
import turn "../turn"

Figure_Kind :: enum u8 {
	Stroke,   // the polyline, width across, with round ends and joins
	Fill,     // the polygon, with the non-zero rule
}

Figure :: struct {
	kind:      Figure_Kind,
	points:    [][2]f32,
	closed:    bool,            // Stroke: the last point joins the first
	width:     f32,             // Stroke: picture pixels
	color:     [4]f32,          // straight (not premultiplied) sRGB, 0..1
	// Fill: the same area as triangles (a pen's ink), for a renderer whose fill takes few points; nil: none
	triangles: [][3][2]f32,
}

// How far a polyline of a curve strays from the curve, picture pixels.
CURVE_TOLERANCE :: 0.1
// The dashes and the gaps, in strokes' widths. A dash's round ends reach half a width past it each side: a dash of 2
// shows 3 widths long, a gap of 3 shows 2. A dot is a disc a width across, two widths apart.
DASHED :: [2]f32{2, 3}
DOTTED :: [2]f32{0, 2}
// An arrow's head: its length is HEAD_WIDTHS widths plus HEAD_EXTRA logical pixels (shortened on a short arrow), its
// half width HEAD_SPREAD of its length.
HEAD_WIDTHS :: 4
HEAD_EXTRA :: 4
HEAD_SPREAD :: 0.6

// A colour of the model (0xRRGGBB, sRGB) as a figure's.
color_of :: proc(rgb: u32, alpha: f32 = 1) -> [4]f32 {
	return {f32((rgb >> 16) & 255) / 255, f32((rgb >> 8) & 255) / 255, f32(rgb & 255) / 255, alpha}
}

// A style's fill colour with its opacity; ok false: none.
fill_color :: proc(style: Style) -> (c: [4]f32, ok: bool) {
	rgb := fill_of(style) or_return
	return color_of(rgb, f32(style.fill_color >> 24) / 255), true
}

// Black or white, whichever stands out from rgb: a text's outline or box when it has no fill colour.
color_against :: proc(rgb: u32) -> [4]f32 {
	r, g, b := f32((rgb >> 16) & 255), f32((rgb >> 8) & 255), f32(rgb & 255)
	return 0.299 * r + 0.587 * g + 0.114 * b > 160 ? [4]f32{0, 0, 0, 1} : [4]f32{1, 1, 1, 1}
}

// The colour under a text's letters (its outline or its box): its fill colour, else black or white.
text_under :: proc(style: Style) -> [4]f32 {
	if c, ok := fill_color(style); ok { return c }
	return color_against(style.color)
}

// The figures of s, appended to out in the order to draw them. Their points are in allocator, except a pen's, which
// are its own (Shape.polygon, Shape.triangles): free them with the allocator, never one by one.
figures :: proc(doc: ^Doc, s: ^Shape, out: ^[dynamic]Figure, allocator := context.allocator) {
	color := color_of(s.style.color)
	w := max(stroke_px(doc, s), 0.5)
	fill, filled := fill_color(s.style)
	switch s.kind {
	case .Rectangle:
		r := box_of(s.a, s.b)
		size := box_size(r)
		radius := min(s.style.radius * doc.scale, size.x * 0.5, size.y * 0.5)
		outline := rounded_rect_points(r, radius, allocator)
		// (the stroke is centred on the box's edge, as a line's is on its path; the fill goes under it)
		if filled { append(out, Figure{kind = .Fill, points = outline, color = fill}) }
		stroke(out, outline, true, w, color, s.style.dash, allocator)
	case .Ellipse:
		r := box_of(s.a, s.b)
		outline := ellipse_points((r.min + r.max) * 0.5, box_size(r) * 0.5, allocator)
		if filled { append(out, Figure{kind = .Fill, points = outline, color = fill}) }
		stroke(out, outline, true, w, color, s.style.dash, allocator)
	case .Line:
		pts := make([][2]f32, 2, allocator)
		pts[0], pts[1] = s.a, s.b
		stroke(out, pts, false, w, color, s.style.dash, allocator)
	case .Arrow:
		arrow(out, s.a, s.b, w, doc.scale, color, s.style.heads, s.style.dash, allocator)
	case .Pen:
		if len(s.polygon) >= 3 { append(out, Figure{kind = .Fill, points = s.polygon, color = color, triangles = s.triangles}) }
	case .Highlighter:
		append(out, Figure{kind = .Fill, points = rounded_rect_points(box_of(s.a, s.b), 0, allocator), color = color_of(s.style.color, HIGHLIGHT_ALPHA)})
	case .Text:
		if s.style.text_look == .Background {
			r := shape_box(doc, s)
			radius := min(text_px(doc, s) * TEXT_BOX_ROUND, box_size(r).x * 0.5, box_size(r).y * 0.5)
			append(out, Figure{kind = .Fill, points = rounded_rect_points(r, radius, allocator), color = text_under(s.style)})
		}
	case .Pixelate, .Blur:
	}
}

// How far a shape's figures reach past its box: its stroke and an arrow's heads (picture pixels).
reach :: proc(doc: ^Doc, s: ^Shape) -> f32 {
	w := stroke_px(doc, s)
	return w * (HEAD_WIDTHS + 1) + HEAD_EXTRA * doc.scale + text_pad(doc, s) + 2
}

// A polyline stroked whole, in dashes, or in dots (discs).
@(private)
stroke :: proc(out: ^[dynamic]Figure, pts: [][2]f32, closed: bool, w: f32, color: [4]f32, dash: Dash, allocator := context.allocator) {
	switch dash {
	case .Solid:
		append(out, Figure{kind = .Stroke, points = pts, closed = closed, width = w, color = color})
	case .Dashed, .Dotted:
		pattern := (dash == .Dashed ? DASHED : DOTTED) * w
		dash_points(out, pts, closed, pattern, w, color, allocator)
	}
}

// The dashes of a polyline: pattern[0] drawn, pattern[1] skipped, in turn, from its start. A dash of length 0 is a dot:
// a disc w across.
@(private)
dash_points :: proc(out: ^[dynamic]Figure, pts: [][2]f32, closed: bool, pattern: [2]f32, w: f32, color: [4]f32, allocator := context.allocator) {
	n := len(pts)
	if n == 0 || pattern[0] + pattern[1] <= 0 { return }
	segments := closed && n > 1 ? n : n - 1
	on := true
	left := pattern[0]
	piece := make([dynamic][2]f32, allocator)
	emit :: proc(out: ^[dynamic]Figure, piece: ^[dynamic][2]f32, w: f32, color: [4]f32, allocator := context.allocator) {
		if len(piece) == 1 {
			append(out, Figure{kind = .Fill, points = disc_points(piece[0], w * 0.5, allocator), color = color})
		} else if len(piece) > 1 {
			append(out, Figure{kind = .Stroke, points = piece[:], width = w, color = color})
		}
		piece^ = make([dynamic][2]f32, allocator)
	}
	append(&piece, pts[0])
	for s in 0 ..< segments {
		a, b := pts[s], pts[(s + 1) % n]
		d := b - a
		l := length(d)
		t: f32 = 0
		for l - t > left {
			t += left
			q := a + d * (t / max(l, 1e-6))
			if on {
				if piece[len(piece) - 1] != q { append(&piece, q) }
				emit(out, &piece, w, color, allocator)
			} else {
				append(&piece, q)
			}
			on = !on
			left = on ? pattern[0] : pattern[1]
		}
		left -= l - t
		if on && piece[len(piece) - 1] != b { append(&piece, b) }
	}
	if on { emit(out, &piece, w, color, allocator) }
}

// An arrow's shaft from a to b and its heads: filled, growing with the width, shorter on a short arrow. The shaft ends
// inside each head: its round end does not show past the head's back.
@(private)
arrow :: proc(out: ^[dynamic]Figure, a, b: Vec, w, scale: f32, color: [4]f32, heads: Heads, dash: Dash, allocator := context.allocator) {
	full := length(b - a)
	if full < 0.5 {
		pts := make([][2]f32, 2, allocator)
		pts[0], pts[1] = a, b
		append(out, Figure{kind = .Stroke, points = pts, width = w, color = color})
		return
	}
	dir := (b - a) / full
	head := min(w * HEAD_WIDTHS + HEAD_EXTRA * scale, full)
	at_end := heads == .End || heads == .Both
	at_start := heads == .Start || heads == .Both
	if at_end && at_start { head = min(head, full * 0.5) }
	pts := make([][2]f32, 2, allocator)
	pts[0] = at_start ? a + dir * (head * 0.5) : a
	pts[1] = at_end ? b - dir * (head * 0.5) : b
	stroke(out, pts, false, w, color, dash, allocator)
	if at_end { append(out, Figure{kind = .Fill, points = head_points(b, dir, head, allocator), color = color}) }
	if at_start { append(out, Figure{kind = .Fill, points = head_points(a, -dir, head, allocator), color = color}) }
}

// A head with its tip at tip, pointing along dir.
@(private)
head_points :: proc(tip, dir: Vec, head: f32, allocator := context.allocator) -> [][2]f32 {
	n := Vec{-dir.y, dir.x}
	half := head * HEAD_SPREAD
	base := tip - dir * head
	pts := make([][2]f32, 3, allocator)
	pts[0], pts[1], pts[2] = tip, base + n * half, base - n * half
	return pts
}

// The pieces of an arc of radius r, sweep turns long, that keep within CURVE_TOLERANCE of it.
@(private)
arc_pieces :: proc(r: f32, sweep: f32) -> int {
	if r <= CURVE_TOLERANCE { return 1 }
	step := 2 * turn.acos(1 - CURVE_TOLERANCE / r)   // (turns per piece)
	return clamp(int(math.ceil(sweep / step)), 1, 1024)
}

// A box's outline with corners of radius, clockwise from its top left (y down).
rounded_rect_points :: proc(r: Box, radius: f32, allocator := context.allocator) -> [][2]f32 {
	if radius <= 0 {
		pts := make([][2]f32, 4, allocator)
		pts[0], pts[1], pts[2], pts[3] = r.min, {r.max.x, r.min.y}, r.max, {r.min.x, r.max.y}
		return pts
	}
	n := arc_pieces(radius, 0.25)
	pts := make([dynamic][2]f32, 0, 4 * (n + 1), allocator)
	centres := [4]Vec{{r.max.x - radius, r.min.y + radius}, {r.max.x - radius, r.max.y - radius}, {r.min.x + radius, r.max.y - radius}, {r.min.x + radius, r.min.y + radius}}
	for c, k in centres {
		// (each corner from its start angle, a quarter turn: the top right from -1/4 turn, then 0, 1/4, 1/2)
		start := f32(k - 1) * 0.25
		for i in 0 ..= n {
			sn, cs := turn.sincos(start + f32(i) / f32(n) * 0.25)
			append(&pts, c + Vec{cs, sn} * radius)
		}
	}
	return pts[:]
}

// An ellipse's outline around c with radii.
ellipse_points :: proc(c, radii: Vec, allocator := context.allocator) -> [][2]f32 {
	n := max(arc_pieces(max(radii.x, radii.y), 1), 8)
	pts := make([][2]f32, n, allocator)
	for i in 0 ..< n {
		sn, cs := turn.sincos(f32(i) / f32(n))
		pts[i] = c + Vec{cs * radii.x, sn * radii.y}
	}
	return pts
}

disc_points :: proc(c: Vec, r: f32, allocator := context.allocator) -> [][2]f32 {
	return ellipse_points(c, {r, r}, allocator)
}
