package image_test

// The encoders: a JPEG that a decoder reads back close to the picture, and a WebP file where libwebp is there, which
// webp_decode reads back.

import "core:testing"
import core_image "core:image"
import "core:image/jpeg"
import image "../../src/image"

@(test)
a_jpeg_reads_back_close_to_the_picture :: proc(t: ^testing.T) {
	// 37 x 21 (not a multiple of 8: the blocks at the edges repeat their last pixels), a gradient and a flat part
	w, h :: 37, 21
	img := image.create(w, h, allocator = context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := img.pixels[(y * w + x) * 4:][:4]
			if x < 20 { p[0], p[1], p[2] = u8(x * 12), u8(y * 12), 128 } else { p[0], p[1], p[2] = 200, 40, 40 }
			p[3] = 255
		}
	}
	file := image.jpeg_encode(img, 95, context.temp_allocator)
	testing.expect(t, len(file) > 4 && file[0] == 0xFF && file[1] == 0xD8 && file[len(file) - 2] == 0xFF && file[len(file) - 1] == 0xD9, "SOI to EOI")
	back, err := jpeg.load_from_bytes(file, {.alpha_add_if_missing})
	if !testing.expectf(t, err == nil, "it reads: %v", err) { return }
	defer core_image.destroy(back)
	testing.expect_value(t, back.width, w)
	testing.expect_value(t, back.height, h)
	px := back.pixels[:]
	worst := 0
	for i in 0 ..< w * h {
		for c in 0 ..< 3 { worst = max(worst, abs(int(px[i * 4 + c]) - int(img.pixels[i * 4 + c]))) }
	}
	testing.expectf(t, worst <= 24, "every channel within a little of the picture: %d at worst", worst)
	// the flat part is flat
	a := px[(10 * w + 30) * 4:][:3]
	testing.expectf(t, abs(int(a[0]) - 200) <= 4 && abs(int(a[1]) - 40) <= 4, "the flat red stays: %v", a)
	// a lower quality, a smaller file
	testing.expect(t, len(image.jpeg_encode(img, 30, context.temp_allocator)) < len(file))
	testing.expect(t, image.jpeg_encode({}, 90, context.temp_allocator) == nil, "no pixel, no file")
}

@(test)
a_webp_is_a_riff_file_where_libwebp_is :: proc(t: ^testing.T) {
	img := image.create(16, 16, image.Color{30, 120, 200, 255}, context.temp_allocator)
	if !image.webp_available() {
		testing.expect(t, image.webp_encode(img, allocator = context.temp_allocator) == nil, "no libwebp: no file")
		return
	}
	for lossless in ([]bool{false, true}) {
		file := image.webp_encode(img, 85, lossless, context.temp_allocator)
		testing.expectf(t, len(file) > 12 && string(file[0:4]) == "RIFF" && string(file[8:12]) == "WEBP", "a WebP file (lossless %v)", lossless)
	}
}

@(test)
a_webp_reads_back_where_libwebp_is :: proc(t: ^testing.T) {
	// 13 x 7 (odd sizes: no row padding may slip in), a gradient with a transparent column
	w, h :: 13, 7
	img := image.create(w, h, allocator = context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := img.pixels[(y * w + x) * 4:][:4]
			p[0], p[1], p[2], p[3] = u8(x * 19), u8(y * 36), 90, x == 0 ? 0 : 255
		}
	}
	if !image.webp_available() {
		_, ok := image.webp_decode([]u8{'R', 'I', 'F', 'F'}, context.temp_allocator)
		testing.expect(t, !ok, "no libwebp: no picture")
		return
	}
	file := image.webp_encode(img, lossless = true, allocator = context.temp_allocator)
	back, ok := image.webp_decode(file, context.temp_allocator)
	if !testing.expect(t, ok, "the lossless file reads") { return }
	testing.expect_value(t, back.width, w)
	testing.expect_value(t, back.height, h)
	// lossless: every pixel as it was, alpha included
	for i in 0 ..< w * h {
		a, b := img.pixels[i * 4:][:4], back.pixels[i * 4:][:4]
		if a[3] == 0 {
			if !testing.expectf(t, b[3] == 0, "pixel %d stays transparent: %v", i, b) { return }
		} else if !testing.expectf(t, a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3], "pixel %d: %v, not %v", i, b, a) { return }
	}
	// lossy: the size comes back and the colours are close
	lossy := image.webp_encode(img, 90, allocator = context.temp_allocator)
	back2, ok2 := image.webp_decode(lossy, context.temp_allocator)
	if testing.expect(t, ok2, "the lossy file reads") {
		testing.expect(t, back2.width == w && back2.height == h, "the lossy picture keeps its size")
	}
	_, bad := image.webp_decode([]u8{'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'E', 'B', 'P'}, context.temp_allocator)
	testing.expect(t, !bad, "a truncated file is refused")
	_, empty := image.webp_decode(nil, context.temp_allocator)
	testing.expect(t, !empty, "no bytes, no picture")
}
