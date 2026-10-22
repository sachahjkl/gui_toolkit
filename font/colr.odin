package font

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:slice"

// The COLR / CPAL interpreter: color glyphs of an OpenType font (COLR version 0 layers, version 1 paint graphs with
// gradients, transforms, compositions and clip boxes; the palette is CPAL's first) drawn by this package itself, on
// the CPU, from the font's tables and glyph outlines. Nothing here talks to the platform: the tables arrive as bytes
// (`colr_open`) and the outlines through a callback, so a Linux build draws the same emoji as Windows.
//
// A glyph is drawn at a pixel size into a premultiplied float canvas (colr_raster.odin) and handed back as straight
// alpha RGBA8 (`Colr_Bitmap`). The caller caches it (the atlas' Color pages): drawing again at another size reuses the
// outlines the caller keeps, only the scan conversion is repeated.
//
// Fonts come from the web: every offset is checked, and a graph with a cycle (PaintColrGlyph reaching itself) or with
// more than COLR_MAX_PAINTS nodes is refused as a whole (the glyph is then drawn as its plain outline by the caller).
// Variable COLR (Var* paints and their delta sets) is read as its default instance: the variation index bases are
// skipped, which is what a font without variation data means anyway.

COLR_MAX_PAINTS :: 1 << 16
COLR_MAX_DEPTH :: 96
// Largest side of a canvas, pixels.
COLR_CANVAS_LIMIT :: 4096

Colr :: struct {
	colr, cpal:     []u8,
	version:        int,
	base_v0:        int,   // BaseGlyphRecords (version 0), offset in COLR
	n_base_v0:      int,
	layers_v0:      int,   // LayerRecords
	n_layers_v0:    int,
	base_list:      int,   // BaseGlyphList (version 1), 0: none
	n_base_list:    int,
	layer_list:     int,
	n_layer_list:   int,
	clip_list:      int,
	n_clips:        int,
	n_entries:      int,   // CPAL: entries of a palette
	colors:         int,   // offset of palette 0's first entry in CPAL
}

// Reads the two tables (that stay valid and unchanged while the result is used). nil when there is no usable COLR.
colr_open :: proc(colr_table, cpal_table: []u8, allocator := context.allocator) -> ^Colr {
	r := Rd{d = colr_table}
	if len(colr_table) < 14 { return nil }
	c := new(Colr, allocator)
	c.colr, c.cpal = colr_table, cpal_table
	c.version = rd_u16(&r, 0)
	c.n_base_v0 = rd_u16(&r, 2)
	c.base_v0 = rd_u32(&r, 4)
	c.layers_v0 = rd_u32(&r, 8)
	c.n_layers_v0 = rd_u16(&r, 12)
	if c.version > 1 || r.bad || c.base_v0 + c.n_base_v0 * 6 > len(colr_table) || c.layers_v0 + c.n_layers_v0 * 4 > len(colr_table) {
		free(c, allocator)
		return nil
	}
	if c.version == 1 {
		bl, ll, cl := rd_u32(&r, 14), rd_u32(&r, 18), rd_u32(&r, 22)
		if r.bad { free(c, allocator); return nil }
		if bl != 0 && bl + 4 <= len(colr_table) {
			c.base_list, c.n_base_list = bl, rd_u32(&r, bl)
			if bl + 4 + c.n_base_list * 6 > len(colr_table) { c.base_list, c.n_base_list = 0, 0 }
		}
		if ll != 0 && ll + 4 <= len(colr_table) {
			c.layer_list, c.n_layer_list = ll, rd_u32(&r, ll)
			if ll + 4 + c.n_layer_list * 4 > len(colr_table) { c.layer_list, c.n_layer_list = 0, 0 }
		}
		if cl != 0 && cl + 5 <= len(colr_table) && rd_u8(&r, cl) == 1 {
			c.clip_list, c.n_clips = cl, rd_u32(&r, cl + 1)
			if cl + 5 + c.n_clips * 7 > len(colr_table) { c.clip_list, c.n_clips = 0, 0 }
		}
	}
	if len(cpal_table) >= 14 {
		p := Rd{d = cpal_table}
		n_entries, n_palettes, n_records, first := rd_u16(&p, 2), rd_u16(&p, 4), rd_u16(&p, 6), rd_u32(&p, 8)
		if !p.bad && n_palettes > 0 {
			idx0 := rd_u16(&p, 12)   // first record of palette 0
			if !p.bad && first + (idx0 + n_entries) * 4 <= len(cpal_table) && idx0 + n_entries <= n_records {
				c.n_entries, c.colors = n_entries, first + idx0 * 4
			}
		}
	}
	return c
}

