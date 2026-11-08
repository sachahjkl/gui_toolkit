// WGSL port of filter.hlsl (filter passes, CSS Filter Effects 1): see that file for the design. The "transparent
// border" sampler of Direct3D is applied by hand (sample_at): WebGPU has no border address mode.

alias float2 = vec2<f32>;
alias float3 = vec3<f32>;
alias float4 = vec4<f32>;

const MODE_COLOR: u32 = 0u;
const MODE_BLUR: u32 = 1u;
const MODE_DOWNSAMPLE: u32 = 2u;
const MODE_SHADOW: u32 = 3u;
const MODE_MASK: u32 = 4u;
const PASS_IN_LINEAR: u32 = 1u;
const PASS_OUT_LINEAR: u32 = 2u;
const PASS_CLAMP: u32 = 4u;
const PASS_SRC2_LINEAR: u32 = 8u;
const PASS_MASK_LUMINANCE: u32 = 16u;
const PASS_MASK_DEST: u32 = 32u;
const PASS_MASK_APPLY: u32 = 64u;
const MASK_OP_SHIFT: u32 = 8u;
const MAX_TAPS: u32 = 64u;
const MAX_MATRICES: u32 = 8u;

struct PassConstants {
	src_origin: float2, src_scale: f32, mode: u32,
	src_size: float2, src_dim: float2,
	dst_origin: float2, dst_scale: f32, flags: u32,
	src2_origin: float2, src2_scale: f32, taps: u32,
	src2_size: float2, src2_dim: float2,
	dir: float2, offset: float2,
	color: float4,
	matrix_count: u32, dst_size_x: f32, dst_size_y: f32, factor: f32,
	tap: array<float4, 32>,
	m: array<float4, 40>,
};

@group(0) @binding(0) var<uniform> pc: PassConstants;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var src2: texture_2d<f32>;
@group(0) @binding(3) var samp: sampler;   // bilinear, clamp to edge

@vertex
fn vs_fx(@builtin(vertex_index) vid: u32) -> @builtin(position) float4 {
	let p = float2(f32((vid << 1u) & 2u), f32(vid & 2u));
	return float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

fn encode(c0: float3) -> float3 {
	let c = saturate(c0);
	return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= float3(0.0031308));
}

fn decode(c0: float3) -> float3 {
	let c = saturate(c0);
	return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= float3(0.04045));
}

fn to_srgb(c: float4) -> float4 {
	if (c.a <= 0.0) { return float4(0.0); }
	return float4(encode(c.rgb / c.a) * c.a, c.a);
}

fn to_linear(c: float4) -> float4 {
	if (c.a <= 0.0) { return float4(0.0); }
	return float4(decode(c.rgb / c.a) * c.a, c.a);
}

// A bilinear sample at texel position `tc` of a texture of `dim` texels, transparent past its edges: clamp-to-edge
// sampling scaled by the part of the bilinear footprint that lies inside is the same thing.
fn bilinear_border(t: texture_2d<f32>, tc: float2, dim: float2) -> float4 {
	let inside = clamp(tc + 0.5, float2(0.0), float2(1.0)) * clamp(dim + 0.5 - tc, float2(0.0), float2(1.0));
	return textureSampleLevel(t, samp, clamp(tc, float2(0.0), dim) / dim, 0.0) * (inside.x * inside.y);
}

// A source texel position (continuous, in texels) sampled: with PASS_CLAMP kept inside the valid region (edges
// repeat), else kept within the transparent ring past it (left and top: the texture's own border).
fn sample_at(first: bool, tc0: float2, size: float2, dim: float2, lin: bool) -> float4 {
	var tc = tc0;
	if ((pc.flags & PASS_CLAMP) != 0u) { tc = clamp(tc, float2(0.5), max(size - 0.5, float2(0.5))); }
	else { tc = min(tc, size + 0.5); }
	var c: float4;
	if (first) { c = bilinear_border(src, tc, dim); } else { c = bilinear_border(src2, tc, dim); }
	if (lin) { return to_srgb(c); }
	return c;
}

