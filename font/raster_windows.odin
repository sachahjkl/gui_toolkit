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
	case .Default: return .DEFAULT
	case .Enabled: return .ENABLED
	case .Disabled: return .DISABLED
	}
	return .DEFAULT
}

// Coverage of a glyph run at (x, y): its bounds (pixels from the origin) and one byte per pixel (temp allocator).
@(private)
coverage :: proc(s: ^State, run: ^DWRITE_GLYPH_RUN, x, y: f32) -> (bounds: RECT, pixels: []u8, ok: bool) {
	analysis: ^IDWriteGlyphRunAnalysis
	mode := dw_rendering(s.settings.rendering)
	three := false
	if s.factory2 != nil {
		if s.factory2->CreateGlyphRunAnalysis2(run, nil, mode, .NATURAL, dw_grid(s.settings.grid_fit), .GRAYSCALE, x, y, &analysis) < 0 { return }
	} else {
		// before Windows 8.1 antialiased analyses only give ClearType (3 bytes per pixel): averaged below
		if s.factory->CreateGlyphRunAnalysis(run, 1, nil, mode, .NATURAL, x, y, &analysis) < 0 { return }
		three = mode != .ALIASED
	}
	defer com_release(analysis)
	tt := three ? DWRITE_TEXTURE_TYPE.CLEARTYPE_3x1 : .ALIASED_1x1
	if analysis->GetAlphaTextureBounds(tt, &bounds) < 0 { return }
	w, h := int(bounds.right - bounds.left), int(bounds.bottom - bounds.top)
	if w <= 0 || h <= 0 { return bounds, nil, true }
	if w >= s.settings.page_size || h >= s.settings.page_size { return bounds, nil, true }   // would not fit a page: nothing to keep
	bpp := three ? 3 : 1
	buf := make([]u8, w * h * bpp, context.temp_allocator)
	if analysis->CreateAlphaTexture(tt, &bounds, raw_data(buf), u32(len(buf))) < 0 { return }
	if three {
		for i in 0 ..< w * h { buf[i] = u8((u32(buf[i * 3]) + u32(buf[i * 3 + 1]) + u32(buf[i * 3 + 2]) + 1) / 3) }
		buf = buf[:w * h]
	}
	return bounds, buf, true
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
	return rasterize_outline(s, f, &run, x)
}

// The coverage of the glyph of `run` into a Gray page. Caller holds the atlas lock.
@(private)
rasterize_outline :: proc(s: ^State, f: ^Font, run: ^DWRITE_GLYPH_RUN, x: f32) -> (Glyph_Image, bool) {
	blank := Glyph_Image{page = -1}
	bounds, px, ok := coverage(s, run, x, 0)
	if !ok || px == nil { return blank, false }
	w, h := int(bounds.right - bounds.left), int(bounds.bottom - bounds.top)
	pi, ax, ay, aok := atlas_alloc(s, .Gray, w, h)
	if !aok { return blank, false }
	p := s.atlas.pages[pi]
	for row in 0 ..< h { copy(p.pixels[(ay + row) * p.size + ax:][:w], px[row * w:][:w]) }
	page_log(p, ax, ay, w, h)
	p.glyphs += 1
	return Glyph_Image{
		page = i32(pi), uv = {f32(ax), f32(ay), f32(ax + w), f32(ay + h)},
		offset = {f32(bounds.left), f32(bounds.top)}, size = {f32(w), f32(h)}, epoch = p.epoch,
	}, false
}