colr_destroy :: proc(c: ^Colr, allocator := context.allocator) {
	if c != nil { free(c, allocator) }
}

// Whether glyph `gid` has color layers or a paint graph.
colr_has_glyph :: proc(c: ^Colr, gid: u16) -> bool {
	_, kind := colr_find(c, gid)
	return kind != .None
}

Colr_Kind :: enum u8 { None, Layers, Graph }

// Where the glyph's description is: a paint table offset (Graph), or the index of its first BaseGlyphRecord (Layers).
colr_find :: proc(c: ^Colr, gid: u16) -> (at: int, kind: Colr_Kind) {
	d := c.colr
	if c.n_base_list > 0 {
		lo, hi := 0, c.n_base_list
		for lo < hi {
			mid := (lo + hi) / 2
			o := c.base_list + 4 + mid * 6
			g := int(d[o]) << 8 | int(d[o + 1])
			switch {
			case g < int(gid): lo = mid + 1
			case g > int(gid): hi = mid
			case:
				off := int(d[o + 2]) << 24 | int(d[o + 3]) << 16 | int(d[o + 4]) << 8 | int(d[o + 5])
				if off <= 0 || c.base_list + off >= len(d) { return 0, .None }
				return c.base_list + off, .Graph
			}
		}
	}
	lo, hi := 0, c.n_base_v0
	for lo < hi {
		mid := (lo + hi) / 2
		o := c.base_v0 + mid * 6
		g := int(d[o]) << 8 | int(d[o + 1])
		switch {
		case g < int(gid): lo = mid + 1
		case g > int(gid): hi = mid
		case: return o, .Layers
		}
	}
	return 0, .None
}

// The clip box of a base glyph (font units, y up: x0 y0 x1 y1), if the font gives one.
colr_clip_box :: proc(c: ^Colr, gid: u16) -> (box: [4]f32, ok: bool) {
	if c.n_clips == 0 { return }
	r := Rd{d = c.colr}
	lo, hi := 0, c.n_clips
	for lo < hi {
		mid := (lo + hi) / 2
		o := c.clip_list + 5 + mid * 7
		first, last := rd_u16(&r, o), rd_u16(&r, o + 2)
		switch {
		case int(gid) < first: hi = mid
		case int(gid) > last: lo = mid + 1
		case:
			b := c.clip_list + rd_u24(&r, o + 4)
			f := rd_u8(&r, b)
			if r.bad || (f != 1 && f != 2) { return }
			box = {f32(rd_i16(&r, b + 1)), f32(rd_i16(&r, b + 3)), f32(rd_i16(&r, b + 5)), f32(rd_i16(&r, b + 7))}
			return box, !r.bad && box[2] > box[0] && box[3] > box[1]
		}
	}
	return
}

////////////////////////////////
// Reading

Rd :: struct {
	d:   []u8,
	bad: bool,   // a read went outside the table
}

rd_u8 :: #force_inline proc "contextless" (r: ^Rd, o: int) -> int {
	if o < 0 || o >= len(r.d) { r.bad = true; return 0 }
	return int(r.d[o])
}

rd_u16 :: #force_inline proc "contextless" (r: ^Rd, o: int) -> int {
	if o < 0 || o + 2 > len(r.d) { r.bad = true; return 0 }
	return int(r.d[o]) << 8 | int(r.d[o + 1])
}

rd_i16 :: #force_inline proc "contextless" (r: ^Rd, o: int) -> int { return int(i16(rd_u16(r, o))) }

rd_u24 :: #force_inline proc "contextless" (r: ^Rd, o: int) -> int {
	if o < 0 || o + 3 > len(r.d) { r.bad = true; return 0 }
	return int(r.d[o]) << 16 | int(r.d[o + 1]) << 8 | int(r.d[o + 2])
}

rd_u32 :: #force_inline proc "contextless" (r: ^Rd, o: int) -> int {
	if o < 0 || o + 4 > len(r.d) { r.bad = true; return 0 }
	return int(r.d[o]) << 24 | int(r.d[o + 1]) << 16 | int(r.d[o + 2]) << 8 | int(r.d[o + 3])
}

