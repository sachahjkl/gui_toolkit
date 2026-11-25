package tk_h264

// Screen pixels to the 4:2:0 planes encoders take: NV12 (VA-API, Media Foundation: the luma, then Cb and Cr interleaved)
// and I420 (openh264: the luma, Cb, Cr). BT.709 in the limited range (16 ..= 235, 16 ..= 240), what players assume for
// HD video and what the SPS says. Each chroma sample is the mean of its 2 x 2 pixels. Odd sides: the last column or row
// counts twice (even_size).

import "base:intrinsics"
import "core:simd"

// Fixed point, 16 bits: the BT.709 matrix scaled to 219 / 255 (luma) and 224 / 255 (chroma). Each chroma row sums to 0,
// so a grey is exactly 128.
@(private) Y_R :: 11966
@(private) Y_G :: 40254
@(private) Y_B :: 4064
@(private) CB_R :: -6596
@(private) CB_G :: -22189
@(private) CB_B :: 28785
@(private) CR_R :: 28785
@(private) CR_G :: -26145
@(private) CR_B :: -2640

// Luma coefficients are even, so halving them fits every fixed-point weight in i16 for 16x16->32 multiply-add
// while keeping ((2*S) >> 16) == (S >> 15) bit-identical for all 8-bit inputs.
@(private = "file") Y_R_HALF :: Y_R / 2
@(private = "file") Y_G_HALF :: Y_G / 2
@(private = "file") Y_B_HALF :: Y_B / 2
@(private = "file") Y_BIAS :: (16 << 15) + (1 << 14)
@(private = "file") C_BIAS :: (128 << 18) + (1 << 17)

#assert(Y_R % 2 == 0 && Y_G % 2 == 0 && Y_B % 2 == 0)
#assert(Y_R_HALF <= int(max(i16)) && Y_G_HALF <= int(max(i16)) && Y_B_HALF <= int(max(i16)))
#assert(CB_R >= int(min(i16)) && CB_R <= int(max(i16)))
#assert(CB_G >= int(min(i16)) && CB_G <= int(max(i16)))
#assert(CB_B >= int(min(i16)) && CB_B <= int(max(i16)))
#assert(CR_R >= int(min(i16)) && CR_R <= int(max(i16)))
#assert(CR_G >= int(min(i16)) && CR_G <= int(max(i16)))
#assert(CR_B >= int(min(i16)) && CR_B <= int(max(i16)))

// The luma of one pixel.
@(private)
luma_of :: #force_inline proc "contextless" (r, g, b: i32) -> u8 {
	return u8(16 + ((Y_R * r + Y_G * g + Y_B * b + 1 << 15) >> 16))
}

// The chroma of the sums of four pixels' channels.
@(private)
chroma_of :: #force_inline proc "contextless" (r4, g4, b4: i32) -> (cb, cr: u8) {
	cb = u8(128 + ((CB_R * r4 + CB_G * g4 + CB_B * b4 + 1 << 17) >> 18))
	cr = u8(128 + ((CR_R * r4 + CR_G * g4 + CR_B * b4 + 1 << 17) >> 18))
	return
}

// `frame` as NV12 in planes of even_size: `luma` (`luma_stride` a row) and `chroma` (Cb Cr pairs, `chroma_stride` a
// row, half the rows). The planes must hold that size.
to_nv12 :: proc(frame: Frame, luma: []u8, luma_stride: int, chroma: []u8, chroma_stride: int) {
	convert(frame, luma, luma_stride, chroma, chroma[1:], chroma_stride, 2)
}

// `frame` as I420 in planes of even_size: `luma`, then `cb` and `cr` (half the width and the rows).
to_i420 :: proc(frame: Frame, luma: []u8, luma_stride: int, cb: []u8, cr: []u8, chroma_stride: int) {
	convert(frame, luma, luma_stride, cb, cr, chroma_stride, 1)
}

