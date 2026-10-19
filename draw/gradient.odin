package draw

import "core:math"
import "../font"
import "../render"

// Gradients evaluated per pixel (CSS Images 4): linear, radial, conic, repeating, with stop positions, transition hints,
// interpolation in several color spaces, tiling (background-size / background-repeat), dithering; filled into a rounded
// rect like `rect` (so clips and corners work as for any shape). And box shadows: the exact gaussian blur of a rounded
// rect (CSS box-shadow), outer or inset.

Gradient_Kind :: enum u8 { Linear, Radial, Conic }

// Where stop colors are interpolated (CSS Color 4 §12: `in <colorspace>`). Srgb is the CSS default for legacy colors.
// (CSS xyz interpolates exactly as Linear: it is a linear map of linear sRGB.)
Gradient_Space :: enum u8 { Srgb, Linear, Oklab, Oklch, Lab, Lch, Hsl, Hwb }

// How hues of polar spaces (Oklch, Lch, Hsl, Hwb) go from one stop to the next (CSS Color 4 §12.4).
Hue_Method :: enum u8 { Shorter, Longer, Increasing, Decreasing }

Gradient_Stop :: struct {
	color:    Color,    // linear, straight alpha (like every color of draw)
	pos:      f32,      // along the gradient: 0 = start, 1 = end (any value; stops must not go back)
	has_hint: bool,
	hint:     f32,      // transition hint to the next stop: where (0..1 of the interval) the colors mix half and half
}

Gradient :: struct {
	kind:      Gradient_Kind,
	repeating: bool,                   // the stops repeat from the first position to the last
	space:     Gradient_Space,
	hue:       Hue_Method,
	// geometry, local units, relative to tile.min (or to the drawn rect's corner when there is no tile)
	start, end: Vec2,                  // Linear: t = 0 at start, 1 at end, constant across
	center:    Vec2,                   // Radial, Conic
	radii:     Vec2,                   // Radial: t = 1 on the ellipse of these radii
	angle:     f32,                    // Conic: where t = 0, radians clockwise from up
	stops:     []Gradient_Stop,
	tile:      Rect,                   // one copy of the gradient (CSS: background positioning area and size); zero:
	                                   // the drawn rect, not repeated
	repeat:    [2]bool,                // tiles repeat along x / y; else only the tile is painted
	spacing:   Vec2,                   // between repeated tiles (background-repeat: space)
	dither:    bool,                   // noise of one 8-bit level against banding
}

