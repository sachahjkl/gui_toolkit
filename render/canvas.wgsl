// 2D canvas drawing on the GPU (render/canvas.odin): the shapes, images, gradients and compositing of an HTML canvas context,
// drawn straight into a persistent RGBA8 texture that holds premultiplied sRGB-encoded values (browsers blend a canvas in
// sRGB values; the texture is then an ordinary image for draw.image, FLAG_TEX_SRGB). Written once here for both backends.
//
// One instanced-quad pipeline draws everything. An instance is a quad (device pixels) with
//   * a geometry that gives the coverage of each pixel: a rect / rounded rect / ellipse evaluated analytically in the shape's
//     local space (exact box filter for axis-aligned rects), or a polygon (G_SHAPE): line edges in bands by y, the winding
//     number of 16 samples per boundary pixel (N-rooks), the fill rule applied per sample, so a union of overlapping pieces
//     (a stroke's quads and joins) never counts twice; pixels no edge touches are filled or empty from one winding number;
//   * a paint (Paint, a table entry): a color, a linear / radial / conic gradient (stops evaluated here: no table of colors
//     to build), a repeating pattern or an image with a source rectangle and a filter;
//   * the global alpha, an optional clip mask (a R8 texture), and a Porter-Duff or blend operator. The Porter-Duff
//     operators are fixed-function blend states of the batch; the blend modes read a copy of the backdrop (back_tex) and
//     write the result themselves.
// The filter entry points (vs_full, ps_fx) run the passes of the `filter` property and the shadows on layers.

alias float2 = vec2<f32>;
alias float3 = vec3<f32>;
alias float4 = vec4<f32>;
alias uint4 = vec4<u32>;

const G_RECT: u32 = 1u;
const G_RRECT: u32 = 2u;
const G_ELLIPSE: u32 = 3u;
const G_SHAPE: u32 = 4u;

const F_EVENODD: u32 = 16u;
const F_UNBOUNDED: u32 = 32u;
const F_CLIP: u32 = 64u;
const F_MASK_OUT: u32 = 128u;
const OP_SHIFT: u32 = 8u;
const OP_MASK: u32 = 31u;

const OP_MULTIPLY: u32 = 11u;
const OP_SCREEN: u32 = 12u;
const OP_OVERLAY: u32 = 13u;
const OP_DARKEN: u32 = 14u;
const OP_LIGHTEN: u32 = 15u;
const OP_COLOR_DODGE: u32 = 16u;
const OP_COLOR_BURN: u32 = 17u;
const OP_HARD_LIGHT: u32 = 18u;
const OP_SOFT_LIGHT: u32 = 19u;
const OP_DIFFERENCE: u32 = 20u;
const OP_EXCLUSION: u32 = 21u;
const OP_HUE: u32 = 22u;
const OP_SATURATION: u32 = 23u;
const OP_COLOR: u32 = 24u;
const OP_LUMINOSITY: u32 = 25u;

const PAINT_SOLID: u32 = 0u;
const PAINT_LINEAR: u32 = 1u;
const PAINT_RADIAL: u32 = 2u;
const PAINT_CONIC: u32 = 3u;
const PAINT_IMAGE: u32 = 4u;

// Paint.flags: wrap x (bits 0-1), wrap y (2-3): 0 transparent outside, 1 clamp, 2 repeat; filter (4-6): 0 nearest, 1 bilinear,
// 2 bilinear with mip levels, 3 anisotropic; bit 8: the texture holds linear light (a video target in a linear renderer);
// bit 9: the alpha of the texel tints the paint's color (the shadow of a blurred layer)
const PF_LINEAR_SRC: u32 = 256u;
const PF_TINT: u32 = 512u;

const FX_MATRIX: u32 = 0u;
const FX_BLUR: u32 = 1u;
const FX_DOWN: u32 = 2u;

struct CGlobals {
	viewport: float2,   // size of the target in pixels
	origin: float2,     // canvas position of the target's pixel (0, 0): non-zero when drawing into a layer
	back_dim: float2,   // size of the backdrop copy
	_p: float2,
};

