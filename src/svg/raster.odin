package tk_svg

import "core:math"
import font "../font"
import paint "../paint"

// The drawing as pixels, on the CPU (a picture to copy or to save, where no frame is drawn): `scale` pixels per unit of its
// viewBox, on `background` (sRGB, straight; transparent: {}), its colours through `o.recolor` as draw_doc has them. Texts are
// filled from the outlines of `o`'s faces in `fonts` (a glyph without one, a colour emoji, is left out). The canvas is the
// caller's: paint.canvas_destroy, paint.png_encode or paint.to_rgba8 for its bytes.
raster :: proc(doc: ^Document, scale: f32, fonts: ^font.State, o: Draw_Options, background := Color{}, allocator := context.allocator) -> paint.Canvas {
	sz := size(doc, scale)
	c := paint.canvas_make(max(1, int(math.ceil(sz.x))), max(1, int(math.ceil(sz.y))), allocator)
	if background.a > 0 { paint.clear(&c, background) }
	origin := Vec2{doc.view[0], doc.view[1]}
	for item in doc.items {
		switch it in item {
		case Shape:
			p := raster_path()
			contours := make([dynamic][]Vec2, context.temp_allocator)
			closed := make([dynamic]bool, context.temp_allocator)
			pts := make([dynamic]Vec2, context.temp_allocator)
			at := Vec2{}
			end :: proc(contours: ^[dynamic][]Vec2, closed: ^[dynamic]bool, pts: ^[dynamic]Vec2, close: bool) {
				if len(pts) > 1 { append(contours, pts[:]); append(closed, close) }
				pts^ = make([dynamic]Vec2, context.temp_allocator)
			}
			for s in it.segs {
				q := (s.p - origin) * scale
				switch s.kind {
				case .Move:
					end(&contours, &closed, &pts, false)
					paint.move_to(&p, q.x, q.y)
					append(&pts, q)
				case .Line:
					paint.line_to(&p, q.x, q.y)
					append(&pts, q)
				case .Quad:
					c1 := (s.c1 - origin) * scale
					paint.quad_to(&p, c1.x, c1.y, q.x, q.y)
					for k in 1 ..= CURVE_LINES {
						t := f32(k) / CURVE_LINES
						u := 1 - t
						append(&pts, at * (u * u) + c1 * (2 * u * t) + q * (t * t))
					}
				case .Cubic:
					c1, c2 := (s.c1 - origin) * scale, (s.c2 - origin) * scale
					paint.cubic_to(&p, c1.x, c1.y, c2.x, c2.y, q.x, q.y)
					for k in 1 ..= CURVE_LINES {
						t := f32(k) / CURVE_LINES
						u := 1 - t
						append(&pts, at * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + q * (t * t * t))
					}
				case .Close:
					paint.close(&p)
					if len(pts) > 0 { q = pts[0] }
					end(&contours, &closed, &pts, true)
					append(&pts, q)   // (a line after a close starts where the figure did)
				}
				at = q
			}
			end(&contours, &closed, &pts, false)
			if f, ok := it.fill.?; ok && f.a > 0 { paint.fill(&c, p, paint.solid(tint(f, o)), it.evenodd ? .Even_Odd : .Non_Zero) }
			if s, ok := it.stroke.?; ok && s.a > 0 && it.stroke_width > 0 {
				pen := paint.Pen{width = max(it.stroke_width * scale, MIN_STROKE_PX)}
				if len(it.dash) > 0 {
					d := raster_path()
					for k, i in contours {
						for run in dash_runs(k, closed[i], it.dash, scale) {
							paint.move_to(&d, run[0].x, run[0].y)
							for v in run[1:] { paint.line_to(&d, v.x, v.y) }
						}
					}
					p = d
				}
				paint.stroke(&c, p, pen, paint.solid(tint(s, o)))
			}
		case Text:
			id := it.bold && o.bold != 0 ? o.bold : o.regular
			px := it.size * scale
			if fonts == nil || id == 0 || px < MIN_TEXT_PX { continue }
			sh := font.shape(fonts, id, px, it.text, allocator = context.temp_allocator)
			pen := (it.at - origin) * scale
			switch it.anchor {
			case .Start:
			case .Middle: pen.x -= sh.width * 0.5
			case .End:    pen.x -= sh.width
			}
			p := raster_path()
			for g in sh.glyphs {
				ol := font.Outline{quads = make([dynamic]font.Quad, context.temp_allocator), ends = make([dynamic]int, context.temp_allocator)}
				if !font.glyph_outline(fonts, g.face, g.id, OUTLINE_TOLERANCE_EM, &ol) { continue }
				at := pen + {g.x, g.y}
				first := 0
				for last in ol.ends {
					for q, k in ol.quads[first:last] {
						a, b, e := at + {q.p[0].x, -q.p[0].y} * px, at + {q.p[1].x, -q.p[1].y} * px, at + {q.p[2].x, -q.p[2].y} * px
						if k == 0 { paint.move_to(&p, a.x, a.y) }
						if q.p[1] == q.p[2] { paint.line_to(&p, e.x, e.y) } else { paint.quad_to(&p, b.x, b.y, e.x, e.y) }
					}
					paint.close(&p)
					first = last
				}
			}
			paint.fill(&c, p, paint.solid(tint(it.color, o)))
		}
	}
	return c
}

// (a curve cut in this many lines for its dashes; the fill and the solid stroke take paint's own flattening)
@(private = "file") CURVE_LINES :: 16
// (glyph outlines are read within this part of an em, as draw's are)
@(private = "file") OUTLINE_TOLERANCE_EM :: 1.0 / 1024

@(private = "file")
raster_path :: proc() -> paint.Path {
	return {verbs = make([dynamic]paint.Verb, context.temp_allocator), points = make([dynamic][2]f32, context.temp_allocator)}
}

@(private = "file")
tint :: proc(c: Color, o: Draw_Options) -> paint.Color { return o.recolor != nil ? o.recolor(c, o.user) : c }
