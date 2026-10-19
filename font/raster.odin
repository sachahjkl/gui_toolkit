package font

import "core:math"
import "core:sync"

// Glyph bitmaps. Coverage (grayscale antialiasing, raw coverage: the renderer applies its text correction, see
// render.Text_Rendering) and color glyphs (COLR / CPAL layers composited to straight-alpha sRGB RGBA) are packed into
// atlas pages kept on the CPU; each draw context uploads what changed since it last looked (atlas_sync_page), so any
// number of renderers can share one font state.
//
// A page is never cleared while a frame may still draw from it: pages remember the atlas clock of their last use, every
// draw context the clock at the start of its frame; when the pages of a kind are all in use and the limit is reached,
// the least recently used page that no current frame has drawn from is cleared and reused, else one more page is made.
//
// Glyphs are cached per (face, glyph, size in 1/16 px, horizontal subpixel position). Rasterize from the threads that
// draw only (one lock).

Page_Kind :: enum u8 { Gray, Color }

// Where a glyph's bitmap is.
Glyph_Image :: struct {
	page:   i32,       // atlas page; -1: nothing to draw (a space, a glyph without outline)
	color:  bool,      // the page is a Color page (RGBA): draw it as an image, not as coverage
	uv:     [4]f32,    // texel rect in the page: x0 y0 x1 y1
	offset: [2]f32,    // top-left of the bitmap from the pen position (whole pixels) on the baseline
	size:   [2]f32,
}

@(private)
Dirty :: struct {
	x, y, w, h: i32,
	version:    u64,
}

@(private)
Shelf :: struct { y, h, x: int }

@(private)
Page :: struct {
	kind:      Page_Kind,
	size:      int,
	pixels:    []u8,           // size * size (Gray) or size * size * 4 (Color: RGBA, sRGB, straight alpha)
	shelves:   [dynamic]Shelf,
	bottom:    int,            // first row no shelf uses
	version:   u64,            // bumps with every change
	log:       [dynamic]Dirty, // changes after log_from
	log_from:  u64,
	last_used: u64,            // atlas clock of the last frame that drew from it
	glyphs:    int,
}

@(private)
Atlas :: struct {
	mu:     sync.Mutex,
	pages:  [dynamic]^Page,
	glyphs: map[u64]Glyph_Image,
	clock:  u64,
	users:  map[rawptr]u64,    // draw contexts: the clock at the start of their current frame
	evictions: int,
}

@(private) LOG_MAX :: 4096

@(private)
atlas_init :: proc(a: ^Atlas) {
	a.glyphs = make(map[u64]Glyph_Image)
	a.users = make(map[rawptr]u64)
	a.clock = 1
}

@(private)
atlas_destroy :: proc(a: ^Atlas) {
	for p in a.pages { delete(p.pixels); delete(p.shelves); delete(p.log); free(p) }
	delete(a.pages)
	delete(a.glyphs)
	delete(a.users)
}

@(private) atlas_lock :: proc(a: ^Atlas) { sync.mutex_lock(&a.mu) }
@(private) atlas_unlock :: proc(a: ^Atlas) { sync.mutex_unlock(&a.mu) }

@(private)
atlas_forget_face :: proc(a: ^Atlas, face: Font_Id) {
	atlas_lock(a)
	defer atlas_unlock(a)
	for k in a.glyphs {
		if Font_Id(k >> 44) == face { delete_key(&a.glyphs, k) }
	}
}

// A draw context starts a frame: pages it draws from until its next frame are kept.
atlas_begin_frame :: proc(s: ^State, user: rawptr) {
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	a.clock += 1
	a.users[user] = a.clock
}

// A draw context goes away.
atlas_remove_user :: proc(s: ^State, user: rawptr) {
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	delete_key(&a.users, user)
}

