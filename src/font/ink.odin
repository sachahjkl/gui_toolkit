package font

import "core:math"
import "core:sync"

// Where the ink of glyphs crosses a band: what a text underline leaves a gap for (CSS `text-decoration-skip-ink`). From the outlines, the same on every
// backend, and kept per glyph and band: a page's underlines ask the same few bands of the same glyphs, and most glyphs are out of the band by their box alone.

// A band is kept in steps of this part of an em.
@(private) INK_BAND_STEPS :: 4096
// Outlines are read within this part of an em.
@(private) INK_TOLERANCE_EM :: 1.0 / 1024
// Entries kept before the cache starts again.
@(private) INK_CACHE_MAX :: 1 << 16

@(private)
Ink_Key :: struct {
	face:   Font_Id,
	gid:    u16,
	lo, hi: i16,
	across: bool,
}

@(private)
Ink_Extent :: struct {
	lo, hi: f32,
	hit:    bool,
}

@(private)
Ink_Cache :: struct {
	mu:      sync.Mutex,
	extents: map[Ink_Key]Ink_Extent,
}

@(private)
ink_cache_destroy :: proc(c: ^Ink_Cache) { delete(c.extents) }

// Forgets all of it (a face is gone: its id may come back as another).
@(private)
ink_cache_clear :: proc(c: ^Ink_Cache) {
	sync.mutex_lock(&c.mu)
	clear(&c.extents)
	sync.mutex_unlock(&c.mu)
}

// Where curve `q` is inside the band [lo, hi] of coordinate `b`, as a range of coordinate `a`, added to `e`.
@(private)
ink_of_quad :: proc(q: Quad, a, b: int, lo, hi: f32, e: ^Ink_Extent) {
	p0, p1, p2 := q.p[0], q.p[1], q.p[2]
	if max(p0[b], p1[b], p2[b]) < lo || min(p0[b], p1[b], p2[b]) > hi { return }
	at :: #force_inline proc(p0, p1, p2: [2]f32, t: f32) -> [2]f32 {
		u := 1 - t
		return p0 * (u * u) + p1 * (2 * u * t) + p2 * (t * t)
	}
	try :: proc(p0, p1, p2: [2]f32, t: f32, a, b: int, lo, hi: f32, e: ^Ink_Extent) {
		if t < 0 || t > 1 { return }
		p := at(p0, p1, p2, t)
		if p[b] < lo - 1e-6 || p[b] > hi + 1e-6 { return }
		e.lo, e.hi = e.hit ? min(e.lo, p[a]) : p[a], e.hit ? max(e.hi, p[a]) : p[a]
		e.hit = true
	}
	try(p0, p1, p2, 0, a, b, lo, hi, e)
	try(p0, p1, p2, 1, a, b, lo, hi, e)
	// where it turns back along `a`, and where it crosses each edge of the band
	if d := p0[a] - 2 * p1[a] + p2[a]; d != 0 { try(p0, p1, p2, (p0[a] - p1[a]) / d, a, b, lo, hi, e) }
	qa, qb := p0[b] - 2 * p1[b] + p2[b], 2 * (p1[b] - p0[b])
	for edge in ([2]f32{lo, hi}) {
		qc := p0[b] - edge
		if qa == 0 {
			if qb != 0 { try(p0, p1, p2, -qc / qb, a, b, lo, hi, e) }
			continue
		}
		disc := qb * qb - 4 * qa * qc
		if disc < 0 { continue }
		root := math.sqrt(disc)
		try(p0, p1, p2, (-qb - root) / (2 * qa), a, b, lo, hi, e)
		try(p0, p1, p2, (-qb + root) / (2 * qa), a, b, lo, hi, e)
	}
}

@(private)
ink_extent_read :: proc(s: ^State, face: Font_Id, gid: u16, lo, hi: f32, across: bool) -> (e: Ink_Extent) {
	f := face_ptr(s, face)
	if f == nil { return }
	box, has_box := s.tb.glyph_box(s, f, gid)
	if has_box && (box.empty || f.fm.upem <= 0) { return }
	if has_box {
		em := 1 / f32(f.fm.upem)
		b0, b1 := (across ? box.x_min : box.y_min) * em, (across ? box.x_max : box.y_max) * em
		if b1 < lo || b0 > hi { return }
	}
	o := Outline{quads = make([dynamic]Quad, context.temp_allocator), ends = make([dynamic]int, context.temp_allocator)}
	a, b := across ? 1 : 0, across ? 0 : 1
	if !glyph_outline(s, face, gid, INK_TOLERANCE_EM, &o) {
		// no outline (a bitmap): its box is its ink
		if has_box {
			em := 1 / f32(max(f.fm.upem, 1))
			return {(across ? box.y_min : box.x_min) * em, (across ? box.y_max : box.x_max) * em, true}
		}
		return
	}
	for q in o.quads { ink_of_quad(q, a, b, lo, hi, &e) }
	return
}

// Where glyph `gid` of `face` has ink inside a band, in ems from its origin, y up: the band is `lo` to `hi` of its height and `x0`, `x1` the extent along its width
// (`across`: the band is of its width, and the extent of its height: a line beside an upright glyph of vertical text). `hit` false: none there.
glyph_ink_extent :: proc(s: ^State, face: Font_Id, gid: u16, lo, hi: f32, across := false) -> (x0, x1: f32, hit: bool) {
	if s == nil || s.tb == nil { return }
	k := Ink_Key{face, gid, i16(clamp(math.floor(lo * INK_BAND_STEPS), f32(min(i16)), f32(max(i16)))), i16(clamp(math.ceil(hi * INK_BAND_STEPS), f32(min(i16)), f32(max(i16)))), across}
	c := &s.ink
	sync.mutex_lock(&c.mu)
	e, known := c.extents[k]
	sync.mutex_unlock(&c.mu)
	if !known {
		e = ink_extent_read(s, face, gid, f32(k.lo) / INK_BAND_STEPS, f32(k.hi) / INK_BAND_STEPS, across)
		sync.mutex_lock(&c.mu)
		if len(c.extents) >= INK_CACHE_MAX { clear(&c.extents) }
		c.extents[k] = e
		sync.mutex_unlock(&c.mu)
	}
	return e.lo, e.hi, e.hit
}

// Where the ink of `glyphs` (at `size`) crosses the band from `top` to `bottom` (pixels from the baseline, y down, as Glyph_Pos), from left to right, each `gap` wider on
// either side and joined where they then touch.
run_ink_spans :: proc(s: ^State, glyphs: []Glyph_Pos, size, top, bottom, gap: f32, allocator := context.temp_allocator) -> [][2]f32 {
	out := make([dynamic][2]f32, 0, 8, allocator)
	if size <= 0 { return out[:] }
	for g in glyphs {
		a, b, hit := glyph_ink_extent(s, g.face, g.id, (g.y - bottom) / size, (g.y - top) / size)
		if !hit { continue }
		span := [2]f32{g.x + a * size - gap, g.x + b * size + gap}
		// (visual order: one out of it, a mark on a base, goes in where it falls)
		i := len(out)
		for i > 0 && out[i - 1][0] > span[0] { i -= 1 }
		inject_at(&out, i, span)
		for j := max(i - 1, 0); j + 1 < len(out); {
			if out[j][1] < out[j + 1][0] { j += 1; continue }
			out[j][1] = max(out[j][1], out[j + 1][1])
			ordered_remove(&out, j + 1)
		}
	}
	return out[:]
}
