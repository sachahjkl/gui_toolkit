package font

import "base:runtime"
import "core:math"
import "core:slice"

// The software rasterizer of the COLR interpreter (colr.odin): outlines to anti-aliased coverage, float surfaces with
// premultiplied RGBA, and the compositing operators of PaintComposite (the W3C Compositing and Blending set).
// Independent of the platform: it only sees `Outline` (quadratic curves in em units, y up).

// A 2D affine transform: x' = a x + c y + e, y' = b x + d y + f.
Mat :: [6]f32

MAT_IDENTITY :: Mat{1, 0, 0, 1, 0, 0}

// m after n: (mat_mul(m, n))(p) = m(n(p)).
mat_mul :: proc "contextless" (m, n: Mat) -> Mat {
	return {
		m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
		m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
		m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5],
	}
}

mat_apply :: #force_inline proc "contextless" (m: Mat, p: [2]f32) -> [2]f32 {
	return {m[0] * p.x + m[2] * p.y + m[4], m[1] * p.x + m[3] * p.y + m[5]}
}

mat_invert :: proc "contextless" (m: Mat) -> (r: Mat, ok: bool) {
	det := m[0] * m[3] - m[1] * m[2]
	if det == 0 || det != det || abs(det) < 1e-20 { return MAT_IDENTITY, false }
	id := 1 / det
	r = {m[3] * id, -m[1] * id, -m[2] * id, m[0] * id, 0, 0}
	r[4] = -(r[0] * m[4] + r[2] * m[5])
	r[5] = -(r[1] * m[4] + r[3] * m[5])
	return r, true
}

mat_translate :: #force_inline proc "contextless" (x, y: f32) -> Mat { return {1, 0, 0, 1, x, y} }
mat_scale :: #force_inline proc "contextless" (x, y: f32) -> Mat { return {x, 0, 0, y, 0, 0} }

// `m` applied around the point c.
mat_around :: proc "contextless" (m: Mat, c: [2]f32) -> Mat {
	return mat_mul(mat_translate(c.x, c.y), mat_mul(m, mat_translate(-c.x, -c.y)))
}

////////////////////////////////
// Coverage

@(private)
Edge :: struct {
	x0, y0, x1, y1: f32,   // y0 < y1
	slope:          f32,   // dx / dy
	dir:            i32,
}

@(private)
Cross :: struct {
	x:   f32,
	dir: i32,
}

// Flattening tolerance of the curves, pixels.
COLR_FLATNESS :: 0.02

// Nonzero-winding coverage of `o` under `m` (em units to canvas pixels) over the pixels of `clip` (x0 y0 x1 y1): the
// rectangle it covers (inside `clip`) and one coverage value per pixel of it. Horizontal coverage is exact, vertical
// coverage is sampled `samples` times per pixel row. ok = false: nothing is covered.
colr_cover :: proc(o: ^Outline, m: Mat, clip: [4]int, samples: int, alloc: runtime.Allocator) -> (rect: [4]int, cov: []f32, ok: bool) {
	if len(o.quads) == 0 { return }
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{-max(f32), -max(f32)}
	for q in o.quads {
		for p in q.p {
			t := mat_apply(m, p)
			lo.x, lo.y = min(lo.x, t.x), min(lo.y, t.y)
			hi.x, hi.y = max(hi.x, t.x), max(hi.y, t.y)
		}
	}
	if !(lo.x == lo.x && lo.y == lo.y && hi.x == hi.x && hi.y == hi.y) { return }   // NaN
	rect = {
		max(clip[0], int(math.floor(clamp(lo.x, -1e6, 1e6)))), max(clip[1], int(math.floor(clamp(lo.y, -1e6, 1e6)))),
		min(clip[2], int(math.ceil(clamp(hi.x, -1e6, 1e6)))), min(clip[3], int(math.ceil(clamp(hi.y, -1e6, 1e6)))),
	}
	if rect[2] <= rect[0] || rect[3] <= rect[1] { return }
	edges := make([dynamic]Edge, 0, len(o.quads) * 6, alloc)
	for q in o.quads {
		p0, p1, p2 := mat_apply(m, q.p[0]), mat_apply(m, q.p[1]), mat_apply(m, q.p[2])
		d := p0 - p1 * 2 + p2
		dev := math.sqrt(d.x * d.x + d.y * d.y)
		n := clamp(int(math.ceil(math.sqrt(dev / (4 * COLR_FLATNESS)))), 1, 48)
		prev := p0
		for i in 1 ..= n {
			t := f32(i) / f32(n)
			u := 1 - t
			cur := p0 * (u * u) + p1 * (2 * u * t) + p2 * (t * t)
			if i == n { cur = p2 }
			add_edge(&edges, prev, cur)
			prev = cur
		}
	}
	if len(edges) == 0 { return }
	cov = scan_edges(edges[:], rect, samples, alloc)
	return rect, cov, true
}