// F2DOT14
rd_f2 :: #force_inline proc "contextless" (r: ^Rd, o: int) -> f32 { return f32(rd_i16(r, o)) / 16384 }

// Fixed 16.16
rd_fixed :: #force_inline proc "contextless" (r: ^Rd, o: int) -> f32 { return f32(i32(rd_u32(r, o))) / 65536 }

// The CPAL color of an entry, straight RGBA in 0 ..= 1 (transparent when the palette has no such entry).
colr_palette :: proc(c: ^Colr, index: int) -> [4]f32 {
	if index < 0 || index >= c.n_entries { return {} }
	o := c.colors + index * 4
	return {f32(c.cpal[o + 2]) / 255, f32(c.cpal[o + 1]) / 255, f32(c.cpal[o]) / 255, f32(c.cpal[o + 3]) / 255}
}

////////////////////////////////
// Drawing

// What `colr_render` needs from the font and its outlines.
Colr_Source :: struct {
	colr:    ^Colr,
	upem:    f32,
	// The outline of a glyph in em units, nil when it has none. The outline stays valid until the render ends.
	outline: proc(user: rawptr, gid: u16) -> ^Outline,
	user:    rawptr,
}

Colr_Bitmap :: struct {
	px:      []u8,        // w * h RGBA, straight alpha, sRGB (allocated with the allocator given to colr_render)
	w, h:    int,
	origin:  [2]int,      // the pen position (whole pixel) on the bitmap
	uses_fg: bool,        // some paint is in the text color
}

Colr_Params :: struct {
	size:    f32,         // em size in pixels
	x:       f32,         // horizontal offset of the pen inside its pixel
	fg:      [3]u8,       // text color, sRGB
	samples: int,         // vertical samples per pixel row of the scan conversion
}

@(private)
Walk :: struct {
	src:       Colr_Source,
	rd:        Rd,
	alloc:     runtime.Allocator,
	arena:     ^virtual.Arena,
	fg:        [3]f32,
	used_fg:   bool,
	budget:    int,
	depth:     int,
	stack:     [COLR_MAX_DEPTH + 2]u16,   // glyphs being painted through PaintColrGlyph
	nstack:    int,
	measuring: bool,
	lo, hi:    [2]f32,         // bounds of what is painted, font units (measuring)
	samples:   int,
	surf:      ^Surface,
	clip:      Clip,
	m:         Mat,
}

// Draws glyph `gid`. ok = false: the glyph has no color description, or its graph is invalid. A glyph with a valid
// description that paints nothing returns ok with an empty bitmap (w = h = 0).
colr_render :: proc(src: Colr_Source, gid: u16, p: Colr_Params, allocator: runtime.Allocator) -> (bm: Colr_Bitmap, ok: bool) {
	c := src.colr
	at, kind := colr_find(c, gid)
	if kind == .None || src.upem <= 0 || p.size <= 0 { return {}, false }
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return {}, false }
	defer virtual.arena_destroy(&arena)
	w := Walk{
		src = src, rd = Rd{d = c.colr}, alloc = virtual.arena_allocator(&arena), arena = &arena, budget = COLR_MAX_PAINTS,
		fg = {f32(p.fg[0]) / 255, f32(p.fg[1]) / 255, f32(p.fg[2]) / 255}, samples = clamp(p.samples, 1, 64),
		m = MAT_IDENTITY, lo = {max(f32), max(f32)}, hi = {-max(f32), -max(f32)},
	}
	w.stack[0], w.nstack = gid, 1

	// the box that is painted: the font's clip box, else what the outlines of the graph cover
	box, has_box := colr_clip_box(c, gid)
	if has_box {
		w.lo, w.hi = {box[0], box[1]}, {box[2], box[3]}
	} else {
		w.measuring = true
		walk_glyph(&w, at, kind)
		w.measuring = false
		if w.rd.bad || w.budget <= 0 { return {}, false }
		w.budget = COLR_MAX_PAINTS
		w.depth = 0
		w.used_fg = false
	}
	if w.hi.x <= w.lo.x || w.hi.y <= w.lo.y { return {}, !w.rd.bad }   // paints nothing

	k := p.size / src.upem
	x0 := int(math.floor(w.lo.x * k + p.x)) - 1
	x1 := int(math.ceil(w.hi.x * k + p.x)) + 1
	y0 := int(math.floor(-w.hi.y * k)) - 1
	y1 := int(math.ceil(-w.lo.y * k)) + 1
	cw, ch := x1 - x0, y1 - y0
	if cw <= 0 || ch <= 0 || cw > COLR_CANVAS_LIMIT || ch > COLR_CANVAS_LIMIT { return {}, false }
	w.surf = surface_make(cw, ch, w.alloc)
	w.clip = Clip{r = {0, 0, cw, ch}}
	w.m = {k, 0, 0, -k, f32(-x0) + p.x, f32(-y0)}
	if has_box {
		w.clip = rect_clip(w.m, box, w.clip.r, w.samples, w.alloc)
		if w.clip.r[2] <= w.clip.r[0] || w.clip.r[3] <= w.clip.r[1] { return {}, true }
	}
	w.stack[0], w.nstack = gid, 1
	walk_glyph(&w, at, kind)
	if w.rd.bad || w.budget <= 0 { return {}, false }

	bm = surface_to_bitmap(w.surf, {-x0, -y0}, allocator)
	bm.uses_fg = w.used_fg
	return bm, true
}

