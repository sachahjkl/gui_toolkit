#+build windows
package font

import "base:runtime"
import "core:sync"

// The COLR interpreter (colr.odin) on a face: its COLR and CPAL tables come from DirectWrite (TryGetFontTable, so
// system fonts, files and memory fonts alike), its glyph outlines from the Slug outline provider, kept per face in a
// cache of limited size. Settings.color_engine = .Builtin makes these faces' color glyphs come from here instead of
// Direct2D (color.odin); the bitmaps then go to the same Color pages, the same async queue and the same text-color
// handling as the others. With .System the glyphs whose paint graph nests a PaintGlyph in a PaintGlyph still come from here:
// Direct2D of Windows 11 24H2 as first released crashes on them (colr_nests_glyph).

@(private)
Face_Colr :: struct {
	c:        ^Colr,
	colr_ctx: rawptr,
	cpal_ctx: rawptr,
	gsub:     []u8,               // for the sequences DirectWrite does not form (tag sequences), see colr_gsub.odin
	gsub_ctx: rawptr,
	mu:       sync.Mutex,
	outlines: map[u16]^Outline,   // em units; emptied (between renders) when over the budget
	bytes:    int,
	active:   int,                // renders in progress: their outlines must not be freed
	nested:   map[u16]bool,       // colr_nests_glyph per glyph, once asked (under mu)
}

// Opens the tables of `f` (nil: no COLR table, or one that does not parse; `refused` tells the second: the face has a
// COLR table nothing here can read, which the system is not given either).
@(private)
face_colr_open :: proc(f: ^Font) -> (fc: ^Face_Colr, refused: bool) {
	context.allocator = runtime.heap_allocator()
	fc = new(Face_Colr)
	read :: proc(f: ^Font, tag: string) -> (data: []u8, ctx: rawptr) {
		p: rawptr
		n: u32
		exists: BOOL
		if f.dw->TryGetFontTable(ot_tag(tag), &p, &n, &ctx, &exists) < 0 || !exists || p == nil || n == 0 { return nil, nil }
		return ([^]u8)(p)[:n], ctx
	}
	colr, cpal: []u8
	colr, fc.colr_ctx = read(f, "COLR")
	if colr == nil { free(fc); return nil, false }
	cpal, fc.cpal_ctx = read(f, "CPAL")
	fc.c = colr_open(colr, cpal)
	if fc.c == nil {
		f.dw->ReleaseFontTable(fc.colr_ctx)
		if fc.cpal_ctx != nil { f.dw->ReleaseFontTable(fc.cpal_ctx) }
		free(fc)
		return nil, true
	}
	fc.gsub, fc.gsub_ctx = read(f, "GSUB")
	fc.outlines = make(map[u16]^Outline)
	fc.nested = make(map[u16]bool)
	return fc, false
}

@(private)
face_colr_close :: proc(f: ^Font) {
	context.allocator = runtime.heap_allocator()
	fc := f.colr
	if fc == nil { return }
	f.colr = nil
	for _, o in fc.outlines { outline_destroy(o); free(o) }
	delete(fc.outlines)
	delete(fc.nested)
	colr_destroy(fc.c)
	if f.dw != nil {
		f.dw->ReleaseFontTable(fc.colr_ctx)
		if fc.cpal_ctx != nil { f.dw->ReleaseFontTable(fc.cpal_ctx) }
		if fc.gsub_ctx != nil { f.dw->ReleaseFontTable(fc.gsub_ctx) }
	}
	free(fc)
}

@(private)
Colr_Job :: struct {
	s:    ^State,
	face: Font_Id,
	fc:   ^Face_Colr,
}