struct Paint {
	color: float4,      // PAINT_SOLID: premultiplied
	m: float4,          // device pixel -> paint space: a b c d
	t: float4,          // e f; linear gradient: t = dot(device, (m.x, m.y)) + t.z, then the stops
	p: float4,          // radial: x0 y0 r0 x1; conic: cx cy start angle; image: source rect x0 y0 x1 y1 (texels)
	q: float4,          // radial: y1 r1; image: texture width, height
	kind: u32,
	nstops: u32,
	stops: u32,         // first stop in `stops` (two float4 each: straight color, then offset)
	flags: u32,
};

struct Fx {
	mode: u32,
	ntaps: u32,
	_p0: u32,
	_p1: u32,
	dir: float2,        // blur: step of one texel along the pass in uv
	src_dim: float2,
	m0: float4,         // MATRIX: rows of the 4x5 color matrix, the fifth column in w... (see canvas.odin)
	m1: float4,
	m2: float4,
	m3: float4,
	m4: float4,
	taps: array<float4, 32>,   // (offset, weight) x 2 per entry
};

@group(0) @binding(0) var<uniform> cg: CGlobals;
@group(0) @binding(1) var<storage, read> heap: array<uint4>;
@group(0) @binding(2) var<storage, read> paints: array<Paint>;
@group(0) @binding(3) var<storage, read> stops: array<float4>;
@group(0) @binding(4) var<uniform> fx: Fx;
@group(0) @binding(5) var s_point: sampler;
@group(0) @binding(6) var s_lin: sampler;
@group(0) @binding(7) var s_aniso: sampler;
@group(0) @binding(8) var s_lin_wrap: sampler;
@group(0) @binding(9) var s_point_wrap: sampler;

@group(1) @binding(0) var src_tex: texture_2d<f32>;
@group(1) @binding(1) var clip_tex: texture_2d<f32>;
@group(1) @binding(2) var back_tex: texture_2d<f32>;

struct VSIn {
	@location(0) box: float4,
	@location(1) geom: float4,
	@location(2) geom2: float4,
	@location(3) inv: float4,
	@location(4) misc: float4,
	@location(5) ids: uint4,
	@builtin(vertex_index) vid: u32,
};

struct PSIn {
	@builtin(position) pos: float4,
	@location(0) @interpolate(flat) geom: float4,
	@location(1) @interpolate(flat) geom2: float4,
	@location(2) @interpolate(flat) inv: float4,
	@location(3) @interpolate(flat) misc: float4,
	@location(4) @interpolate(flat) ids: uint4,
};

@vertex
fn vs_canvas(i: VSIn) -> PSIn {
	let corner = float2(f32(i.vid >> 1u), f32(i.vid & 1u));
	let p = mix(i.box.xy, i.box.zw, corner) - cg.origin;
	var o: PSIn;
	o.pos = float4(p.x / cg.viewport.x * 2.0 - 1.0, 1.0 - p.y / cg.viewport.y * 2.0, 0.0, 1.0);
	o.geom = i.geom;
	o.geom2 = i.geom2;
	o.inv = i.inv;
	o.misc = i.misc;
	o.ids = i.ids;
	return o;
}

////////////////////////////////
// Coverage

fn to_local(i: PSIn, pc: float2) -> float2 {
	return float2(i.inv.x * pc.x + i.inv.z * pc.y + i.misc.x, i.inv.y * pc.x + i.inv.w * pc.y + i.misc.y);
}

// The part of [a0, a1] inside [b0, b1], as a fraction of the length a1 - a0.
fn overlap1(a0: f32, a1: f32, b0: f32, b1: f32) -> f32 {
	return clamp((min(a1, b1) - max(a0, b0)) / max(a1 - a0, 1e-12), 0.0, 1.0);
}