// A box (font units) under m as a clip: the pixels it covers, with their coverage.
@(private)
rect_clip :: proc(m: Mat, box: [4]f32, within: [4]int, samples: int, alloc: runtime.Allocator) -> Clip {
	o: Outline
	o.quads = make([dynamic]Quad, 0, 4, alloc)
	pts := [4][2]f32{{box[0], box[1]}, {box[2], box[1]}, {box[2], box[3]}, {box[0], box[3]}}
	for i in 0 ..< 4 {
		a, b := pts[i], pts[(i + 1) % 4]
		append(&o.quads, Quad{{a, b, b}})
	}
	rect, cov, ok := colr_cover(&o, m, within, samples, alloc)
	if !ok { return Clip{} }
	return Clip{rect, cov}
}

@(private)
surface_to_bitmap :: proc(s: ^Surface, origin: [2]int, allocator: runtime.Allocator) -> Colr_Bitmap {
	// trimmed to the pixels that have ink
	x0, y0, x1, y1 := s.w, s.h, 0, 0
	for y in 0 ..< s.h {
		for x in 0 ..< s.w {
			if s.px[y * s.w + x].a * 255 < 0.5 { continue }
			x0, y0 = min(x0, x), min(y0, y)
			x1, y1 = max(x1, x + 1), max(y1, y + 1)
		}
	}
	if x1 <= x0 || y1 <= y0 { return {} }
	bw, bh := x1 - x0, y1 - y0
	bm := Colr_Bitmap{px = make([]u8, bw * bh * 4, allocator), w = bw, h = bh, origin = {origin.x - x0, origin.y - y0}}
	for y in 0 ..< bh {
		for x in 0 ..< bw {
			p := s.px[(y0 + y) * s.w + x0 + x]
			o := (y * bw + x) * 4
			if p.a <= 0 { continue }
			inv := 1 / p.a
			bm.px[o] = u8(clamp(p.r * inv * 255 + 0.5, 0, 255))
			bm.px[o + 1] = u8(clamp(p.g * inv * 255 + 0.5, 0, 255))
			bm.px[o + 2] = u8(clamp(p.b * inv * 255 + 0.5, 0, 255))
			bm.px[o + 3] = u8(clamp(p.a * 255 + 0.5, 0, 255))
		}
	}
	return bm
}

@(private)
walk_glyph :: proc(w: ^Walk, at: int, kind: Colr_Kind) {
	switch kind {
	case .Graph: walk_paint(w, at)
	case .Layers:
		// version 0: each layer is a glyph filled with a palette color, drawn in order
		first, n := rd_u16(&w.rd, at + 2), rd_u16(&w.rd, at + 4)
		c := w.src.colr
		if w.rd.bad || first + n > c.n_layers_v0 { w.rd.bad = true; return }
		for i in 0 ..< n {
			o := c.layers_v0 + (first + i) * 4
			gid := rd_u16(&w.rd, o)
			col := palette_color(w, rd_u16(&w.rd, o + 2), 1)
			fill_glyph(w, u16(gid), proc(w: ^Walk, user: rawptr) { fill_solid(w, (^[4]f32)(user)^) }, &col)
		}
	case .None:
	}
}

// The palette entry as straight RGBA; 0xFFFF is the text color. `alpha` multiplies the color's own.
@(private)
palette_color :: proc(w: ^Walk, index: int, alpha: f32) -> [4]f32 {
	if index == 0xFFFF {
		w.used_fg = true
		return {w.fg.r, w.fg.g, w.fg.b, clamp(alpha, 0, 1)}
	}
	col := colr_palette(w.src.colr, index)
	col.a = clamp(col.a * alpha, 0, 1)
	return col
}