// Outline of `gid` for the interpreter (cached). The pointer stays valid until the render ends: a cache over its
// budget is only emptied when no render is in progress.
@(private)
colr_outline :: proc(user: rawptr, gid: u16) -> ^Outline {
	j := (^Colr_Job)(user)
	fc := j.fc
	sync.mutex_lock(&fc.mu)
	if o, ok := fc.outlines[gid]; ok {
		sync.mutex_unlock(&fc.mu)
		return len(o.quads) > 0 ? o : nil
	}
	sync.mutex_unlock(&fc.mu)
	context.allocator = runtime.heap_allocator()
	o := new(Outline)
	provider := j.s.atlas.slug.provider
	if provider == nil || !provider(j.s, j.face, gid, j.s.settings.slug_tolerance, o) { outline_destroy(o) }
	n := size_of(Outline) + len(o.quads) * size_of(Quad) + len(o.ends) * size_of(int)
	sync.mutex_lock(&fc.mu)
	defer sync.mutex_unlock(&fc.mu)
	if prior, ok := fc.outlines[gid]; ok {   // made meanwhile by another thread
		outline_destroy(o)
		free(o)
		return len(prior.quads) > 0 ? prior : nil
	}
	fc.outlines[gid] = o
	fc.bytes += n
	return len(o.quads) > 0 ? o : nil
}

@(private)
face_colr_begin :: proc(s: ^State, fc: ^Face_Colr) {
	sync.mutex_lock(&fc.mu)
	defer sync.mutex_unlock(&fc.mu)
	if fc.active == 0 && fc.bytes > s.settings.colr_cache_kb * 1024 {
		for _, o in fc.outlines { outline_destroy(o); free(o) }
		clear(&fc.outlines)
		fc.bytes = 0
	}
	fc.active += 1
}

@(private)
face_colr_end :: proc(fc: ^Face_Colr) {
	sync.mutex_lock(&fc.mu)
	fc.active -= 1
	sync.mutex_unlock(&fc.mu)
}

// Whether the interpreter draws glyph `gid` of `f` (it has a color description there): with Color_Engine.Builtin, every
// glyph it can read; with .System, the glyphs Direct2D must not be given (`colr_avoids_system`).
@(private)
colr_draws :: proc(s: ^State, f: ^Font, gid: u16) -> bool {
	if !s.settings.color_glyphs || f.colr == nil || !colr_has_glyph(f.colr.c, gid) { return false }
	return s.settings.color_engine == .Builtin || colr_nests_glyph_cached(f.colr, gid)
}

@(private)
colr_nests_glyph_cached :: proc(fc: ^Face_Colr, gid: u16) -> bool {
	sync.mutex_lock(&fc.mu)
	nested, known := fc.nested[gid]
	sync.mutex_unlock(&fc.mu)
	if known { return nested }
	nested = colr_nests_glyph(fc.c, gid)
	sync.mutex_lock(&fc.mu)
	fc.nested[gid] = nested
	sync.mutex_unlock(&fc.mu)
	return nested
}

// Whether glyph `gid` of face `id` is drawn by the interpreter even though Direct2D is the color engine: its paint graph
// nests a PaintGlyph in another PaintGlyph (`colr_nests_glyph`), which Direct2D of Windows 11 24H2 as first released
// (d2d1.dll 10.0.26100.1) crashes on. A test that compares the two engines leaves these glyphs out.
colr_avoids_system :: proc(s: ^State, id: Font_Id, gid: u16) -> bool {
	f := face_ptr(s, id)
	if f == nil || f.colr == nil || !colr_has_glyph(f.colr.c, gid) { return false }
	return colr_nests_glyph_cached(f.colr, gid)
}

// Draws the glyph (pen at subpixel x) with the interpreter. The bitmap is heap memory the caller frees (colr_put does).
// Takes no lock of the atlas: it can run on the color glyph thread.
@(private)
colr_draw :: proc(s: ^State, face: Font_Id, f: ^Font, gid: u16, size: f32, x: f32, fg: [3]u8) -> (bm: Colr_Bitmap, ok: bool) {
	fc := f.colr
	if fc == nil { return }
	job := Colr_Job{s, face, fc}
	face_colr_begin(s, fc)
	defer face_colr_end(fc)
	src := Colr_Source{colr = fc.c, upem = f.upem, outline = colr_outline, user = &job}
	bm, ok = colr_render(src, gid, Colr_Params{size = size, x = x, fg = fg, samples = s.settings.colr_samples}, runtime.heap_allocator())
	sync.atomic_add(ok ? &s.colr_drawn : &s.colr_refused, 1)
	return
}

// Glyphs the interpreter drew and glyphs it refused (they then go to Direct2D, or show their outline).
colr_counts :: proc(s: ^State) -> (drawn, refused: int) {
	return sync.atomic_load(&s.colr_drawn), sync.atomic_load(&s.colr_refused)
}

