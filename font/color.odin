#+build windows
package font

import "base:runtime"
import "core:math"
import "vendor:directx/d3d11"

// Color glyphs. A glyph a face draws in color (COLR v0 layers, COLR v1 paint trees with their gradients, transforms,
// compositions and clips, sbix / CBDT / PNG bitmaps, SVG documents) is drawn by Direct2D on a private device into a
// bitmap read back on the CPU, then packed into a Color page (straight-alpha sRGB, as the draw layer samples it):
//   * Windows 11 22H2 and later: ID2D1DeviceContext7::DrawGlyphRunWithColorSupport draws every representation;
//   * Windows 10 1607 and later: the runs of TranslateColorGlyphRun, each drawn by the call of its format (no paint
//     trees: a COLR v1 glyph shows its v0 layers when the font has some, else its outline);
//   * without Direct2D: COLR v0 layers rasterized and composited here.
// Layers in the text color (palette entry 0xFFFF, COLR v1 foreground paints, SVG `currentColor`) take the color the
// glyph is drawn with: such a glyph is found by drawing it in two colors, and is then kept once per text color.
//
// The device is made on first use, on the WARP software rasterizer (results do not depend on the GPU or its driver,
// and nothing is lost when the display device is reset). Everything here runs under the atlas lock.

@(private)
Color_Raster :: struct {
	tried:   bool,
	device:  ^d3d11.IDevice,
	dxgi:    rawptr,
	d2d:     ^ID2D1Device,
	dc:      ^ID2D1DeviceContext,   // the context (ID2D1DeviceContext methods only)
	dc4:     ^ID2D1DeviceContext,   // the same object as ID2D1DeviceContext4, nil before Windows 10 1607
	dc7:     ^ID2D1DeviceContext,   // as ID2D1DeviceContext7 with COLR v1 paint support, nil before Windows 11 22H2
	brush:   ^ID2D1SolidColorBrush,
	target:  ^ID2D1Bitmap1,
	staging: ^ID2D1Bitmap1,
	cap:     [2]int,                // size of target and staging
}

// Largest side of the canvas a color glyph is drawn on (a glyph larger than an atlas page could not be kept anyway).
@(private) COLOR_CANVAS_MAX :: 4096

// Image formats that make a glyph a color glyph.
@(private)
COLOR_FORMATS :: DWRITE_GLYPH_IMAGE_FORMATS_COLR | DWRITE_GLYPH_IMAGE_FORMATS_COLR_PAINT_TREE | DWRITE_GLYPH_IMAGE_FORMATS_SVG |
	DWRITE_GLYPH_IMAGE_FORMATS_PNG | DWRITE_GLYPH_IMAGE_FORMATS_JPEG | DWRITE_GLYPH_IMAGE_FORMATS_TIFF | DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8

@(private)
BITMAP_FORMATS :: DWRITE_GLYPH_IMAGE_FORMATS_PNG | DWRITE_GLYPH_IMAGE_FORMATS_JPEG | DWRITE_GLYPH_IMAGE_FORMATS_TIFF | DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8

@(private)
color_raster_init :: proc(cr: ^Color_Raster) -> bool {
	if cr.tried { return cr.dc != nil }
	cr.tried = true
	cr.device, cr.dxgi = d3d_device_for_d2d(.WARP)
	if cr.device == nil { return false }
	props := D2D1_CREATION_PROPERTIES{threadingMode = 0}
	if D2D1CreateDevice(cr.dxgi, &props, &cr.d2d) < 0 || cr.d2d == nil { color_raster_destroy(cr); cr.tried = true; return false }
	if cr.d2d->CreateDeviceContext(0, &cr.dc) < 0 || cr.dc == nil { color_raster_destroy(cr); cr.tried = true; return false }
	cr.dc4 = com_query(cr.dc, &IID_ID2D1DeviceContext4, ID2D1DeviceContext)
	cr.dc7 = com_query(cr.dc, &IID_ID2D1DeviceContext7, ID2D1DeviceContext)
	if cr.dc7 != nil && cr.dc7->GetPaintFeatureLevel() < DWRITE_PAINT_FEATURE_LEVEL_COLR_V1 {
		com_release(cr.dc7)
		cr.dc7 = nil
	}
	black := D2D1_COLOR_F{0, 0, 0, 1}
	if cr.dc->CreateSolidColorBrush(&black, nil, &cr.brush) < 0 || cr.brush == nil { color_raster_destroy(cr); cr.tried = true; return false }
	cr.dc->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE)
	return true
}