fn rect_coverage(i: PSIn, pc: float2) -> f32 {
	let q = to_local(i, pc);
	let c = i.geom.xy;
	let h = i.geom.zw;
	if (abs(i.inv.y) < 1e-7 && abs(i.inv.z) < 1e-7) {
		// axis aligned: the exact box filter
		let fx = 0.5 * abs(i.inv.x);
		let fy = 0.5 * abs(i.inv.w);
		return overlap1(q.x - fx, q.x + fx, c.x - h.x, c.x + h.x) * overlap1(q.y - fy, q.y + fy, c.y - h.y, c.y + h.y);
	}
	let d = abs(q - c) - h;
	let sd = length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0);
	return clamp(0.5 - sd * i.misc.w, 0.0, 1.0);
}

fn rrect_coverage(i: PSIn, pc: float2) -> f32 {
	let q = to_local(i, pc);
	let c = i.geom.xy;
	let h = i.geom.zw;
	let rel = q - c;
	// radii: top-left, top-right, bottom-right, bottom-left
	var r: f32;
	if (rel.x >= 0.0) { r = select(i.geom2.z, i.geom2.y, rel.y < 0.0); }
	else { r = select(i.geom2.w, i.geom2.x, rel.y < 0.0); }
	let d = abs(rel) - h + float2(r);
	let sd = min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0))) - r;
	return clamp(0.5 - sd * i.misc.w, 0.0, 1.0);
}

fn ellipse_coverage(i: PSIn, pc: float2) -> f32 {
	let q = to_local(i, pc);
	let h = max(i.geom.zw, float2(1e-6));
	let p = (q - i.geom.xy) / h;
	let k0 = length(p);
	let k1 = length(p / h);
	var sd = 0.0;
	if (k1 > 1e-9) { sd = k0 * (k0 - 1.0) / k1; } else { sd = -min(h.x, h.y); }
	return clamp(0.5 - sd * i.misc.w, 0.0, 1.0);
}

fn edge_at(base: u32, e: u32) -> float4 {
	return bitcast<float4>(heap[base + e]);
}

// Polygon coverage. Heap layout from `base` (vec4<u32> units): one header per band (edge count, first list entry, first
// edge, 0), the edges (x0 y0 x1 y1, bit-cast; never horizontal) and the lists (four edge numbers per vec4), each list
// sorted by the larger x of its edges, descending.
fn shape_coverage(i: PSIn, pc: float2) -> f32 {
	let q = to_local(i, pc);
	// half extents, in local units, of the box the pixel covers (its bounding box when the shape is rotated)
	let hx = 0.5 * (abs(i.inv.x) + abs(i.inv.z));
	let hy = 0.5 * (abs(i.inv.y) + abs(i.inv.w));
	let bb = i.geom;
	if (q.y + hy < bb.y || q.y - hy > bb.w || q.x + hx < bb.x || q.x - hx > bb.z) { return 0.0; }
	let base = i.ids.z;
	let nb = i.ids.w & 0xffffu;
	let bh = max((bb.w - bb.y) / f32(nb), 1e-12);
	let band = u32(clamp(i32(floor((q.y - bb.y) / bh)), 0, i32(nb) - 1));
	let head = heap[base + band];
	let n = head.x;
	let list = base + head.y;
	let ebase = base + head.z;
	let evenodd = (i.ids.x & F_EVENODD) != 0u;

	var wc = 0;
	var boundary = false;
	let left = q.x - hx;
	for (var k = 0u; k < n; k++) {
		let e = edge_at(ebase, heap[list + (k >> 2u)][k & 3u]);
		let xmax = max(e.x, e.z);
		if (xmax < left) { break; }
		let ymin = min(e.y, e.w);
		let ymax = max(e.y, e.w);
		if (ymax < q.y - hy || ymin > q.y + hy) { continue; }
		let dy = e.w - e.y;
		if (q.y >= ymin && q.y < ymax) {
			let x = e.x + (q.y - e.y) * (e.z - e.x) / dy;
			if (x > q.x) { wc += select(-1, 1, dy > 0.0); }
		}
		if (!boundary && min(e.x, e.z) <= q.x + hx) {
			let nrm = normalize(float2(dy, e.x - e.z));
			let dist = dot(q - e.xy, nrm);
			if (abs(dist) <= hx * abs(nrm.x) + hy * abs(nrm.y)) { boundary = true; }
		}
	}
	if (!boundary) {
		if (evenodd) { return select(0.0, 1.0, (wc & 1) != 0); }
		return select(0.0, 1.0, wc != 0);
	}

	// 16 N-rook samples
	var w: array<i32, 16>;
	for (var s = 0u; s < 16u; s++) { w[s] = 0; }
	for (var k = 0u; k < n; k++) {
		let e = edge_at(ebase, heap[list + (k >> 2u)][k & 3u]);
		let xmax = max(e.x, e.z);
		if (xmax < left) { break; }
		let ymin = min(e.y, e.w);
		let ymax = max(e.y, e.w);
		if (ymax < q.y - hy || ymin > q.y + hy) { continue; }
		let dy = e.w - e.y;
		let slope = (e.z - e.x) / dy;
		let dirv = select(-1, 1, dy > 0.0);
		for (var s = 0u; s < 16u; s++) {
			let ox = (f32(s) + 0.5) / 16.0 - 0.5;
			let oy = (f32((s * 5u) & 15u) + 0.5) / 16.0 - 0.5;
			let sp = float2(q.x + i.inv.x * ox + i.inv.z * oy, q.y + i.inv.y * ox + i.inv.w * oy);
			if (sp.y >= ymin && sp.y < ymax) {
				let x = e.x + (sp.y - e.y) * slope;
				if (x > sp.x) { w[s] += dirv; }
			}
		}
	}
	var inside = 0.0;
	for (var s = 0u; s < 16u; s++) {
		if (evenodd) { inside += select(0.0, 1.0, (w[s] & 1) != 0); } else { inside += select(0.0, 1.0, w[s] != 0); }
	}
	return inside / 16.0;
}

