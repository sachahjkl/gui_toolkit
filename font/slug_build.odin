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
// and y = 0; the cache adds where it put the curves (slug_patch_lists).

BAND_EPSILON :: f32(1.0 / 1024)
MAX_BANDS :: 32            // per axis (the shaders take up to 256)
SLUG_TEXTURE_WIDTH :: 4096 // both textures: a glyph's data lies in one row
// The least extent (em) given to a glyph's box: it divides.
@(private) SLUG_BOX_SPAN_MIN_EM :: 1e-6

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
	reserve(&b.curves, len(o.quads) + len(o.ends))
	// curve texels
	first := 0
	for end in o.ends {
		n := end - first
		if n <= 0 { continue }
		base := len(b.curves)
		for k in 0 ..< n {
			q := o.quads[first + k]
			append(&b.curves, [4]f16{f16(q.p[0].x), f16(q.p[0].y), f16(q.p[1].x), f16(q.p[1].y)})
		}
		// the last texel closes the contour: the end of the last curve is the start of the first
		f := o.quads[first].p[0]
		append(&b.curves, [4]f16{f16(f.x), f16(f.y), 0, 0})
		// the half-float values are what the shader sees: bounds from the texels keep the bands consistent with them
		for k in 0 ..< n {
			t, nxt := b.curves[base + k], b.curves[base + k + 1]
			p0, p1, p2 := [2]f32{f32(t[0]), f32(t[1])}, [2]f32{f32(t[2]), f32(t[3])}, [2]f32{f32(nxt[0]), f32(nxt[1])}
			bc := Band_Curve{idx = base + k}
			bc.lo = {min(p0.x, p1.x, p2.x), min(p0.y, p1.y, p2.y)}
			bc.hi = {max(p0.x, p1.x, p2.x), max(p0.y, p1.y, p2.y)}
			bc.flat = {bc.lo.y == bc.hi.y, bc.lo.x == bc.hi.x}
			append(&curves, bc)
		}
		first = end
	}
	if len(curves) == 0 || len(b.curves) > SLUG_TEXTURE_WIDTH { return false }

	box := o.bbox
	b.bbox = box
	axes := [2]Band_Axis{band_axis(curves[:], 0), band_axis(curves[:], 1)}
	b.n_v = pick_band_count(&axes[0], box[0], box[2])
	b.n_h = pick_band_count(&axes[1], box[1], box[3])
	w, h := max(box[2] - box[0], SLUG_BOX_SPAN_MIN_EM), max(box[3] - box[1], SLUG_BOX_SPAN_MIN_EM)
	b.transform = {f32(b.n_v) / w, f32(b.n_h) / h, -box[0] * f32(b.n_v) / w, -box[1] * f32(b.n_h) / h}
	b.headers = b.n_h + b.n_v
	resize(&b.bands, b.headers)

	// lists after the headers: each curve put in the bands it spans, in the axis's order
	for axis in 0 ..< 2 {
		n := axis == 1 ? b.n_h : b.n_v
		g := band_grid(box[axis], axis == 1 ? h : w, n)
		ax := &axes[axis]
		spans := make([][2]i8, len(ax.idx), context.temp_allocator)
		start: [MAX_BANDS + 1]int
		for i in 0 ..< len(ax.idx) {
			spans[i] = band_span(&g, ax.lo[i], ax.hi[i])
			for band in spans[i][0] ..= spans[i][1] { start[band + 1] += 1 }
		}
		for band in 0 ..< n { start[band + 1] += start[band] }
		lists := make([]int, start[n], context.temp_allocator)
		fill := start
		for i in 0 ..< len(ax.idx) {
			for band in spans[i][0] ..= spans[i][1] {
				lists[fill[band]] = ax.idx[i]
				fill[band] += 1
			}
		}
		prev_off, prev_cnt := -1, 0
		prev_list: []int
		for band in 0 ..< n {
			list := lists[start[band]:start[band + 1]]
			header := (axis == 1 ? 0 : b.n_h) + band
			if prev_off >= 0 && slice.equal(list, prev_list) {
				b.bands[header] = {u16(prev_cnt), u16(prev_off)}
				continue
			}
			if len(b.bands) + len(list) > SLUG_TEXTURE_WIDTH { return false }
			off := len(b.bands)
			for ci in list { append(&b.bands, [2]u16{u16(ci), 0}) }
			b.bands[header] = {u16(len(list)), u16(off)}
			prev_off, prev_cnt, prev_list = off, len(list), list
		}
	}
	return true
}