@(private)
color_raster_destroy :: proc(cr: ^Color_Raster) {
	if cr.dc != nil { cr.dc->SetTarget(nil) }
	com_release(cr.staging)
	com_release(cr.target)
	com_release(cr.brush)
	com_release(cr.dc7)
	com_release(cr.dc4)
	com_release(cr.dc)
	com_release(cr.d2d)
	if cr.dxgi != nil { com_release((^IUnknown)(cr.dxgi)) }
	if cr.device != nil { cr.device->Release() }
	cr^ = {}
}

// Target and read-back bitmaps of at least w x h.
@(private)
color_canvas :: proc(cr: ^Color_Raster, w, h: int) -> bool {
	if cr.target != nil && cr.cap.x >= w && cr.cap.y >= h { return true }
	cr.dc->SetTarget(nil)
	com_release(cr.staging); cr.staging = nil
	com_release(cr.target); cr.target = nil
	cw := max(w, cr.cap.x, 64)
	ch := max(h, cr.cap.y, 64)
	cw, ch = (cw + 63) &~ 63, (ch + 63) &~ 63
	pf := D2D1_PIXEL_FORMAT{DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED}
	tp := D2D1_BITMAP_PROPERTIES1{pixelFormat = pf, dpiX = 96, dpiY = 96, bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET}
	sp := D2D1_BITMAP_PROPERTIES1{pixelFormat = pf, dpiX = 96, dpiY = 96, bitmapOptions = D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW}
	size := D2D1_SIZE_U{u32(cw), u32(ch)}
	if cr.dc->CreateBitmap(size, nil, 0, &tp, &cr.target) < 0 || cr.target == nil { cr.cap = {}; return false }
	if cr.dc->CreateBitmap(size, nil, 0, &sp, &cr.staging) < 0 || cr.staging == nil {
		com_release(cr.target); cr.target = nil
		cr.cap = {}
		return false
	}
	cr.cap = {cw, ch}
	return true
}

// The color formats of the runs glyph `run` translates to (0: not a color glyph). Paint trees are asked for only where
// they can be drawn (`paint`).
@(private)
glyph_formats :: proc(s: ^State, run: ^DWRITE_GLYPH_RUN, paint: bool) -> DWRITE_GLYPH_IMAGE_FORMATS {
	all := COLOR_FORMATS | DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE | DWRITE_GLYPH_IMAGE_FORMATS_CFF
	e: ^IDWriteColorGlyphRunEnumerator1
	hr: HRESULT
	switch {
	case paint && s.factory8 != nil:
		hr = s.factory8->TranslateColorGlyphRun8({0, 0}, run, nil, all, DWRITE_PAINT_FEATURE_LEVEL_COLR_V1, .NATURAL, nil, 0, &e)
	case s.factory4 != nil:
		hr = s.factory4->TranslateColorGlyphRun4({0, 0}, run, nil, all &~ DWRITE_GLYPH_IMAGE_FORMATS_COLR_PAINT_TREE, .NATURAL, nil, 0, &e)
	case s.factory2 != nil:
		e0: ^IDWriteColorGlyphRunEnumerator
		if s.factory2->TranslateColorGlyphRun(0, 0, run, nil, .NATURAL, nil, 0, &e0) < 0 || e0 == nil { return 0 }
		com_release(e0)
		return DWRITE_GLYPH_IMAGE_FORMATS_COLR
	case:
		return 0
	}
	if hr < 0 || e == nil { return 0 }   // DWRITE_E_NOCOLOR
	defer com_release(e)
	fmts: DWRITE_GLYPH_IMAGE_FORMATS
	for {
		has: BOOL
		if e->MoveNext(&has) < 0 || !has { break }
		c: ^DWRITE_COLOR_GLYPH_RUN1
		if e->GetCurrentRun1(&c) < 0 || c == nil { break }
		fmts |= c.glyphImageFormat
	}
	return fmts & COLOR_FORMATS
}
// Can this package draw the color glyphs of face `id` in color? False for a face whose only color representation is
// one the system cannot draw (COLR v1 paint trees before Windows 11 22H2 without v0 layers): a cascade should rather
// take those characters from another face (the system emoji font) than show outlines. True for faces without color.
color_renderable :: proc(s: ^State, id: Font_Id) -> bool {
	f := face_ptr(s, id)
	if f == nil || !f.color || f.dw4 == nil { return true }
	fmts := f.dw4->GetGlyphImageFormats() & COLOR_FORMATS
	atlas_lock(&s.atlas)
	defer atlas_unlock(&s.atlas)
	cr := &s.color_raster
	d2d := color_raster_init(cr)
	if d2d && cr.dc7 != nil && s.factory8 != nil { return true }
	drawable := DWRITE_GLYPH_IMAGE_FORMATS_COLR
	if d2d && cr.dc4 != nil && s.factory4 != nil { drawable |= DWRITE_GLYPH_IMAGE_FORMATS_SVG | BITMAP_FORMATS }
	return fmts & drawable != 0
}

