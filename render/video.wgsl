// Video pictures to RGBA: the planes of a decoded picture (NV12 / P010 from a hardware decoder, or I420 planes in memory),
// sampled with the bilinear filter (that is what upsamples the chroma), turned to RGB with the picture's matrix and range,
// cropped to its visible area and rotated, into a render target that is then an ordinary RGBA texture (draw.image).
// One full-screen triangle; the target is the size of the visible (rotated) picture, so every output pixel is one pixel of
// the picture. Written once here for both backends (naga makes the HLSL).

alias float2 = vec2<f32>;
alias float3 = vec3<f32>;
alias float4 = vec4<f32>;

const FLAG_THREE_PLANES: u32 = 1u;   // I420: U and V in separate textures (else one interleaved UV texture)
const FLAG_OUT_LINEAR: u32 = 2u;     // the target stores sRGB through a *_SRGB view: write linear light (else sRGB values)
const FLAG_PQ: u32 = 4u;             // SMPTE ST 2084 (HDR10)
const FLAG_HLG: u32 = 8u;            // ARIB STD-B67

struct VideoParams {
	crop: float4,        // visible rectangle in luma texels: x0 y0 x1 y1
	dim: float2,         // size of the luma plane in texels
	rotation: u32,       // clockwise degrees: 0, 90, 180, 270
	flags: u32,
	offset: float4,      // subtracted from (y, u, v) after scaling to 0..1
	scale: float4,       // then multiplied: range expansion, and the bit depth of 16-bit planes
	m0: float4,          // rgb = m * yuv: rows (the fourth component is unused)
	m1: float4,
	m2: float4,
	hdr: float4,         // x: SDR white in nits that tone mapping targets, y: peak of the content in nits
};

@group(0) @binding(0) var<uniform> vp: VideoParams;
@group(0) @binding(1) var tex_y: texture_2d<f32>;
@group(0) @binding(2) var tex_u: texture_2d<f32>;   // NV12 / P010: U in .r and V in .g; I420: U in .r
@group(0) @binding(3) var tex_v: texture_2d<f32>;   // I420: V in .r
@group(0) @binding(4) var samp: sampler;            // bilinear, clamp

@vertex
fn vs_video(@builtin(vertex_index) vid: u32) -> @builtin(position) float4 {
	let p = float2(f32((vid << 1u) & 2u), f32(vid & 2u));
	return float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

fn decode_srgb(c0: float3) -> float3 {
	let c = saturate(c0);
	return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= float3(0.04045));
}

fn encode_srgb(c0: float3) -> float3 {
	let c = saturate(c0);
	return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= float3(0.0031308));
}

// ST 2084 inverse EOTF: the signal 0..1 to light in units of 10000 nits.
fn pq_to_linear(e: float3) -> float3 {
	let m1 = 0.1593017578125;
	let m2 = 78.84375;
	let c1 = 0.8359375;
	let c2 = 18.8515625;
	let c3 = 18.6875;
	let p = pow(max(e, float3(0.0)), float3(1.0 / m2));
	return pow(max(p - c1, float3(0.0)) / (c2 - c3 * p), float3(1.0 / m1));
}

fn hlg_to_linear(e: float3) -> float3 {
	let a = 0.17883277;
	let b = 0.28466892;
	let c = 0.55991073;
	return select((exp((e - c) / a) + b) / 12.0, e * e / 3.0, e <= float3(0.5));
}

// BT.2020 to BT.709 primaries (linear light).
fn bt2020_to_709(c: float3) -> float3 {
	return float3(
		1.6605 * c.x - 0.5876 * c.y - 0.0728 * c.z,
		-0.1246 * c.x + 1.1329 * c.y - 0.0083 * c.z,
		-0.0182 * c.x - 0.1006 * c.y + 1.1187 * c.z);
}

@fragment
fn ps_video(@builtin(position) pos: float4) -> @location(0) float4 {
	// the target pixel in 0..1 across the (rotated) picture
	var size = vp.crop.zw - vp.crop.xy;
	var rot = vp.rotation;
	var out_dim = size;
	if (rot == 90u || rot == 270u) { out_dim = size.yx; }
	let u = pos.x / out_dim.x;
	let v = pos.y / out_dim.y;
	var s = float2(u, v);
	if (rot == 90u) { s = float2(v, 1.0 - u); }
	else if (rot == 180u) { s = float2(1.0 - u, 1.0 - v); }
	else if (rot == 270u) { s = float2(1.0 - v, u); }
	let texel = vp.crop.xy + s * size;
	let uv = texel / vp.dim;
	let y = textureSampleLevel(tex_y, samp, uv, 0.0).r;
	var cb: f32;
	var cr: f32;
	if ((vp.flags & FLAG_THREE_PLANES) != 0u) {
		cb = textureSampleLevel(tex_u, samp, uv, 0.0).r;
		cr = textureSampleLevel(tex_v, samp, uv, 0.0).r;
	} else {
		let c = textureSampleLevel(tex_u, samp, uv, 0.0).rg;
		cb = c.x;
		cr = c.y;
	}
	let yuv = (float3(y, cb, cr) * vp.scale.w - vp.offset.xyz) * vp.scale.xyz;
	var rgb = float3(dot(vp.m0.xyz, yuv), dot(vp.m1.xyz, yuv), dot(vp.m2.xyz, yuv));
	if ((vp.flags & (FLAG_PQ | FLAG_HLG)) != 0u) {
		// HDR to the SDR display: light, tone mapped (Reinhard on the luminance, white at the content's peak), in BT.709, sRGB encoded
		var lin: float3;
		if ((vp.flags & FLAG_PQ) != 0u) { lin = pq_to_linear(saturate(rgb)) * 10000.0 / vp.hdr.x; }
		else { lin = hlg_to_linear(saturate(rgb)) / 0.265 * (203.0 / vp.hdr.x); }   // reference white at signal 0.75
		lin = bt2020_to_709(lin);
		let l = dot(lin, float3(0.2126, 0.7152, 0.0722));
		let peak = max(vp.hdr.y / vp.hdr.x, 1.0);
		let mapped = l * (1.0 + l / (peak * peak)) / (1.0 + l);
		let k = select(0.0, mapped / l, l > 1e-5);
		rgb = encode_srgb(lin * k);
	}
	rgb = saturate(rgb);
	if ((vp.flags & FLAG_OUT_LINEAR) != 0u) { rgb = decode_srgb(rgb); }
	return float4(rgb, 1.0);
}
