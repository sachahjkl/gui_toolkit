// Tests of the Slug glyph data: outlines from DirectWrite, bands, the cache.
//   odin test tests/slug -vet
package slug_test

import "core:fmt"
import "core:math"
import "core:testing"
import "../../font"

setup :: proc(t: ^testing.T, settings := font.DEFAULT_SETTINGS) -> ^font.State {
	s := new(font.State)
	font.init(s, settings)
	testing.expect(t, s.ok, "DirectWrite did not start")
	return s
}

teardown :: proc(s: ^font.State) {
	font.destroy(s)
	free(s)
}

glyph_of :: proc(s: ^font.State, face: font.Font_Id, r: rune) -> u16 {
	sh := font.shape(s, face, 16, fmt.tprintf("%c", r), {}, context.temp_allocator)
	return len(sh.glyphs) > 0 ? sh.glyphs[0].id : 0
}

@(test)
outline_of_h :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	face, ok := font.load_system(s, "Segoe UI")
	testing.expect(t, ok)
	o: font.Outline
	defer font.outline_destroy(&o)
	testing.expect(t, font.dwrite_outline_provider(s, face, glyph_of(s, face, 'H'), 1.0 / 4096, &o))
	testing.expect_value(t, len(o.quads), 12)
	testing.expect_value(t, len(o.ends), 1)
	testing.expect(t, o.bbox[3] > 0.6 && o.bbox[3] < 0.8, "cap height in em, y up")
	testing.expect(t, o.bbox[1] > -0.05)
	// closed: every curve starts where the one before ends
	for q, i in o.quads {
		n := o.quads[(i + 1) % len(o.quads)]
		testing.expect(t, q.p[2] == n.p[0], "contour not closed")
	}
}

////////////////////////////////
// A CPU port of the reference pixel shader (SlugRender), run on the built data: the bands, their sort order and the
// texel layout must give the coverage of the outline.

root_code :: proc(y1, y2, y3: f32) -> u32 {
	i1 := transmute(u32)y1 >> 31
	i2 := transmute(u32)y2 >> 30
	i3 := transmute(u32)y3 >> 29
	shift := (i2 & 2) | (i1 & ~u32(2))
	shift = (i3 & 4) | (shift & ~u32(4))
	return (0x2E74 >> shift) & 0x0101
}

solve_horiz :: proc(p12: [4]f32, p3: [2]f32) -> [2]f32 {
	a := [2]f32{p12[0] - p12[2] * 2 + p3.x, p12[1] - p12[3] * 2 + p3.y}
	b := [2]f32{p12[0] - p12[2], p12[1] - p12[3]}
	ra := 1 / a.y
	rb := 0.5 / b.y
	d := math.sqrt(max(b.y * b.y - a.y * p12[1], 0))
	t1 := (b.y - d) * ra
	t2 := (b.y + d) * ra
	if abs(a.y) < 1.0 / 65536 { t1 = p12[1] * rb; t2 = t1 }
	return {(a.x * t1 - b.x * 2) * t1 + p12[0], (a.x * t2 - b.x * 2) * t2 + p12[0]}
}

solve_vert :: proc(p12: [4]f32, p3: [2]f32) -> [2]f32 {
	a := [2]f32{p12[0] - p12[2] * 2 + p3.x, p12[1] - p12[3] * 2 + p3.y}
	b := [2]f32{p12[0] - p12[2], p12[1] - p12[3]}
	ra := 1 / a.x
	rb := 0.5 / b.x
	d := math.sqrt(max(b.x * b.x - a.x * p12[0], 0))
	t1 := (b.x - d) * ra
	t2 := (b.x + d) * ra
	if abs(a.x) < 1.0 / 65536 { t1 = p12[0] * rb; t2 = t1 }
	return {(a.y * t1 - b.y * 2) * t1 + p12[1], (a.y * t2 - b.y * 2) * t2 + p12[1]}
}

sat :: proc(x: f32) -> f32 { return clamp(x, 0, 1) }