// The curves the bands along an axis can hold (1: horizontal bands, a y range; 0: vertical bands, an x range: not those
// parallel to the bands' rays), in the order of the bands' lists: descending largest coordinate across the band (x for
// a horizontal band, y for a vertical one), stable on the curve's order. Their extent along the axis and their texel.
@(private)
Band_Axis :: struct {
	lo, hi: []f32,
	idx:    []int,
}

// A sort key: the order of the largest coordinate across the band, inverted, above the curve's index.
@(private) BAND_KEY_SHIFT :: 32
@(private) BAND_KEY_INDEX_MASK :: 1 << BAND_KEY_SHIFT - 1
@(private) F32_SIGN :: u32(1) << 31

@(private)
band_axis :: proc(curves: []Band_Curve, axis: int) -> (r: Band_Axis) {
	other := 1 - axis
	keys := make([dynamic]u64, 0, len(curves), context.temp_allocator)
	for c, i in curves {
		if c.flat[axis == 1 ? 0 : 1] { continue }   // parallel to the rays of this band
		append(&keys, u64(~f32_order(c.hi[other])) << BAND_KEY_SHIFT | u64(i))
	}
	slice.sort(keys[:])
	r.lo = make([]f32, len(keys), context.temp_allocator)
	r.hi = make([]f32, len(keys), context.temp_allocator)
	r.idx = make([]int, len(keys), context.temp_allocator)
	for k, j in keys {
		c := &curves[k & BAND_KEY_INDEX_MASK]
		r.lo[j], r.hi[j], r.idx[j] = c.lo[axis], c.hi[axis], c.idx
	}
	return
}

// An f32 as a u32 in the same order (-0 as 0).
@(private)
f32_order :: #force_inline proc(f: f32) -> u32 {
	bits := transmute(u32)(f == 0 ? 0 : f)
	return bits & F32_SIGN != 0 ? ~bits : bits | F32_SIGN
}

// `n` bands from `lo` over `span`: band k is [a[k], z[k]], overlapping its neighbours by BAND_EPSILON.
@(private)
Band_Grid :: struct {
	a, z:      [MAX_BANDS]f32,
	lo, scale: f32,   // a coordinate's band is about (x - lo) * scale
	n:         int,
}

@(private)
band_grid :: proc(lo, span: f32, n: int) -> (g: Band_Grid) {
	g.lo, g.scale, g.n = lo, f32(n) / span, n
	for k in 0 ..< n {
		g.a[k] = lo + span * f32(k) / f32(n) - BAND_EPSILON
		g.z[k] = lo + span * f32(k + 1) / f32(n) + BAND_EPSILON
	}
	return
}

// The first and last bands of `g` a curve from `lo` to `hi` touches (hi >= a[k] and lo <= z[k]); first > last when
// none. The guess from the scale is corrected against the bands' own bounds, so the bands are those of the test
// written out.
@(private)
band_span :: #force_inline proc(g: ^Band_Grid, lo, hi: f32) -> [2]i8 {
	first := clamp(int((lo - g.lo) * g.scale), 0, g.n - 1)
	for first > 0 && g.z[first - 1] >= lo { first -= 1 }
	for first < g.n && g.z[first] < lo { first += 1 }
	last := clamp(int((hi - g.lo) * g.scale), 0, g.n - 1)
	for last < g.n - 1 && g.a[last + 1] <= hi { last += 1 }
	for last >= 0 && g.a[last] > hi { last -= 1 }
	return {i8(first), i8(last)}
}

// The number of bands along an axis from `lo` to `hi`: the smallest whose fullest band is within one curve of the best
// any count gives.
@(private)
pick_band_count :: proc(ax: ^Band_Axis, lo, hi: f32) -> int {
	span := max(hi - lo, SLUG_BOX_SPAN_MIN_EM)
	candidates := [?]int{1, 2, 3, 4, 6, 8, 12, 16, 24, MAX_BANDS}
	worst: [len(candidates)]int
	best := max(int)
	for n, k in candidates {
		g := band_grid(lo, span, n)
		// curves starting minus curves ended, per band: the running sum is a band's count
		delta: [MAX_BANDS + 1]int
		for i in 0 ..< len(ax.lo) {
			s := band_span(&g, ax.lo[i], ax.hi[i])
			if s[0] > s[1] { continue }
			delta[s[0]] += 1
			delta[s[1] + 1] -= 1
		}
		cnt := 0
		for band in 0 ..< n {
			cnt += delta[band]
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