@fragment
fn ps_fx(@builtin(position) pos: float4) -> @location(0) float4 {
	if (pos.x > pc.dst_size_x || pos.y > pc.dst_size_y) { return float4(0.0); }   // the ring
	let p = pc.dst_origin + pos.xy / pc.dst_scale;   // screen point of this texel's center
	let tc = (p - pc.src_origin) * pc.src_scale;
	let lin = (pc.flags & PASS_IN_LINEAR) != 0u;
	var c = float4(0.0);
	if (pc.mode == MODE_BLUR) {
		for (var i = 0u; i < pc.taps && i < MAX_TAPS; i++) {
			let tp = pc.tap[i / 2u];
			var ow = tp.xy;
			if ((i & 1u) != 0u) { ow = tp.zw; }
			if (i == 0u) {
				c += ow.y * sample_at(true, tc, pc.src_size, pc.src_dim, lin);
			} else {
				c += ow.y * (sample_at(true, tc + pc.dir * ow.x, pc.src_size, pc.src_dim, lin) + sample_at(true, tc - pc.dir * ow.x, pc.src_size, pc.src_dim, lin));
			}
		}
	} else if (pc.mode == MODE_DOWNSAMPLE) {
		// a factor x factor box: bilinear taps centered between texel pairs, (factor / 2)^2 of them
		let n = u32(pc.factor * 0.5 + 0.5);
		let first = 1.0 - f32(n);
		for (var y = 0u; y < n; y++) {
			for (var x = 0u; x < n; x++) {
				c += sample_at(true, tc + float2(first + 2.0 * f32(x), first + 2.0 * f32(y)), pc.src_size, pc.src_dim, lin);
			}
		}
		c = c / f32(n * n);
	} else if (pc.mode == MODE_SHADOW) {
		let a = sample_at(true, (p - pc.offset - pc.src_origin) * pc.src_scale, pc.src_size, pc.src_dim, false).a;
		let o = sample_at(false, (p - pc.src2_origin) * pc.src2_scale, pc.src2_size, pc.src2_dim, (pc.flags & PASS_SRC2_LINEAR) != 0u);
		let sh = float4(pc.color.rgb * pc.color.a, pc.color.a) * a;
		c = o + sh * (1.0 - o.a);
	} else if (pc.mode == MODE_MASK) {
		// src2: a mask layer (premultiplied sRGB); its coverage is its alpha, or its luminance (CSS Masking 1 7.1:
		// the luminance of the straight color times the alpha, i.e. of the premultiplied color)
		let m = sample_at(false, (p - pc.src2_origin) * pc.src2_scale, pc.src2_size, pc.src2_dim, (pc.flags & PASS_SRC2_LINEAR) != 0u);
		var s = m.a;
		if ((pc.flags & PASS_MASK_LUMINANCE) != 0u) { s = saturate(dot(m.rgb, float3(0.2125, 0.7154, 0.0721))); }
		if ((pc.flags & PASS_MASK_APPLY) != 0u) {
			// src: the masked content, in whatever space it is (scaling premultiplied color commutes with it), maybe
			// reduced (a large blur last); read no further than its ring
			c = sample_at(true, tc, pc.src_size, pc.src_dim, false) * s;
		} else {
			// src: the mask layers below, composited so far (mask-composite: add, subtract, intersect, exclude)
			var r = s;
			if ((pc.flags & PASS_MASK_DEST) != 0u) {
				let d = sample_at(true, tc, pc.src_size, pc.src_dim, false).a;
				let op = (pc.flags >> MASK_OP_SHIFT) & 3u;
				if (op == 0u) { r = s + d * (1.0 - s); }
				else if (op == 1u) { r = s * (1.0 - d); }
				else if (op == 2u) { r = s * d; }
				else { r = s * (1.0 - d) + d * (1.0 - s); }
			}
			c = float4(r, r, r, r);
		}
		return c;
	} else {
		c = sample_at(true, tc, pc.src_size, pc.src_dim, lin);
		if (pc.mode == MODE_COLOR && pc.matrix_count > 0u) {
			var v = float4(0.0, 0.0, 0.0, c.a);
			if (c.a > 0.0) { v = float4(c.rgb / c.a, c.a); }
			for (var k = 0u; k < pc.matrix_count && k < MAX_MATRICES; k++) {
				v = saturate(float4(dot(pc.m[k * 5u], v), dot(pc.m[k * 5u + 1u], v), dot(pc.m[k * 5u + 2u], v), dot(pc.m[k * 5u + 3u], v)) + pc.m[k * 5u + 4u]);
			}
			c = float4(v.rgb * v.a, v.a);
		}
	}
	if ((pc.flags & PASS_OUT_LINEAR) != 0u) { c = to_linear(c); }
	return c;
}