@(private)
add_edge :: proc(edges: ^[dynamic]Edge, a, b: [2]f32) {
	if a.y == b.y { return }
	e: Edge
	if a.y < b.y {
		e = Edge{x0 = a.x, y0 = a.y, x1 = b.x, y1 = b.y, dir = 1}
	} else {
		e = Edge{x0 = b.x, y0 = b.y, x1 = a.x, y1 = a.y, dir = -1}
	}
	e.slope = (e.x1 - e.x0) / (e.y1 - e.y0)
	append(edges, e)
}

@(private)
scan_edges :: proc(edges: []Edge, rect: [4]int, samples: int, alloc: runtime.Allocator) -> []f32 {
	w, h := rect[2] - rect[0], rect[3] - rect[1]
	cov := make([]f32, w * h, alloc)
	area := make([]f32, w + 2, alloc)
	diff := make([]f32, w + 2, alloc)
	slice.sort_by(edges, proc(a, b: Edge) -> bool { return a.y0 < b.y0 })
	active := make([dynamic]int, 0, 32, alloc)
	xs := make([dynamic]Cross, 0, 32, alloc)
	fx0 := f32(rect[0])
	fw := f32(w)
	inv_n := 1 / f32(samples)
	next := 0
	for row in 0 ..< h {
		any := false
		for si in 0 ..< samples {
			y := f32(rect[1] + row) + (f32(si) + 0.5) * inv_n
			for next < len(edges) && edges[next].y0 <= y {
				append(&active, next)
				next += 1
			}
			i := 0
			for i < len(active) {
				if edges[active[i]].y1 <= y { unordered_remove(&active, i) } else { i += 1 }
			}
			if len(active) == 0 { continue }
			clear(&xs)
			for ei in active {
				e := &edges[ei]
				append(&xs, Cross{e.x0 + (y - e.y0) * e.slope, e.dir})
			}
			// insertion sort: a handful of crossings
			for j in 1 ..< len(xs) {
				c := xs[j]
				k := j - 1
				for k >= 0 && xs[k].x > c.x {
					xs[k + 1] = xs[k]
					k -= 1
				}
				xs[k + 1] = c
			}
			wind: i32
			start: f32
			for c in xs {
				was := wind
				wind += c.dir
				if was == 0 && wind != 0 {
					start = c.x
				} else if was != 0 && wind == 0 {
					xa := clamp(start - fx0, 0, fw)
					xb := clamp(c.x - fx0, 0, fw)
					if xb > xa {
						any = true
						ia, ib := int(xa), int(xb)
						if ia == ib {
							area[ia] += xb - xa
						} else {
							area[ia] += f32(ia + 1) - xa
							diff[ia + 1] += 1
							diff[ib] -= 1
							area[ib] += xb - f32(ib)
						}
					}
				}
			}
		}
		if !any { continue }
		run: f32
		line := cov[row * w:][:w]
		for x in 0 ..< w {
			run += diff[x]
			line[x] = clamp((area[x] + run) * inv_n, 0, 1)
			area[x], diff[x] = 0, 0
		}
		area[w], area[w + 1], diff[w], diff[w + 1] = 0, 0, 0, 0
	}
	return cov
}

