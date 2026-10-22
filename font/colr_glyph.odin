#+build windows
package font

import "base:runtime"
import "core:sync"

// The COLR interpreter (colr.odin) on a face: its COLR and CPAL tables come from DirectWrite (TryGetFontTable, so
// system fonts, files and memory fonts alike), its glyph outlines from the Slug outline provider, kept per face in a
// cache of limited size. Settings.color_engine = .Builtin makes these faces' color glyphs come from here instead of
// Direct2D (color.odin); the bitmaps then go to the same Color pages, the same async queue and the same text-color
// handling as the others.

@(private)
Face_Colr :: struct {
	c:        ^Colr,
	colr_ctx: rawptr,
	cpal_ctx: rawptr,
	mu:       sync.Mutex,
	outlines: map[u16]^Outline,   // em units; emptied (between renders) when over the budget
	bytes:    int,
	active:   int,                // renders in progress: their outlines must not be freed
}

// Opens the tables of `f` (nil: no COLR table, or one that does not parse).
@(private)
face_colr_open :: proc(f: ^Font) -> ^Face_Colr {
	context.allocator = runtime.heap_allocator()
	fc := new(Face_Colr)
	read :: proc(f: ^Font, tag: string) -> (data: []u8, ctx: rawptr) {
		p: rawptr
		n: u32
		exists: BOOL
		if f.dw->TryGetFontTable(ot_tag(tag), &p, &n, &ctx, &exists) < 0 || !exists || p == nil || n == 0 { return nil, nil }
		return ([^]u8)(p)[:n], ctx
	}
	colr, cpal: []u8
	colr, fc.colr_ctx = read(f, "COLR")
	if colr == nil { free(fc); return nil }
	cpal, fc.cpal_ctx = read(f, "CPAL")
	fc.c = colr_open(colr, cpal)
	if fc.c == nil {
		f.dw->ReleaseFontTable(fc.colr_ctx)
		if fc.cpal_ctx != nil { f.dw->ReleaseFontTable(fc.cpal_ctx) }
		free(fc)
		return nil
	}
	fc.outlines = make(map[u16]^Outline)
	return fc
}

@(private)
face_colr_close :: proc(f: ^Font) {
	context.allocator = runtime.heap_allocator()
	fc := f.colr
	if fc == nil { return }
	f.colr = nil
	for _, o in fc.outlines { outline_destroy(o); free(o) }
	delete(fc.outlines)
	colr_destroy(fc.c)
	if f.dw != nil {
		f.dw->ReleaseFontTable(fc.colr_ctx)
		if fc.cpal_ctx != nil { f.dw->ReleaseFontTable(fc.cpal_ctx) }
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

// Whether the interpreter draws glyph `gid` of `f` (it has a color description there).
@(private)
colr_draws :: proc(s: ^State, f: ^Font, gid: u16) -> bool {
	return s.settings.color_engine == .Builtin && s.settings.color_glyphs && f.colr != nil && colr_has_glyph(f.colr.c, gid)
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

// Caller holds the atlas lock.
@(private)
rasterize_colr :: proc(s: ^State, face: Font_Id, f: ^Font, gid: u16, size: f32, x: f32, fg: [3]u8) -> (g: Glyph_Image, uses_fg: bool, ok: bool) {
	bm, drawn := colr_draw(s, face, f, gid, size, x, fg)
	if !drawn { return {}, false, false }
	return colr_put(s, bm), bm.uses_fg, true
}

// The interpreter's view of a face (nil: the face has no usable COLR table): for diagnostics and tools.
colr_of :: proc(s: ^State, id: Font_Id) -> ^Colr {
	f := face_ptr(s, id)
	if f == nil || f.colr == nil { return nil }
	return f.colr.c
}