// sRGB, straight alpha.
@(private)
fg_color :: #force_inline proc(fg: [3]u8) -> D2D1_COLOR_F {
	return {f32(fg[0]) / 255, f32(fg[1]) / 255, f32(fg[2]) / 255, 1}
}

// Draws the glyph of `run` (pen at subpixel x) on a canvas through Direct2D, `fg` the text color. Returns the canvas
// (premultiplied BGRA rows of `w` pixels, temp allocator) and where the pen's whole pixel is on it.
@(private)
d2d_draw_glyph :: proc(s: ^State, f: ^Font, run: ^DWRITE_GLYPH_RUN, x: f32, fg: [3]u8) -> (px: []u8, w, h: int, origin: [2]int, ok: bool) {
	cr := &s.color_raster
	size := run.fontEmSize
	k := size / f.upem
	gm: DWRITE_GLYPH_METRICS
	if f.dw->GetDesignGlyphMetrics(run.glyphIndices, 1, &gm, false) < 0 { return }
	pad := int(math.ceil(size * 0.5)) + 2
	asc := int(math.ceil(f32(f.dm.ascent) * k))
	desc := int(math.ceil(f32(f.dm.descent) * k))
	adv := int(math.ceil(f32(gm.advanceWidth) * k))
	// the ink box of the outline, if it reaches further than the line box (tall glyphs)
	top := int(math.ceil(f32(gm.verticalOriginY - gm.topSideBearing) * k))
	bottom := int(math.ceil(f32(i32(gm.advanceHeight) - gm.bottomSideBearing - gm.verticalOriginY) * k))
	lsb := int(math.floor(f32(gm.leftSideBearing) * k))
	left := min(lsb, 0) - pad
	above := max(asc, top) + pad
	below := max(desc, bottom) + pad
	w = max(adv, adv - int(math.floor(f32(gm.rightSideBearing) * k))) - left + pad
	h = above + below
	if w <= 0 || h <= 0 || w > COLOR_CANVAS_MAX || h > COLOR_CANVAS_MAX { return }
	if !color_canvas(cr, w, h) { return }
	origin = {-left, above}
	o := D2D1_POINT_2F{f32(origin.x) + x, f32(origin.y)}
	dc := cr.dc
	dc->SetTarget(cr.target)
	dc->BeginDraw()
	identity := D2D1_MATRIX_3X2_F{1, 0, 0, 1, 0, 0}
	dc->SetTransform(&identity)
	clear_color := D2D1_COLOR_F{}
	dc->Clear(&clear_color)
	fgc := fg_color(fg)
	cr.brush->SetColor(&fgc)
	if cr.dc7 != nil {
		cr.dc7->DrawGlyphRunWithColorSupport(o, run, nil, cr.brush, nil, 0, .NATURAL, 0)
	} else {
		d2d_draw_runs(s, o, run, fg)
	}
	hr := dc->EndDraw(nil, nil)
	dc->SetTarget(nil)
	if hr < 0 { return }
	dst := D2D1_POINT_2U{}
	rect := D2D1_RECT_U{0, 0, u32(w), u32(h)}
	if cr.staging->CopyFromBitmap(&dst, cr.target, &rect) < 0 { return }
	mapped: D2D1_MAPPED_RECT
	if cr.staging->Map(D2D1_MAP_OPTIONS_READ, &mapped) < 0 { return }
	defer cr.staging->Unmap()
	px = make([]u8, w * h * 4, context.temp_allocator)
	for row in 0 ..< h { copy(px[row * w * 4:][:w * 4], mapped.bits[int(mapped.pitch) * row:][:w * 4]) }
	return px, w, h, origin, true
}