////////////////////////////////
// Surfaces

// Premultiplied RGBA, one float per channel.
Surface :: struct {
	w, h: int,
	px:   [][4]f32,
}

surface_make :: proc(w, h: int, alloc: runtime.Allocator) -> ^Surface {
	s := new(Surface, alloc)
	s.w, s.h = w, h
	s.px = make([][4]f32, w * h, alloc)
	return s
}

// A rectangle of the canvas and, optionally, a coverage value per pixel of it (nil: all of it).
Clip :: struct {
	r:   [4]int,
	cov: []f32,
}

clip_cov :: #force_inline proc "contextless" (c: ^Clip, x, y: int) -> f32 {
	if c.cov == nil { return 1 }
	return c.cov[(y - c.r[1]) * (c.r[2] - c.r[0]) + (x - c.r[0])]
}

// The part of `clip` inside the coverage `cov` of `rect` (rect inside clip.r).
clip_and :: proc(clip: ^Clip, rect: [4]int, cov: []f32, alloc: runtime.Allocator) -> Clip {
	if clip.cov == nil { return Clip{rect, cov} }
	w := rect[2] - rect[0]
	out := make([]f32, len(cov), alloc)
	for y in rect[1] ..< rect[3] {
		for x in rect[0] ..< rect[2] {
			i := (y - rect[1]) * w + (x - rect[0])
			out[i] = cov[i] * clip_cov(clip, x, y)
		}
	}
	return Clip{rect, out}
}

// src (premultiplied) over the pixel.
over :: #force_inline proc "contextless" (dst: ^[4]f32, src: [4]f32) {
	k := 1 - src.a
	dst^ = {src.r + dst.r * k, src.g + dst.g * k, src.b + dst.b * k, src.a + dst.a * k}
}

////////////////////////////////
// PaintComposite

// COLR v1 composite modes (the values of the format).
Composite_Mode :: enum u8 {
	Clear, Src, Dest, Src_Over, Dest_Over, Src_In, Dest_In, Src_Out, Dest_Out, Src_Atop, Dest_Atop, Xor, Plus,
	Screen, Overlay, Darken, Lighten, Color_Dodge, Color_Burn, Hard_Light, Soft_Light, Difference, Exclusion, Multiply,
	Hsl_Hue, Hsl_Saturation, Hsl_Color, Hsl_Luminosity,
}

// Source onto backdrop for each pixel (both premultiplied); the result goes to `dst`.
surface_composite :: proc(mode: Composite_Mode, src, dst: ^Surface) {
	n := min(len(src.px), len(dst.px))
	for i in 0 ..< n { dst.px[i] = composite_px(mode, src.px[i], dst.px[i]) }
}

@(private)
composite_px :: proc "contextless" (mode: Composite_Mode, s, b: [4]f32) -> [4]f32 {
	sa, ba := s.a, b.a
	pd :: #force_inline proc "contextless" (s, b: [4]f32, fa, fb: f32) -> [4]f32 { return s * fa + b * fb }
	switch mode {
	case .Clear: return {}
	case .Src: return s
	case .Dest: return b
	case .Src_Over: return pd(s, b, 1, 1 - sa)
	case .Dest_Over: return pd(s, b, 1 - ba, 1)
	case .Src_In: return pd(s, b, ba, 0)
	case .Dest_In: return pd(s, b, 0, sa)
	case .Src_Out: return pd(s, b, 1 - ba, 0)
	case .Dest_Out: return pd(s, b, 0, 1 - sa)
	case .Src_Atop: return pd(s, b, ba, 1 - sa)
	case .Dest_Atop: return pd(s, b, 1 - ba, sa)
	case .Xor: return pd(s, b, 1 - ba, 1 - sa)
	case .Plus:
		r := s + b
		return {min(r.r, 1), min(r.g, 1), min(r.b, 1), min(r.a, 1)}
	case .Screen, .Overlay, .Darken, .Lighten, .Color_Dodge, .Color_Burn, .Hard_Light, .Soft_Light, .Difference, .Exclusion, .Multiply,
	     .Hsl_Hue, .Hsl_Saturation, .Hsl_Color, .Hsl_Luminosity:
		return blend_px(mode, s, b)
	}
	return pd(s, b, 1, 1 - sa)
}