// One pass for both layouts: the chroma samples are `step` bytes apart in `cb` and in `cr`.
@(private)
convert :: proc(frame: Frame, luma: []u8, luma_stride: int, cb, cr: []u8, chroma_stride: int, step: int) {
	if frame.width <= 0 || frame.height <= 0 { return }
	when ODIN_ENDIAN == .Little && simd.HAS_HARDWARE_SIMD {
		is_nv12 := step == 2 && uintptr(raw_data(cr)) == uintptr(raw_data(cb)) + 1
		is_i420 := step == 1
		if (is_nv12 || is_i420) && slices_fit(frame, luma, luma_stride, cb, cr, chroma_stride, step) {
			when ODIN_ARCH == .amd64 {
				if frame.width >= 16 && has_avx2() {
					if frame.format == .RGBA {
						if is_nv12 {
							convert_avx2(frame, luma, luma_stride, cb, cr, chroma_stride, true, true)
						} else {
							convert_avx2(frame, luma, luma_stride, cb, cr, chroma_stride, true, false)
						}
					} else {
						if is_nv12 {
							convert_avx2(frame, luma, luma_stride, cb, cr, chroma_stride, false, true)
						} else {
							convert_avx2(frame, luma, luma_stride, cb, cr, chroma_stride, false, false)
						}
					}
					return
				}
			}
			if frame.width >= 8 {
				if frame.format == .RGBA {
					if is_nv12 {
						convert_128(frame, luma, luma_stride, cb, cr, chroma_stride, true, true)
					} else {
						convert_128(frame, luma, luma_stride, cb, cr, chroma_stride, true, false)
					}
				} else {
					if is_nv12 {
						convert_128(frame, luma, luma_stride, cb, cr, chroma_stride, false, true)
					} else {
						convert_128(frame, luma, luma_stride, cb, cr, chroma_stride, false, false)
					}
				}
				return
			}
		}
	}
	convert_scalar(frame, luma, luma_stride, cb, cr, chroma_stride, step)
}

// Verify all row pointers stay inside their slices once per frame so the SIMD row loop needs no per-row bounds calls.
@(private = "file")
slices_fit :: #force_inline proc(
	frame: Frame, luma: []u8, luma_stride: int, cb, cr: []u8, chroma_stride: int, step: int,
) -> bool {
	if frame.width <= 0 || frame.height <= 0 { return false }
	width, height := even_size(frame.width, frame.height)
	if frame.stride < 0 || luma_stride < width || chroma_stride < 0 { return false }
	if height > 2 && chroma_stride < (width / 2) * step { return false }
	if len(frame.pixels) < (frame.height - 1) * frame.stride + frame.width * 4 { return false }
	if len(luma) < (height - 1) * luma_stride + width { return false }
	last_chroma := (height / 2 - 1) * chroma_stride + (width / 2 - 1) * step
	return last_chroma >= 0 && last_chroma < len(cb) && last_chroma < len(cr)
}

@(private = "file")
convert_scalar :: proc(frame: Frame, luma: []u8, luma_stride: int, cb, cr: []u8, chroma_stride: int, step: int) {
	r_at, b_at := 2, 0
	if frame.format == .RGBA { r_at, b_at = 0, 2 }
	width, height := even_size(frame.width, frame.height)
	last_x, last_y := frame.width - 1, frame.height - 1
	for y := 0; y < height; y += 2 {
		row0 := frame.pixels[min(y, last_y) * frame.stride:]
		row1 := frame.pixels[min(y + 1, last_y) * frame.stride:]
		out0 := luma[y * luma_stride:]
		out1 := luma[(y + 1) * luma_stride:]
		chroma_row := (y / 2) * chroma_stride
		for x := 0; x < width; x += 2 {
			p0 := min(x, last_x) * 4
			p1 := min(x + 1, last_x) * 4
			r00, g00, b00 := i32(row0[p0 + r_at]), i32(row0[p0 + 1]), i32(row0[p0 + b_at])
			r01, g01, b01 := i32(row0[p1 + r_at]), i32(row0[p1 + 1]), i32(row0[p1 + b_at])
			r10, g10, b10 := i32(row1[p0 + r_at]), i32(row1[p0 + 1]), i32(row1[p0 + b_at])
			r11, g11, b11 := i32(row1[p1 + r_at]), i32(row1[p1 + 1]), i32(row1[p1 + b_at])
			out0[x] = luma_of(r00, g00, b00)
			out0[x + 1] = luma_of(r01, g01, b01)
			out1[x] = luma_of(r10, g10, b10)
			out1[x + 1] = luma_of(r11, g11, b11)
			u, v := chroma_of(r00 + r01 + r10 + r11, g00 + g01 + g10 + g11, b00 + b01 + b10 + b11)
			at := chroma_row + (x / 2) * step
			cb[at] = u
			cr[at] = v
		}
	}
}