// Fills `r` (rounded by `radii`, corner order as rect_corners) with `g`, multiplied by `tint` (alpha) and the alpha
// stack. Works under any transform, in pictures, inside clips.
gradient :: proc(c: ^Context, r: Rect, g: Gradient, radii: [4]f32 = {}, tint: Color = WHITE) {
	if len(g.stops) == 0 || rect_empty(r) { return }
	xf, alpha, shape := cur(c)
	simple := xf.simple
	s: f32 = 1
	off := Vec2{}
	if simple { s, off = xf.m.a, {xf.m.e, xf.m.f} }
	// the table entry: geometry in the instance's units (baked like the rect when the transform is baked)
	tile := g.tile
	has_tile := !(tile.min == {} && tile.max == {})
	origin := has_tile ? tile.min : r.min
	pt :: proc(p: Vec2, s: f32, off: Vec2) -> Vec2 { return p * s + off }
	first := len(c.grads)
	flags: u32 = u32(g.kind)
	if g.repeating { flags |= render.GRAD_REPEATING }
	if g.dither { flags |= render.GRAD_DITHER }
	if g.repeat[0] { flags |= render.GRAD_REPEAT_X }
	if g.repeat[1] { flags |= render.GRAD_REPEAT_Y }
	n := min(len(g.stops), render.MAX_GRADIENT_STOPS)
	stops := g.stops[:n]
	// a repeating gradient whose period is zero is its average color (CSS Images 4 §3.6)
	t0, t1 := stops[0].pos, stops[n - 1].pos
	average := g.repeating && t1 - t0 <= 1e-6
	header := [4]u32{flags, u32(g.space), u32(g.hue), average ? 1 : u32(n)}
	append(&c.grads, transmute([4]f32)header)
	geom: [4]f32
	switch g.kind {
	case .Linear:
		a, b := pt(g.start, s, {}), pt(g.end, s, {})
		geom = {a.x, a.y, b.x, b.y}
	case .Radial:
		cc := pt(g.center, s, {})
		geom = {cc.x, cc.y, g.radii.x * s, g.radii.y * s}
	case .Conic:
		cc := pt(g.center, s, {})
		geom = {cc.x, cc.y, g.angle, 0}
	}
	append(&c.grads, geom)
	to := pt(origin, s, off)
	tsize := has_tile ? rect_size(tile) * s : Vec2{}
	append(&c.grads, [4]f32{to.x, to.y, tsize.x, tsize.y})
	append(&c.grads, [4]f32{g.spacing.x * s, g.spacing.y * s, t0, t1})
	if average {
		one := [1][4]f32{average_stops(stops, g.space)}
		fix_hues(one[:], g.space, g.hue)
		append(&c.grads, one[0])
		append(&c.grads, [4]f32{0, -1, 0, 0})
	} else {
		enc := make([][4]f32, n, context.temp_allocator)
		for st, i in stops { enc[i] = to_space(st.color, g.space) }
		fix_hues(enc, g.space, g.hue)
		for st, i in stops {
			append(&c.grads, enc[i])
			append(&c.grads, [4]f32{st.pos, st.has_hint ? clamp(st.hint, 0, 1) : -1, 0, 0})
		}
	}
	col := tint
	col.a *= alpha
	flags_i: u32 = c.circular ? render.FLAG_CIRCLE : 0
	inst := render.Rect_Inst{colors = {col, col, col, col}, soft = 1, use_tex = render.KIND_GRADIENT, tex_size = font.ATLAS_SIZE, clip = shape, flags = flags_i, aux = u32(first)}
	if simple {
		inst.dst = {r.min.x * s + off.x, r.min.y * s + off.y, r.max.x * s + off.x, r.max.y * s + off.y}
		inst.radii = radii * s
	} else {
		inst.dst = {r.min.x, r.min.y, r.max.x, r.max.y}
		inst.radii = radii
		inst.xform = gpu_xform(c, xf)
	}
	append(&c.insts, inst)
}

// Polar spaces: which component is the hue (-1: none).
@(private)
hue_index :: proc(space: Gradient_Space) -> int {
	#partial switch space {
	case .Oklch, .Lch: return 2
	case .Hsl, .Hwb: return 0
	}
	return -1
}

// A linear straight color to the interpolation space, premultiplied (all components but the hue).
@(private)
to_space :: proc(col: Color, space: Gradient_Space) -> [4]f32 {
	a := clamp(col.a, 0, 1)
	lin := [3]f32{col.r, col.g, col.b}
	v: [3]f32
	switch space {
	case .Srgb: v = {render.linear_to_srgb(lin.x), render.linear_to_srgb(lin.y), render.linear_to_srgb(lin.z)}
	case .Linear: v = lin
	case .Oklab: v = linear_to_oklab(lin)
	case .Oklch: v = to_polar(linear_to_oklab(lin), 2e-4)
	case .Lab: v = linear_to_lab(lin)
	case .Lch: v = to_polar(linear_to_lab(lin), 0.015)
	case .Hsl: v = srgb_to_hsl({render.linear_to_srgb(lin.x), render.linear_to_srgb(lin.y), render.linear_to_srgb(lin.z)})
	case .Hwb:
		sv := [3]f32{render.linear_to_srgb(lin.x), render.linear_to_srgb(lin.y), render.linear_to_srgb(lin.z)}
		h := srgb_to_hsl(sv)
		v = {h.x, min(sv.x, sv.y, sv.z), 1 - max(sv.x, sv.y, sv.z)}
		if v.y + v.z >= 1 - 1e-5 { v.x = math.nan_f32() }   // gray: powerless hue
	}
	hi := hue_index(space)
	out := [4]f32{v.x * a, v.y * a, v.z * a, a}
	if hi >= 0 { out[hi] = v[hi] }
	return out
}

