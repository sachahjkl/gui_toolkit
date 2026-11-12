package tk_image

import "core:math"
import font "../font"
import paint "../paint"

// Text as a picture, drawn on the CPU from the outlines of the faces in a font.State (as svg.raster draws its texts): no
// window, no GPU. A glyph without an outline (a colour emoji) is left out.

// (glyph outlines are read within this part of an em, as draw's are)
@(private = "file")
OUTLINE_TOLERANCE_EM :: 1.0 / 1024

// `text` in `color`, `size` pixels per em, from `face` of `fonts` (shaped, with its fallbacks), on a transparent picture
// just large enough: as wide as its advance, as tall as the face's ascent and descent, one pixel more on each side for
// the antialiased edges. Empty without fonts or text.
text_image :: proc(fonts: ^font.State, face: font.Font_Id, text: string, size: f32, color: Color, allocator := context.allocator) -> Image {
	if fonts == nil || face == 0 || len(text) == 0 || size <= 0 { return {} }
	shaped := font.shape(fonts, face, size, text, allocator = context.temp_allocator)
	metrics := font.face_metrics(fonts, face)
	if metrics.upem <= 0 { return {} }
	ascent := abs(f32(metrics.ascent)) / f32(metrics.upem) * size
	descent := abs(f32(metrics.descent)) / f32(metrics.upem) * size
	width := int(math.ceil(shaped.width)) + 2
	height := int(math.ceil(ascent + descent)) + 2
	canvas := paint.canvas_make(width, height, context.temp_allocator)
	path := paint.Path{verbs = make([dynamic]paint.Verb, context.temp_allocator), points = make([dynamic][2]f32, context.temp_allocator)}
	pen := [2]f32{1, 1 + ascent}
	for g in shaped.glyphs {
		outline := font.Outline{quads = make([dynamic]font.Quad, context.temp_allocator), ends = make([dynamic]int, context.temp_allocator)}
		if !font.glyph_outline(fonts, g.face, g.id, OUTLINE_TOLERANCE_EM, &outline) { continue }
		at := pen + {g.x, g.y}
		first := 0
		for last in outline.ends {
			for q, k in outline.quads[first:last] {
				// (outlines are in ems, y up; the canvas is in pixels, y down)
				a := at + {q.p[0].x, -q.p[0].y} * size
				b := at + {q.p[1].x, -q.p[1].y} * size
				e := at + {q.p[2].x, -q.p[2].y} * size
				if k == 0 { paint.move_to(&path, a.x, a.y) }
				if q.p[1] == q.p[2] { paint.line_to(&path, e.x, e.y) } else { paint.quad_to(&path, b.x, b.y, e.x, e.y) }
			}
			paint.close(&path)
			first = last
		}
	}
	tint := paint.Color{f32(color[0]) / 255, f32(color[1]) / 255, f32(color[2]) / 255, f32(color[3]) / 255}
	paint.fill(&canvas, path, paint.solid(tint))
	return {pixels = paint.to_rgba8(canvas, allocator), width = width, height = height}
}

// `text` drawn over `img` in place, as text_image makes it, at `anchor`, `margin` pixels in from the sides, its alpha
// times `opacity`.
watermark_text :: proc(img: Image, fonts: ^font.State, face: font.Font_Id, text: string, size: f32, color: Color, anchor := Anchor.Bottom_Right, margin := 16, opacity: f32 = 0.5) {
	mark := text_image(fonts, face, text, size, color, context.temp_allocator)
	if !valid(mark) { return }
	watermark(img, mark, anchor, margin, opacity)
}