// co = cs (1 - ab) + cb (1 - as) + as ab B(Cb, Cs), on premultiplied colors; ao = as + ab - as ab.
@(private)
blend_px :: proc "contextless" (mode: Composite_Mode, s, b: [4]f32) -> [4]f32 {
	sa, ba := s.a, b.a
	ao := sa + ba - sa * ba
	if sa <= 0 { return b }
	if ba <= 0 { return s }
	cs := [3]f32{s.r / sa, s.g / sa, s.b / sa}
	cb := [3]f32{b.r / ba, b.g / ba, b.b / ba}
	bl: [3]f32
	#partial switch mode {
	case .Hsl_Hue: bl = set_lum(set_sat(cs, sat(cb)), lum(cb))
	case .Hsl_Saturation: bl = set_lum(set_sat(cb, sat(cs)), lum(cb))
	case .Hsl_Color: bl = set_lum(cs, lum(cb))
	case .Hsl_Luminosity: bl = set_lum(cb, lum(cs))
	case:
		for i in 0 ..< 3 { bl[i] = blend_sep(mode, cb[i], cs[i]) }
	}
	r: [4]f32
	for i in 0 ..< 3 { r[i] = s[i] * (1 - ba) + b[i] * (1 - sa) + sa * ba * bl[i] }
	r.a = ao
	return r
}

@(private)
blend_sep :: proc "contextless" (mode: Composite_Mode, cb, cs: f32) -> f32 {
	#partial switch mode {
	case .Multiply: return cb * cs
	case .Screen: return cb + cs - cb * cs
	case .Overlay: return blend_sep(.Hard_Light, cs, cb)
	case .Darken: return min(cb, cs)
	case .Lighten: return max(cb, cs)
	case .Color_Dodge:
		if cb == 0 { return 0 }
		if cs >= 1 { return 1 }
		return min(1, cb / (1 - cs))
	case .Color_Burn:
		if cb >= 1 { return 1 }
		if cs <= 0 { return 0 }
		return 1 - min(1, (1 - cb) / cs)
	case .Hard_Light:
		if cs <= 0.5 { return cb * 2 * cs }
		t := 2 * cs - 1
		return cb + t - cb * t
	case .Soft_Light:
		if cs <= 0.5 { return cb - (1 - 2 * cs) * cb * (1 - cb) }
		d: f32 = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : math.sqrt(cb)
		return cb + (2 * cs - 1) * (d - cb)
	case .Difference: return abs(cb - cs)
	case .Exclusion: return cb + cs - 2 * cb * cs
	}
	return cs
}

@(private) lum :: proc "contextless" (c: [3]f32) -> f32 { return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }
@(private) sat :: proc "contextless" (c: [3]f32) -> f32 { return max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }

@(private)
clip_color :: proc "contextless" (c: [3]f32) -> [3]f32 {
	l, n, x := lum(c), min(c.r, c.g, c.b), max(c.r, c.g, c.b)
	r := c
	if n < 0 { for i in 0 ..< 3 { r[i] = l + (r[i] - l) * l / (l - n) } }
	if x > 1 { for i in 0 ..< 3 { r[i] = l + (r[i] - l) * (1 - l) / (x - l) } }
	return r
}

@(private)
set_lum :: proc "contextless" (c: [3]f32, l: f32) -> [3]f32 {
	d := l - lum(c)
	return clip_color({c.r + d, c.g + d, c.b + d})
}

@(private)
set_sat :: proc "contextless" (c: [3]f32, s: f32) -> [3]f32 {
	mx, mn := max(c.r, c.g, c.b), min(c.r, c.g, c.b)
	if mx <= mn { return {} }
	r: [3]f32
	for i in 0 ..< 3 { r[i] = (c[i] - mn) * s / (mx - mn) }
	return r
}