// Before ID2D1DeviceContext7: the color runs of the glyph, each drawn by the call of its format.
@(private)
d2d_draw_runs :: proc(s: ^State, o: D2D1_POINT_2F, run: ^DWRITE_GLYPH_RUN, fg: [3]u8) {
	cr := &s.color_raster
	fgc := fg_color(fg)
	want := DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE | DWRITE_GLYPH_IMAGE_FORMATS_CFF | DWRITE_GLYPH_IMAGE_FORMATS_COLR |
		DWRITE_GLYPH_IMAGE_FORMATS_SVG | BITMAP_FORMATS
	e: ^IDWriteColorGlyphRunEnumerator1
	if s.factory4->TranslateColorGlyphRun4(o, run, nil, want, .NATURAL, nil, 0, &e) < 0 || e == nil {
		cr.dc->DrawGlyphRun(o, run, cr.brush, .NATURAL)
		return
	}
	defer com_release(e)
	for {
		has: BOOL
		if e->MoveNext(&has) < 0 || !has { break }
		c: ^DWRITE_COLOR_GLYPH_RUN1
		if e->GetCurrentRun1(&c) < 0 || c == nil { break }
		at := D2D1_POINT_2F{c.baselineOriginX, c.baselineOriginY}
		f := c.glyphImageFormat
		switch {
		case f & (DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE | DWRITE_GLYPH_IMAGE_FORMATS_CFF) != 0:
			cr.brush->SetColor(&fgc)
			cr.dc->DrawGlyphRun(at, &c.glyphRun, cr.brush, c.measuringMode)
		case f & DWRITE_GLYPH_IMAGE_FORMATS_COLR != 0:
			col := c.paletteIndex == 0xFFFF ? fgc : D2D1_COLOR_F{c.runColor.r, c.runColor.g, c.runColor.b, c.runColor.a}
			cr.brush->SetColor(&col)
			cr.dc->DrawGlyphRun(at, &c.glyphRun, cr.brush, c.measuringMode)
		case f & DWRITE_GLYPH_IMAGE_FORMATS_SVG != 0:
			cr.brush->SetColor(&fgc)
			cr.dc4->DrawSvgGlyphRun(at, &c.glyphRun, cr.brush, nil, 0, c.measuringMode)
		case f & BITMAP_FORMATS != 0:
			cr.dc4->DrawColorBitmapGlyphRun(f & BITMAP_FORMATS, at, &c.glyphRun, c.measuringMode, 0)
		}
	}
}

// Color glyph `run` (one glyph, pen at subpixel x) into a Color page. ok = false: not a color glyph, or none of its
// representations can be drawn here (draw its outline). `uses_fg`: the result depends on `fg`.
@(private)
rasterize_color :: proc(s: ^State, f: ^Font, run: ^DWRITE_GLYPH_RUN, x: f32, fg: [3]u8, probe_fg: bool) -> (g: Glyph_Image, uses_fg: bool, ok: bool) {
	cr := &s.color_raster
	d2d := color_raster_init(cr)
	fmts := glyph_formats(s, run, d2d && cr.dc7 != nil && cr.dc4 != nil)
	if fmts == 0 { return {}, false, false }
	if d2d && cr.dc4 != nil && s.factory4 != nil {
		{
			px, w, h, origin, drawn := d2d_draw_glyph(s, f, run, x, fg)
			if drawn {
				if probe_fg && fmts & (COLOR_FORMATS &~ BITMAP_FORMATS) != 0 {
					// drawn again in a color far from fg on every channel: a difference anywhere means text-color layers
					other := [3]u8{fg[0] < 128 ? 255 : 0, fg[1] < 128 ? 255 : 0, fg[2] < 128 ? 255 : 0}
					if px2, w2, h2, _, again := d2d_draw_glyph(s, f, run, x, other); again && w2 == w && h2 == h {
						for i in 0 ..< len(px) { if px[i] != px2[i] { uses_fg = true; break } }
					}
				}
				return color_bitmap_put(s, px, w, h, origin), uses_fg, true
			}
		}
	}
	if fmts & DWRITE_GLYPH_IMAGE_FORMATS_COLR == 0 { return {}, false, false }
	return rasterize_colr_layers(s, run, x, fg)
}