// Drops every glyph bitmap (rendering settings changed); pages are cleared as they are reused.
clear_atlas :: proc(s: ^State) {
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	clear(&a.glyphs)
	for p in a.pages { page_reset(p) }
}

atlas_page_count :: proc(s: ^State) -> int {
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	return len(a.pages)
}

// Kind, size (texels on a side) and version of page `i`.
atlas_page_info :: proc(s: ^State, i: int) -> (kind: Page_Kind, size: int, version: u64) {
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	if i < 0 || i >= len(a.pages) { return }
	p := a.pages[i]
	return p.kind, p.size, p.version
}

Upload_Proc :: #type proc(user: rawptr, page: int, kind: Page_Kind, x, y, w, h: int, pixels: []u8, stride: int)

// Calls `upload` with every part of page `i` that changed after version `since` (all of it when `since` is 0 or too
// old). Returns the version the caller now has.
atlas_sync_page :: proc(s: ^State, i: int, since: u64, user: rawptr, upload: Upload_Proc) -> u64 {
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	if i < 0 || i >= len(a.pages) { return since }
	p := a.pages[i]
	if since == p.version { return since }
	bpp := p.kind == .Color ? 4 : 1
	stride := p.size * bpp
	if since == 0 || since < p.log_from {
		used := max(p.bottom, 1)
		upload(user, i, p.kind, 0, 0, p.size, min(used, p.size), p.pixels[:], stride)
		return p.version
	}
	for d in p.log {
		if d.version <= since { continue }
		off := int(d.y) * stride + int(d.x) * bpp
		upload(user, i, p.kind, int(d.x), int(d.y), int(d.w), int(d.h), p.pixels[off:], stride)
	}
	return p.version
}

@(private)
page_reset :: proc(p: ^Page) {
	for i in 0 ..< len(p.pixels) { p.pixels[i] = 0 }
	clear(&p.shelves)
	clear(&p.log)
	p.version += 1
	p.log_from = p.version   // users behind this upload the page again
	p.bottom = 0
	p.glyphs = 0
}

@(private)
page_alloc :: proc(p: ^Page, w, h: int) -> (x, y: int, ok: bool) {
	pad :: 1
	pw, ph := w + pad, h + pad
	if pw > p.size || ph > p.size { return 0, 0, false }
	best := -1
	for sh, i in p.shelves {
		if sh.h < ph || sh.h > ph + ph / 2 + 2 || sh.x + pw > p.size { continue }
		if best < 0 || sh.h < p.shelves[best].h { best = i }
	}
	if best < 0 {
		hh := (ph + 3) &~ 3
		if p.bottom + hh > p.size { return 0, 0, false }
		append(&p.shelves, Shelf{y = p.bottom, h = hh})
		p.bottom += hh
		best = len(p.shelves) - 1
	}
	sh := &p.shelves[best]
	x, y = sh.x, sh.y
	sh.x += pw
	return x, y, true
}

@(private)
page_log :: proc(p: ^Page, x, y, w, h: int) {
	p.version += 1
	if len(p.log) >= LOG_MAX {
		p.log_from = p.log[LOG_MAX / 2 - 1].version
		copy(p.log[:], p.log[LOG_MAX / 2:])
		resize(&p.log, len(p.log) - LOG_MAX / 2)
	}
	append(&p.log, Dirty{i32(x), i32(y), i32(w), i32(h), p.version})
}

