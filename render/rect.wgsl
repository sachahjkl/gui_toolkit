// WGSL port of rect.hlsl (the Direct3D 11 shader), line by line where it can be: see that file for the design notes
// (blend spaces, transforms, layers, retained pictures, gradients, shadows). Differences forced by WebGPU:
//   * no border sampler address mode: the one-texel transparent border of a reduced image is applied by hand (sample_border);
//   * one bind group for the frame's tables (group 0) and one for the textures of the batch (group 1);
//   * the constant buffers carry dynamic offsets (one slot per target / replay in a per-frame arena).

alias float2 = vec2<f32>;
alias float3 = vec3<f32>;
alias float4 = vec4<f32>;
alias uint2 = vec2<u32>;
alias uint4 = vec4<u32>;

const KIND_SHAPE: u32 = 0u;
const KIND_GLYPH: u32 = 1u;
const KIND_IMAGE: u32 = 2u;
const KIND_GRADIENT: u32 = 3u;
const KIND_SHADOW: u32 = 4u;
const SHADOW_INSET: u32 = 1u;
const SHADOW_HOLE: u32 = 2u;
const GRAD_RADIAL: u32 = 1u;
const GRAD_CONIC: u32 = 2u;
const GRAD_REPEATING: u32 = 0x100u;
const GRAD_DITHER: u32 = 0x200u;
const GRAD_REPEAT_X: u32 = 0x400u;
const GRAD_REPEAT_Y: u32 = 0x800u;
const GRAD_HEADER: u32 = 4u;
const MAX_GRADIENT_STOPS: u32 = 256u;
const GSPACE_SRGB: u32 = 0u;
const GSPACE_LINEAR: u32 = 1u;
const GSPACE_OKLAB: u32 = 2u;
const GSPACE_OKLCH: u32 = 3u;
const GSPACE_LAB: u32 = 4u;
const GSPACE_LCH: u32 = 5u;
const GSPACE_HSL: u32 = 6u;
const GSPACE_HWB: u32 = 7u;
const FLAG_TILE: u32 = 1u;
const FLAG_LAYER: u32 = 2u;
const FLAG_CIRCLE: u32 = 4u;
const FLAG_SCREEN: u32 = 8u;
const FLAG_BLEND: u32 = 16u;
const FLAG_TEX_SRGB: u32 = 32u;
const FLAG_LERP_SRGB: u32 = 64u;
const FLAG_LERP_LINEAR: u32 = 128u;
const FLAG_SCALED: u32 = 0x10000u;
const FLAG_MATRIX: u32 = 0x20000u;
const FLAG_PROJECT: u32 = 0x40000u;
const BLEND_SHIFT: u32 = 8u;
const SPACE_LINEAR: u32 = 0u;
const SPACE_SRGB: u32 = 1u;
const CLIP_ELLIPSE: u32 = 1u;
const CLIP_POLYGON: u32 = 2u;
const CLIP_CIRCLE: u32 = 1u;
const CLIP_EVENODD: u32 = 2u;
const CLIP_SCISSOR: u32 = 4u;
const MAX_CLIP_DEPTH: i32 = 8;
const MAX_POLYGON_POINTS: u32 = 4096u;

const BLEND_MULTIPLY: u32 = 1u;
const BLEND_SCREEN: u32 = 2u;
const BLEND_OVERLAY: u32 = 3u;
const BLEND_DARKEN: u32 = 4u;
const BLEND_LIGHTEN: u32 = 5u;
const BLEND_COLOR_DODGE: u32 = 6u;
const BLEND_COLOR_BURN: u32 = 7u;
const BLEND_HARD_LIGHT: u32 = 8u;
const BLEND_SOFT_LIGHT: u32 = 9u;
const BLEND_DIFFERENCE: u32 = 10u;
const BLEND_EXCLUSION: u32 = 11u;
const BLEND_HUE: u32 = 12u;
const BLEND_SATURATION: u32 = 13u;
const BLEND_COLOR: u32 = 14u;
const BLEND_LUMINOSITY: u32 = 15u;
const BLEND_PLUS_DARKER: u32 = 16u;
const BLEND_PLUS_LIGHTER: u32 = 17u;

struct Globals {
	viewport_size: float2,
	corner_n: f32,
	corner_boost: f32,
	target_origin: float2,
	target_space: u32,
	text_gamma: f32,
	text_contrast: f32,
	text_exponent: f32,
	_pad: float2,
};

struct Replay {
	m0: float4,
	m1: float4,
	i0: float4,
	i1: float4,
	base: uint4,
	misc: uint4,
};

struct Xform {
	abcd: float4,
	ef: float4,
};

struct ClipShape {
	inv: float4,
	t: float2,
	px: f32,
	parent: u32,
	center: float2,
	half_size: float2,
	radii: float4,
	kind: u32,
	first: u32,
	count: u32,
	flags: u32,
	xform: u32,
	_p0: u32,
	_p1: u32,
	_p2: u32,
};

struct Slot {
	abcd: float4,
	ef: float4,
	inv_abcd: float4,
	inv_ef: float4,
};

@group(0) @binding(0) var<uniform> g: Globals;
@group(0) @binding(1) var<uniform> rp: Replay;
@group(0) @binding(2) var<storage, read> xforms: array<Xform>;
@group(0) @binding(3) var<storage, read> clips: array<ClipShape>;
@group(0) @binding(4) var<storage, read> points: array<float2>;
@group(0) @binding(5) var<storage, read> grads: array<float4>;
@group(0) @binding(6) var<storage, read> slots: array<Slot>;
@group(0) @binding(7) var<storage, read> rclips: array<ClipShape>;
@group(0) @binding(8) var<storage, read> rpoints: array<float2>;
@group(0) @binding(9) var<storage, read> rgrads: array<float4>;
@group(0) @binding(10) var samp: sampler;
@group(0) @binding(11) var samp_img: sampler;
@group(0) @binding(12) var samp_wrap: sampler;

@group(1) @binding(0) var atlas: texture_2d<f32>;
@group(1) @binding(1) var image: texture_2d<f32>;
@group(1) @binding(2) var backdrop: texture_2d<f32>;

struct VSIn {
	@location(0) dst: float4,
	@location(1) src: float4,
	@location(2) c0: float4,
	@location(3) c1: float4,
	@location(4) c2: float4,
	@location(5) c3: float4,
	@location(6) radii: float4,
	@location(7) style: float4,
	@location(8) extra: uint4,
	@builtin(vertex_index) vid: u32,
};

struct PSIn {
	@builtin(position) pos: float4,
	@location(0) rect_pos: float2,
	@location(1) @interpolate(flat) half_size: float2,
	@location(2) uv: float2,
	@location(3) color: float4,
	@location(4) @interpolate(flat) radii: float4,
	@location(5) @interpolate(flat) style: float4,
	@location(6) @interpolate(flat) src: float4,
	@location(7) @interpolate(flat) extra: uint4,
	@location(8) lpos: float2,
	@location(9) @interpolate(flat) p0: float4,
	@location(10) @interpolate(flat) p1: float4,
	@location(11) @interpolate(flat) p2: float4,
};