// Scalar tail for remaining pairs of columns, including odd-width column duplication; caller checked slices_fit.
@(private = "file")
convert_tail_ptr :: #force_inline proc "contextless" (
	row0, row1, out0, out1, cb, cr: [^]u8,
	start_x, width, last_x, r_at, b_at, step: int,
) {
	for x := start_x; x < width; x += 2 {
		p0 := min(x, last_x) * 4
		p1 := min(x + 1, last_x) * 4
		r00, g00, b00 := i32(row0[p0 + r_at]), i32(row0[p0 + 1]), i32(row0[p0 + b_at])
		r01, g01, b01 := i32(row0[p1 + r_at]), i32(row0[p1 + 1]), i32(row0[p1 + b_at])
		r10, g10, b10 := i32(row1[p0 + r_at]), i32(row1[p0 + 1]), i32(row1[p0 + b_at])
		r11, g11, b11 := i32(row1[p1 + r_at]), i32(row1[p1 + 1]), i32(row1[p1 + b_at])
		out0[x] = luma_of(r00, g00, b00)
		out0[x + 1] = luma_of(r01, g01, b01)
		out1[x] = luma_of(r10, g10, b10)
		out1[x + 1] = luma_of(r11, g11, b11)
		u, v := chroma_of(r00 + r01 + r10 + r11, g00 + g01 + g10 + g11, b00 + b01 + b10 + b11)
		at := (x / 2) * step
		cb[at] = u
		cr[at] = v
	}
}

@(private = "file") u8x8 :: #simd[8]u8
@(private = "file") i16x4 :: #simd[4]i16

// Signed 16x16 -> 32 multiply-add of adjacent lane pairs: out[i] = a[2i]*b[2i] + a[2i+1]*b[2i+1].
@(private = "file")
madd_i16x8 :: #force_inline proc "contextless" (a, b: simd.i16x8) -> simd.i32x4 {
	return simd.sums_of_n(simd.i32x8(a) * simd.i32x8(b), 2)
}