fn geometry_coverage(i: PSIn, pc: float2) -> f32 {
	let kind = i.ids.x & 15u;
	switch kind {
		case 1u: { return rect_coverage(i, pc); }
		case 2u: { return rrect_coverage(i, pc); }
		case 3u: { return ellipse_coverage(i, pc); }
		case 4u: { return shape_coverage(i, pc); }
		default: { return 1.0; }
	}
}

////////////////////////////////
// Paint

fn encode_srgb(c0: float3) -> float3 {
	let c = saturate(c0);
	return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= float3(0.0031308));
}

fn stop_color(a: u32, b: u32, t: f32) -> float4 {
	// straight colors a and b at the positions in the entry after them
	let ca = stops[a];
	let cb = stops[b];
	let oa = stops[a + 1u].x;
	let ob = stops[b + 1u].x;
	let d = ob - oa;
	if (d <= 0.0) { return cb; }
	return ca + (cb - ca) * ((t - oa) / d);
}

fn gradient_color(p: Paint, t0: f32) -> float4 {
	let n = p.nstops;
	if (n == 0u) { return float4(0.0); }
	var t = t0;
	if (t != t) { t = 0.0; }
	t = clamp(t, 0.0, 1.0);
	let first = p.stops;
	if (t <= stops[first + 1u].x) { return stops[first]; }
	let last = first + (n - 1u) * 2u;
	if (t >= stops[last + 1u].x) { return stops[last]; }
	// the first stop whose offset is above t: binary search
	var lo = 1u;
	var hi = n - 1u;
	while (lo < hi) {
		let mid = (lo + hi) >> 1u;
		if (t < stops[first + mid * 2u + 1u].x) { hi = mid; } else { lo = mid + 1u; }
	}
	var c = stop_color(first + (lo - 1u) * 2u, first + lo * 2u, t);
	c.a = clamp(c.a, 0.0, 1.0);
	return c;
}

fn premultiply(c: float4) -> float4 {
	return float4(c.rgb * c.a, c.a);
}