struct Mat {
	abcd: float4,
	ef: float2,
};

fn mat_make(abcd: float4, ef: float2) -> Mat { return Mat(abcd, ef); }

// m after n
fn mat_mul(m: Mat, n: Mat) -> Mat {
	return Mat(
		float4(m.abcd.x * n.abcd.x + m.abcd.z * n.abcd.y, m.abcd.y * n.abcd.x + m.abcd.w * n.abcd.y,
		       m.abcd.x * n.abcd.z + m.abcd.z * n.abcd.w, m.abcd.y * n.abcd.z + m.abcd.w * n.abcd.w),
		float2(m.abcd.x * n.ef.x + m.abcd.z * n.ef.y + m.ef.x, m.abcd.y * n.ef.x + m.abcd.w * n.ef.y + m.ef.y));
}

fn mat_apply(m: Mat, p: float2) -> float2 {
	return float2(m.abcd.x * p.x + m.abcd.z * p.y + m.ef.x, m.abcd.y * p.x + m.abcd.w * p.y + m.ef.y);
}

fn mat_simple(m: Mat) -> bool { return m.abcd.y == 0.0 && m.abcd.z == 0.0 && m.abcd.x == m.abcd.w && m.abcd.x > 0.0; }

fn mat_scale(m: Mat) -> f32 { return sqrt(abs(m.abcd.x * m.abcd.w - m.abcd.y * m.abcd.z)); }

fn replay_mat() -> Mat { return mat_make(rp.m0, rp.m1.xy); }
fn replay_inv() -> Mat { return mat_make(rp.i0, rp.i1.xy); }
fn is_retained() -> bool { return rp.misc.x != 0u; }

fn srgb_encode(c0: float3) -> float3 {
	let c = saturate(c0);
	return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= float3(0.0031308));
}

fn srgb_decode(c0: float3) -> float3 {
	let c = saturate(c0);
	return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= float3(0.04045));
}

fn srgb_decode1(c: f32) -> f32 { return srgb_decode(float3(c, c, c)).x; }

fn convert_space(c: float3, from_space: u32, to_space: u32) -> float3 {
	if (from_space == to_space) { return c; }
	if (to_space == SPACE_SRGB) { return srgb_encode(c); }
	return srgb_decode(c);
}

fn convert_premul(c: float4, from_space: u32, to_space: u32) -> float4 {
	if (from_space == to_space) { return c; }
	if (c.a <= 0.0) { return float4(0.0); }
	return float4(convert_space(c.rgb / c.a, from_space, to_space) * c.a, c.a);
}

fn text_to_luma(x: f32) -> f32 { return select(pow(max(x, 0.0), g.text_gamma), srgb_decode1(x), g.text_gamma < 0.0); }
fn text_to_luma3(x: float3) -> float3 {
	if (g.text_gamma < 0.0) { return srgb_decode(x); }
	return pow(max(x, float3(0.0)), float3(g.text_gamma));
}
fn text_from_luma(l: f32) -> f32 {
	if (g.text_gamma < 0.0) { return srgb_encode(float3(l, l, l)).x; }
	return pow(max(l, 0.0), 1.0 / g.text_gamma);
}

fn lerp_space(flags: u32) -> u32 {
	if ((flags & FLAG_LERP_SRGB) != 0u) { return SPACE_SRGB; }
	if ((flags & FLAG_LERP_LINEAR) != 0u) { return SPACE_LINEAR; }
	return g.target_space;
}

// A projected quad (FLAG_PROJECT, KIND_IMAGE): a layer drawn through a homography. The instance's `xform` is the first of two
// entries of the transform table holding the 3x3 matrix H (rows r0 r1 r2, row-major: entry 0 = r0.xyz r1.xyz, entry 1 = r2.xyz) that
// maps layer texels (x, y, 1) to homogeneous screen pixels (X, Y, W). The vertex position is written homogeneous
// (X, Y, W scaled to clip space, with the same W), so the rasterizer clips against W > 0 and interpolates the varyings with
// perspective correction: the layer's texel position (uv) and the local position the edge is antialiased from (rect_pos) are exact.
// colors[0] is the tint (alpha included); colors[1].x is the most taps of the anisotropic filter.
fn vs_project(i: VSIn) -> PSIn {
	let corner = float2(f32(i.vid >> 1u), f32(i.vid & 1u));
	let e0 = xforms[i.extra.x];
	let e1 = xforms[i.extra.x + 1u];
	let r0 = e0.abcd.xyz;
	let r1 = float3(e0.abcd.w, e0.ef.x, e0.ef.y);
	let r2 = e1.abcd.xyz;
	let size = i.dst.zw - i.dst.xy;
	// local margin that is 1 px on screen at this corner, from the Jacobian of the projection there
	let p0 = float3(i.dst.xy + corner * size, 1.0);
	let w0 = max(dot(r2, p0), 1e-3);
	let s0 = float2(dot(r0, p0), dot(r1, p0)) / w0;
	let jx = float2(r0.x - s0.x * r2.x, r1.x - s0.y * r2.x) / w0;
	let jy = float2(r0.y - s0.x * r2.y, r1.y - s0.y * r2.y) / w0;
	let det = jx.x * jy.y - jx.y * jy.x;
	var grow = float2(0.0);
	if (abs(det) > 1e-12) { grow = min(float2(length(jy), length(jx)) / abs(det), float2(64.0)); }
	let t = corner + (corner * 2.0 - 1.0) * grow / max(abs(size), float2(1e-6));
	let lp = i.dst.xy + t * size;
	let p = float3(lp, 1.0);
	let hx = dot(r0, p);
	let hy = dot(r1, p);
	let hw = dot(r2, p);
	var o: PSIn;
	o.pos = float4(
		(hx - hw * g.target_origin.x) / g.viewport_size.x * 2.0 - hw,
		hw - (hy - hw * g.target_origin.y) / g.viewport_size.y * 2.0,
		0.5 * hw, hw);
	o.rect_pos = (t - 0.5) * size;
	o.half_size = size * 0.5;
	o.lpos = lp;
	o.uv = mix(i.src.xy, i.src.zw, t);
	o.src = i.src;
	var c = i.c0;
	c.a = c.a * rp.m1.z;
	if (lerp_space(i.extra.z) == SPACE_SRGB) { c = float4(srgb_encode(c.rgb), c.a); }
	o.color = float4(c.rgb * c.a, c.a);
	o.radii = float4(0.0);
	o.style = float4(0.0, 1.0, i.style.z, 1.0);
	o.extra = uint4(1u, i.extra.y, i.extra.z, i.extra.w);
	o.p0 = i.c1;
	o.p1 = i.c2;
	o.p2 = i.c3;
	return o;
}

