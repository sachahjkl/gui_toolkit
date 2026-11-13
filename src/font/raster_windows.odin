#+build windows
package font

// Glyph bitmaps on Windows: DirectWrite's glyph run analysis gives the coverage of outlines (hinted as the settings
// say), Direct2D or the COLR interpreter draws color glyphs.

// Whether a glyph of a color face is drawn in color (and so goes to the color glyph thread).
@(private)
platform_color_glyph :: proc(s: ^State, f: ^Font, gid: u16, size: f32) -> bool {
	return s.factory != nil && is_color_glyph(s, f, gid, size)
}

@(private)
dw_rendering :: proc(r: Rendering) -> DWRITE_RENDERING_MODE {
	switch r {
	case .Natural_Symmetric: return .NATURAL_SYMMETRIC
	case .Natural: return .NATURAL
	case .Gdi_Classic: return .GDI_CLASSIC
	case .Aliased: return .ALIASED
	}
	return .NATURAL_SYMMETRIC
}

@(private)
dw_grid :: proc(g: Grid_Fit) -> DWRITE_GRID_FIT_MODE {
	switch g {
	case .Auto: return .DEFAULT
	case .Enabled: return .ENABLED
	case .Disabled: return .DISABLED
	}
	return .DEFAULT
}

// Coverage of a glyph run at (x, y): its bounds (pixels from the origin) and one byte per pixel (temp allocator). `lcd`:
// three bytes per pixel, one per colour stripe from left to right, DirectWrite's filter applied (`three` says if it was).
@(private)
coverage :: proc(s: ^State, run: ^DWRITE_GLYPH_RUN, x, y: f32, want_lcd := false) -> (bounds: RECT, pixels: []u8, ok: bool, lcd: bool) {
	analysis: ^IDWriteGlyphRunAnalysis
	mode := dw_rendering(s.settings.rendering)
	lcd = want_lcd && mode != .ALIASED
	three := lcd
	if s.factory2 != nil {
		aa: DWRITE_TEXT_ANTIALIAS_MODE = lcd ? .CLEARTYPE : .GRAYSCALE
		if s.factory2->CreateGlyphRunAnalysis2(run, nil, mode, .NATURAL, dw_grid(s.settings.grid_fit), aa, x, y, &analysis) < 0 { return }
	} else {
		// before Windows 8.1 antialiased analyses only give ClearType (3 bytes per pixel): averaged below
		if s.factory->CreateGlyphRunAnalysis(run, 1, nil, mode, .NATURAL, x, y, &analysis) < 0 { return }
		three = mode != .ALIASED
	}
	defer com_release(analysis)
	tt := three ? DWRITE_TEXTURE_TYPE.CLEARTYPE_3x1 : .ALIASED_1x1
	if analysis->GetAlphaTextureBounds(tt, &bounds) < 0 { return }
	w, h := int(bounds.right - bounds.left), int(bounds.bottom - bounds.top)
	if w <= 0 || h <= 0 { return bounds, nil, true, lcd }
	if w * (lcd ? 3 : 1) >= s.settings.page_size || h >= s.settings.page_size { return bounds, nil, true, lcd }   // would not fit a page: nothing to keep
	bpp := three ? 3 : 1
	buf := make([]u8, w * h * bpp, context.temp_allocator)
	if analysis->CreateAlphaTexture(tt, &bounds, raw_data(buf), u32(len(buf))) < 0 { return }
	if lcd {
		if s.settings.subpixel_text == .Bgr { for i in 0 ..< w * h { buf[i * 3], buf[i * 3 + 2] = buf[i * 3 + 2], buf[i * 3] } }
	} else if three {
		for i in 0 ..< w * h { buf[i] = u8((u32(buf[i * 3]) + u32(buf[i * 3 + 1]) + u32(buf[i * 3 + 2]) + 1) / 3) }
		buf = buf[:w * h]
	}
	return bounds, buf, true, lcd
}

// Caller holds the atlas lock.
@(private)
rasterize :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, x: f32, fg: [3]u8, probe_fg: bool, key: u64) -> (Glyph_Image, bool) {
	blank := Glyph_Image{page = -1}
	f := face_ptr(s, face)
	if f == nil || s.factory == nil || size <= 0 { return blank, false }
	ids := [1]u16{gid}
	advs := [1]f32{0}
	offs := [1]DWRITE_GLYPH_OFFSET{}
	run := DWRITE_GLYPH_RUN{fontFace = f.dw, fontEmSize = size, glyphCount = 1, glyphIndices = &ids[0], glyphAdvances = &advs[0], glyphOffsets = &offs[0]}
	if f.color && s.settings.color_glyphs {
		if colr_draws(s, f, gid) {
			// a graph the interpreter refuses (a cycle, offsets out of the table) is not drawn in color at all
			if g, uses_fg, ok := rasterize_colr(s, face, f, gid, size, x, fg, key); ok { return g, uses_fg }
		} else if g, uses_fg, ok := rasterize_color(s, f, &run, x, fg, probe_fg); ok {
			return g, uses_fg
		}
	}
	return rasterize_outline(s, f, &run, x, key & GLYPH_KEY_LCD != 0)
}

// The coverage of the glyph of `run` into a Gray page. Caller holds the atlas lock.
@(private)
rasterize_outline :: proc(s: ^State, f: ^Font, run: ^DWRITE_GLYPH_RUN, x: f32, want_lcd := false) -> (Glyph_Image, bool) {
	blank := Glyph_Image{page = -1}
	bounds, px, ok, lcd := coverage(s, run, x, 0, want_lcd)
	if !ok || px == nil { return blank, false }
	w, h := int(bounds.right - bounds.left), int(bounds.bottom - bounds.top)
	tw := lcd ? w * 3 : w   // its width in texels: a pixel's coverages side by side
	pi, ax, ay, aok := atlas_alloc(s, .Gray, tw, h)
	if !aok { return blank, false }
	p := s.atlas.pages[pi]
	for row in 0 ..< h { copy(p.pixels[(ay + row) * p.size + ax:][:tw], px[row * tw:][:tw]) }
	page_log(p, ax, ay, tw, h)
	p.glyphs += 1
	return Glyph_Image{
		page = i32(pi), uv = {f32(ax), f32(ay), f32(ax + tw), f32(ay + h)},
		offset = {f32(bounds.left), f32(bounds.top)}, size = {f32(w), f32(h)}, epoch = p.epoch, lcd = lcd,
	}, false
}