// Portable 128-bit SIMD path: 8 pixels per row pair (16 pixels per iteration), baseline SSE2 on amd64 and NEON on arm64.
@(private = "file")
convert_128 :: proc(frame: Frame, luma: []u8, luma_stride: int, cb, cr: []u8, chroma_stride: int, $IS_RGBA, $IS_NV12: bool) {
	R_AT :: 0 when IS_RGBA else 2
	B_AT :: 2 when IS_RGBA else 0
	STEP :: 2 when IS_NV12 else 1

	K_Y0 :: i16(Y_R_HALF) when IS_RGBA else i16(Y_B_HALF)
	K_Y2 :: i16(Y_B_HALF) when IS_RGBA else i16(Y_R_HALF)
	K_CB0 :: i16(CB_R) when IS_RGBA else i16(CB_B)
	K_CB2 :: i16(CB_B) when IS_RGBA else i16(CB_R)
	K_CR0 :: i16(CR_R) when IS_RGBA else i16(CR_B)
	K_CR2 :: i16(CR_B) when IS_RGBA else i16(CR_R)

	k_y_br := simd.i16x8{K_Y0, K_Y2, K_Y0, K_Y2, K_Y0, K_Y2, K_Y0, K_Y2}
	k_y_g := simd.i32x4(Y_G_HALF)
	k_cb_br := simd.i16x8{K_CB0, K_CB2, K_CB0, K_CB2, K_CB0, K_CB2, K_CB0, K_CB2}
	k_cb_g := simd.i32x4(CB_G)
	k_cr_br := simd.i16x8{K_CR0, K_CR2, K_CR0, K_CR2, K_CR0, K_CR2, K_CR0, K_CR2}
	k_cr_g := simd.i32x4(CR_G)

	mask_ff_16 := simd.u16x8(0x00FF)
	mask_ff_32 := simd.u32x4(0x0000_00FF)
	sh8_32 := simd.u32x4(8)
	y_bias := simd.i32x4(Y_BIAS)
	c_bias := simd.i32x4(C_BIAS)
	sh15 := simd.u32x4(15)
	sh18 := simd.u32x4(18)

	width, height := even_size(frame.width, frame.height)
	last_x, last_y := frame.width - 1, frame.height - 1
	vec_limit := frame.width &~ 7

	pixels_base := raw_data(frame.pixels)
	luma_base := raw_data(luma)
	cb_base := raw_data(cb)
	cr_base := raw_data(cr)

	for y := 0; y < height; y += 2 {
		row0_p := pixels_base[min(y, last_y) * frame.stride:]
		row1_p := pixels_base[min(y + 1, last_y) * frame.stride:]
		out0_p := luma_base[y * luma_stride:]
		out1_p := luma_base[(y + 1) * luma_stride:]
		chroma_off := (y / 2) * chroma_stride
		cb_p := cb_base[chroma_off:]
		cr_p := cr_base[chroma_off:]

		x := 0
		for ; x < vec_limit; x += 8 {
			px := x * 4
			p0a := intrinsics.unaligned_load((^simd.u16x8)(&row0_p[px]))
			p0b := intrinsics.unaligned_load((^simd.u16x8)(&row0_p[px + 16]))
			p1a := intrinsics.unaligned_load((^simd.u16x8)(&row1_p[px]))
			p1b := intrinsics.unaligned_load((^simd.u16x8)(&row1_p[px + 16]))

			// Each pixel occupies two little-endian u16 lanes: low bytes hold [B, R] (or [R, B]); byte 1 holds G.
			br0a := transmute(simd.i16x8)(p0a & mask_ff_16)
			g0a := transmute(simd.i32x4)(simd.shr_masked(transmute(simd.u32x4)p0a, sh8_32) & mask_ff_32)
			br0b := transmute(simd.i16x8)(p0b & mask_ff_16)
			g0b := transmute(simd.i32x4)(simd.shr_masked(transmute(simd.u32x4)p0b, sh8_32) & mask_ff_32)

			y0a := simd.shr_masked(transmute(simd.u32x4)(madd_i16x8(br0a, k_y_br) + g0a * k_y_g + y_bias), sh15)
			y0b := simd.shr_masked(transmute(simd.u32x4)(madd_i16x8(br0b, k_y_br) + g0b * k_y_g + y_bias), sh15)
			y0 := u8x8(simd.shuffle(y0a, y0b, 0, 1, 2, 3, 4, 5, 6, 7))
			intrinsics.unaligned_store((^u8x8)(&out0_p[x]), y0)

			br1a := transmute(simd.i16x8)(p1a & mask_ff_16)
			g1a := transmute(simd.i32x4)(simd.shr_masked(transmute(simd.u32x4)p1a, sh8_32) & mask_ff_32)
			br1b := transmute(simd.i16x8)(p1b & mask_ff_16)
			g1b := transmute(simd.i32x4)(simd.shr_masked(transmute(simd.u32x4)p1b, sh8_32) & mask_ff_32)

			y1a := simd.shr_masked(transmute(simd.u32x4)(madd_i16x8(br1a, k_y_br) + g1a * k_y_g + y_bias), sh15)
			y1b := simd.shr_masked(transmute(simd.u32x4)(madd_i16x8(br1b, k_y_br) + g1b * k_y_g + y_bias), sh15)
			y1 := u8x8(simd.shuffle(y1a, y1b, 0, 1, 2, 3, 4, 5, 6, 7))
			intrinsics.unaligned_store((^u8x8)(&out1_p[x]), y1)

			// Sum 2x2 pixel blocks vertically then horizontally (each pixel's two channels fit in one u32 lane).
			br_va := transmute(simd.u32x4)(br0a + br1a)
			br_vb := transmute(simd.u32x4)(br0b + br1b)
			br_4 := transmute(simd.i16x8)simd.shuffle(br_va, br_vb, 0, 2, 4, 6) + transmute(simd.i16x8)simd.shuffle(br_va, br_vb, 1, 3, 5, 7)

			g_va := g0a + g1a
			g_vb := g0b + g1b
			// g_4 is in 0..=1020; narrowing through i16 lets SSE2/NEON lower the chroma multiply to pmaddwd/smull.
			g_4 := simd.i32x4(i16x4(simd.shuffle(g_va, g_vb, 0, 2, 4, 6) + simd.shuffle(g_va, g_vb, 1, 3, 5, 7)))

			u4 := simd.shr_masked(transmute(simd.u32x4)(madd_i16x8(br_4, k_cb_br) + g_4 * k_cb_g + c_bias), sh18)
			v4 := simd.shr_masked(transmute(simd.u32x4)(madd_i16x8(br_4, k_cr_br) + g_4 * k_cr_g + c_bias), sh18)

			when IS_NV12 {
				uv := u8x8(simd.interleave(u4, v4))
				intrinsics.unaligned_store((^u8x8)(&cb_p[x]), uv)
			} else {
				uv := transmute([2]u32)u8x8(simd.shuffle(u4, v4, 0, 1, 2, 3, 4, 5, 6, 7))
				intrinsics.unaligned_store((^u32)(&cb_p[x / 2]), uv[0])
				intrinsics.unaligned_store((^u32)(&cr_p[x / 2]), uv[1])
			}
		}

		if x < width {
			convert_tail_ptr(row0_p, row1_p, out0_p, out1_p, cb_p, cr_p, x, width, last_x, R_AT, B_AT, STEP)
		}
	}
}

