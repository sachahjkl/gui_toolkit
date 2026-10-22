package font

import "core:math"
import "core:slice"

// Slug glyph data from an Outline: the curve texels and the band texels one glyph occupies (README of the reference,
// "Tips and Tricks"; paper: JCGT 6(2), 2017).
//
//   Curve texels, RGBA16F: curve k of a contour reads texel j = (p1, p2) and texel j+1 = (p3, ...): the end of a
//   curve is the start of the next one, so a closed contour of n curves takes n+1 texels (the last one repeats the first
//   point). A straight line is {p1, p2 = p3, p3}.
//
//   Band texels, RG16UI, from the glyph's location: one (curve count, offset of the list) entry for each horizontal
//   band, then one for each vertical band, then the lists: a list is the curve texels' locations (x, y) of the curves
//   that touch the band, in descending order of their largest x (horizontal bands) or y (vertical bands), which is what
//   lets the pixel shader stop early. Bands overlap by BAND_EPSILON so a curve on a border is in both. Straight curves
//   parallel to a band's rays are left out (they cannot change a winding number). Adjacent bands with the same curves
//   share a list.
//
// The glyph is built with local coordinates: the curve locations in lists have x = index in the glyph's own curve texels
// and y = 0; the cache adds where it put the curves (patch_lists).

BAND_EPSILON :: f32(1.0 / 1024)
MAX_BANDS :: 32            // per axis (the shaders take up to 256)
SLUG_TEXTURE_WIDTH :: 4096 // both textures: a glyph's data lies in one row

Slug_Built :: struct {
	curves:   [dynamic][4]f16,
	bands:    [dynamic][2]u16,
	headers:  int,           // entries before the lists: n_h + n_v
	n_h, n_v: int,           // number of horizontal / vertical bands
	transform: [4]f32,       // band scale x, y and offset x, y: band = int(em_coord * scale + offset)
	bbox:     [4]f32,
}

slug_built_destroy :: proc(b: ^Slug_Built) {
	delete(b.curves)
	delete(b.bands)
	b^ = {}
}

@(private)
Band_Curve :: struct {
	idx:    int,       // texel index in the glyph's curve texels
	lo, hi: [2]f32,    // bounds of the control points
	flat:   [2]bool,   // flat[0]: all y equal (never in a horizontal band); flat[1]: all x equal
}

// Builds the glyph data. false: the glyph does not fit one row of the textures (the caller draws it another way).
slug_build :: proc(o: ^Outline, b: ^Slug_Built) -> bool {
	if len(o.quads) == 0 { return false }
	curves := make([dynamic]Band_Curve, 0, len(o.quads), context.temp_allocator)
	// curve texels
	first := 0
	for end in o.ends {
		n := end - first
		if n <= 0 { continue }
		base := len(b.curves)
		for k in 0 ..< n {
			q := o.quads[first + k]
			append(&b.curves, [4]f16{f16(q.p[0].x), f16(q.p[0].y), f16(q.p[1].x), f16(q.p[1].y)})
			// the half-float values are what the shader sees: bounds from the quantized control points keep the bands
			// consistent with them
			p0 := [2]f32{f32(f16(q.p[0].x)), f32(f16(q.p[0].y))}
			p1 := [2]f32{f32(f16(q.p[1].x)), f32(f16(q.p[1].y))}
			nxt := o.quads[first + (k + 1) % n].p[0]
			p2 := [2]f32{f32(f16(nxt.x)), f32(f16(nxt.y))}
			bc := Band_Curve{idx = base + k}
			bc.lo = {min(p0.x, p1.x, p2.x), min(p0.y, p1.y, p2.y)}
			bc.hi = {max(p0.x, p1.x, p2.x), max(p0.y, p1.y, p2.y)}
			bc.flat = {bc.lo.y == bc.hi.y, bc.lo.x == bc.hi.x}
			append(&curves, bc)
		}
		// the last texel closes the contour: the end of the last curve is the start of the first
		f := o.quads[first].p[0]
		append(&b.curves, [4]f16{f16(f.x), f16(f.y), 0, 0})
		first = end
	}
	if len(curves) == 0 || len(b.curves) > SLUG_TEXTURE_WIDTH { return false }

	box := o.bbox
	w, h := max(box[2] - box[0], 1e-6), max(box[3] - box[1], 1e-6)
	b.bbox = box
	b.n_v = pick_band_count(curves[:], 0, box[0], box[2])
	b.n_h = pick_band_count(curves[:], 1, box[1], box[3])
	b.transform = {f32(b.n_v) / w, f32(b.n_h) / h, -box[0] * f32(b.n_v) / w, -box[1] * f32(b.n_h) / h}
	b.headers = b.n_h + b.n_v
	resize(&b.bands, b.headers)

	// lists after the headers
	ensure :: proc(b: ^Slug_Built, n: int) -> bool { return len(b.bands) + n <= SLUG_TEXTURE_WIDTH }
	for axis in 0 ..< 2 {
		n := axis == 1 ? b.n_h : b.n_v
		lo := box[axis]
		span := axis == 1 ? h : w
		prev_off, prev_cnt := -1, 0
		prev_list: []int
		for band in 0 ..< n {
			a := lo + span * f32(band) / f32(n) - BAND_EPSILON
			z := lo + span * f32(band + 1) / f32(n) + BAND_EPSILON
			list := band_list(curves[:], axis, a, z)
			header := (axis == 1 ? 0 : b.n_h) + band
			if prev_off >= 0 && slice.equal(list, prev_list) {
				b.bands[header] = {u16(prev_cnt), u16(prev_off)}
				continue
			}
			if !ensure(b, len(list)) { return false }
			off := len(b.bands)
			for ci in list { append(&b.bands, [2]u16{u16(ci), 0}) }
			b.bands[header] = {u16(len(list)), u16(off)}
			prev_off, prev_cnt, prev_list = off, len(list), list
		}
	}
	return true
}

