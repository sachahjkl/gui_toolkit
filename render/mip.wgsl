// Mip chain generation (WebGPU has no GenerateMips): each level is the bilinear reduction of the one above, drawn
// by a full-screen triangle into a view of that level.

@group(0) @binding(0) var mip_src: texture_2d<f32>;
@group(0) @binding(1) var mip_samp: sampler;

@vertex
fn vs_mip(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4<f32> {
	let p = vec2<f32>(f32((vid << 1u) & 2u), f32(vid & 2u));
	return vec4<f32>(p * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0), 0.0, 1.0);
}

@fragment
fn ps_mip(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
	let dim = vec2<f32>(textureDimensions(mip_src));
	// the destination texel covers 2 x 2 source texels: sample at their shared corner
	return textureSampleLevel(mip_src, mip_samp, pos.xy * 2.0 / dim, 0.0);
}