@vertex
fn vs_main(i: VSIn) -> PSIn {
	if ((i.extra.z & FLAG_PROJECT) != 0u) { return vs_project(i); }
	let corner = float2(f32(i.vid >> 1u), f32(i.vid & 1u));   // 0: (0,0) 1: (0,1) 2: (1,0) 3: (1,1) as a triangle strip
	let kind = u32(i.style.z + 0.5);
	var dst = i.dst;
	var radii = i.radii;
	var style = i.style;
	var xf = false;
	var m = mat_make(float4(1.0, 0.0, 0.0, 1.0), float2(0.0, 0.0));
	if (is_retained()) {
		// picture space -> screen, through the instance's slot
		m = replay_mat();
		if (i.extra.x != 0u) {
			let s = slots[rp.base.x + i.extra.x];
			m = mat_mul(m, mat_make(s.abcd, s.ef.xy));
		}
		if (mat_simple(m)) {
			// baked as draw bakes uniform scale + translation on the CPU (rect_corners, text, image_inst)
			let k = m.abcd.x;
			dst = float4(dst.x * k + m.ef.x, dst.y * k + m.ef.y, dst.z * k + m.ef.x, dst.w * k + m.ef.y);
			if (kind != KIND_SHADOW) { radii = radii * k; }
			style.x = style.x * k;
			if (style.y > 1.0) { style.y = style.y * k; }
		} else {
			xf = true;
		}
	} else if (i.extra.x != 0u) {
		let x = xforms[i.extra.x];
		m = mat_make(x.abcd, x.ef.xy);
		xf = true;
	}
	let size = dst.zw - dst.xy;
	var t = corner;                               // position across the rect (0..1, beyond when grown)
	var pix: float2;
	if (xf) {
		let det = m.abcd.x * m.abcd.w - m.abcd.y * m.abcd.z;
		// local margin that is 1 px on screen, measured perpendicular to each pair of sides
		var grow = float2(0.0);
		if (abs(det) > 1e-12) { grow = float2(length(m.abcd.zw), length(m.abcd.xy)) / abs(det); }
		t = t + (corner * 2.0 - 1.0) * grow / max(abs(size), float2(1e-6));
		let lp = dst.xy + t * size;
		pix = mat_apply(m, lp);
	} else {
		pix = mix(dst.xy, dst.zw, corner);
	}
	var o: PSIn;
	pix = pix - g.target_origin;
	o.pos = float4(pix.x / g.viewport_size.x * 2.0 - 1.0, 1.0 - pix.y / g.viewport_size.y * 2.0, 0.0, 1.0);
	o.rect_pos = (t - 0.5) * size;
	o.half_size = size * 0.5;
	o.lpos = i.dst.xy + t * (i.dst.zw - i.dst.xy);
	let tex = max(style.w, 1.0);
	o.uv = mix(i.src.xy, i.src.zw, t) / tex;
	o.src = i.src / tex;
	// gradients and shadows have one color; their other "colors" are parameters
	var c = i.c3;
	if (kind >= KIND_GRADIENT || i.vid == 0u) { c = i.c0; } else if (i.vid == 1u) { c = i.c1; } else if (i.vid == 2u) { c = i.c2; }
	c.a = c.a * rp.m1.z;   // the replay's alpha (1 for immediate instances)
	if (lerp_space(i.extra.z) == SPACE_SRGB) { c = float4(srgb_encode(c.rgb), c.a); }
	o.color = float4(c.rgb * c.a, c.a);   // premultiplied: a transparent corner does not drag the others' hue to black
	o.radii = radii;
	o.style = style;
	o.extra = uint4(select(0u, 1u, xf), i.extra.y, i.extra.z, i.extra.w);
	o.p0 = i.c1;
	o.p1 = i.c2;
	o.p2 = i.c3;
	if (kind == KIND_GLYPH) {
		// Skia's text correction (SkMaskGamma), per glyph: the text's luminance s (sRGB-encoded) and the background
		// guessed as its opposite d = 1 - s, as luma through the text curve (Ls, Ld) and as the target blends them
		// (bs, bd). The pixel shader boosts and re-blends the coverage with them.
		o.style.y = 0.0;
		if (g.text_gamma != 0.0) {
			let s = text_from_luma(dot(float3(0.2126, 0.7152, 0.0722), text_to_luma3(srgb_encode(i.c0.rgb))));
			let d = 1.0 - s;
			if (abs(s - d) >= 1.0 / 256.0) {
				let ls = text_to_luma(s);
				let ld = text_to_luma(d);
				let bs = select(s, srgb_decode1(s), g.target_space == SPACE_LINEAR);
				let bd = select(d, srgb_decode1(d), g.target_space == SPACE_LINEAR);
				o.radii = float4(ls, ld, bd, 1.0 / (bs - bd));
				o.style.x = g.text_contrast * ld;   // the contrast fades out as the guessed background gets dark
				o.style.y = 1.0;
			}
		}
	}
	return o;
}

// Glyph coverage to alpha (render.Text_Rendering): exponent, then Skia's correction prepared by the vertex shader.
fn text_coverage(a0: f32, i: PSIn) -> f32 {
	var a = a0;
	if (g.text_exponent != 1.0) { a = pow(max(a, 0.0), g.text_exponent); }
	if (i.style.y < 0.5) { return a; }
	let boosted = a + (1.0 - a) * i.style.x * a;
	let lin = i.radii.x * boosted + (1.0 - boosted) * i.radii.y;   // the blend wanted, through the text curve
	var o = text_from_luma(lin);                                   // back to encoded values
	if (g.target_space == SPACE_LINEAR) { o = srgb_decode1(o); }
	return saturate((o - i.radii.z) * i.radii.w);                  // the coverage the target's blend needs for it
}

// the corner shape of the primitive being shaded: the renderer's, or circular (FLAG_CIRCLE / CLIP_CIRCLE)
var<private> shape_n: f32;
var<private> shape_boost: f32;

fn use_corner_shape(circle: bool) {
	shape_n = select(g.corner_n, 2.0, circle);
	shape_boost = select(g.corner_boost, 1.0, circle);
}

// Rounded-rect distance (x) and the direction of its gradient (yz, local space). With corner_n > 2 the corner is a
// superellipse: its curvature ramps up from the straight edge instead of jumping.
fn rect_sdf_dir(p: float2, half_size: float2, r0: f32) -> float3 {
	let r = min(r0 * shape_boost, min(half_size.x, half_size.y));
	let d = abs(p) - half_size + r;
	let q = max(d, float2(0.0));
	var outside = length(q);
	if (shape_n > 2.01) {
		outside = pow(pow(max(q.x, 1e-6), shape_n) + pow(max(q.y, 1e-6), shape_n), 1.0 / shape_n);
	}
	var dir: float2;
	if (q.x > 0.0 && q.y > 0.0) { dir = normalize(q); } else if (d.x > d.y) { dir = float2(1.0, 0.0); } else { dir = float2(0.0, 1.0); }
	dir = dir * float2(select(1.0, -1.0, p.x < 0.0), select(1.0, -1.0, p.y < 0.0));
	return float3(min(max(d.x, d.y), 0.0) + outside - r, dir);
}