// Paint table at `off` (absolute in COLR).
@(private)
walk_paint :: proc(w: ^Walk, off: int) {
	if w.rd.bad { return }
	w.budget -= 1
	w.depth += 1
	defer w.depth -= 1
	if w.budget <= 0 || w.depth > COLR_MAX_DEPTH { w.rd.bad = true; return }
	r := &w.rd
	format := rd_u8(r, off)
	child :: #force_inline proc(r: ^Rd, off, at: int) -> int { return off + rd_u24(r, off + at) }
	switch format {
	case 1:   // PaintColrLayers
		n, first := rd_u8(r, off + 1), rd_u32(r, off + 2)
		c := w.src.colr
		if r.bad || first + n > c.n_layer_list { r.bad = true; return }
		for i in 0 ..< n {
			po := rd_u32(r, c.layer_list + 4 + (first + i) * 4)
			if r.bad { return }
			walk_paint(w, c.layer_list + po)
		}
	case 2, 3:   // PaintSolid
		col := palette_color(w, rd_u16(r, off + 1), rd_f2(r, off + 3))
		if r.bad { return }
		fill_solid(w, col)
	case 4, 5:   // PaintLinearGradient
		g := Gradient{kind = .Linear}
		line := child(r, off, 1)
		g.p0 = {f32(rd_i16(r, off + 4)), f32(rd_i16(r, off + 6))}
		g.p1 = {f32(rd_i16(r, off + 8)), f32(rd_i16(r, off + 10))}
		g.p2 = {f32(rd_i16(r, off + 12)), f32(rd_i16(r, off + 14))}
		if r.bad || !read_color_line(w, &g, line, format == 5) { return }
		fill_gradient(w, &g)
	case 6, 7:   // PaintRadialGradient
		g := Gradient{kind = .Radial}
		line := child(r, off, 1)
		g.p0 = {f32(rd_i16(r, off + 4)), f32(rd_i16(r, off + 6))}
		g.r0 = f32(rd_u16(r, off + 8))
		g.p1 = {f32(rd_i16(r, off + 10)), f32(rd_i16(r, off + 12))}
		g.r1 = f32(rd_u16(r, off + 14))
		if r.bad || !read_color_line(w, &g, line, format == 7) { return }
		fill_gradient(w, &g)
	case 8, 9:   // PaintSweepGradient
		g := Gradient{kind = .Sweep}
		line := child(r, off, 1)
		g.p0 = {f32(rd_i16(r, off + 4)), f32(rd_i16(r, off + 6))}
		// sweep angles carry a bias of 1.0 (+180 degrees), so that +360 can be written
		g.a0 = (rd_f2(r, off + 8) + 1) * 180
		g.a1 = (rd_f2(r, off + 10) + 1) * 180
		if r.bad || !read_color_line(w, &g, line, format == 9) { return }
		fill_gradient(w, &g)
	case 10:   // PaintGlyph
		sub := child(r, off, 1)
		gid := rd_u16(r, off + 4)
		if r.bad { return }
		Ctx :: struct { w: ^Walk, sub: int }
		ctx := Ctx{w, sub}
		fill_glyph(w, u16(gid), proc(w: ^Walk, user: rawptr) { walk_paint(w, (^Ctx)(user).sub) }, &ctx)
	case 11:   // PaintColrGlyph
		gid := u16(rd_u16(r, off + 1))
		if r.bad { return }
		if slice.contains(w.stack[:w.nstack], gid) || w.nstack >= len(w.stack) { r.bad = true; return }   // a cycle
		at, kind := colr_find(w.src.colr, gid)
		if kind != .Graph { r.bad = true; return }
		w.stack[w.nstack] = gid
		w.nstack += 1
		// the referenced glyph's own clip box bounds what it paints (what Direct2D does with it)
		if box, has := colr_clip_box(w.src.colr, gid); has {
			clip_box_scope(w, box, at)
		} else {
			walk_paint(w, at)
		}
		w.nstack -= 1
	case 12, 13:   // PaintTransform
		sub, tm := child(r, off, 1), child(r, off, 4)
		m := Mat{rd_fixed(r, tm), rd_fixed(r, tm + 4), rd_fixed(r, tm + 8), rd_fixed(r, tm + 12), rd_fixed(r, tm + 16), rd_fixed(r, tm + 20)}
		with_matrix(w, sub, m)
	case 14, 15:   // PaintTranslate
		sub := child(r, off, 1)
		with_matrix(w, sub, mat_translate(f32(rd_i16(r, off + 4)), f32(rd_i16(r, off + 6))))
	case 16, 17:   // PaintScale
		sub := child(r, off, 1)
		with_matrix(w, sub, mat_scale(rd_f2(r, off + 4), rd_f2(r, off + 6)))
	case 18, 19:   // PaintScaleAroundCenter
		sub := child(r, off, 1)
		with_matrix(w, sub, mat_around(mat_scale(rd_f2(r, off + 4), rd_f2(r, off + 6)), {f32(rd_i16(r, off + 8)), f32(rd_i16(r, off + 10))}))
	case 20, 21:   // PaintScaleUniform
		sub := child(r, off, 1)
		s := rd_f2(r, off + 4)
		with_matrix(w, sub, mat_scale(s, s))
	case 22, 23:   // PaintScaleUniformAroundCenter
		sub := child(r, off, 1)
		s := rd_f2(r, off + 4)
		with_matrix(w, sub, mat_around(mat_scale(s, s), {f32(rd_i16(r, off + 6)), f32(rd_i16(r, off + 8))}))
	case 24, 25:   // PaintRotate
		sub := child(r, off, 1)
		with_matrix(w, sub, rotation(rd_f2(r, off + 4)))
	case 26, 27:   // PaintRotateAroundCenter
		sub := child(r, off, 1)
		with_matrix(w, sub, mat_around(rotation(rd_f2(r, off + 4)), {f32(rd_i16(r, off + 6)), f32(rd_i16(r, off + 8))}))
	case 28, 29:   // PaintSkew
		sub := child(r, off, 1)
		with_matrix(w, sub, skew(rd_f2(r, off + 4), rd_f2(r, off + 6)))
	case 30, 31:   // PaintSkewAroundCenter
		sub := child(r, off, 1)
		with_matrix(w, sub, mat_around(skew(rd_f2(r, off + 4), rd_f2(r, off + 6)), {f32(rd_i16(r, off + 8)), f32(rd_i16(r, off + 10))}))
	case 32:   // PaintComposite
		source, mode, backdrop := child(r, off, 1), rd_u8(r, off + 4), child(r, off, 5)
		if r.bad { return }
		composite_paints(w, source, Composite_Mode(mode), backdrop, mode <= int(Composite_Mode.Hsl_Luminosity))
	case:
		r.bad = true   // a format this reader does not know: refuse the glyph rather than draw it wrong
	}
}

