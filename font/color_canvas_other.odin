#+build !windows
package font

import "base:runtime"

// Color glyphs for a 2D canvas, off Windows: the COLR interpreter and the bitmaps of CBDT (cbdt.odin), straight-alpha RGBA.

Color_Glyph :: struct {
	px:     []u8,
	w, h:   int,
	ox, oy: f32,
}

glyph_is_color :: proc(s: ^State, face: Font_Id, gid: u16, size: f32) -> bool {
	f := face_ptr(s, face)
	return f != nil && f.color && size > 0 && platform_color_glyph(s, f, gid, size)
}

color_glyph_rgba :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, fg: [3]u8 = {}, allocator := context.temp_allocator) -> (c: Color_Glyph, ok: bool) {
	f := face_ptr(s, face)
	if f == nil || !f.color || size <= 0 || !s.settings.color_glyphs { return }
	bm: Colr_Bitmap
	drawn: bool
	if colr_draws(s, f, gid) { bm, drawn = colr_draw(s, face, f, gid, size, 0, fg) } else { bm, drawn = cbdt_draw(f.colr, gid, size) }
	if !drawn { return }
	defer delete(bm.px, runtime.heap_allocator())
	if bm.w <= 0 || bm.h <= 0 { return }
	px := make([]u8, bm.w * bm.h * 4, allocator)
	copy(px, bm.px)
	return Color_Glyph{px = px, w = bm.w, h = bm.h, ox = f32(-bm.origin.x), oy = f32(-bm.origin.y)}, true
}