// The curves of the band [a, z] along `axis` (1: horizontal band, y range; 0: vertical band, x range), sorted by their
// largest coordinate across the band (x for a horizontal band, y for a vertical one), descending. Indices of texels.
@(private)
band_list :: proc(curves: []Band_Curve, axis: int, a, z: f32) -> []int {
	other := 1 - axis
	picked := make([dynamic]int, 0, 8, context.temp_allocator)
	for c, i in curves {
		if c.flat[axis == 1 ? 0 : 1] { continue }   // parallel to the rays of this band
		if c.hi[axis] < a || c.lo[axis] > z { continue }
		append(&picked, i)
	}
	// sort by descending hi[other] (stable on the curve index)
	Keyed :: struct { key: f32, i: int }
	keyed := make([]Keyed, len(picked), context.temp_allocator)
	for p, k in picked { keyed[k] = {curves[p].hi[other], p} }
	slice.sort_by(keyed, proc(l, r: Keyed) -> bool { return l.key > r.key || (l.key == r.key && l.i < r.i) })
	out := make([]int, len(keyed), context.temp_allocator)
	for k, j in keyed { out[j] = curves[k.i].idx }
	return out
}

// The number of bands along `axis`: the smallest whose fullest band is within one curve of the best any count gives.
@(private)
pick_band_count :: proc(curves: []Band_Curve, axis: int, lo, hi: f32) -> int {
	span := max(hi - lo, 1e-6)
	candidates := [?]int{1, 2, 3, 4, 6, 8, 12, 16, 24, MAX_BANDS}
	worst: [len(candidates)]int
	best := max(int)
	for n, k in candidates {
		for band in 0 ..< n {
			a := lo + span * f32(band) / f32(n) - BAND_EPSILON
			z := lo + span * f32(band + 1) / f32(n) + BAND_EPSILON
			cnt := 0
			for c in curves {
				if c.flat[axis == 1 ? 0 : 1] || c.hi[axis] < a || c.lo[axis] > z { continue }
				cnt += 1
			}
			worst[k] = max(worst[k], cnt)
		}
		best = min(best, worst[k])
	}
	for n, k in candidates {
		if worst[k] <= best + 1 { return n }
	}
	return candidates[len(candidates) - 1]
}

// Moves the curve locations of the lists to where the cache put the curve texels: (x0 + index, y).
slug_patch_lists :: proc(b: ^Slug_Built, x0, y: int) {
	for i in b.headers ..< len(b.bands) {
		b.bands[i] = {u16(x0 + int(b.bands[i].x)), u16(y)}
	}
}

// The em-space position of a pixel sample in the glyph's band grid: for tests and tools.
slug_band_of :: proc(b: ^Slug_Built, em: [2]f32) -> [2]int {
	x := clamp(int(math.floor(em.x * b.transform[0] + b.transform[2])), 0, b.n_v - 1)
	y := clamp(int(math.floor(em.y * b.transform[1] + b.transform[3])), 0, b.n_h - 1)
	return {x, y}
}