fn rect_sdf(p: float2, half_size: float2, r: f32) -> f32 { return rect_sdf_dir(p, half_size, r).x; }

// A local-space distance in screen pixels: divided by how much it changes per pixel along its gradient.
fn to_px(s: f32, dir: float2, dpx: float2, dpy: float2) -> f32 {
	return s / max(length(float2(dot(dir, dpx), dot(dir, dpy))), 1e-6);
}

fn corner_radius(p: float2, radii: float4) -> f32 {
	if (p.x < 0.0) { return select(radii.y, radii.x, p.y < 0.0); }
	return select(radii.w, radii.z, p.y < 0.0);
}

fn ellipse_sdf(p: float2, r0: float2) -> f32 {
	let r = max(r0, float2(1e-4));
	if (abs(r.x - r.y) < 1e-4) { return length(p) - r.x; }
	let k0 = length(p / r);
	let k1 = length(p / (r * r));
	if (k1 > 1e-6) { return k0 * (k0 - 1.0) / k1; }
	return -min(r.x, r.y);
}

fn point_at(ret: bool, k: u32) -> float2 {
	if (ret) { return rpoints[rp.base.z + k]; }
	return points[k];
}

// Signed distance to a polygon (negative inside), with the nonzero or even-odd rule.
fn polygon_sdf(p: float2, first: u32, count0: u32, evenodd: bool, ret: bool) -> f32 {
	let count = min(count0, MAX_POLYGON_POINTS);
	if (count < 3u) { return 1e9; }
	var d = 1e30;
	var winding = 0;
	var a = point_at(ret, first + count - 1u);
	for (var i = 0u; i < count; i++) {
		let b = point_at(ret, first + i);
		let e = b - a;
		let w = p - a;
		let q = w - e * saturate(dot(w, e) / max(dot(e, e), 1e-12));
		d = min(d, dot(q, q));
		let side = e.x * w.y - e.y * w.x;
		if (a.y <= p.y) {
			if (b.y > p.y && side > 0.0) { winding++; }
		} else if (b.y <= p.y && side < 0.0) {
			winding--;
		}
		a = b;
	}
	var inside = winding != 0;
	if (evenodd) { inside = (winding & 1) != 0; }
	if (inside) { return -sqrt(d); }
	return sqrt(d);
}

fn clip_sdf(c: ClipShape, lp0: float2, ret: bool) -> f32 {
	if (c.kind == CLIP_ELLIPSE) { return ellipse_sdf(lp0 - c.center, c.half_size); }
	if (c.kind == CLIP_POLYGON) { return polygon_sdf(lp0, c.first, c.count, (c.flags & CLIP_EVENODD) != 0u, ret); }
	use_corner_shape((c.flags & CLIP_CIRCLE) != 0u);
	let lp = lp0 - c.center;
	return rect_sdf(lp, c.half_size, corner_radius(lp, c.radii));
}

// Coverage of the (nested) clip shapes of the frame's table at a screen position.
fn clip_coverage(screen: float2, idx0: u32) -> f32 {
	var coverage = 1.0;
	var idx = idx0;
	for (var k = 0; k < MAX_CLIP_DEPTH && idx != 0u; k++) {
		let c = clips[idx];
		let lp = float2(c.inv.x * screen.x + c.inv.z * screen.y + c.t.x, c.inv.y * screen.x + c.inv.w * screen.y + c.t.y);
		coverage = coverage * saturate(0.5 - clip_sdf(c, lp, false) * c.px);
		idx = c.parent;
	}
	return coverage;
}

// Coverage of a picture's clips (each in the space of its slot, through the replay's matrix), then of the clips
// around the replay.
fn retained_clip_coverage(screen: float2, idx0: u32) -> f32 {
	var coverage = 1.0;
	var idx = idx0;
	let l = replay_mat();
	let q = mat_apply(replay_inv(), screen);   // picture space
	for (var k = 0; k < MAX_CLIP_DEPTH && idx != 0u; k++) {
		let c = rclips[rp.base.y + idx];
		var to_screen = l;
		var lp = q;
		if (c.xform != 0u) {
			let s = slots[rp.base.x + c.xform];
			to_screen = mat_mul(l, mat_make(s.abcd, s.ef.xy));
			lp = mat_apply(mat_make(s.inv_abcd, s.inv_ef.xy), q);
		}
		// a plain rect under a uniform scale + translation: the scissor already cut it exactly (as push_clip does)
		if (!((c.flags & CLIP_SCISSOR) != 0u && mat_simple(to_screen))) {
			coverage = coverage * saturate(0.5 - clip_sdf(c, lp, true) * mat_scale(to_screen));
		}
		idx = c.parent;
	}
	return coverage * clip_coverage(screen, rp.misc.y);
}

fn any_clip_coverage(screen: float2, idx: u32) -> f32 {
	if (is_retained()) { return retained_clip_coverage(screen, idx); }
	return clip_coverage(screen, idx);
}

////////////////////////////////
// Gradients (CSS Images 4): see render.Gradient_Header in render.odin for the table layout.

fn grad_entry(k: u32) -> float4 {
	if (is_retained()) { return rgrads[rp.base.w + k]; }
	return grads[k];
}

