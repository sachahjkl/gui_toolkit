package tk_h264

// Screen pixels to the 4:2:0 planes encoders take: NV12 (VA-API, Media Foundation: the luma, then Cb and Cr interleaved)
// and I420 (openh264: the luma, Cb, Cr). BT.709 in the limited range (16 ..= 235, 16 ..= 240), what players assume for
// HD video and what the SPS says. Each chroma sample is the mean of its 2 x 2 pixels. Odd sides: the last column or row
// counts twice (even_size).

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