// Room for a w x h bitmap in a page of `kind`. Caller holds the lock.
@(private)
atlas_alloc :: proc(s: ^State, kind: Page_Kind, w, h: int) -> (page, x, y: int, ok: bool) {
	a := &s.atlas
	n_kind := 0
	for p, i in a.pages {
		if p.kind != kind { continue }
		n_kind += 1
		if x, y, ok = page_alloc(p, w, h); ok { return i, x, y, true }
	}
	limit := kind == .Color ? s.settings.max_color_pages : s.settings.max_gray_pages
	if n_kind >= limit {
		// the least recently used page no current frame draws from
		oldest := max(u64)
		for _, start in a.users { oldest = min(oldest, start) }
		if len(a.users) == 0 { oldest = a.clock }
		victim := -1
		for p, i in a.pages {
			if p.kind != kind || p.last_used >= oldest { continue }
			if victim < 0 || p.last_used < a.pages[victim].last_used { victim = i }
		}
		if victim >= 0 {
			for k, g in a.glyphs { if int(g.page) == victim { delete_key(&a.glyphs, k) } }
			page_reset(a.pages[victim])
			a.evictions += 1
			if x, y, ok = page_alloc(a.pages[victim], w, h); ok { return victim, x, y, true }
		}
	}
	size := s.settings.page_size
	p := new(Page)
	p.kind, p.size = kind, size
	p.pixels = make([]u8, size * size * (kind == .Color ? 4 : 1))
	p.version, p.log_from = 1, 1
	append(&a.pages, p)
	if x, y, ok = page_alloc(p, w, h); ok { return len(a.pages) - 1, x, y, true }
	return 0, 0, 0, false
}

// Pages evicted so far (diagnostics, tests).
atlas_evictions :: proc(s: ^State) -> int {
	atlas_lock(&s.atlas)
	defer atlas_unlock(&s.atlas)
	return s.atlas.evictions
}

@(private)
glyph_key :: #force_inline proc(face: Font_Id, gid: u16, size: f32, sub: int) -> u64 {
	sq := u64(clamp(math.round(size * 16), 1, (1 << 20) - 1))
	return u64(face) << 44 | u64(gid) << 28 | sq << 8 | u64(sub)
}

// Subpixel position (0 ..< subpixel_steps) and whole pixel of a pen x on the screen.
subpixel :: proc(s: ^State, x: f32) -> (ix: f32, sub: int) {
	n := f32(s.settings.subpixel_steps)
	ix = math.floor(x)
	sub = int(math.round((x - ix) * n))
	if sub >= int(n) { sub = 0; ix += 1 }
	return
}

// The bitmap of glyph `gid` of `face` at `size` px, its pen at subpixel position `sub` (see `subpixel`). Rasterized
// on first use. Call from drawing threads only.
glyph_image :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, sub: int) -> Glyph_Image {
	a := &s.atlas
	key := glyph_key(face, gid, size, sub)
	atlas_lock(a)
	defer atlas_unlock(a)
	if g, ok := a.glyphs[key]; ok {
		if g.page >= 0 { a.pages[g.page].last_used = a.clock }
		return g
	}
	g := rasterize(s, face, gid, size, f32(sub) / f32(s.settings.subpixel_steps))
	a.glyphs[key] = g
	if g.page >= 0 { a.pages[g.page].last_used = a.clock }
	return g
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
rasterize :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, x: f32) -> Glyph_Image {
	blank := Glyph_Image{page = -1}
	f := face_ptr(s, face)
	if f == nil || s.factory == nil || size <= 0 { return blank }
	ids := [1]u16{gid}
	advs := [1]f32{0}
	offs := [1]DWRITE_GLYPH_OFFSET{}
	run := DWRITE_GLYPH_RUN{fontFace = f.dw, fontEmSize = size, glyphCount = 1, glyphIndices = &ids[0], glyphAdvances = &advs[0], glyphOffsets = &offs[0]}
	if f.color && s.settings.color_glyphs && s.factory2 != nil {
		if g, ok := rasterize_color(s, &run, x); ok { return g }
	}
	bounds, px, ok := coverage(s, &run, x, 0)
	if !ok || px == nil { return blank }
	w, h := int(bounds.right - bounds.left), int(bounds.bottom - bounds.top)
	pi, ax, ay, aok := atlas_alloc(s, .Gray, w, h)
	if !aok { return blank }
	p := s.atlas.pages[pi]
	for row in 0 ..< h { copy(p.pixels[(ay + row) * p.size + ax:][:w], px[row * w:][:w]) }
	page_log(p, ax, ay, w, h)
	p.glyphs += 1
	return Glyph_Image{
		page = i32(pi), uv = {f32(ax), f32(ay), f32(ax + w), f32(ay + h)},
		offset = {f32(bounds.left), f32(bounds.top)}, size = {f32(w), f32(h)},
	}
}