// A canvas (premultiplied BGRA) cut to its ink and put in a Color page as straight-alpha RGBA.
@(private)
color_bitmap_put :: proc(s: ^State, px: []u8, w, h: int, origin: [2]int) -> Glyph_Image {
	x0, y0, x1, y1 := w, h, 0, 0
	for row in 0 ..< h {
		line := px[row * w * 4:][:w * 4]
		for col in 0 ..< w {
			if line[col * 4 + 3] == 0 { continue }
			x0, y0 = min(x0, col), min(y0, row)
			x1, y1 = max(x1, col + 1), max(y1, row + 1)
		}
	}
	if x1 <= x0 || y1 <= y0 { return Glyph_Image{page = -1, color = true} }
	gw, gh := x1 - x0, y1 - y0
	pi, ax, ay, ok := atlas_alloc(s, .Color, gw, gh)
	if !ok { return Glyph_Image{page = -1, color = true} }
	p := s.atlas.pages[pi]
	for row in 0 ..< gh {
		src := px[((y0 + row) * w + x0) * 4:][:gw * 4]
		dst := p.pixels[((ay + row) * p.size + ax) * 4:][:gw * 4]
		for col in 0 ..< gw {
			b, gg, r, a := src[col * 4], src[col * 4 + 1], src[col * 4 + 2], src[col * 4 + 3]
			if a == 0 { dst[col * 4], dst[col * 4 + 1], dst[col * 4 + 2], dst[col * 4 + 3] = 0, 0, 0, 0; continue }
			un :: #force_inline proc(v, a: u8) -> u8 { return u8(min((u32(v) * 255 + u32(a) / 2) / u32(a), 255)) }
			dst[col * 4], dst[col * 4 + 1], dst[col * 4 + 2], dst[col * 4 + 3] = un(r, a), un(gg, a), un(b, a), a
		}
	}
	page_log(p, ax, ay, gw, gh)
	p.glyphs += 1
	return Glyph_Image{
		page = i32(pi), color = true, uv = {f32(ax), f32(ay), f32(ax + gw), f32(ay + gh)},
		offset = {f32(x0 - origin.x), f32(y0 - origin.y)}, size = {f32(gw), f32(gh)}, epoch = p.epoch,
	}
}

@(private)
Layer :: struct {
	bounds: RECT,
	pixels: []u8,
	color:  [4]f32,   // sRGB, straight alpha
}

