package tk_png

import "core:encoding/endian"
import "core:testing"
import "../flate"

// PNG colour types (IHDR).
@(private = "file") GREY :: 0
@(private = "file") RGB :: 2
@(private = "file") PALETTE :: 3
@(private = "file") GREY_ALPHA :: 4

// A PNG file of any colour type and bit depth, built by hand: each row after a None filter byte, one IDAT. What other
// programs write, to read back.
@(private = "file")
other_png :: proc(width, height, color_type, depth: int, rows: []u8, plte: []u8 = nil, trns: []u8 = nil) -> []u8 {
	stride := len(rows) / height
	raw := make([dynamic]u8, context.temp_allocator)
	for y in 0 ..< height {
		append(&raw, 0)
		append(&raw, ..rows[y * stride:][:stride])
	}
	buf := make([dynamic]u8, context.temp_allocator)
	signature := SIGNATURE
	append(&buf, ..signature[:])
	ihdr: [IHDR_BYTES]u8
	endian.put_u32(ihdr[0:], .Big, u32(width))
	endian.put_u32(ihdr[4:], .Big, u32(height))
	ihdr[8], ihdr[9] = u8(depth), u8(color_type)
	chunk(&buf, "IHDR", ihdr[:])
	if plte != nil { chunk(&buf, "PLTE", plte) }
	if trns != nil { chunk(&buf, "tRNS", trns) }
	chunk(&buf, "IDAT", flate.deflate(.Zlib, raw[:], context.temp_allocator))
	chunk(&buf, "IEND", nil)
	return buf[:]
}

@(private = "file")
expect_pixels :: proc(t: ^testing.T, data: []u8, width, height: int, want: []u8, loc := #caller_location) {
	rgba, w, h, ok := decode(data, context.temp_allocator)
	testing.expect(t, ok, "decodes", loc = loc)
	testing.expect_value(t, [2]int{w, h}, [2]int{width, height}, loc = loc)
	testing.expectf(t, string(rgba) == string(want), "pixels %v, want %v", rgba, want, loc = loc)
}

// Both levels write a file that reads back to the same pixels, alpha untouched (straight, not premultiplied).
@(test)
both_levels_read_back :: proc(t: ^testing.T) {
	px := []u8{
		255, 0, 0, 255,   0, 255, 0, 128,   0, 0, 255, 0,
		10, 20, 30, 255,  10, 20, 30, 255,  200, 100, 50, 1,
	}
	for level in Compression {
		data := encode(px, 3, 2, level, context.temp_allocator)
		testing.expect(t, len(data) > 8 && string(data[1:4]) == "PNG", "a PNG file")
		expect_pixels(t, data, 3, 2, px)
	}
	testing.expect(t, encode(px, 0, 2) == nil, "an empty size")
	testing.expect(t, encode(px[:8], 3, 2) == nil, "fewer pixels than the size")
}

// A picture of what an interface holds (flat areas, rows like the last, gradients, noise), pixel for pixel, at sizes either
// side of the row distance deflate's 32 KiB window allows. The small level is the smaller file.
@(test)
a_large_picture_reads_back :: proc(t: ^testing.T) {
	for size in ([?][2]int{{1, 1}, {2310, 1505}, {9000, 40}}) {
		w, h := size.x, size.y
		px := make([]u8, w * h * 4)
		defer delete(px)
		seed: u32 = 12345
		for y in 0 ..< h {
			for x in 0 ..< w {
				p := px[(y * w + x) * 4:][:4]
				switch {
				case y % 200 < 100 && x < w / 2: p[0], p[1], p[2], p[3] = 20, 22, 24, 255
				case y % 200 < 100:              p[0], p[1], p[2], p[3] = u8(x), u8(x >> 8), 90, 255
				case y % 200 < 150:              p[0], p[1], p[2], p[3] = u8(x % 7 * 30), u8(x % 5 * 40), u8(y / 10), 255
				case:
					seed = seed * 1664525 + 1013904223
					p[0], p[1], p[2], p[3] = u8(seed >> 24), u8(seed >> 16), u8(seed >> 8), u8(seed)
				}
			}
		}
		fast := encode(px, w, h, .Fast)
		defer delete(fast)
		small := encode(px, w, h, .Small)
		defer delete(small)
		for data in ([2][]u8{fast, small}) {
			rgba, dw, dh, ok := decode(data)
			testing.expectf(t, ok && dw == w && dh == h, "%v decodes", size)
			testing.expectf(t, string(rgba) == string(px), "%v: the same pixels", size)
			delete(rgba)
		}
		if w * h > 1 { testing.expectf(t, len(small) < len(fast), "%v: small %d bytes, fast %d", size, len(small), len(fast)) }
	}
}

// Every colour type and bit depth another program writes comes out as straight RGBA8.
@(test)
other_formats_read_as_rgba8 :: proc(t: ^testing.T) {
	// grey, 8 bits
	expect_pixels(t, other_png(2, 1, GREY, 8, {0, 200}), 2, 1, {0, 0, 0, 255, 200, 200, 200, 255})
	// grey, 1 bit: 1 0 1 0
	expect_pixels(t, other_png(4, 1, GREY, 1, {0b1010_0000}), 4, 1, {255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255})
	// grey and alpha, 8 bits
	expect_pixels(t, other_png(1, 1, GREY_ALPHA, 8, {90, 40}), 1, 1, {90, 90, 90, 40})
	// RGB, 16 bits: the nearest 8-bit value
	expect_pixels(t, other_png(1, 1, RGB, 16, {0xFF, 0xFF, 0x80, 0x80, 0x00, 0x7F}), 1, 1, {255, 128, 0, 255})
	// a palette with transparency (tRNS): the second colour half transparent, straight
	expect_pixels(t, other_png(2, 1, PALETTE, 8, {0, 1}, plte = {10, 20, 30, 200, 150, 100}, trns = {255, 128}), 2, 1, {10, 20, 30, 255, 200, 150, 100, 128})
}

@(test)
what_is_not_a_png_is_refused :: proc(t: ^testing.T) {
	_, _, _, ok := decode(nil)
	testing.expect(t, !ok, "nothing")
	_, _, _, ok = decode({0x89, 'P', 'N', 'G', 0, 0, 0, 0, 1})
	testing.expect(t, !ok, "a signature and junk")
	data := encode({1, 2, 3, 4}, 1, 1, .Small, context.temp_allocator)
	_, _, _, ok = decode(data[:len(data) - 20])
	testing.expect(t, !ok, "a file cut short")
}