// The position along a radial gradient (the largest s with a non-negative radius whose circle passes through the point)
// and whether there is one; the two circles of createRadialGradient.
fn radial_t(p: Paint, q: float2) -> float2 {
	let c0 = p.p.xy;
	let r0 = p.p.z;
	let c1 = float2(p.p.w, p.q.x);
	let r1 = p.q.y;
	let cd = c1 - c0;
	let dr = r1 - r0;
	let pd = q - c0;
	let a = dot(cd, cd) - dr * dr;
	let b = dot(pd, cd) + r0 * dr;
	let c = dot(pd, pd) - r0 * r0;
	if (abs(a) < 1e-9) {
		if (abs(b) < 1e-9) { return float2(0.0, 0.0); }
		let s = c / (2.0 * b);
		return float2(s, select(0.0, 1.0, r0 + s * dr >= 0.0));
	}
	let disc = b * b - a * c;
	if (disc < 0.0) { return float2(0.0, 0.0); }
	let sq = sqrt(disc);
	var s1 = (b + sq) / a;
	var s2 = (b - sq) / a;
	if (s1 < s2) { let t = s1; s1 = s2; s2 = t; }
	if (r0 + s1 * dr >= 0.0) { return float2(s1, 1.0); }
	if (r0 + s2 * dr >= 0.0) { return float2(s2, 1.0); }
	return float2(0.0, 0.0);
}

fn decode_wrap(f: u32, shift: u32) -> u32 {
	return (f >> shift) & 3u;
}

// Texel position of a device pixel center in the paint's image.
fn image_texel(p: Paint, pc: float2) -> float2 {
	return float2(p.m.x * pc.x + p.m.z * pc.y + p.t.x, p.m.y * pc.x + p.m.w * pc.y + p.t.y);
}

fn from_linear(c: float4) -> float4 {
	if (c.a <= 0.0) { return float4(0.0); }
	return float4(encode_srgb(c.rgb / c.a) * c.a, c.a);
}

// The image paint at a device pixel; `ddx` and `ddy` are the derivatives of the texel position, taken in uniform control flow.
fn image_color(p: Paint, tc: float2, ddx: float2, ddy: float2) -> float4 {
	let src0 = p.p.xy;
	let src1 = p.p.zw;
	let dim = max(p.q.xy, float2(1.0));
	let wx = decode_wrap(p.flags, 0u);
	let wy = decode_wrap(p.flags, 2u);
	let filt = (p.flags >> 4u) & 7u;
	var u = tc;
	let size = max(src1 - src0, float2(1.0));
	// outside the source rectangle: transparent, clamped to its edge, or wrapped
	if (wx == 0u && (u.x < src0.x || u.x >= src1.x)) { return float4(0.0); }
	if (wy == 0u && (u.y < src0.y || u.y >= src1.y)) { return float4(0.0); }
	if (wx == 2u) { u.x = src0.x + (u.x - src0.x) - floor((u.x - src0.x) / size.x) * size.x; }
	if (wy == 2u) { u.y = src0.y + (u.y - src0.y) - floor((u.y - src0.y) / size.y) * size.y; }
	if (wx != 2u) { u.x = clamp(u.x, src0.x + select(0.5, 0.0, filt == 0u), src1.x - select(0.5, 1e-3, filt == 0u)); }
	if (wy != 2u) { u.y = clamp(u.y, src0.y + select(0.5, 0.0, filt == 0u), src1.y - select(0.5, 1e-3, filt == 0u)); }
	let uv = u / dim;
	let gx = ddx / dim;
	let gy = ddy / dim;
	let rep = wx == 2u || wy == 2u;
	var c: float4;
	if (filt == 0u) {
		if (rep) { c = textureSampleGrad(src_tex, s_point_wrap, uv, gx, gy); } else { c = textureSampleGrad(src_tex, s_point, uv, gx, gy); }
	} else if (filt == 1u) {
		if (rep) { c = textureSampleLevel(src_tex, s_lin_wrap, uv, 0.0); } else { c = textureSampleLevel(src_tex, s_lin, uv, 0.0); }
	} else if (filt == 2u) {
		if (rep) { c = textureSampleGrad(src_tex, s_lin_wrap, uv, gx, gy); } else { c = textureSampleGrad(src_tex, s_lin, uv, gx, gy); }
	} else {
		if (rep) { c = textureSampleGrad(src_tex, s_lin_wrap, uv, gx, gy); } else { c = textureSampleGrad(src_tex, s_aniso, uv, gx, gy); }
	}
	if ((p.flags & PF_LINEAR_SRC) != 0u) { c = from_linear(c); }
	if ((p.flags & PF_TINT) != 0u) { c = p.color * c.a; }
	return c;
}