// F2Dot14 angle in half turns, counter-clockwise (y up).
@(private)
rotation :: proc(a: f32) -> Mat {
	s, c := math.sincos(a * math.PI)
	return {c, s, -s, c, 0, 0}
}

// The paint spec: x' = x - tan(xSkew) y, y' = y + tan(ySkew) x (angles counter-clockwise).
@(private)
skew :: proc(ax, ay: f32) -> Mat {
	return {1, math.tan(ay * math.PI), -math.tan(ax * math.PI), 1, 0, 0}
}

// The paint at `at` clipped to a box (font units, in the current transform).
@(private)
clip_box_scope :: proc(w: ^Walk, box: [4]f32, at: int) {
	if w.measuring {
		for c in ([4][2]f32{{box[0], box[1]}, {box[2], box[1]}, {box[0], box[3]}, {box[2], box[3]}}) {
			t := mat_apply(w.m, c)
			w.lo.x, w.lo.y = min(w.lo.x, t.x), min(w.lo.y, t.y)
			w.hi.x, w.hi.y = max(w.hi.x, t.x), max(w.hi.y, t.y)
		}
		walk_paint(w, at)
		return
	}
	temp := virtual.arena_temp_begin(w.arena)
	defer virtual.arena_temp_end(temp)
	rc := rect_clip(w.m, box, w.clip.r, w.samples, w.alloc)
	if rc.r[2] <= rc.r[0] || rc.r[3] <= rc.r[1] { return }
	saved := w.clip
	w.clip = clip_and(&saved, rc.r, rc.cov, w.alloc)
	walk_paint(w, at)
	w.clip = saved
}

