package font

import "base:runtime"
import "core:math"
import "core:sync"

// Glyph bitmaps. Coverage (grayscale antialiasing, raw coverage: the renderer applies its text correction, see
// render.Text_Rendering) and color glyphs (every color format, drawn by Direct2D: color.odin) are packed into
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
	epoch:  u32,       // the page's epoch when the bitmap was put there (see Page_Ref)
	uses_fg: bool,     // a color glyph with layers in the text color: kept once per text color
	pending: bool,     // a color glyph being drawn (Settings.color_async): nothing to draw yet (see color_async.odin)
}

@(private)
Fg_Key :: struct {
	key: u64,
	fg:  [3]u8,
}

// A page as something recorded saw it: the bitmaps it points at are still there while the page's epoch is the same
// (a page cleared for reuse, or by clear_atlas, starts a new epoch). Retained drawing keeps these (draw.Picture).
Page_Ref :: struct {
	page:  i32,
	epoch: u32,
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
	epoch:     u32,            // bumps when the page is cleared (its bitmaps are gone)
}

@(private)
Atlas :: struct {
	mu:     sync.Mutex,
	pages:  [dynamic]^Page,
	glyphs: map[u64]Glyph_Image,
	fg_glyphs: map[Fg_Key]Glyph_Image,   // color glyphs that use the text color, per color (`glyphs` marks them)
	pending:   map[u64]bool,             // color glyphs queued (color_async.odin), by key
	fg_pending: map[Fg_Key]bool,         // ... and those known to use the text color, by key and color
	clock:  u64,
	users:  map[rawptr]u64,    // draw contexts: the clock at the start of their current frame
	evictions: int,
	settings_generation: u64,  // bumps when the rendering settings change (bitmaps made before no longer match)
	slug:   Slug_Store,        // glyph curves of the Slug renderer (slug_cache.odin); shares the lock and the clock
}

@(private) LOG_MAX :: 4096

@(private)
atlas_init :: proc(a: ^Atlas) {
	context.allocator = runtime.heap_allocator()
	a.glyphs = make(map[u64]Glyph_Image)
	a.fg_glyphs = make(map[Fg_Key]Glyph_Image)
	a.pending = make(map[u64]bool)
	a.fg_pending = make(map[Fg_Key]bool)
	a.users = make(map[rawptr]u64)
	a.clock = 1
	slug_init(&a.slug)
}

@(private)
atlas_destroy :: proc(a: ^Atlas) {
	context.allocator = runtime.heap_allocator()
	for p in a.pages { delete(p.pixels); delete(p.shelves); delete(p.log); free(p) }
	delete(a.pages)
	delete(a.glyphs)
	delete(a.fg_glyphs)
	delete(a.pending)
	delete(a.fg_pending)
	delete(a.users)
	slug_destroy(&a.slug)
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
	for k in a.fg_glyphs {
		if Font_Id(k.key >> 44) == face { delete_key(&a.fg_glyphs, k) }
	}
	for k in a.pending { if Font_Id(k >> 44) == face { delete_key(&a.pending, k) } }
	for k in a.fg_pending { if Font_Id(k.key >> 44) == face { delete_key(&a.fg_pending, k) } }
	slug_forget_face(&a.slug, face)
}

// A draw context starts a frame: pages it draws from until its next frame are kept.
atlas_begin_frame :: proc(s: ^State, user: rawptr) {
	context.allocator = runtime.heap_allocator()
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
	clear(&a.fg_glyphs)
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
	p.epoch += 1
}

// The rendering settings' generation (set_settings): glyph bitmaps of an older generation were made differently.
atlas_settings_generation :: proc(s: ^State) -> u64 {
	atlas_lock(&s.atlas)
	defer atlas_unlock(&s.atlas)
	return s.atlas.settings_generation
}