fn paint_color(p: Paint, pc: float2, tc: float2, ddx: float2, ddy: float2) -> float4 {
	switch p.kind {
		case 0u: { return p.color; }
		case 1u: {
			let t = p.m.x * pc.x + p.m.y * pc.y + p.t.z;
			return premultiply(gradient_color(p, t));
		}
		case 2u: {
			let q = image_texel(p, pc);
			let r = radial_t(p, q);
			if (r.y < 0.5) { return float4(0.0); }
			return premultiply(gradient_color(p, r.x));
		}
		case 3u: {
			let q = image_texel(p, pc);
			let a = atan2(q.y - p.p.y, q.x - p.p.x) - p.p.z;
			let t0 = a / 6.283185307179586;
			let t = t0 - floor(t0);
			return premultiply(gradient_color(p, t));
		}
		default: { return image_color(p, tc, ddx, ddy); }
	}
}

////////////////////////////////
// Operators

fn lum(c: float3) -> f32 { return 0.3 * c.x + 0.59 * c.y + 0.11 * c.z; }
fn sat_of(c: float3) -> f32 { return max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z)); }

fn clip_color(c: float3) -> float3 {
	let l = lum(c);
	let n = min(c.x, min(c.y, c.z));
	let x = max(c.x, max(c.y, c.z));
	var r = c;
	if (n < 0.0) { r = float3(l) + (r - float3(l)) * l / (l - n); }
	if (x > 1.0) { r = float3(l) + (r - float3(l)) * (1.0 - l) / (x - l); }
	return r;
}

fn set_lum(c: float3, l: f32) -> float3 {
	let d = l - lum(c);
	return clip_color(c + float3(d));
}

fn set_sat(c: float3, s: f32) -> float3 {
	let mx = max(c.x, max(c.y, c.z));
	let mn = min(c.x, min(c.y, c.z));
	if (mx <= mn) { return float3(0.0); }
	return (c - float3(mn)) * s / (mx - mn);
}

fn hard_light(cb: f32, cs: f32) -> f32 {
	if (cs <= 0.5) { return cb * 2.0 * cs; }
	let t = 2.0 * cs - 1.0;
	return cb + t - cb * t;
}

fn blend_channel(op: u32, cb: f32, cs: f32) -> f32 {
	switch op {
		case 11u: { return cb * cs; }
		case 12u: { return cb + cs - cb * cs; }
		case 13u: { return hard_light(cs, cb); }
		case 14u: { return min(cb, cs); }
		case 15u: { return max(cb, cs); }
		case 16u: {
			if (cb == 0.0) { return 0.0; }
			if (cs >= 1.0) { return 1.0; }
			return min(1.0, cb / (1.0 - cs));
		}
		case 17u: {
			if (cb >= 1.0) { return 1.0; }
			if (cs <= 0.0) { return 0.0; }
			return 1.0 - min(1.0, (1.0 - cb) / cs);
		}
		case 18u: { return hard_light(cb, cs); }
		case 19u: {
			if (cs <= 0.5) { return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb); }
			var dd = sqrt(cb);
			if (cb <= 0.25) { dd = ((16.0 * cb - 12.0) * cb + 4.0) * cb; }
			return cb + (2.0 * cs - 1.0) * (dd - cb);
		}
		case 20u: { return abs(cb - cs); }
		case 21u: { return cb + cs - 2.0 * cb * cs; }
		default: { return cs; }
	}
}

