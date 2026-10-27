#+build !windows
package font

// Color glyphs for a 2D canvas, off Windows: the platform color-glyph rasterizer is not here yet (the native backend
// draws text from outlines; see font_other.odin), so no glyph is drawn in color. The public types and functions exist so
// an application (Wren's canvas) compiles everywhere and falls back to the outline by itself. When a portable rasterizer
// lands (COLR from the backend's tables, sbix / CBDT / SVG), these return real bitmaps the same way the Windows ones do.

Color_Glyph :: struct {
	px:     []u8,
	w, h:   int,
	ox, oy: f32,
}

glyph_is_color :: proc(s: ^State, face: Font_Id, gid: u16, size: f32) -> bool { return false }

color_glyph_rgba :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, fg: [3]u8 = {}, allocator := context.temp_allocator) -> (cg: Color_Glyph, ok: bool) {
	return
}