// Coverage at em position `rc`, `ppem` pixels per em (axis aligned).
cpu_coverage :: proc(b: ^font.Slug_Built, rc: [2]f32, ppem: f32) -> f32 {
	band := font.slug_band_of(b, rc)
	xcov, xwgt, ycov, ywgt: f32
	texel :: proc(b: ^font.Slug_Built, i: int) -> [4]f32 {
		c := b.curves[i]
		return {f32(c[0]), f32(c[1]), f32(c[2]), f32(c[3])}
	}
	// horizontal band
	h := b.bands[band.y]
	for k in 0 ..< int(h[0]) {
		loc := b.bands[int(h[1]) + k]
		p := texel(b, int(loc[0]))
		p12 := [4]f32{p[0] - rc.x, p[1] - rc.y, p[2] - rc.x, p[3] - rc.y}
		q := texel(b, int(loc[0]) + 1)
		p3 := [2]f32{q[0] - rc.x, q[1] - rc.y}
		if max(p12[0], p12[2], p3.x) * ppem < -0.5 { break }
		code := root_code(p12[1], p12[3], p3.y)
		if code != 0 {
			r := solve_horiz(p12, p3) * ppem
			if code & 1 != 0 { xcov += sat(r.x + 0.5); xwgt = max(xwgt, sat(1 - abs(r.x) * 2)) }
			if code > 1 { xcov -= sat(r.y + 0.5); xwgt = max(xwgt, sat(1 - abs(r.y) * 2)) }
		}
	}
	v := b.bands[b.n_h + band.x]
	for k in 0 ..< int(v[0]) {
		loc := b.bands[int(v[1]) + k]
		p := texel(b, int(loc[0]))
		p12 := [4]f32{p[0] - rc.x, p[1] - rc.y, p[2] - rc.x, p[3] - rc.y}
		q := texel(b, int(loc[0]) + 1)
		p3 := [2]f32{q[0] - rc.x, q[1] - rc.y}
		if max(p12[1], p12[3], p3.y) * ppem < -0.5 { break }
		code := root_code(p12[0], p12[2], p3.x)
		if code != 0 {
			r := solve_vert(p12, p3) * ppem
			if code & 1 != 0 { ycov -= sat(r.x + 0.5); ywgt = max(ywgt, sat(1 - abs(r.x) * 2)) }
			if code > 1 { ycov += sat(r.y + 0.5); ywgt = max(ywgt, sat(1 - abs(r.y) * 2)) }
		}
	}
	cov := max(abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536), min(abs(xcov), abs(ycov)))
	return sat(cov)
}

// Winding number of the outline around a point (flattened curves), the reference the shader is compared with.
winding :: proc(o: ^font.Outline, p: [2]f32) -> int {
	w := 0
	for q in o.quads {
		N :: 16
		prev := q.p[0]
		for i in 1 ..= N {
			t := f32(i) / N
			a, bb, c := (1 - t) * (1 - t), 2 * t * (1 - t), t * t
			cur := [2]f32{a * q.p[0].x + bb * q.p[1].x + c * q.p[2].x, a * q.p[0].y + bb * q.p[1].y + c * q.p[2].y}
			if (prev.y <= p.y) != (cur.y <= p.y) {
				x := prev.x + (p.y - prev.y) / (cur.y - prev.y) * (cur.x - prev.x)
				if x > p.x { w += cur.y > prev.y ? 1 : -1 }
			}
			prev = cur
		}
	}
	return w
}