// Hues of consecutive stops adjusted for the hue method (CSS Color 4 §12.4); a powerless hue (gray, NaN) takes its
// neighbor's.
@(private)
fix_hues :: proc(enc: [][4]f32, space: Gradient_Space, method: Hue_Method) {
	hi := hue_index(space)
	if hi < 0 || len(enc) == 0 { return }
	// powerless hues: from the next stop with a hue, else the previous
	for i in 0 ..< len(enc) {
		if !math.is_nan(enc[i][hi]) { continue }
		h := f32(0)
		found := false
		for j in i + 1 ..< len(enc) { if !math.is_nan(enc[j][hi]) { h, found = enc[j][hi], true; break } }
		if !found { for j := i - 1; j >= 0; j -= 1 { if !math.is_nan(enc[j][hi]) { h, found = enc[j][hi], true; break } } }
		enc[i][hi] = h
	}
	for i in 1 ..< len(enc) {
		a := enc[i - 1][hi]
		b := enc[i][hi]
		b = a + math.mod(math.mod(b - a, 360) + 360, 360)   // b - a in [0, 360)
		d := b - a
		switch method {
		case .Shorter: if d > 180 { b -= 360 }
		case .Longer: if d > 0 && d < 180 { b -= 360 }
		case .Increasing:
		case .Decreasing: if d > 0 { b -= 360 }
		}
		enc[i][hi] = b
	}
}

@(private)
average_stops :: proc(stops: []Gradient_Stop, space: Gradient_Space) -> [4]f32 {
	sum: [4]f32
	for st in stops { c := to_space(st.color, .Linear); sum += c }
	sum /= f32(len(stops))
	// back to the requested space (the shader decodes from it)
	if sum[3] <= 0 { return {} }
	return to_space(Color{sum[0] / sum[3], sum[1] / sum[3], sum[2] / sum[3], sum[3]}, space)
}

@(private)
linear_to_oklab :: proc(c: [3]f32) -> [3]f32 {
	l := 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
	m := 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
	s := 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
	l, m, s = math.cbrt(l), math.cbrt(m), math.cbrt(s)
	return {
		0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
	}
}

// Linear sRGB (D65) to CIE Lab (D50, Bradford), as CSS Color 4.
@(private)
linear_to_lab :: proc(c: [3]f32) -> [3]f32 {
	x := 0.41239079926595934 * c.x + 0.357584339383878 * c.y + 0.1804807884018343 * c.z
	y := 0.21263900587151027 * c.x + 0.715168678767756 * c.y + 0.07219231536073371 * c.z
	z := 0.01933081871559182 * c.x + 0.11919477979462598 * c.y + 0.9505321522496607 * c.z
	// to D50
	x50 := 1.0479298208405488 * x + 0.022946793341019088 * y - 0.05019222954313557 * z
	y50 := 0.029627815688159344 * x + 0.990434484573249 * y - 0.01707382502938514 * z
	z50 := -0.009243058152591178 * x + 0.015055144896577895 * y + 0.7518742899580008 * z
	E :: 216.0 / 24389
	K :: 24389.0 / 27
	f :: proc(v: f32) -> f32 { return v > E ? math.cbrt(v) : (K * v + 16) / 116 }
	fx, fy, fz := f(x50 / (0.3457 / 0.3585)), f(y50), f(z50 / ((1 - 0.3457 - 0.3585) / 0.3585))
	return {116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)}
}

// (L, a, b) to (L, C, h degrees); h is NaN (powerless) under `achromatic` chroma.
@(private)
to_polar :: proc(v: [3]f32, achromatic: f32) -> [3]f32 {
	ch := math.sqrt(v.y * v.y + v.z * v.z)
	h := math.atan2(v.z, v.y) * 180 / math.PI
	if h < 0 { h += 360 }
	if ch < achromatic { h = math.nan_f32() }
	return {v.x, ch, h}
}