@(private)
Layer :: struct {
	bounds: RECT,
	pixels: []u8,
	color:  [4]f32,   // sRGB, straight alpha
}

// COLR / CPAL glyph: its layers composited into a Color page. ok = false: not a color glyph (draw its outline).
@(private)
rasterize_color :: proc(s: ^State, run: ^DWRITE_GLYPH_RUN, x: f32) -> (Glyph_Image, bool) {
	layers := make([dynamic]Layer, 0, 8, context.temp_allocator)
	collect :: proc(s: ^State, layers: ^[dynamic]Layer, cr: ^DWRITE_COLOR_GLYPH_RUN) {
		b, px, ok := coverage(s, &cr.glyphRun, cr.baselineOriginX, cr.baselineOriginY)
		if !ok || px == nil { return }
		col := [4]f32{cr.runColor.r, cr.runColor.g, cr.runColor.b, cr.runColor.a}
		if cr.paletteIndex == 0xFFFF { col = {0, 0, 0, 1} }   // "text color" layers: no text color is known here
		append(layers, Layer{b, px, col})
	}
	if s.factory4 != nil {
		e: ^IDWriteColorGlyphRunEnumerator1
		formats := DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE | DWRITE_GLYPH_IMAGE_FORMATS_CFF | DWRITE_GLYPH_IMAGE_FORMATS_COLR
		hr := s.factory4->TranslateColorGlyphRun4({x, 0}, run, nil, formats, .NATURAL, nil, 0, &e)
		if hr < 0 || e == nil { return {}, false }
		defer com_release(e)
		for {
			has: BOOL
			if e->MoveNext(&has) < 0 || !has { break }
			cr: ^DWRITE_COLOR_GLYPH_RUN1
			if e->GetCurrentRun1(&cr) < 0 || cr == nil { break }
			if cr.glyphImageFormat & (DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE | DWRITE_GLYPH_IMAGE_FORMATS_CFF | DWRITE_GLYPH_IMAGE_FORMATS_COLR) == 0 { continue }
			collect(s, &layers, &cr.base)
		}
	} else {
		e: ^IDWriteColorGlyphRunEnumerator
		hr := s.factory2->TranslateColorGlyphRun(x, 0, run, nil, .NATURAL, nil, 0, &e)
		if hr < 0 || e == nil { return {}, false }
		defer com_release(e)
		for {
			has: BOOL
			if e->MoveNext(&has) < 0 || !has { break }
			cr: ^DWRITE_COLOR_GLYPH_RUN
			if e->GetCurrentRun(&cr) < 0 || cr == nil { break }
			collect(s, &layers, cr)
		}
	}
	if len(layers) == 0 { return Glyph_Image{page = -1, color = true}, true }
	u := layers[0].bounds
	for l in layers[1:] {
		u.left, u.top = min(u.left, l.bounds.left), min(u.top, l.bounds.top)
		u.right, u.bottom = max(u.right, l.bounds.right), max(u.bottom, l.bounds.bottom)
	}
	w, h := int(u.right - u.left), int(u.bottom - u.top)
	if w <= 0 || h <= 0 { return Glyph_Image{page = -1, color = true}, true }
	// "over", layer after layer, on straight-alpha sRGB values (as Direct2D draws color fonts into an 8-bit target)
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
	if !ok { return Glyph_Image{page = -1, color = true}, true }
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
		offset = {f32(u.left), f32(u.top)}, size = {f32(w), f32(h)},
	}, true
}