when ODIN_ARCH == .amd64 {
	@(private = "file") DISABLE_AVX2 :: #config(GT_H264_NO_AVX2, false)

	@(private = "file")
	has_avx2 :: proc "contextless" () -> bool {
		when DISABLE_AVX2 {
			return false
		} else when intrinsics.has_target_feature("avx2") {
			return true
		} else when ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
			return false
		} else {
			max_id, _, _, _ := intrinsics.x86_cpuid(0, 0)
			if max_id < 7 { return false }
			_, _, ecx1, _ := intrinsics.x86_cpuid(1, 0)
			// Require both XSAVE (bit 26) and OSXSAVE (bit 27) before calling XGETBV.
			if (ecx1 & ((1 << 26) | (1 << 27))) != ((1 << 26) | (1 << 27)) { return false }
			xcr0, _ := intrinsics.x86_xgetbv(0)
			// OS must save both XMM (bit 1) and YMM (bit 2) register state.
			if (xcr0 & 0b110) != 0b110 { return false }
			_, ebx7, _, _ := intrinsics.x86_cpuid(7, 0)
			return (ebx7 & (1 << 5)) != 0
		}
	}

	@(private = "file", enable_target_feature = "avx2")
	madd_i16x16 :: #force_inline proc "contextless" (a, b: simd.i16x16) -> simd.i32x8 {
		return simd.sums_of_n(simd.i32x16(a) * simd.i32x16(b), 2)
	}

	// Runtime-dispatched AVX2 path: 16 pixels per row pair (32 pixels per iteration).
	@(private = "file", enable_target_feature = "avx2")
	convert_avx2 :: proc(frame: Frame, luma: []u8, luma_stride: int, cb, cr: []u8, chroma_stride: int, $IS_RGBA, $IS_NV12: bool) {
		R_AT :: 0 when IS_RGBA else 2
		B_AT :: 2 when IS_RGBA else 0
		STEP :: 2 when IS_NV12 else 1

		K_Y0 :: i16(Y_R_HALF) when IS_RGBA else i16(Y_B_HALF)
		K_Y2 :: i16(Y_B_HALF) when IS_RGBA else i16(Y_R_HALF)
		K_CB0 :: i16(CB_R) when IS_RGBA else i16(CB_B)
		K_CB2 :: i16(CB_B) when IS_RGBA else i16(CB_R)
		K_CR0 :: i16(CR_R) when IS_RGBA else i16(CR_B)
		K_CR2 :: i16(CR_B) when IS_RGBA else i16(CR_R)

		k_y_br := simd.i16x16{K_Y0, K_Y2, K_Y0, K_Y2, K_Y0, K_Y2, K_Y0, K_Y2, K_Y0, K_Y2, K_Y0, K_Y2, K_Y0, K_Y2, K_Y0, K_Y2}
		k_y_g := simd.i32x8(Y_G_HALF)
		k_cb_br := simd.i16x16{K_CB0, K_CB2, K_CB0, K_CB2, K_CB0, K_CB2, K_CB0, K_CB2, K_CB0, K_CB2, K_CB0, K_CB2, K_CB0, K_CB2, K_CB0, K_CB2}
		k_cb_g := simd.i32x8(CB_G)
		k_cr_br := simd.i16x16{K_CR0, K_CR2, K_CR0, K_CR2, K_CR0, K_CR2, K_CR0, K_CR2, K_CR0, K_CR2, K_CR0, K_CR2, K_CR0, K_CR2, K_CR0, K_CR2}
		k_cr_g := simd.i32x8(CR_G)

		mask_ff_16 := simd.u16x16(0x00FF)
		mask_ff_32 := simd.u32x8(0x0000_00FF)
		sh8_32 := simd.u32x8(8)
		y_bias := simd.i32x8(Y_BIAS)
		c_bias := simd.i32x8(C_BIAS)
		sh15 := simd.u32x8(15)
		sh18 := simd.u32x8(18)

		width, height := even_size(frame.width, frame.height)
		last_x, last_y := frame.width - 1, frame.height - 1
		vec_limit := frame.width &~ 15

		pixels_base := raw_data(frame.pixels)
		luma_base := raw_data(luma)
		cb_base := raw_data(cb)
		cr_base := raw_data(cr)

		for y := 0; y < height; y += 2 {
			row0_p := pixels_base[min(y, last_y) * frame.stride:]
			row1_p := pixels_base[min(y + 1, last_y) * frame.stride:]
			out0_p := luma_base[y * luma_stride:]
			out1_p := luma_base[(y + 1) * luma_stride:]
			chroma_off := (y / 2) * chroma_stride
			cb_p := cb_base[chroma_off:]
			cr_p := cr_base[chroma_off:]

			x := 0
			for ; x < vec_limit; x += 16 {
				px := x * 4
				p0a := intrinsics.unaligned_load((^simd.u16x16)(&row0_p[px]))
				p0b := intrinsics.unaligned_load((^simd.u16x16)(&row0_p[px + 32]))
				p1a := intrinsics.unaligned_load((^simd.u16x16)(&row1_p[px]))
				p1b := intrinsics.unaligned_load((^simd.u16x16)(&row1_p[px + 32]))

				br0a := transmute(simd.i16x16)(p0a & mask_ff_16)
				g0a := transmute(simd.i32x8)(simd.shr_masked(transmute(simd.u32x8)p0a, sh8_32) & mask_ff_32)
				br0b := transmute(simd.i16x16)(p0b & mask_ff_16)
				g0b := transmute(simd.i32x8)(simd.shr_masked(transmute(simd.u32x8)p0b, sh8_32) & mask_ff_32)

				y0a := simd.shr_masked(transmute(simd.u32x8)(madd_i16x16(br0a, k_y_br) + g0a * k_y_g + y_bias), sh15)
				y0b := simd.shr_masked(transmute(simd.u32x8)(madd_i16x16(br0b, k_y_br) + g0b * k_y_g + y_bias), sh15)
				y0 := simd.u8x16(simd.shuffle(y0a, y0b, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15))
				intrinsics.unaligned_store((^simd.u8x16)(&out0_p[x]), y0)

				br1a := transmute(simd.i16x16)(p1a & mask_ff_16)
				g1a := transmute(simd.i32x8)(simd.shr_masked(transmute(simd.u32x8)p1a, sh8_32) & mask_ff_32)
				br1b := transmute(simd.i16x16)(p1b & mask_ff_16)
				g1b := transmute(simd.i32x8)(simd.shr_masked(transmute(simd.u32x8)p1b, sh8_32) & mask_ff_32)

				y1a := simd.shr_masked(transmute(simd.u32x8)(madd_i16x16(br1a, k_y_br) + g1a * k_y_g + y_bias), sh15)
				y1b := simd.shr_masked(transmute(simd.u32x8)(madd_i16x16(br1b, k_y_br) + g1b * k_y_g + y_bias), sh15)
				y1 := simd.u8x16(simd.shuffle(y1a, y1b, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15))
				intrinsics.unaligned_store((^simd.u8x16)(&out1_p[x]), y1)

				// Keep the 2x2 horizontal shuffle in-lane on AVX2 (blocks [0, 1, 4, 5 | 2, 3, 6, 7]) and fix order after narrowing.
				br_va := transmute(simd.u32x8)(br0a + br1a)
				br_vb := transmute(simd.u32x8)(br0b + br1b)
				br_4 := transmute(simd.i16x16)simd.shuffle(br_va, br_vb, 0, 2, 8, 10, 4, 6, 12, 14) +
					transmute(simd.i16x16)simd.shuffle(br_va, br_vb, 1, 3, 9, 11, 5, 7, 13, 15)

				g_va := g0a + g1a
				g_vb := g0b + g1b
				g_4 := simd.i32x8(simd.i16x8(
					simd.shuffle(g_va, g_vb, 0, 2, 8, 10, 4, 6, 12, 14) +
					simd.shuffle(g_va, g_vb, 1, 3, 9, 11, 5, 7, 13, 15),
				))

				u8_inlane := u8x8(simd.shr_masked(transmute(simd.u32x8)(madd_i16x16(br_4, k_cb_br) + g_4 * k_cb_g + c_bias), sh18))
				v8_inlane := u8x8(simd.shr_masked(transmute(simd.u32x8)(madd_i16x16(br_4, k_cr_br) + g_4 * k_cr_g + c_bias), sh18))
				u8_ord := simd.swizzle(u8_inlane, 0, 1, 4, 5, 2, 3, 6, 7)
				v8_ord := simd.swizzle(v8_inlane, 0, 1, 4, 5, 2, 3, 6, 7)

				when IS_NV12 {
					intrinsics.unaligned_store((^simd.u8x16)(&cb_p[x]), simd.interleave(u8_ord, v8_ord))
				} else {
					intrinsics.unaligned_store((^u8x8)(&cb_p[x / 2]), u8_ord)
					intrinsics.unaligned_store((^u8x8)(&cr_p[x / 2]), v8_ord)
				}
			}

			if x < width {
				convert_tail_ptr(row0_p, row1_p, out0_p, out1_p, cb_p, cr_p, x, width, last_x, R_AT, B_AT, STEP)
			}
		}
	}
}
