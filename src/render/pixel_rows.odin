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

// A `size` picture of premultiplied texels of a target in `space` (rows `pitch` bytes apart) as straight sRGB RGBA8:
// straight_srgb of each. An opaque texel of bytes is its own bytes in an sRGB target, and each of its bytes through one
// table in a linear one: where 4 in a row are opaque they are made at once.
@(private)
straight_srgb_rows :: proc(dst, src: [^]u8, pitch: int, size: [2]int, layout: Texel_Layout, space: Blend_Space) #no_bounds_check {
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
	bytes := layout != .Half
	// what straight_srgb makes of a color byte of an opaque texel
	opaque: [256]u8
	if bytes && space != .Srgb {
		for &o, c in opaque {
			v := f32(c) / 255
			o, _, _, _ = straight_srgb({v, v, v, 1}, space)
		}
	}
	for y in 0 ..< size.y {
		from, to := src[y * pitch:], dst[y * size.x * 4:]
		i := 0
		for ; bytes && i + TEXELS <= size.x; i += TEXELS {
			v := load(from, i)
			if simd.reduce_and(transmute(#simd[TEXELS]u32)v) & OPAQUE != OPAQUE {
				for k in 0 ..< TEXELS { one(to, from, i + k, layout, space) }
				continue
			}
			if layout == .BGRA8 { v = red_blue_swapped(v) }
			if space != .Srgb {
				b := transmute([TEXELS * 4]u8)v
				for k in 0 ..< TEXELS { b[k * 4], b[k * 4 + 1], b[k * 4 + 2] = opaque[b[k * 4]], opaque[b[k * 4 + 1]], opaque[b[k * 4 + 2]] }
				v = transmute(Texels)b
			}
			store(to, i, v)
		}
		for ; i < size.x; i += 1 { one(to, from, i, layout, space) }
	}
}
