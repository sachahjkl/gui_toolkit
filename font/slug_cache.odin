package font

import "base:runtime"

// The Slug glyph store: per (face, glyph) the curve and band texels of slug_build, kept in pages that mirror the two GPU
// textures (curves RGBA16F, bands RG16UI, both SLUG_TEXTURE_WIDTH wide; page k is row k of each). A glyph's data lies
// in one page, bump-allocated. Pages are never cleared while a frame may still draw from them (the same clock as the
// atlas: see raster.odin): when `Settings.slug_pages` are all in use the least recently used page no current frame
// draws from is cleared and reused (its glyphs are forgotten, its epoch bumps and recorded pictures that drew from it
// go stale, see Page_Ref), else one more is made. Draw contexts upload the pages that changed (slug_sync_page).
// Lookups and the store share the atlas lock.

Slug_Kind :: enum u8 {
	Curves,   // drawn by the Slug shaders from the data at `loc`
	Blank,    // nothing to draw (a space)
	Atlas,    // not drawable this way (a color glyph, an outline the provider lacks, too much data): use the atlas
}

Slug_Glyph :: struct {
	kind:      Slug_Kind,
	page:      i32,
	epoch:     u32,
	loc:       [2]u16,     // glyph band data in the band texture (x, y = page)
	band_max:  [2]u8,      // vertical bands - 1, horizontal bands - 1
	transform: [4]f32,     // band scale x, y, offset x, y
	bbox:      [4]f32,     // em units, y up
}

@(private)
Slug_Page :: struct {
	curves:    [][4]f16,   // SLUG_TEXTURE_WIDTH texels
	bands:     [][2]u16,
	cu, bu:    int,        // texels used
	version:   u64,
	last_used: u64,        // atlas clock
	epoch:     u32,
	glyphs:    int,
}

@(private)
Slug_Store :: struct {
	pages:     [dynamic]^Slug_Page,
	glyphs:    map[u64]Slug_Glyph,
	provider:  Outline_Provider,
	evictions: int,
	built:     int,           // glyphs built (diagnostics)
	blanks:    int,
}

@(private)
slug_key :: #force_inline proc(face: Font_Id, gid: u16) -> u64 { return u64(face) << 16 | u64(gid) }

@(private)
slug_init :: proc(st: ^Slug_Store) {
	context.allocator = runtime.heap_allocator()
	st.glyphs = make(map[u64]Slug_Glyph)
	// the provider is the backend's (init sets it)
}

@(private)
slug_destroy :: proc(st: ^Slug_Store) {
	context.allocator = runtime.heap_allocator()
	for p in st.pages { delete(p.curves); delete(p.bands); free(p) }
	delete(st.pages)
	delete(st.glyphs)
}

@(private)
slug_forget_face :: proc(st: ^Slug_Store, face: Font_Id) {
	for k in st.glyphs { if Font_Id(k >> 16) == face { delete_key(&st.glyphs, k) } }
}

// Forgets every glyph and clears every page (settings that shape the data changed).
@(private)
slug_clear :: proc(st: ^Slug_Store) {
	clear(&st.glyphs)
	for p in st.pages { slug_page_reset(p) }
}

@(private)
slug_page_reset :: proc(p: ^Slug_Page) {
	p.cu, p.bu, p.glyphs = 0, 0, 0
	p.version += 1
	p.epoch += 1
}

// Replaces where outlines come from (a TrueType / CFF reader on another platform, a test). Glyphs already built stay.
slug_set_provider :: proc(s: ^State, p: Outline_Provider) {
	atlas_lock(&s.atlas)
	defer atlas_unlock(&s.atlas)
	s.atlas.slug.provider = p
}

// The glyph data of `gid` of `face`, built on first use. Call from the threads that draw (the atlas lock is taken).
slug_glyph :: proc(s: ^State, face: Font_Id, gid: u16) -> Slug_Glyph {
	context.allocator = runtime.heap_allocator()
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	st := &a.slug
	key := slug_key(face, gid)
	if g, ok := st.glyphs[key]; ok {
		if g.kind == .Curves { st.pages[g.page].last_used = a.clock }
		return g
	}
	g := slug_make(s, face, gid)
	st.glyphs[key] = g
	return g
}