@(private)
srgb_to_hsl :: proc(c: [3]f32) -> [3]f32 {
	mx, mn := max(c.x, c.y, c.z), min(c.x, c.y, c.z)
	l := (mx + mn) * 0.5
	d := mx - mn
	if d < 1e-6 { return {math.nan_f32(), 0, l} }
	s := (l == 0 || l == 1) ? 0 : (mx - l) / min(l, 1 - l)
	h: f32
	switch mx {
	case c.x: h = (c.y - c.z) / d + (c.y < c.z ? 6 : 0)
	case c.y: h = (c.z - c.x) / d + 2
	case: h = (c.x - c.y) / d + 4
	}
	return {h * 60, s, l}
}

////////////////////////////////
// Box shadows

// An outer box shadow (CSS Backgrounds 3 §7.1): `shape` (the border box moved by the offset and grown by the spread,
// with its radii) blurred by a gaussian of standard deviation `sigma` (CSS: half the blur radius), in `color`. With
// `hole` non-empty nothing is drawn inside it (CSS clips the shadow out of the border box `hole`, radii `hole_radii`).
// Exact (analytic) at any size and blur, under any transform, in pictures and clips.
box_shadow :: proc(c: ^Context, shape: Rect, radii: [4]f32, sigma: f32, color: Color, hole: Rect = {}, hole_radii: [4]f32 = {}) {
	if color.a <= 0 || rect_empty(shape) { return }
	reach := 3 * max(sigma, 0) + 1
	flags: f32 = rect_empty(hole) ? 0 : render.SHADOW_HOLE
	shadow_inst(c, rect_pad(shape, reach), shape, radii, sigma, color, hole, hole_radii, flags)
}

// An inset box shadow: inside `inside` (the padding box, radii `inside_radii`), the outside of `hole` (the padding box
// moved by the offset and shrunk by the spread, with its radii) blurred by `sigma`, in `color`.
inset_shadow :: proc(c: ^Context, inside: Rect, inside_radii: [4]f32, hole: Rect, hole_radii: [4]f32, sigma: f32, color: Color) {
	if color.a <= 0 || rect_empty(inside) { return }
	shadow_inst(c, inside, hole, hole_radii, sigma, color, inside, inside_radii, render.SHADOW_INSET)
}

@(private)
shadow_inst :: proc(c: ^Context, quad, shape: Rect, radii: [4]f32, sigma: f32, color: Color, other: Rect, other_radii: [4]f32, flags: f32) {
	xf, alpha, clip := cur(c)
	col := color
	col.a *= alpha
	sh, ot := shape, other
	rr, orr := radii, other_radii
	q := quad
	sg := max(sigma, 0)
	inst := render.Rect_Inst{soft = 1, use_tex = render.KIND_SHADOW, tex_size = 1, clip = clip, flags = c.circular ? render.FLAG_CIRCLE : 0}
	if xf.simple {
		s, o := xf.m.a, Vec2{xf.m.e, xf.m.f}
		bake :: proc(r: Rect, s: f32, o: Vec2) -> Rect { return {r.min * s + o, r.max * s + o} }
		q, sh, ot = bake(q, s, o), bake(sh, s, o), bake(ot, s, o)
		rr, orr, sg = rr * s, orr * s, sg * s
	} else {
		inst.xform = gpu_xform(c, xf)
	}
	// a hole or an inside rect of no area: none
	if rect_empty(ot) { ot = {} }
	inst.dst = {q.min.x, q.min.y, q.max.x, q.max.y}
	inst.src = {sh.min.x, sh.min.y, sh.max.x, sh.max.y}
	inst.radii = rr
	inst.colors = {col, {ot.min.x, ot.min.y, ot.max.x, ot.max.y}, orr, {sg, flags, 0, 0}}
	append(&c.insts, inst)
}