@(private)
with_matrix :: proc(w: ^Walk, sub: int, local: Mat) {
	if w.rd.bad { return }
	saved := w.m
	w.m = mat_mul(w.m, local)
	walk_paint(w, sub)
	w.m = saved
}

@(private)
composite_paints :: proc(w: ^Walk, source: int, mode: Composite_Mode, backdrop: int, known: bool) {
	if w.measuring {
		walk_paint(w, backdrop)
		walk_paint(w, source)
		return
	}
	if !known { w.rd.bad = true; return }
	temp := virtual.arena_temp_begin(w.arena)
	defer virtual.arena_temp_end(temp)
	parent := w.surf
	bd := surface_make(parent.w, parent.h, w.alloc)
	w.surf = bd
	walk_paint(w, backdrop)
	sc := surface_make(parent.w, parent.h, w.alloc)
	w.surf = sc
	walk_paint(w, source)
	w.surf = parent
	if w.rd.bad { return }
	surface_composite(mode, sc, bd)
	for i in 0 ..< len(bd.px) { over(&parent.px[i], bd.px[i]) }
}

////////////////////////////////
// Fills

// Clips to the outline of glyph `gid`, then runs `body` (the paint below it). Measuring only widens the bounds.
@(private)
fill_glyph :: proc(w: ^Walk, gid: u16, body: proc(w: ^Walk, user: rawptr), user: rawptr) {
	o := w.src.outline(w.src.user, gid)
	om := mat_mul(w.m, mat_scale(w.src.upem, w.src.upem))   // outlines are in em units, paints in font units
	if w.measuring {
		if o != nil && len(o.quads) > 0 {
			for q in o.quads {
				for p in q.p {
					t := mat_apply(om, p)
					w.lo.x, w.lo.y = min(w.lo.x, t.x), min(w.lo.y, t.y)
					w.hi.x, w.hi.y = max(w.hi.x, t.x), max(w.hi.y, t.y)
				}
			}
		}
		body(w, user)
		return
	}
	if o == nil || len(o.quads) == 0 { return }
	temp := virtual.arena_temp_begin(w.arena)
	defer virtual.arena_temp_end(temp)
	rect, cov, ok := colr_cover(o, om, w.clip.r, w.samples, w.alloc)
	if !ok { return }
	saved := w.clip
	w.clip = clip_and(&saved, rect, cov, w.alloc)
	body(w, user)
	w.clip = saved
}

@(private)
fill_solid :: proc(w: ^Walk, col: [4]f32) {
	if w.measuring { return }
	pm := [4]f32{col.r * col.a, col.g * col.a, col.b * col.a, col.a}
	s := w.surf
	for y in w.clip.r[1] ..< w.clip.r[3] {
		for x in w.clip.r[0] ..< w.clip.r[2] {
			c := clip_cov(&w.clip, x, y)
			if c <= 0 { continue }
			over(&s.px[y * s.w + x], pm * c)
		}
	}
}

Gradient_Kind :: enum u8 { Linear, Radial, Sweep }

@(private)
Stop :: struct {
	t:   f32,
	col: [4]f32,   // straight RGBA
}

@(private)
Gradient :: struct {
	kind:       Gradient_Kind,
	p0, p1, p2: [2]f32,
	r0, r1:     f32,
	a0, a1:     f32,   // sweep: degrees
	extend:     int,   // 0 pad, 1 repeat, 2 reflect
	empty:      bool,  // paints nothing
	stops:      [dynamic]Stop,
}

@(private)
read_color_line :: proc(w: ^Walk, g: ^Gradient, off: int, var: bool) -> bool {
	r := &w.rd
	g.extend = rd_u8(r, off)
	n := rd_u16(r, off + 1)
	stride := var ? 10 : 6
	if r.bad || n == 0 || off + 3 + n * stride > len(r.d) { r.bad = true; return false }
	if g.extend > 2 { g.extend = 0 }
	g.stops = make([dynamic]Stop, 0, n, w.alloc)
	for i in 0 ..< n {
		o := off + 3 + i * stride
		col := palette_color(w, rd_u16(r, o + 2), rd_f2(r, o + 4))
		append(&g.stops, Stop{rd_f2(r, o), col})
	}
	slice.stable_sort_by(g.stops[:], proc(a, b: Stop) -> bool { return a.t < b.t })
	// every stop at one offset: with repeat or reflect the line is ill-formed and nothing is painted (pad: a step)
	if g.extend != 0 && g.stops[0].t == g.stops[len(g.stops) - 1].t { g.empty = true }
	return !r.bad
}

