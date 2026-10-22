package font

import "core:math"

// Glyph outlines for the Slug renderer: closed contours of quadratic Bézier curves in em units (1.0 = the font's em,
// y up, the origin on the baseline at the pen). Where they come from is a provider (`Outline_Provider`): DirectWrite's
// GetGlyphRunOutline on Windows (slug_dwrite.odin); a TrueType / CFF reader in Odin can replace it on other platforms
// by setting `State.slug.provider`. Everything after this file (bands, texels, the cache, the shaders) only sees
// `Outline`.

Quad :: struct {
	p: [3][2]f32,   // start, control, end (a straight line is {a, b, b})
}

// The outline of one glyph. Contours are consecutive runs of `quads`: contour k is quads[ends[k-1]:ends[k]] (ends[-1] = 0),
// each closed (the last curve ends where the first one starts) and wound as the font has it (nonzero fill).
Outline :: struct {
	quads: [dynamic]Quad,
	ends:  [dynamic]int,
	bbox:  [4]f32,   // x0 y0 x1 y1 of all control points, em units, y up
}

outline_destroy :: proc(o: ^Outline) {
	delete(o.quads)
	delete(o.ends)
	o^ = {}
}

// Fills `out` (empty on entry) with the outline of glyph `gid` of `face`. false: the provider has none for this glyph
// (a space has an empty outline and returns true with no contours).
Outline_Provider :: #type proc(s: ^State, face: Font_Id, gid: u16, tolerance: f32, out: ^Outline) -> bool

// Ends the contour being built, which started at `start` and is now at `cur` (closed with a line when they differ).
// Contours with no curve are dropped.
outline_end :: proc(o: ^Outline, start, cur: [2]f32) {
	if cur != start { outline_line(o, cur, start) }
	if n := len(o.quads); n > (len(o.ends) > 0 ? o.ends[len(o.ends) - 1] : 0) { append(&o.ends, n) }
}

outline_line :: proc(o: ^Outline, a, b: [2]f32) {
	if a == b { return }
	append(&o.quads, Quad{{a, b, b}})
}

outline_quad :: proc(o: ^Outline, a, c, b: [2]f32) {
	if a == b && a == c { return }
	append(&o.quads, Quad{{a, c, b}})
}

// A cubic Bézier as quadratics within `tol` (em units). A cubic that is a quadratic raised in degree (what DirectWrite
// hands out for TrueType glyphs) comes back as that same quadratic, exactly; a true cubic (CFF) is cut into as few
// equal pieces as keep each piece's quadratic within `tol` of it (error bound sqrt(3)/36 * |p3 - 3 c2 + 3 c1 - p0| / n^3).
outline_cubic :: proc(o: ^Outline, p0, c1, c2, p3: [2]f32, tol: f32) {
	q1 := p0 + (c1 - p0) * 1.5
	q2 := p3 + (c2 - p3) * 1.5
	d := q1 - q2
	if d.x * d.x + d.y * d.y <= tol * tol * 0.01 {
		outline_quad(o, p0, (q1 + q2) * 0.5, p3)
		return
	}
	third := p3 - c2 * 3 + c1 * 3 - p0
	err := math.sqrt(third.x * third.x + third.y * third.y) * (math.sqrt(f32(3)) / 36)
	n := clamp(int(math.ceil(math.pow(err / max(tol, 1e-9), 1.0 / 3.0))), 1, 32)
	for i in 0 ..< n {
		a := cubic_piece(p0, c1, c2, p3, f32(i) / f32(n), f32(i + 1) / f32(n))
		outline_quad(o, a[0], (a[1] * 3 - a[0] + a[2] * 3 - a[3]) * 0.25, a[3])
	}
}

// The part [t0, t1] of a cubic as a cubic (de Casteljau twice).
@(private)
cubic_piece :: proc(p0, c1, c2, p3: [2]f32, t0, t1: f32) -> (piece: [4][2]f32) {
	lerp :: proc(a, b: [2]f32, t: f32) -> [2]f32 { return a + (b - a) * t }
	split :: proc(p: [4][2]f32, t: f32) -> (l, r: [4][2]f32) {
		a, b, c := lerp(p[0], p[1], t), lerp(p[1], p[2], t), lerp(p[2], p[3], t)
		d, e := lerp(a, b, t), lerp(b, c, t)
		m := lerp(d, e, t)
		return {p[0], a, d, m}, {m, e, c, p[3]}
	}
	whole := [4][2]f32{p0, c1, c2, p3}
	// [0, t1] then the part of it from t0 / t1
	left := whole
	if t1 < 1 { left, _ = split(whole, t1) }
	piece = left
	if t0 > 0 { _, piece = split(left, t1 > 0 ? t0 / t1 : 0) }
	return piece
}

// Bounding box of all control points.
outline_bounds :: proc(o: ^Outline) {
	if len(o.quads) == 0 { o.bbox = {}; return }
	b := [4]f32{max(f32), max(f32), -max(f32), -max(f32)}
	for q in o.quads {
		for p in q.p {
			b[0], b[1] = min(b[0], p.x), min(b[1], p.y)
			b[2], b[3] = max(b[2], p.x), max(b[3], p.y)
		}
	}
	o.bbox = b
}