@(test)
bands_give_the_outline_coverage :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	for family in ([?]string{"Segoe UI", "Consolas", "Times New Roman"}) {
		face, ok := font.load_system(s, family)
		if !testing.expectf(t, ok, "%s missing", family) { continue }
		for r in ([?]rune{'H', 'O', 'g', 'S', '@', '&', 'W', 'i', '%', 'a', 'e', 'R'}) {
			o: font.Outline
			defer font.outline_destroy(&o)
			if !font.dwrite_outline_provider(s, face, glyph_of(s, face, r), 1.0 / 4096, &o) || len(o.quads) == 0 { continue }
			b: font.Slug_Built
			defer font.slug_built_destroy(&b)
			testing.expectf(t, font.slug_build(&o, &b), "%s %c does not build", family, r)
			// 24 px per em: every pixel of the glyph's box against 8x8 samples of the exact winding number
			ppem := f32(24)
			bad, total := 0, 0
			x0, y0 := math.floor(o.bbox[0] * ppem) - 1, math.floor(o.bbox[1] * ppem) - 1
			x1, y1 := math.ceil(o.bbox[2] * ppem) + 1, math.ceil(o.bbox[3] * ppem) + 1
			for py := y0; py < y1; py += 1 {
				for px := x0; px < x1; px += 1 {
					ref: f32
					for sy in 0 ..< 8 {
						for sx in 0 ..< 8 {
							p := [2]f32{(px + (f32(sx) + 0.5) / 8) / ppem, (py + (f32(sy) + 0.5) / 8) / ppem}
							if winding(&o, p) != 0 { ref += 1.0 / 64 }
						}
					}
					got := cpu_coverage(&b, {(px + 0.5) / ppem, (py + 0.5) / ppem}, ppem)
					total += 1
					if abs(got - ref) > 0.25 { bad += 1 }
				}
			}
			testing.expectf(t, bad * 50 <= total, "%s %c: %d of %d pixels differ by more than a quarter", family, r, bad, total)
		}
	}
}

// A cubic that is a quadratic raised in degree comes back as that quadratic; a true cubic is cut into pieces whose
// quadratics stay within the tolerance of it.
@(test)
cubics_become_quadratics :: proc(t: ^testing.T) {
	o: font.Outline
	defer font.outline_destroy(&o)
	q0, q1, q2 := [2]f32{0, 0}, [2]f32{0.5, 1}, [2]f32{1, 0}
	font.outline_cubic(&o, q0, q0 + (q1 - q0) * (2.0 / 3), q2 + (q1 - q2) * (2.0 / 3), q2, 1.0 / 4096)
	testing.expect_value(t, len(o.quads), 1)
	testing.expect(t, abs(o.quads[0].p[1].x - 0.5) < 1e-5 && abs(o.quads[0].p[1].y - 1) < 1e-5)
	// an S-shaped cubic
	p0, c1, c2, p3 := [2]f32{0, 0}, [2]f32{0.1, 1}, [2]f32{0.9, -1}, [2]f32{1, 0}
	clear(&o.quads)
	tol := f32(1.0 / 2048)
	font.outline_cubic(&o, p0, c1, c2, p3, tol)
	testing.expect(t, len(o.quads) > 1)
	cubic :: proc(t: f32, p0, c1, c2, p3: [2]f32) -> [2]f32 {
		u := 1 - t
		return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p3 * (t * t * t)
	}
	worst: f32
	for q in o.quads {
		for i in 0 ..= 16 {
			s := f32(i) / 16
			u := 1 - s
			pt := q.p[0] * (u * u) + q.p[1] * (2 * u * s) + q.p[2] * (s * s)
			// distance to the cubic's polyline
			best := max(f32)
			for k in 0 ..< 2000 {
				c := cubic(f32(k) / 1999, p0, c1, c2, p3)
				d := pt - c
				best = min(best, math.sqrt(d.x * d.x + d.y * d.y))
			}
			worst = max(worst, best)
		}
	}
	testing.expectf(t, worst <= tol * 1.5, "the quadratics are %.6f em from the cubic (tolerance %.6f)", worst, tol)
	// the chain is continuous
	for i in 1 ..< len(o.quads) { testing.expect(t, math.sqrt(math.pow(o.quads[i].p[0].x - o.quads[i - 1].p[2].x, 2) + math.pow(o.quads[i].p[0].y - o.quads[i - 1].p[2].y, 2)) < 1e-5) }
}

