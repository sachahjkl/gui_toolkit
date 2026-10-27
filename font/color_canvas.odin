#+build windows
package font

import "base:runtime"

// Color glyphs for a 2D canvas (and any caller that draws a single color glyph as an image rather than into the atlas):
// one COLR / CPAL / sbix / CBDT / SVG glyph rasterized to a straight-alpha RGBA bitmap at an exact em size, with the
// offset from the pen to the bitmap's top-left corner. Unlike `glyph_image`, nothing goes through the glyph atlas or
// the draw layer: the caller owns the pixels and composites them itself (Canvas 2D fillText draws emoji this way, taking
// the transform, global alpha and clip like any image). Portable: the COLR interpreter (`color_engine = .Builtin`, or the
// glyphs Direct2D must not be given) draws the same bitmap on every platform; otherwise Direct2D draws it.

// A color glyph as pixels: `px` is w*h*4 straight-alpha sRGB RGBA, allocated with the allocator passed to
// `color_glyph_rgba`; (ox, oy) is where the bitmap's top-left sits relative to the pen on the baseline (pixels, y down,
// so oy is usually negative: the glyph rises above the baseline).
Color_Glyph :: struct {
	px:     []u8,
	w, h:   int,
	ox, oy: f32,
}

// Whether glyph `gid` of face `face` is drawn in color at `size` px (an emoji, a COLR / sbix / CBDT / SVG glyph): then
// `color_glyph_rgba` returns its colored bitmap, and a caller that only has an outline provider should draw it as an
// image instead. false for a plain outline glyph, a face with no color, or an id that no live face has.
glyph_is_color :: proc(s: ^State, face: Font_Id, gid: u16, size: f32) -> bool {
	f := face_ptr(s, face)
	if f == nil || !f.color || size <= 0 { return false }
	return is_color_glyph(s, f, gid, size)
}

// Rasterizes the color glyph `gid` of face `face` at `size` px to a straight-alpha RGBA bitmap, with `fg` (sRGB) the
// text color for the glyph's foreground layers (emoji ignore it; a glyph with text-color layers takes it). ok = false
// when the glyph is not a color glyph here, the face is gone, or the glyph could not be drawn (the caller then falls
// back to the outline). The pixels are on `allocator` (default the context's temp allocator); the caller frees them if
// it keeps them past a temp reset.
color_glyph_rgba :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, fg: [3]u8 = {}, allocator := context.temp_allocator) -> (cg: Color_Glyph, ok: bool) {
	f := face_ptr(s, face)
	if f == nil || !f.color || size <= 0 { return }

	// the COLR interpreter when it owns the glyph (Builtin engine, or a glyph Direct2D must not be given)
	if colr_draws(s, f, gid) {
		bm, drawn := colr_draw(s, face, f, gid, size, 0, fg)
		if !drawn { return }
		defer delete(bm.px, runtime.heap_allocator())
		if bm.w <= 0 || bm.h <= 0 { return }
		px := make([]u8, bm.w * bm.h * 4, allocator)
		if px == nil { return }
		copy(px, bm.px)   // already straight-alpha RGBA
		return Color_Glyph{px = px, w = bm.w, h = bm.h, ox = f32(-bm.origin.x), oy = f32(-bm.origin.y)}, true
	}

	// Direct2D (COLR v1, sbix / CBDT / SVG): premultiplied BGRA cut from a private device
	d2d, paint := color_caps(s)
	if !d2d { return }
	ids := [1]u16{gid}
	advs := [1]f32{0}
	offs := [1]DWRITE_GLYPH_OFFSET{}
	run := DWRITE_GLYPH_RUN{fontFace = f.dw, fontEmSize = size, glyphCount = 1, glyphIndices = &ids[0], glyphAdvances = &advs[0], glyphOffsets = &offs[0]}
	fmts, text_color := glyph_formats(s, &run, paint)
	if fmts == 0 { return }
	bpx, w, h, origin, _, drawn := color_render(s, f, &run, 0, fg, true, fmts, text_color)
	if !drawn || w <= 0 || h <= 0 { return }
	px := make([]u8, w * h * 4, allocator)
	if px == nil { return }
	// premultiplied BGRA -> straight RGBA
	for i := 0; i < w * h; i += 1 {
		b, g, r, a := bpx[i * 4], bpx[i * 4 + 1], bpx[i * 4 + 2], bpx[i * 4 + 3]
		d := px[i * 4:][:4]
		switch a {
		case 0:   d[0], d[1], d[2], d[3] = 0, 0, 0, 0
		case 255: d[0], d[1], d[2], d[3] = r, g, b, 255
		case:
			un :: #force_inline proc "contextless" (v, a: u8) -> u8 { return u8(min((u32(v) * 255 + u32(a) / 2) / u32(a), 255)) }
			d[0], d[1], d[2], d[3] = un(r, a), un(g, a), un(b, a), a
		}
	}
	return Color_Glyph{px = px, w = w, h = h, ox = f32(-origin.x), oy = f32(-origin.y)}, true
}
