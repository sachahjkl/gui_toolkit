package tk_svg

import "core:math"
import draw "../draw"
import font "../font"

// How a drawing is drawn: in the program's fonts (a text says only bold or not), its colours through `recolor` (sRGB in,
// sRGB out: a program's theme), nil: as they are.
Options :: struct {
	regular, bold: font.Font_Id,
	recolor:       proc(c: Color, user: rawptr) -> Color,
	user:          rawptr,
}

// Its size on screen at `scale` (its viewBox's width and height times it).
size :: proc(doc: ^Document, scale: f32) -> Vec2 { return {doc.view[2], doc.view[3]} * scale }

// Draws it with its top left corner at `at`, `scale` screen pixels per unit of its viewBox. The paths are built in screen
// space: curves are as smooth and strokes as wide as the scale makes them.
draw_doc :: proc(dc: ^draw.Context, doc: ^Document, at: Vec2, scale: f32, o: Options) {
	to :: proc(doc: ^Document, at: Vec2, scale: f32, p: Vec2) -> Vec2 { return at + (p - Vec2{doc.view[0], doc.view[1]}) * scale }
	for item in doc.items {
		switch it in item {
		case Shape:
			p := draw.path_make(allocator = context.temp_allocator)
			for s in it.segs {
				switch s.kind {
				case .Move:  draw.path_move_to(&p, to(doc, at, scale, s.p))
				case .Line:  draw.path_line_to(&p, to(doc, at, scale, s.p))
				case .Quad:  draw.path_quad_to(&p, to(doc, at, scale, s.c1), to(doc, at, scale, s.p))
				case .Cubic: draw.path_cubic_to(&p, to(doc, at, scale, s.c1), to(doc, at, scale, s.c2), to(doc, at, scale, s.p))
				case .Close: draw.path_close(&p)
				}
			}
			if c, ok := it.fill.?; ok && c.a > 0 { draw.path_fill(dc, &p, linear(c, o), it.evenodd) }
			if c, ok := it.stroke.?; ok && c.a > 0 && it.stroke_width > 0 {
				w := max(it.stroke_width * scale, MIN_STROKE_PX)
				if len(it.dash) > 0 { dashed(dc, &p, w, linear(c, o), it.dash, scale) } else { draw.path_stroke(dc, &p, w, linear(c, o)) }
			}
		case Text:
			id := it.bold && o.bold != 0 ? o.bold : o.regular
			sz := it.size * scale
			if id == 0 || sz < MIN_TEXT_PX { continue }
			w := font.text_width(dc.fonts, id, sz, it.text)
			x := to(doc, at, scale, it.at)
			switch it.anchor {
			case .Start:
			case .Middle: x.x -= w * 0.5
			case .End:    x.x -= w
			}
			draw.text(dc, id, sz, x, linear(it.color, o), it.text)
		}
	}
}

// (finer than this, a line or a letter is not seen: a stroke stays a hairline, a text too small is left out)
@(private) MIN_STROKE_PX :: 0.75
@(private) MIN_TEXT_PX :: 3

@(private)
linear :: proc(c: Color, o: Options) -> draw.Color {
	v := o.recolor != nil ? o.recolor(c, o.user) : c
	return draw.srgb(v.r, v.g, v.b, v.a)
}

// A stroke in dashes: on and off along each contour of the flattened path, the pattern's lengths at `scale`.
@(private)
dashed :: proc(dc: ^draw.Context, p: ^draw.Path, width: f32, color: draw.Color, pattern: []f32, scale: f32) {
	total: f32
	for d in pattern { total += d }
	if total <= 0 { draw.path_stroke(dc, p, width, color); return }
	for k in p.contours {
		pts := p.points[k.first:][:k.count]
		n := len(pts) + (k.closed ? 1 : 0)
		i, left, on := 0, pattern[0] * scale, true
		run := make([dynamic]draw.Vec2, context.temp_allocator)
		if on { append(&run, pts[0]) }
		for j in 1 ..< n {
			a, b := pts[j - 1], pts[j % len(pts)]
			seg := math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
			t: f32 = 0
			for seg - t > left {
				t += left
				q := a + (b - a) * (t / seg)
				if on {
					append(&run, q)
					draw.polyline(dc, run[:], width, color)
					clear(&run)
				} else {
					append(&run, q)
				}
				on = !on
				i = (i + 1) % len(pattern)
				left = max(pattern[i] * scale, 0.5)
			}
			left -= seg - t
			if on { append(&run, b) }
		}
		if on && len(run) > 1 { draw.polyline(dc, run[:], width, color) }
	}
}