// Without Direct2D: the COLR / CPAL layers of the glyph rasterized and composited "over", layer after layer, on
// straight-alpha sRGB values (as Direct2D draws color fonts into an 8-bit target).
@(private)
rasterize_colr_layers :: proc(s: ^State, run: ^DWRITE_GLYPH_RUN, x: f32, fg: [3]u8) -> (Glyph_Image, bool, bool) {
	context.allocator = runtime.heap_allocator()
	if s.factory2 == nil { return {}, false, false }
	layers := make([dynamic]Layer, 0, 8, context.temp_allocator)
	uses_fg := false
	text := [4]f32{f32(fg[0]) / 255, f32(fg[1]) / 255, f32(fg[2]) / 255, 1}
	collect :: proc(s: ^State, layers: ^[dynamic]Layer, cr: ^DWRITE_COLOR_GLYPH_RUN, text: [4]f32, uses_fg: ^bool) {
		b, px, ok := coverage(s, &cr.glyphRun, cr.baselineOriginX, cr.baselineOriginY)
		if !ok || px == nil { return }
		col := [4]f32{cr.runColor.r, cr.runColor.g, cr.runColor.b, cr.runColor.a}
		if cr.paletteIndex == 0xFFFF { col = text; uses_fg^ = true }
		append(layers, Layer{b, px, col})
	}
	if s.factory4 != nil {
		e: ^IDWriteColorGlyphRunEnumerator1
		formats := DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE | DWRITE_GLYPH_IMAGE_FORMATS_CFF | DWRITE_GLYPH_IMAGE_FORMATS_COLR
		hr := s.factory4->TranslateColorGlyphRun4({x, 0}, run, nil, formats, .NATURAL, nil, 0, &e)
		if hr < 0 || e == nil { return {}, false, false }
		defer com_release(e)
		for {
			has: BOOL
			if e->MoveNext(&has) < 0 || !has { break }
			cr: ^DWRITE_COLOR_GLYPH_RUN1
			if e->GetCurrentRun1(&cr) < 0 || cr == nil { break }
			if cr.glyphImageFormat & formats == 0 { continue }
			collect(s, &layers, &cr.base, text, &uses_fg)
		}
	} else {
		e: ^IDWriteColorGlyphRunEnumerator
		hr := s.factory2->TranslateColorGlyphRun(x, 0, run, nil, .NATURAL, nil, 0, &e)
		if hr < 0 || e == nil { return {}, false, false }
		defer com_release(e)
		for {
			has: BOOL
			if e->MoveNext(&has) < 0 || !has { break }
			cr: ^DWRITE_COLOR_GLYPH_RUN
			if e->GetCurrentRun(&cr) < 0 || cr == nil { break }
			collect(s, &layers, cr, text, &uses_fg)
		}
	}
	if len(layers) == 0 { return Glyph_Image{page = -1, color = true}, false, true }
	u := layers[0].bounds
	for l in layers[1:] {
		u.left, u.top = min(u.left, l.bounds.left), min(u.top, l.bounds.top)
		u.right, u.bottom = max(u.right, l.bounds.right), max(u.bottom, l.bounds.bottom)
	}
	w, h := int(u.right - u.left), int(u.bottom - u.top)
	if w <= 0 || h <= 0 { return Glyph_Image{page = -1, color = true}, uses_fg, true }
	acc := make([]f32, w * h * 4, context.temp_allocator)
	for l in layers {
		lw := int(l.bounds.right - l.bounds.left)
		lh := int(l.bounds.bottom - l.bounds.top)
		ox, oy := int(l.bounds.left - u.left), int(l.bounds.top - u.top)
		for row in 0 ..< lh {
			for col in 0 ..< lw {
				cov := f32(l.pixels[row * lw + col]) / 255
				if cov <= 0 { continue }
				sa := cov * l.color[3]
				d := acc[((oy + row) * w + ox + col) * 4:][:4]
				da := d[3]
				oa := sa + da * (1 - sa)
				if oa <= 0 { continue }
				for k in 0 ..< 3 { d[k] = (l.color[k] * sa + d[k] * da * (1 - sa)) / oa }
				d[3] = oa
			}
		}
	}
	pi, ax, ay, ok := atlas_alloc(s, .Color, w, h)
	if !ok { return Glyph_Image{page = -1, color = true}, uses_fg, true }
	p := s.atlas.pages[pi]
	for row in 0 ..< h {
		dst := p.pixels[((ay + row) * p.size + ax) * 4:][:w * 4]
		for col in 0 ..< w {
			sv := acc[(row * w + col) * 4:][:4]
			for k in 0 ..< 4 { dst[col * 4 + k] = u8(clamp(sv[k] * 255 + 0.5, 0, 255)) }
		}
	}
	page_log(p, ax, ay, w, h)
	p.glyphs += 1
	return Glyph_Image{
		page = i32(pi), color = true, uv = {f32(ax), f32(ay), f32(ax + w), f32(ay + h)},
		offset = {f32(u.left), f32(u.top)}, size = {f32(w), f32(h)}, epoch = p.epoch,
	}, uses_fg, true
}