// Whether the bitmaps `refs` point at are all still in the atlas; if so their pages count as used by the current
// frame of every draw context (not reused before those frames end), as if their glyphs had been looked up again.
atlas_pages_hold :: proc(s: ^State, refs: []Page_Ref) -> bool {
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	for r in refs {
		if r.page < 0 || int(r.page) >= len(a.pages) || a.pages[r.page].epoch != r.epoch { return false }
	}
	for r in refs { a.pages[r.page].last_used = a.clock }
	return true
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
	context.allocator = runtime.heap_allocator()
	a := &s.atlas
	// a bitmap (with its pad) that is bigger than a page can never be placed: no eviction, no page made for nothing
	if w + 1 > s.settings.page_size || h + 1 > s.settings.page_size { return 0, 0, 0, false }
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
			for k, g in a.fg_glyphs { if int(g.page) == victim { delete_key(&a.fg_glyphs, k) } }
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

// The largest size (px per em) a glyph is rasterized at: its bitmap, at most about twice the em on a side, then fits an
// atlas page. Text above it is rasterized at this size and stretched by the draw layer (draw.glyph_run does).
raster_size_limit :: proc(s: ^State) -> f32 {
	return max(f32(s.settings.page_size) / 2, 64)
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
// on first use. `fg` (sRGB) is the text color: only color glyphs with layers in the text color depend on it (coverage
// is colored when drawn). Call from drawing threads only.
glyph_image :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, sub: int, fg: [3]u8 = {}) -> Glyph_Image {
	context.allocator = runtime.heap_allocator()
	a := &s.atlas
	key := glyph_key(face, gid, size, sub)
	atlas_lock(a)
	defer atlas_unlock(a)
	x := f32(sub) / f32(s.settings.subpixel_steps)
	if g, ok := a.glyphs[key]; ok {
		if !g.uses_fg {
			if g.page >= 0 { a.pages[g.page].last_used = a.clock }
			return g
		}
		fk := Fg_Key{key, fg}
		if fg_g, found := a.fg_glyphs[fk]; found {
			if fg_g.page >= 0 { a.pages[fg_g.page].last_used = a.clock }
			return fg_g
		}
		if s.settings.color_async {
			if fk in a.fg_pending { return Glyph_Image{page = -1, color = true, pending = true} }
			if color_enqueue(s, Color_Job{key = key, fg = fg, known_fg = true, face = face, gid = gid, size = size, x = x, settings = a.settings_generation}) {
				a.fg_pending[fk] = true
				return Glyph_Image{page = -1, color = true, pending = true}
			}
		}
		fg_g, _ := rasterize(s, face, gid, size, x, fg, false)
		fg_g.uses_fg = true
		a.fg_glyphs[fk] = fg_g
		if fg_g.page >= 0 { a.pages[fg_g.page].last_used = a.clock }
		return fg_g
	}
	if key in a.pending { return Glyph_Image{page = -1, color = true, pending = true} }
	if s.settings.color_async && s.settings.color_glyphs {
		// a color glyph is drawn on the color glyph thread (outlines of color faces are rasterized here)
		if f := face_ptr(s, face); f != nil && f.color && s.factory != nil && size > 0 && is_color_glyph(s, f, gid, size) {
			if color_enqueue(s, Color_Job{key = key, fg = fg, face = face, gid = gid, size = size, x = x, settings = a.settings_generation}) {
				a.pending[key] = true
				return Glyph_Image{page = -1, color = true, pending = true}
			}
		}
	}
	g, uses_fg := rasterize(s, face, gid, size, x, fg, true)
	if uses_fg {
		g.uses_fg = true
		a.glyphs[key] = Glyph_Image{page = -1, color = true, uses_fg = true}
		a.fg_glyphs[Fg_Key{key, fg}] = g
	} else {
		a.glyphs[key] = g
	}
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
rasterize :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, x: f32, fg: [3]u8, probe_fg: bool) -> (Glyph_Image, bool) {
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
			if g, uses_fg, ok := rasterize_colr(s, face, f, gid, size, x, fg); ok { return g, uses_fg }
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