// Another provider replaces DirectWrite's: a square, built here, is drawn from the store like any glyph.
@(test)
provider_is_replaceable :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	face, ok := font.load_system(s, "Segoe UI")
	testing.expect(t, ok)
	font.slug_set_provider(s, proc(s: ^font.State, face: font.Font_Id, gid: u16, tol: f32, out: ^font.Outline) -> bool {
		a, b, c, d := [2]f32{0.1, 0}, [2]f32{0.1, 0.5}, [2]f32{0.6, 0.5}, [2]f32{0.6, 0}
		font.outline_line(out, a, b); font.outline_line(out, b, c); font.outline_line(out, c, d)
		font.outline_end(out, a, d)
		font.outline_bounds(out)
		return true
	})
	g := font.slug_glyph(s, face, 7)
	testing.expect_value(t, g.kind, font.Slug_Kind.Curves)
	testing.expect_value(t, g.bbox, [4]f32{0.1, 0, 0.6, 0.5})
	testing.expect_value(t, g.band_max, [2]u8{0, 0})
}

@(test)
cache_pages_and_eviction :: proc(t: ^testing.T) {
	st := font.DEFAULT_SETTINGS
	st.slug_pages = 1
	s := setup(t, st)
	defer teardown(s)
	face, ok := font.load_system(s, "Segoe UI")
	testing.expect(t, ok)
	g := font.slug_glyph(s, face, glyph_of(s, face, 'A'))
	testing.expect_value(t, g.kind, font.Slug_Kind.Curves)
	g2 := font.slug_glyph(s, face, glyph_of(s, face, 'A'))
	testing.expect_value(t, g2, g)   // cached
	sp := font.slug_glyph(s, face, glyph_of(s, face, ' '))
	testing.expect_value(t, sp.kind, font.Slug_Kind.Blank)
	// a flood of distinct glyphs: with one page allowed and no frame holding it, the page is reused
	font.atlas_begin_frame(s, s)
	for gid in 3 ..< 600 { font.slug_glyph(s, face, u16(gid)) }
	// (a frame never loses pages it draws from: the limit is passed rather than reused within one frame)
	pages_in_frame := font.slug_stats(s).pages
	testing.expect(t, pages_in_frame > 1)
	font.atlas_begin_frame(s, s)
	for gid in 600 ..< 1200 { font.slug_glyph(s, face, u16(gid)) }
	stats := font.slug_stats(s)
	testing.expect(t, stats.evictions > 0, "pages are reused")

	// the data of the first glyph was dropped with its page
	refs := []font.Page_Ref{{page = g.page, epoch = g.epoch}}
	testing.expect(t, !font.slug_pages_hold(s, refs))
}

// Small text: with the native backend, a glyph drawn at slug_hint_ppem or less gets its own outline hinted for that size
// (the light auto-hinter: the x-height and the baseline on whole pixels); bigger, or of unknown size, it keeps the
// design outline. Without a hinter (DirectWrite's backend) the setting changes nothing.
@(test)
hinted_glyphs_per_size :: proc(t: ^testing.T) {
	st := font.DEFAULT_SETTINGS
	st.slug_hint_ppem = 24
	s := setup(t, st)
	defer teardown(s)
	face, ok := font.load_system(s, "Segoe UI")
	testing.expect(t, ok)
	x := glyph_of(s, face, 'x')
	plain := font.slug_glyph(s, face, x)
	big := font.slug_glyph(s, face, x, 40)
	testing.expect(t, !plain.hinted && !big.hinted, "unknown and big sizes keep the design outline")
	testing.expect_value(t, big.bbox, plain.bbox)
	small := font.slug_glyph(s, face, x, 13)
	when font.NATIVE_TEXT {
		testing.expect(t, small.hinted, "13 px per em is hinted")
		testing.expect_value(t, font.slug_glyph(s, face, x, 13), small)   // cached per size
		top, bottom := small.bbox[3] * 13, small.bbox[1] * 13
		testing.expectf(t, abs(top - math.round(top)) < 0.02, "the x-height lands on a pixel: %v", top)
		testing.expectf(t, abs(bottom) < 0.02, "the baseline stays at 0: %v", bottom)
		testing.expect(t, small.orient == plain.orient)
	} else {
		testing.expect(t, !small.hinted, "no hinter, no hinting")
	}
}