// A drawn bitmap into a Color page (caller holds the atlas lock); frees the bitmap.
@(private)
colr_put :: proc(s: ^State, bm: Colr_Bitmap) -> Glyph_Image {
	bm := bm
	defer delete(bm.px, runtime.heap_allocator())
	if bm.w <= 0 || bm.h <= 0 { return Glyph_Image{page = -1, color = true} }
	pi, ax, ay, ok := atlas_alloc(s, .Color, bm.w, bm.h)
	if !ok { return Glyph_Image{page = -1, color = true} }
	p := s.atlas.pages[pi]
	for row in 0 ..< bm.h {
		copy(p.pixels[((ay + row) * p.size + ax) * 4:][:bm.w * 4], bm.px[row * bm.w * 4:][:bm.w * 4])
	}
	page_log(p, ax, ay, bm.w, bm.h)
	p.glyphs += 1
	return Glyph_Image{
		page = i32(pi), color = true, uv = {f32(ax), f32(ay), f32(ax + bm.w), f32(ay + bm.h)},
		offset = {f32(-bm.origin.x), f32(-bm.origin.y)}, size = {f32(bm.w), f32(bm.h)}, epoch = p.epoch,
	}
}

// Caller holds the atlas lock. The drawing itself (bounded, but it can take a while) runs with the lock released, so
// that the other threads that draw are not held up; the lock is taken again for the bitmap's place in a page.
@(private)
rasterize_colr :: proc(s: ^State, face: Font_Id, f: ^Font, gid: u16, size: f32, x: f32, fg: [3]u8) -> (g: Glyph_Image, uses_fg: bool, ok: bool) {
	atlas_unlock(&s.atlas)
	bm, drawn := colr_draw(s, face, f, gid, size, x, fg)
	atlas_lock(&s.atlas)
	if !drawn { return {}, false, false }
	return colr_put(s, bm), bm.uses_fg, true
}

// The interpreter's view of a face (nil: the face has no usable COLR table): for diagnostics and tools.
colr_of :: proc(s: ^State, id: Font_Id) -> ^Colr {
	f := face_ptr(s, id)
	if f == nil || f.colr == nil { return nil }
	return f.colr.c
}

// Tag sequences (a flag emoji followed by tag characters U+E0020 .. U+E007F: England, Scotland, Wales): DirectWrite shapes
// them as separate glyphs. For a face with COLR the sequence is looked up in its GSUB ccmp ligatures instead. Appends
// the one glyph and its cluster and returns the new pen; ok = false when the sequence does not collapse into one glyph
// (the caller then shapes it as usual).
@(private)
shape_tag_sequence :: proc(s: ^State, f: ^Font, face_id: Font_Id, size: f32, w: []u16, bytes: []i32, glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster, pen: f32) -> (new_pen: f32, ok: bool) {
	fc := f.colr
	if fc == nil || len(fc.gsub) == 0 { return pen, false }
	cps := make([dynamic]u32, 0, len(w), context.temp_allocator)
	for i := 0; i < len(w); {
		r, n := decode16(w, i)
		append(&cps, u32(r))
		i += n
	}
	gids := make([]u16, len(cps), context.temp_allocator)
	if f.dw->GetGlyphIndices(raw_data(cps), u32(len(cps)), raw_data(gids)) < 0 { return pen, false }
	for g in gids { if g == 0 { return pen, false } }
	out, found := gsub_ligate(fc.gsub, {'c', 'c', 'm', 'p'}, gids, context.temp_allocator)
	if !found || len(out) != 1 { return pen, false }
	gm: DWRITE_GLYPH_METRICS
	if f.dw->GetDesignGlyphMetrics(&out[0], 1, &gm, false) < 0 { return pen, false }
	adv := f32(gm.advanceWidth) * size / f.upem
	append(glyphs, Glyph_Pos{face = face_id, id = out[0], x = pen, advance = adv, cluster = 0})
	append(clusters, Cluster{start = 0, end = bytes[len(w)] - bytes[0], x0 = pen, x1 = pen + adv})
	return pen + adv, true
}

@(private)
has_tag_chars :: proc(w: []u16) -> bool {
	for u in w { if u == 0xDB40 { return true } }   // the high surrogate of U+E0000 .. U+E0FFF
	return false
}