// The gradient's color at t, with the extend mode applied, premultiplied.
@(private)
gradient_color :: proc(g: ^Gradient, t: f32, first, last: f32) -> [4]f32 {
	s := g.stops[:]
	u: f32
	if last > first {
		u = (t - first) / (last - first)
		switch g.extend {
		case 1: u -= math.floor(u)
		case 2:
			u = math.mod(u, 2)
			if u < 0 { u += 2 }
			if u > 1 { u = 2 - u }
		case: u = clamp(u, 0, 1)
		}
		u = first + u * (last - first)
	} else {
		u = t >= last ? max(f32) : -max(f32)   // all stops at one offset: a hard step
	}
	col: [4]f32
	switch {
	case u <= s[0].t: col = s[0].col
	case u >= s[len(s) - 1].t: col = s[len(s) - 1].col
	case:
		i := 1
		for i < len(s) - 1 && s[i].t < u { i += 1 }
		a, b := s[i - 1], s[i]
		f: f32 = b.t > a.t ? (u - a.t) / (b.t - a.t) : 1
		col = a.col + (b.col - a.col) * f
	}
	return {col.r * col.a, col.g * col.a, col.b * col.a, col.a}
}

@(private)
fill_gradient :: proc(w: ^Walk, g: ^Gradient) {
	if w.measuring || g.empty { return }
	inv, ok := mat_invert(w.m)
	if !ok { return }
	first, last := g.stops[0].t, g.stops[len(g.stops) - 1].t
	s := w.surf
	// geometry of the three kinds, in the gradient's own space
	v: [2]f32
	vv: f32
	a, cdd, dr: f32
	cd: [2]f32
	switch g.kind {
	case .Linear:
		// the color line runs along p0p1 projected on the normal of p0p2: lines of equal color are parallel to p0p2
		d1, d2 := g.p1 - g.p0, g.p2 - g.p0
		n := [2]f32{-d2.y, d2.x}
		nn := n.x * n.x + n.y * n.y
		if nn == 0 { return }
		k := (d1.x * n.x + d1.y * n.y) / nn
		v = n * k
		vv = v.x * v.x + v.y * v.y
		if vv == 0 { return }
	case .Radial:
		cd = g.p1 - g.p0
		dr = g.r1 - g.r0
		a = cd.x * cd.x + cd.y * cd.y - dr * dr
		cdd = a
	case .Sweep:
		if g.a1 == g.a0 && g.extend != 0 { return }   // ill-formed
	}
	for y in w.clip.r[1] ..< w.clip.r[3] {
		for x in w.clip.r[0] ..< w.clip.r[2] {
			c := clip_cov(&w.clip, x, y)
			if c <= 0 { continue }
			p := mat_apply(inv, {f32(x) + 0.5, f32(y) + 0.5})
			t: f32
			switch g.kind {
			case .Linear:
				d := p - g.p0
				t = (d.x * v.x + d.y * v.y) / vv
			case .Radial:
				pd := p - g.p0
				b := pd.x * cd.x + pd.y * cd.y + g.r0 * dr
				cc := pd.x * pd.x + pd.y * pd.y - g.r0 * g.r0
				s0: f32
				if abs(cdd) < 1e-9 {
					if abs(b) < 1e-12 { continue }
					s0 = cc / (2 * b)
					if g.r0 + s0 * dr < 0 { continue }
				} else {
					disc := b * b - a * cc
					if disc < 0 { continue }
					sq := math.sqrt(disc)
					s1, s2 := (b + sq) / a, (b - sq) / a
					if s1 < s2 { s1, s2 = s2, s1 }
					switch {
					case g.r0 + s1 * dr >= 0: s0 = s1
					case g.r0 + s2 * dr >= 0: s0 = s2
					case: continue
					}
				}
				t = s0
			case .Sweep:
				// counter-clockwise from +x, 0 <= angle < 360: the only angles the gradient is sampled at
				ang := math.atan2(p.y - g.p0.y, p.x - g.p0.x) * (180 / math.PI)
				if ang < 0 { ang += 360 }
				switch {
				case g.a1 != g.a0: t = (ang - g.a0) / (g.a1 - g.a0)
				case ang >= g.a0: t = 2   // start = end with pad: a step
				case: t = -1
				}
			}
			col := gradient_color(g, t, first, last)
			over(&s.px[y * s.w + x], col * c)
		}
	}
}