// Caller holds the atlas lock.
@(private)
slug_make :: proc(s: ^State, face: Font_Id, gid: u16) -> Slug_Glyph {
	atlas_fallback := Slug_Glyph{kind = .Atlas, page = -1}
	st := &s.atlas.slug
	f := face_ptr(s, face)
	if f == nil || st.provider == nil || !s.ok { return atlas_fallback }
	if f.color && s.settings.color_glyphs && platform_color_glyph(s, f, gid, 32) { return atlas_fallback }
	o: Outline
	defer outline_destroy(&o)
	if !st.provider(s, face, gid, s.settings.slug_tolerance, &o) { return atlas_fallback }
	if len(o.quads) == 0 { st.blanks += 1; return Slug_Glyph{kind = .Blank, page = -1} }
	b: Slug_Built
	defer slug_built_destroy(&b)
	if !slug_build(&o, &b) { return atlas_fallback }
	pi := slug_alloc(s, len(b.curves), len(b.bands))
	if pi < 0 { return atlas_fallback }
	p := st.pages[pi]
	cx, bx := p.cu, p.bu
	slug_patch_lists(&b, cx, pi)
	copy(p.curves[cx:], b.curves[:])
	copy(p.bands[bx:], b.bands[:])
	p.cu += len(b.curves)
	p.bu += len(b.bands)
	p.version += 1
	p.last_used = s.atlas.clock
	p.glyphs += 1
	st.built += 1
	return Slug_Glyph{
		kind = .Curves, page = i32(pi), epoch = p.epoch, loc = {u16(bx), u16(pi)},
		band_max = {u8(b.n_v - 1), u8(b.n_h - 1)}, transform = b.transform, bbox = b.bbox,
	}
}

// A page with room for `nc` curve texels and `nb` band texels, -1 when the glyph cannot be stored.
@(private)
slug_alloc :: proc(s: ^State, nc, nb: int) -> int {
	a := &s.atlas
	st := &a.slug
	for i := len(st.pages) - 1; i >= 0; i -= 1 {
		p := st.pages[i]
		if p.cu + nc <= SLUG_TEXTURE_WIDTH && p.bu + nb <= SLUG_TEXTURE_WIDTH { return i }
	}
	if len(st.pages) >= s.settings.slug_pages {
		oldest := max(u64)
		for _, start in a.users { oldest = min(oldest, start) }
		if len(a.users) == 0 { oldest = a.clock }
		victim := -1
		for p, i in st.pages {
			if p.last_used >= oldest { continue }
			if victim < 0 || p.last_used < st.pages[victim].last_used { victim = i }
		}
		if victim >= 0 {
			for k, g in st.glyphs { if g.kind == .Curves && int(g.page) == victim { delete_key(&st.glyphs, k) } }
			slug_page_reset(st.pages[victim])
			st.evictions += 1
			return victim
		}
	}
	if len(st.pages) >= SLUG_MAX_PAGES { return -1 }
	p := new(Slug_Page)
	p.curves = make([][4]f16, SLUG_TEXTURE_WIDTH)
	p.bands = make([][2]u16, SLUG_TEXTURE_WIDTH)
	p.version = 1
	append(&st.pages, p)
	return len(st.pages) - 1
}

// The most pages (texture rows) the store ever makes, whatever the setting asks.
SLUG_MAX_PAGES :: 2048

slug_page_count :: proc(s: ^State) -> int {
	atlas_lock(&s.atlas)
	defer atlas_unlock(&s.atlas)
	return len(s.atlas.slug.pages)
}

Slug_Upload_Proc :: #type proc(user: rawptr, page: int, curves: [][4]f16, bands: [][2]u16)

// Calls `upload` with the used part of page `i` when it changed after version `since`. Returns the version the caller now has.
slug_sync_page :: proc(s: ^State, i: int, since: u64, user: rawptr, upload: Slug_Upload_Proc) -> u64 {
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	st := &a.slug
	if i < 0 || i >= len(st.pages) { return since }
	p := st.pages[i]
	if since == p.version { return since }
	if p.cu > 0 || p.bu > 0 { upload(user, i, p.curves[:p.cu], p.bands[:p.bu]) }
	return p.version
}

// Whether the pages `refs` point at are all still as they were (nothing reused); if so they count as used by the
// current frame, like atlas_pages_hold.
slug_pages_hold :: proc(s: ^State, refs: []Page_Ref) -> bool {
	a := &s.atlas
	atlas_lock(a)
	defer atlas_unlock(a)
	st := &a.slug
	for r in refs {
		if r.page < 0 || int(r.page) >= len(st.pages) || st.pages[r.page].epoch != r.epoch { return false }
	}
	for r in refs { st.pages[r.page].last_used = a.clock }
	return true
}

Slug_Stats :: struct {
	pages:     int,
	glyphs:    int,    // glyphs with data in the store
	built:     int,    // built since the start
	evictions: int,
	curve_bytes, band_bytes: int,   // CPU memory of the pages (the GPU textures are as large)
	used_bytes: int,                // texels holding data
}

slug_stats :: proc(s: ^State) -> (r: Slug_Stats) {
	atlas_lock(&s.atlas)
	defer atlas_unlock(&s.atlas)
	st := &s.atlas.slug
	r.pages, r.built, r.evictions = len(st.pages), st.built, st.evictions
	for p in st.pages {
		r.glyphs += p.glyphs
		r.curve_bytes += len(p.curves) * size_of([4]f16)
		r.band_bytes += len(p.bands) * size_of([2]u16)
		r.used_bytes += p.cu * size_of([4]f16) + p.bu * size_of([2]u16)
	}
	return
}
