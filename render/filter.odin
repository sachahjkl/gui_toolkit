package render

import "core:math"

// Shared filter-pass data: the blur-radius limit, the precision of intermediate images, the filter pass's constant
// buffer layout, and the gaussian tap computation. Both backends fill Pass_Constants and call blur_taps; the Direct3D
// frame submission that runs the passes is in frame.odin (Windows only), the wgpu one in wgpu_frame.odin.

// Blurs with a larger standard deviation (screen pixels) run on images reduced by powers of two (see
// set_blur_sigma_limit).
DEFAULT_BLUR_SIGMA_LIMIT :: 8

// Standard deviation, in screen pixels, above which a blur is computed on an image reduced by 2, 4, 8...: the cost of
// a pass is then bounded (about 3 * limit taps per side) whatever the radius. Lower is faster and softer; clamped to
// 2 .. MAX_BLUR_SIGMA.
set_blur_sigma_limit :: proc(r: ^Renderer, sigma: f32) { r.blur_sigma_limit = clamp(sigma, 2, MAX_BLUR_SIGMA) }

// Storage of the intermediate and final images of filter chains: Unorm8 (sRGB-encoded premultiplied 8-bit values,
// as browsers keep them: half the memory and bandwidth) or Half (fp16, the default). Layers themselves are always fp16.
set_filter_precision :: proc(r: ^Renderer, f: Target_Format) { r.filter_format = f }
filter_precision :: proc(r: ^Renderer) -> Target_Format { return r.filter_format }

// The constant buffer of filter.wgsl (register b1), laid out as HLSL packs it.
@(private)
Pass_Constants :: struct #packed {
	src_origin:  [2]f32, src_scale: f32, mode: u32,
	src_size:    [2]f32, src_dim: [2]f32,
	dst_origin:  [2]f32, dst_scale: f32, flags: u32,
	src2_origin: [2]f32, src2_scale: f32, taps: u32,
	src2_size:   [2]f32, src2_dim: [2]f32,
	dir:         [2]f32, offset: [2]f32,
	color:       [4]f32,
	matrix_count: u32, dst_size: [2]f32, factor: f32,
	tap:         [MAX_BLUR_TAPS / 2][4]f32,              // (offset, weight) x 2
	m:           [MAX_COLOR_MATRICES * 5][4]f32,         // per matrix: rows r g b a, then the constant column
}
#assert(size_of(Pass_Constants) % 16 == 0)

// Gaussian taps for a standard deviation in texels, folded in bilinear pairs: tap 0 is the center, each other tap k
// samples at +-offset (between two texels, the filter mixing them with the right weights). Returns the tap count.
blur_taps :: proc(sigma: f32, out: ^[MAX_BLUR_TAPS / 2][4]f32) -> int {
	s := clamp(sigma, 0.05, MAX_BLUR_SIGMA)
	radius := min(int(math.ceil(3 * s)), 2 * (MAX_BLUR_TAPS - 1))
	w := make([]f32, radius + 2, context.temp_allocator)
	total: f32
	for i in 0 ..= radius {
		w[i] = math.exp(-f32(i * i) / (2 * s * s))
		total += i == 0 ? w[i] : 2 * w[i]
	}
	for i in 0 ..= radius { w[i] /= total }
	n := 0
	put :: proc(out: ^[MAX_BLUR_TAPS / 2][4]f32, n: ^int, off, wt: f32) {
		k := n^
		if k % 2 == 0 { out[k / 2].x, out[k / 2].y = off, wt } else { out[k / 2].z, out[k / 2].w = off, wt }
		n^ += 1
	}
	put(out, &n, 0, w[0])
	for i := 1; i <= radius && n < MAX_BLUR_TAPS; i += 2 {
		a, b := w[i], w[i + 1]   // w[radius + 1] = 0
		put(out, &n, (f32(i) * a + f32(i + 1) * b) / (a + b), a + b)
	}
	return n
}