// Both colors premultiplied; W3C Compositing and Blending Level 1 for the blend modes.
fn blend_mode(op: u32, s: float4, d: float4) -> float4 {
	let sa = s.a;
	let da = d.a;
	var cs = float3(0.0);
	var cb = float3(0.0);
	if (sa > 0.0) { cs = s.rgb / sa; }
	if (da > 0.0) { cb = d.rgb / da; }
	var b = float3(0.0);
	switch op {
		case 22u: { b = set_lum(set_sat(cs, sat_of(cb)), lum(cb)); }
		case 23u: { b = set_lum(set_sat(cb, sat_of(cs)), lum(cb)); }
		case 24u: { b = set_lum(cs, lum(cb)); }
		case 25u: { b = set_lum(cb, lum(cs)); }
		default: { b = float3(blend_channel(op, cb.x, cs.x), blend_channel(op, cb.y, cs.y), blend_channel(op, cb.z, cs.z)); }
	}
	let k = sa * da;
	return float4(s.rgb * (1.0 - da) + d.rgb * (1.0 - sa) + float3(k) * b, sa + da - k);
}

@fragment
fn ps_canvas(i: PSIn) -> @location(0) float4 {
	let pc = i.pos.xy + cg.origin;
	let flags = i.ids.x;
	let p = paints[i.ids.y];
	// the texel position of an image paint and its derivatives, before any branch
	let tc = image_texel(p, pc);
	let ddx = dpdx(tc);
	let ddy = dpdy(tc);

	var cov = geometry_coverage(i, pc);
	let alpha = i.misc.z;
	var clipm = 1.0;
	if ((flags & F_CLIP) != 0u) {
		clipm = textureLoad(clip_tex, vec2<i32>(pc), 0).x;
		if (clipm <= 0.0) { discard; }
	}
	if ((flags & F_MASK_OUT) != 0u) {
		let m = cov * clipm;
		return float4(m, m, m, m);
	}
	let op = (flags >> OP_SHIFT) & OP_MASK;
	if (cov <= 0.0 && (flags & F_UNBOUNDED) == 0u) { discard; }
	var s = float4(0.0);
	if (cov > 0.0) { s = paint_color(p, pc, tc, ddx, ddy) * (cov * alpha * clipm); }
	if (op >= OP_MULTIPLY) {
		let d = textureLoad(back_tex, vec2<i32>(pc), 0);
		return blend_mode(op, s, d);
	}
	return s;
}

////////////////////////////////
// Filter passes

@vertex
fn vs_full(@builtin(vertex_index) vid: u32) -> @builtin(position) float4 {
	let p = float2(f32((vid << 1u) & 2u), f32(vid & 2u));
	return float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

@fragment
fn ps_fx(@builtin(position) pos: float4) -> @location(0) float4 {
	let uv = pos.xy / cg.viewport;
	if (fx.mode == FX_BLUR) {
		var acc = float4(0.0);
		for (var k = 0u; k < fx.ntaps; k++) {
			let t = fx.taps[k >> 1u];
			var off = t.x;
			var wgt = t.y;
			if ((k & 1u) == 1u) { off = t.z; wgt = t.w; }
			if (k == 0u) {
				acc += textureSampleLevel(src_tex, s_lin, uv, 0.0) * wgt;
			} else {
				acc += (textureSampleLevel(src_tex, s_lin, uv + fx.dir * off, 0.0) + textureSampleLevel(src_tex, s_lin, uv - fx.dir * off, 0.0)) * wgt;
			}
		}
		return acc;
	}
	let c = textureSampleLevel(src_tex, s_lin, uv, 0.0);
	if (fx.mode == FX_DOWN) { return c; }
	// FX_MATRIX: straight color, 4x5 matrix with the constants in the fifth column (packed in m4), clamped
	var rgb = float3(0.0);
	if (c.a > 0.0) { rgb = c.rgb / c.a; }
	let v = float4(rgb, c.a);
	let r = float4(dot(fx.m0, v) + fx.m4.x, dot(fx.m1, v) + fx.m4.y, dot(fx.m2, v) + fx.m4.z, dot(fx.m3, v) + fx.m4.w);
	let o = clamp(r, float4(0.0), float4(1.0));
	return float4(o.rgb * o.a, o.a);
}
