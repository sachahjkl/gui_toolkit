package render

import "base:intrinsics"
import "core:simd"

// Rows of texels read back from the GPU, made the pixels a program gets: 4 texels (one SSE or NEON register) at once.

// How a texel read back lies in memory.
@(private)
Texel_Layout :: enum u8 {
	RGBA8,
	BGRA8,
	Half,   // four f16, R first
}

@(private = "file") Texels :: #simd[16]u8
@(private = "file") TEXELS :: 4   // texels of 4 bytes in a register

@(private = "file")
load :: #force_inline proc "contextless" (p: [^]u8, texel: int) -> Texels { return intrinsics.unaligned_load((^Texels)(&p[texel * 4])) }

@(private = "file")
store :: #force_inline proc "contextless" (p: [^]u8, texel: int, v: Texels) { intrinsics.unaligned_store((^Texels)(&p[texel * 4]), v) }

// Bytes 0 and 2 of each texel exchanged: BGRA from RGBA, RGBA from BGRA.
@(private = "file")
red_blue_swapped :: #force_inline proc "contextless" (v: Texels) -> Texels {
	return simd.shuffle(v, v, 2, 1, 0, 3, 6, 5, 4, 7, 10, 9, 8, 11, 14, 13, 12, 15)
}

// `n` texels of 4 bytes from `src` to `dst` (not overlapping), bytes 0 and 2 of each exchanged.
@(private)
swap_red_blue :: proc "contextless" (dst, src: [^]u8, n: int) #no_bounds_check {
	i := 0
	for ; i + TEXELS <= n; i += TEXELS { store(dst, i, red_blue_swapped(load(src, i))) }
	for ; i < n; i += 1 {
		s, d := src[i * 4:], dst[i * 4:]
		d[0], d[1], d[2], d[3] = s[2], s[1], s[0], s[3]
	}
}

// `n` premultiplied texels of a target in `space` as straight sRGB RGBA8: straight_srgb of each. An opaque texel of sRGB
// bytes is its own bytes: where 4 in a row are opaque they are moved as they are.
@(private)
straight_srgb_row :: proc(dst, src: [^]u8, n: int, layout: Texel_Layout, space: Blend_Space) #no_bounds_check {
	one :: #force_inline proc(dst, src: [^]u8, i: int, layout: Texel_Layout, space: Blend_Space) #no_bounds_check {
		px: [4]f32
		switch layout {
		case .Half:
			h := ([^]u16)(src)
			for k in 0 ..< 4 { px[k] = f32(transmute(f16)h[i * 4 + k]) }
		case .BGRA8:
			s := src[i * 4:]
			px = {f32(s[2]) / 255, f32(s[1]) / 255, f32(s[0]) / 255, f32(s[3]) / 255}
		case .RGBA8:
			s := src[i * 4:]
			px = {f32(s[0]) / 255, f32(s[1]) / 255, f32(s[2]) / 255, f32(s[3]) / 255}
		}
		d := dst[i * 4:]
		d[0], d[1], d[2], d[3] = straight_srgb(px, space)
	}
	OPAQUE :: 0xFF00_0000
	as_they_are := layout != .Half && space == .Srgb
	i := 0
	for ; as_they_are && i + TEXELS <= n; i += TEXELS {
		v := load(src, i)
		if simd.reduce_and(transmute(#simd[TEXELS]u32)v) & OPAQUE == OPAQUE {
			store(dst, i, layout == .BGRA8 ? red_blue_swapped(v) : v)
		} else {
			for k in 0 ..< TEXELS { one(dst, src, i + k, layout, space) }
		}
	}
	for ; i < n; i += 1 { one(dst, src, i, layout, space) }
}