fn oklab_to_linear(c: float3) -> float3 {
	let l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
	let m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
	let s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
	let l = l_ * l_ * l_;
	let m = m_ * m_ * m_;
	let s = s_ * s_ * s_;
	return float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
	             -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
	             -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

// CIE Lab (D50) to linear sRGB (D65, Bradford adaptation), as CSS Color 4.
fn lab_to_linear(c: float3) -> float3 {
	let fy = (c.x + 16.0) / 116.0;
	let fx = fy + c.y / 500.0;
	let fz = fy - c.z / 200.0;
	let e = 216.0 / 24389.0;
	let k = 24389.0 / 27.0;
	let x = select((116.0 * fx - 16.0) / k, fx * fx * fx, fx * fx * fx > e);
	let y = select(c.x / k, fy * fy * fy, c.x > k * e);
	let z = select((116.0 * fz - 16.0) / k, fz * fz * fz, fz * fz * fz > e);
	let xyz = float3(x * 0.3457 / 0.3585, y, z * (1.0 - 0.3457 - 0.3585) / 0.3585);   // D50 white
	let d65 = float3( 0.9554734527042182 * xyz.x - 0.023098536874261423 * xyz.y + 0.0632593086610217 * xyz.z,
	                 -0.028369706963208136 * xyz.x + 1.0099954580058226 * xyz.y + 0.021041398966943008 * xyz.z,
	                  0.012314001688319899 * xyz.x - 0.020507696433477912 * xyz.y + 1.3303659366080753 * xyz.z);
	return float3( 3.2409699419045226 * d65.x - 1.537383177570094 * d65.y - 0.4986107602930034 * d65.z,
	              -0.9692436362808796 * d65.x + 1.8759675015077202 * d65.y + 0.04155505740717559 * d65.z,
	               0.05563007969699366 * d65.x - 0.20397695888897652 * d65.y + 1.0569715142428786 * d65.z);
}

// HSL (hue in degrees, s and l 0..1) to sRGB values.
fn hsl_to_srgb(c: float3) -> float3 {
	let h = c.x - 360.0 * floor(c.x / 360.0);
	let kv = (float3(0.0, 8.0, 4.0) + h / 30.0) % float3(12.0);
	let a = c.y * min(c.z, 1.0 - c.z);
	return float3(c.z) - a * max(float3(-1.0), min(min(kv - 3.0, 9.0 - kv), float3(1.0)));
}

fn hwb_to_srgb(c: float3) -> float3 {
	let w = c.y;
	let b = c.z;
	if (w + b >= 1.0) { let g2 = w / (w + b); return float3(g2, g2, g2); }
	return hsl_to_srgb(float3(c.x, 1.0, 0.5)) * (1.0 - w - b) + w;
}

struct GradOut {
	color: float4,    // straight, in linear light or sRGB values (`srgb`)
	srgb: bool,
	dither: bool,
};

fn gradient_color(p: float2, h: u32) -> GradOut {
	let hd = bitcast<uint4>(grad_entry(h));
	let flags = hd.x;
	let space = hd.y;
	let n = min(hd.w, MAX_GRADIENT_STOPS);
	var out: GradOut;
	out.srgb = space == GSPACE_SRGB || space == GSPACE_HSL || space == GSPACE_HWB;
	out.dither = (flags & GRAD_DITHER) != 0u;
	out.color = float4(0.0);
	let geom = grad_entry(h + 1u);
	let tile = grad_entry(h + 2u);
	let per = grad_entry(h + 3u);
	var q = p - tile.xy;
	if (tile.z > 0.0) {
		let period = tile.z + per.x;
		if ((flags & GRAD_REPEAT_X) != 0u) { q.x = q.x - floor(q.x / period) * period; }
		if (q.x < 0.0 || q.x > tile.z) { return out; }
	}
	if (tile.w > 0.0) {
		let period = tile.w + per.y;
		if ((flags & GRAD_REPEAT_Y) != 0u) { q.y = q.y - floor(q.y / period) * period; }
		if (q.y < 0.0 || q.y > tile.w) { return out; }
	}
	var t: f32;
	let kind = flags & 0xffu;
	if (kind == GRAD_RADIAL) {
		t = length((q - geom.xy) / max(abs(geom.zw), float2(1e-4)));
	} else if (kind == GRAD_CONIC) {
		let d = q - geom.xy;
		let a = atan2(d.x, -d.y);   // clockwise from up
		t = fract((a - geom.z) / 6.283185307179586);
	} else {
		let d = geom.zw - geom.xy;
		t = dot(q - geom.xy, d) / max(dot(d, d), 1e-12);
	}
	if ((flags & GRAD_REPEATING) != 0u) {
		let span = per.w - per.z;
		if (span > 1e-6) { t = per.z + fract((t - per.z) / span) * span; }
	}
	let s0 = h + GRAD_HEADER;
	var c: float4;
	if (n <= 1u || t <= grad_entry(s0 + 1u).x) {
		c = grad_entry(s0);
	} else if (t >= grad_entry(s0 + 2u * (n - 1u) + 1u).x) {
		c = grad_entry(s0 + 2u * (n - 1u));
	} else {
		var k = 1u;
		for (; k < n - 1u; k++) { if (t < grad_entry(s0 + 2u * k + 1u).x) { break; } }
		let pa = grad_entry(s0 + 2u * (k - 1u) + 1u);
		let pb = grad_entry(s0 + 2u * k + 1u).x;
		var f = 1.0;
		if (pb > pa.x) { f = (t - pa.x) / (pb - pa.x); }
		if (pa.y >= 0.0) {
			// transition hint (CSS Images 4 3.5.3): the midpoint color sits at fraction pa.y of the interval
			let hint = pa.y;
			if (hint <= 0.0) { f = 1.0; }
			else if (hint >= 1.0) { f = select(0.0, 1.0, f >= 1.0); }
			else { f = pow(saturate(f), log(0.5) / log(hint)); }
		}
		c = mix(grad_entry(s0 + 2u * (k - 1u)), grad_entry(s0 + 2u * k), f);
	}
	if (c.a <= 1e-7) { return out; }
	var v = c.rgb;
	// premultiplied: divide every component but a polar space's hue
	if (space == GSPACE_OKLCH || space == GSPACE_LCH) { v = float3(v.xy / c.a, v.z); }
	else if (space == GSPACE_HSL || space == GSPACE_HWB) { v = float3(v.x, v.yz / c.a); }
	else { v = v / c.a; }
	var rgb: float3;
	switch (space) {
		case GSPACE_LINEAR: { rgb = v; }
		case GSPACE_OKLAB: { rgb = oklab_to_linear(v); }
		case GSPACE_OKLCH: { let hr = radians(v.z); rgb = oklab_to_linear(float3(v.x, v.y * cos(hr), v.y * sin(hr))); }
		case GSPACE_LAB: { rgb = lab_to_linear(v); }
		case GSPACE_LCH: { let hr = radians(v.z); rgb = lab_to_linear(float3(v.x, v.y * cos(hr), v.y * sin(hr))); }
		case GSPACE_HSL: { rgb = hsl_to_srgb(v); }
		case GSPACE_HWB: { rgb = hwb_to_srgb(v); }
		default: { rgb = v; }
	}
	out.color = float4(saturate(rgb), saturate(c.a));
	return out;
}

// Triangular noise of +-1 level of 8 bits at a screen pixel (dithering of gradients).
fn dither_noise(screen: float2) -> f32 {
	let p = uint2(screen);
	var hsh = p.x * 1973u + p.y * 9277u + 26699u;
	hsh = (hsh ^ (hsh >> 13u)) * 1274126177u;
	hsh = hsh ^ (hsh >> 16u);
	let a = f32(hsh & 0xffffu) / 65535.0;
	let b = f32(hsh >> 16u) / 65535.0;
	return (a + b - 1.0) / 255.0;
}

////////////////////////////////
// Shadows: a gaussian of standard deviation `sigma` over a rounded rect. Along x the integral is exact (erf); along y
// the rows of the straight middle part are exact too (the box is a product of two intervals there), the rows of the
// corners are integrated with the midpoint rule over the part of the kernel that matters.

fn erf_approx(x0: f32) -> f32 {
	// Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7)
	let s = sign(x0);
	let x = abs(x0);
	let t = 1.0 / (1.0 + 0.3275911 * x);
	let y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
	return s * y;
}

// The standard normal cumulative distribution.
fn Phi(x: f32) -> f32 { return 0.5 + 0.5 * erf_approx(x * 0.7071067811865476); }

const SHADOW_SAMPLES: i32 = 16;

fn arc_part(p: float2, center: float2, r: f32, sx: f32, sy: f32, sigma: f32) -> f32 {
	if (r <= 0.0) { return 0.0; }
	// sin a for the rows within 4 sigma of p
	let s0 = sy * (p.y - 4.0 * sigma - center.y) / r;
	let s1 = sy * (p.y + 4.0 * sigma - center.y) / r;
	let lo = clamp(min(s0, s1), 0.0, 1.0);
	let hi = clamp(max(s0, s1), 0.0, 1.0);
	if (hi <= lo) { return 0.0; }
	let inv = 1.0 / sigma;
	// the edge of these rows lies within [center.x - r, center.x] or [center.x, center.x + r]: far from it, Phi is 0 or 1
	let xa = select(center.x, center.x - r, sx < 0.0);
	let xb = select(center.x + r, center.x, sx < 0.0);
	if ((p.x - xa) * inv < -5.0) { return 0.0; }
	if ((p.x - xb) * inv > 5.0) { return abs(Phi((p.y - (center.y + sy * r * lo)) * inv) - Phi((p.y - (center.y + sy * r * hi)) * inv)); }
	let a0 = asin(lo);
	let a1 = asin(hi);
	let h = (a1 - a0) / f32(SHADOW_SAMPLES);
	var acc = 0.0;
	for (var k = 0; k < SHADOW_SAMPLES; k++) {
		let a = a0 + (f32(k) + 0.5) * h;
		let sa = sin(a);
		let ca = cos(a);
		let dy = (p.y - (center.y + sy * r * sa)) * inv;
		acc += exp(-0.5 * dy * dy) * Phi((p.x - (center.x + sx * r * ca)) * inv) * ca;
	}
	return acc * h * r * inv * 0.3989422804014327;
}

// The blurred coverage of a rounded rect (x0 y0 x1 y1, radii tl bl tr br) at p.
fn blurred_rrect(p0: float2, rect: float4, radii: float4, sigma: f32) -> f32 {
	let c = (rect.xy + rect.zw) * 0.5;
	let hs = max((rect.zw - rect.xy) * 0.5, float2(0.0));
	if (hs.x <= 0.0 || hs.y <= 0.0) { return 0.0; }
	let p = p0 - c;
	let r = min(max(radii, float4(0.0)), float4(min(hs.x, hs.y)));
	let inv = 1.0 / sigma;
	// left edge: straight between the top-left and bottom-left arcs
	let left = Phi((p.x + hs.x) * inv) * max(Phi((p.y + hs.y - r.x) * inv) - Phi((p.y - hs.y + r.y) * inv), 0.0)
		+ arc_part(p, float2(-hs.x + r.x, -hs.y + r.x), r.x, -1.0, -1.0, sigma)
		+ arc_part(p, float2(-hs.x + r.y, hs.y - r.y), r.y, -1.0, 1.0, sigma);
	let right = Phi((p.x - hs.x) * inv) * max(Phi((p.y + hs.y - r.z) * inv) - Phi((p.y - hs.y + r.w) * inv), 0.0)
		+ arc_part(p, float2(hs.x - r.z, -hs.y + r.z), r.z, 1.0, -1.0, sigma)
		+ arc_part(p, float2(hs.x - r.w, hs.y - r.w), r.w, 1.0, 1.0, sigma);
	return saturate(left - right);
}

// Antialiased coverage of a rounded rect (x0 y0 x1 y1, radii tl bl tr br, circular corners) at p, in units whose
// screen rate of change is given by dpx / dpy.
fn rrect_coverage(p: float2, rect: float4, radii: float4, dpx: float2, dpy: float2) -> f32 {
	let c = (rect.xy + rect.zw) * 0.5;
	let hs = max((rect.zw - rect.xy) * 0.5, float2(0.0));
	use_corner_shape(true);
	let q = p - c;
	let sd = rect_sdf_dir(q, hs, corner_radius(q, radii));
	return saturate(0.5 - to_px(sd.x, sd.yz, dpx, dpy));
}

////////////////////////////////
// Blend modes (CSS Compositing 1 section 10), on straight sRGB colors as browsers compute them.

fn blend_channel(b: f32, s: f32, mode: u32) -> f32 {
	switch (mode) {
		case BLEND_MULTIPLY: { return b * s; }
		case BLEND_SCREEN: { return b + s - b * s; }
		case BLEND_OVERLAY: { return select(s + (2.0 * b - 1.0) - s * (2.0 * b - 1.0), s * 2.0 * b, b <= 0.5); }
		case BLEND_DARKEN: { return min(b, s); }
		case BLEND_LIGHTEN: { return max(b, s); }
		case BLEND_COLOR_DODGE: {
			if (b <= 0.0) { return 0.0; }
			if (s >= 1.0) { return 1.0; }
			return min(1.0, b / (1.0 - s));
		}
		case BLEND_COLOR_BURN: {
			if (b >= 1.0) { return 1.0; }
			if (s <= 0.0) { return 0.0; }
			return 1.0 - min(1.0, (1.0 - b) / s);
		}
		case BLEND_HARD_LIGHT: { return select(b + (2.0 * s - 1.0) - b * (2.0 * s - 1.0), b * 2.0 * s, s <= 0.5); }
		case BLEND_SOFT_LIGHT: {
			if (s <= 0.5) { return b - (1.0 - 2.0 * s) * b * (1.0 - b); }
			let d = select(sqrt(b), ((16.0 * b - 12.0) * b + 4.0) * b, b <= 0.25);
			return b + (2.0 * s - 1.0) * (d - b);
		}
		case BLEND_DIFFERENCE: { return abs(b - s); }
		case BLEND_EXCLUSION: { return b + s - 2.0 * b * s; }
		default: { return s; }
	}
}

fn lum(c: float3) -> f32 { return dot(c, float3(0.3, 0.59, 0.11)); }

fn clip_color(c0: float3) -> float3 {
	var c = c0;
	let l = lum(c);
	let n = min(c.r, min(c.g, c.b));
	let x = max(c.r, max(c.g, c.b));
	if (n < 0.0) { c = l + (c - l) * l / max(l - n, 1e-6); }
	if (x > 1.0) { c = l + (c - l) * (1.0 - l) / max(x - l, 1e-6); }
	return c;
}

fn set_lum(c: float3, l: f32) -> float3 { return clip_color(c + (l - lum(c))); }

fn sat_of(c: float3) -> f32 { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }

fn set_sat(c: float3, s: f32) -> float3 {
	let mx = max(c.r, max(c.g, c.b));
	let mn = min(c.r, min(c.g, c.b));
	if (mx > mn) { return (c - mn) * s / (mx - mn); }
	return float3(0.0);
}

fn blend_color(b: float3, s: float3, mode: u32) -> float3 {
	switch (mode) {
		case BLEND_HUE: { return set_lum(set_sat(s, sat_of(b)), lum(b)); }
		case BLEND_SATURATION: { return set_lum(set_sat(b, sat_of(s)), lum(b)); }
		case BLEND_COLOR: { return set_lum(s, lum(b)); }
		case BLEND_LUMINOSITY: { return set_lum(b, lum(s)); }
		default: { return float3(blend_channel(b.r, s.r, mode), blend_channel(b.g, s.g, mode), blend_channel(b.b, s.b, mode)); }
	}
}

// Source (the layer) over backdrop through `mode`; both and the result are premultiplied in the target's space (the
// formulas run on straight sRGB values: converted in and out only for a linear target).
fn blend_composite(src: float4, dst: float4, mode: u32) -> float4 {
	let as_ = saturate(src.a);
	let ab = saturate(dst.a);
	var cs = float3(0.0);
	if (as_ > 0.0) { cs = convert_space(src.rgb / as_, g.target_space, SPACE_SRGB); }
	var cb = float3(0.0);
	if (ab > 0.0) { cb = convert_space(dst.rgb / ab, g.target_space, SPACE_SRGB); }
	cs = saturate(cs);
	cb = saturate(cb);
	var ao: f32;
	var co: float3;   // premultiplied sRGB
	if (mode == BLEND_PLUS_LIGHTER) {
		ao = min(1.0, as_ + ab);
		co = min(float3(1.0), cs * as_ + cb * ab);
	} else if (mode == BLEND_PLUS_DARKER) {
		ao = min(1.0, as_ + ab);
		co = max(float3(0.0), float3(ao) - (as_ - cs * as_) - (ab - cb * ab));
	} else {
		let mixed = (1.0 - ab) * cs + ab * saturate(blend_color(cb, cs, mode));
		ao = as_ + ab * (1.0 - as_);
		co = as_ * mixed + (1.0 - as_) * ab * cb;
	}
	if (ao <= 0.0) { return float4(0.0); }
	return float4(convert_space(saturate(co / ao), SPACE_SRGB, g.target_space) * ao, ao);
}

// A bilinear sample of texel position `tc` (continuous, in texels) of `image` with a transparent one-texel border
// around it: Direct3D's border address mode, which WebGPU has no equivalent of. Clamp-to-edge sampling scaled by the
// part of the bilinear footprint that lies inside is the same thing.
fn sample_border(tc: float2, dim: float2) -> float4 {
	let inside = clamp(tc + 0.5, float2(0.0), float2(1.0)) * clamp(dim + 0.5 - tc, float2(0.0), float2(1.0));
	return textureSampleLevel(image, samp_img, clamp(tc, float2(0.0), dim) / dim, 0.0) * (inside.x * inside.y);
}

struct Texel {
	t: float4,
	space: u32,
};

// The texel of a layer composite (FLAG_LAYER: at uv, texels of the layer) or a backdrop (FLAG_SCREEN: at the screen
// pixel) as a filter chain left it: fetched one for one, or sampled bilinearly from a reduced image (FLAG_SCALED), then
// through its color matrices (FLAG_MATRIX: a Color pass done here instead of in a target of its own). `space` is the
// texel's space, sRGB after the matrices.
fn layer_texel(i: PSIn, screen: float2, space0: u32) -> Texel {
	let flags = i.extra.z;
	let dim = float2(textureDimensions(image));
	var t: float4;
	var space = space0;
	if ((flags & FLAG_SCREEN) != 0u) {
		if ((flags & FLAG_SCALED) != 0u) {
			// edges repeat (a backdrop); tex_size (style.w) is the scale
			let tc = clamp((screen - i.src.xy) * i.style.w, float2(0.5), max(i.src.zw - 0.5, float2(0.5)));
			t = sample_border(tc, dim);
		} else {
			let tc = clamp(vec2<i32>(floor(screen - i.src.xy)), vec2<i32>(0), max(vec2<i32>(i.src.zw) - 1, vec2<i32>(0)));
			t = textureLoad(image, tc, 0);
		}
	} else if ((flags & FLAG_SCALED) != 0u) {
		// transparent past the reduced image (its ring, the texture's border)
		t = sample_border(min(i.uv, i.src.zw + 0.5), dim);
	} else {
		t = textureLoad(image, vec2<i32>(floor(i.uv)), 0);
	}
	if ((flags & FLAG_MATRIX) != 0u) {
		let base = i.extra.w;
		let n = min(u32(grads[base].x + 0.5), 8u);
		var v = float4(0.0, 0.0, 0.0, t.a);
		if (t.a > 0.0) { v = float4(convert_space(t.rgb / t.a, space, SPACE_SRGB), t.a); }
		for (var k = 0u; k < n; k++) {
			let e = base + 1u + k * 5u;
			v = saturate(float4(dot(grads[e], v), dot(grads[e + 1u], v), dot(grads[e + 2u], v), dot(grads[e + 3u], v)) + grads[e + 4u]);
		}
		t = float4(v.rgb * v.a, v.a);
		space = SPACE_SRGB;
	}
	return Texel(t, space);
}

// A texel of a layer drawn through a homography (FLAG_PROJECT), filtered along the long axis of the pixel's footprint in the
// layer (anisotropic: taps one texel apart, up to p0.x of them) so a plane seen at a slant stays sharp without shimmering.
// Reads stay inside the layer's valid texels (src), so nothing leaks in from the pooled texture around it.
fn proj_texel(i: PSIn, duvx: float2, duvy: float2) -> float4 {
	let dim = float2(textureDimensions(image));
	let lo = i.src.xy + 0.5;
	let hi = max(i.src.zw - 0.5, lo);
	var major = duvx;
	var lmaj = length(duvx);
	let ly = length(duvy);
	if (ly > lmaj) { major = duvy; lmaj = ly; }
	let n = u32(clamp(ceil(lmaj - 0.05), 1.0, max(i.p0.x, 1.0)));
	var acc = float4(0.0);
	for (var k = 0u; k < n; k++) {
		let o = (f32(k) + 0.5) / f32(n) - 0.5;
		acc += textureSampleLevel(image, samp_img, clamp(i.uv + major * o, lo, hi) / dim, 0.0);
	}
	return acc / f32(n);
}

@fragment
fn ps_main(i: PSIn) -> @location(0) float4 {
	let p = i.rect_pos;
	// derivatives first, outside any branch: local units per screen pixel (constant per primitive), texture LOD
	let dpx = dpdx(p);
	let dpy = dpdy(p);
	let duvx = dpdx(i.uv);
	let duvy = dpdy(i.uv);
	let ldx = dpdx(i.lpos);   // instance units per screen pixel (gradients, shadows)
	let ldy = dpdy(i.lpos);
	let xf = i.extra.x != 0u;
	let kind = u32(i.style.z + 0.5);
	use_corner_shape((i.extra.z & FLAG_CIRCLE) != 0u);
	// straight color in the target's space
	var color = i.color;
	if (color.a > 0.0) { color = float4(color.rgb / color.a, color.a); } else { color = float4(0.0, 0.0, 0.0, color.a); }
	color = float4(convert_space(color.rgb, lerp_space(i.extra.z), g.target_space), color.a);
	var tex_space = SPACE_LINEAR;
	if ((i.extra.z & FLAG_TEX_SRGB) != 0u) { tex_space = SPACE_SRGB; }
	let screen = i.pos.xy + g.target_origin;
	let clipped = i.extra.y != 0u || rp.misc.y != 0u;
	if ((i.extra.z & FLAG_BLEND) != 0u) {
		// the layer's texel and what lay under it; the batch writes the result (no hardware blending)
		let lt = layer_texel(i, screen, tex_space);
		let s = convert_premul(lt.t, lt.space, g.target_space) * color.a;
		let d = textureLoad(backdrop, vec2<i32>(floor(screen - i.radii.xy)), 0);
		let o = blend_composite(s, d, (i.extra.z >> BLEND_SHIFT) & 0xffu);
		var cov = 1.0;
		if (clipped) { cov = any_clip_coverage(screen, i.extra.y); }
		return mix(d, o, cov);
	}
	let lp = i.lpos;
	if (kind == KIND_SHADOW) {
		let sigma = i.p2.x;
		let sflags = u32(i.p2.y + 0.5);
		// below a third of a screen pixel the blur is invisible: the shape's antialiased coverage
		let px_per_unit = 1.0 / max(length(float2(length(ldx), length(ldy))) * 0.7071067811865476, 1e-6);
		// the other rect first: where it hides everything (inside the box of an outer shadow, outside the padding box of
		// an inset one), nothing to blur
		var other = 0.0;
		if ((sflags & (SHADOW_INSET | SHADOW_HOLE)) != 0u) { other = rrect_coverage(lp, i.p0, i.p1, ldx, ldy); }
		var keep = 1.0 - other;
		if ((sflags & SHADOW_INSET) != 0u) { keep = other; }
		if (keep <= 0.0) { discard; }
		var mask: f32;
		if (sigma * px_per_unit < 0.33) { mask = rrect_coverage(lp, i.src, i.radii, ldx, ldy); } else { mask = blurred_rrect(lp, i.src, i.radii, sigma); }
		if ((sflags & SHADOW_INSET) != 0u) { mask = keep * (1.0 - mask); } else { mask = keep * mask; }
		color.a = color.a * mask;
		if (clipped) { color.a = color.a * any_clip_coverage(screen, i.extra.y); }
		return color;
	}
	var dither = false;
	if (kind == KIND_GRADIENT) {
		let gr = gradient_color(lp, i.extra.w);
		dither = gr.dither;
		color = float4(convert_space(gr.color.rgb, select(SPACE_LINEAR, SPACE_SRGB, gr.srgb), g.target_space), color.a * gr.color.a);
	}
	if (kind == KIND_GLYPH) {
		// coverage from the atlas, kept inside the glyph's cell (a transformed quad is grown past it)
		let h = 0.5 / max(i.style.w, 1.0);
		let cov = textureSampleGrad(atlas, samp, clamp(i.uv, i.src.xy + h, i.src.zw - h), duvx, duvy).r;
		color.a = color.a * text_coverage(cov, i);
		if (xf) {
			let sd = rect_sdf_dir(p, i.half_size, 0.0);
			color.a = color.a * saturate(0.5 - to_px(sd.x, sd.yz, dpx, dpy));
		}
	} else {
		if (kind == KIND_IMAGE) {
			let dim = float2(textureDimensions(image));
			let uv = i.uv / dim;
			var texel: float4;
			// a layer is composited pixel for pixel: fetch, never filter (filter weights would leak the transparent
			// texels around its edges)
			if ((i.extra.z & FLAG_PROJECT) != 0u) {
				texel = proj_texel(i, duvx, duvy);
			} else if ((i.extra.z & (FLAG_LAYER | FLAG_SCREEN)) != 0u) {
				let lt = layer_texel(i, screen, tex_space);
				texel = lt.t;
				tex_space = lt.space;
			} else if ((i.extra.z & FLAG_TILE) != 0u) {
				texel = textureSampleGrad(image, samp_wrap, uv, duvx / dim, duvy / dim);
			} else {
				let h = 0.5 / dim;   // never filter in texels outside the source rect (sprite sheets)
				texel = textureSampleGrad(image, samp_img, clamp(uv, i.src.xy / dim + h, i.src.zw / dim - h), duvx / dim, duvy / dim);
			}
			// stored premultiplied, blended straight
			var straight = float3(0.0);
			if (texel.a > 0.0) { straight = texel.rgb / texel.a; }
			color = float4(color.rgb * convert_space(straight, tex_space, g.target_space), color.a * texel.a);
		}
		let r = corner_radius(p, i.radii);
		let border = i.style.x;
		let soft = i.style.y;
		var coverage: f32;
		if (soft > 1.0) {
			// soft shape (shadows, glows): the edge fades over 2*soft pixels inside the rect
			let s = rect_sdf(p, i.half_size - soft * 2.0, max(r - soft * 2.0, 0.0));
			coverage = 1.0 - smoothstep(0.0, soft * 2.0, s);
		} else {
			let sd = rect_sdf_dir(p, i.half_size, r);
			var s = sd.x;
			if (xf) { s = to_px(s, sd.yz, dpx, dpy); }
			coverage = saturate(0.5 - s);
			if (border > 0.0) {
				let id = rect_sdf_dir(p, i.half_size - border, max(r - border, 0.0));
				var inner = id.x;
				if (xf) { inner = to_px(inner, id.yz, dpx, dpy); }
				coverage = coverage * saturate(inner + 0.5);
			}
		}
		color.a = color.a * coverage;
	}
	if (clipped) { color.a = color.a * any_clip_coverage(screen, i.extra.y); }
	if (dither && color.a > 0.0) {
		// against banding: noise in the target's 8-bit encoding
		let n = dither_noise(screen);
		if (g.target_space == SPACE_SRGB) { color = float4(saturate(color.rgb + n), color.a); }
		else { color = float4(srgb_decode(srgb_encode(color.rgb) + n), color.a); }
	}
	return color;
}
