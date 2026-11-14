package image_test

// image.decode: a file is read by its first bytes, whatever its name: PNG pixel for pixel, JPEG close to its picture,
// BMP pixel for pixel, WebP where libwebp is there; what is no picture, or a picture cut short, is refused.

import "core:testing"
import core_image "core:image"
import "core:image/bmp"
import image "../../src/image"
import png "../../src/png"

@(private = "file")
decode_sample :: proc() -> image.Image {
	// 13 x 7: odd sizes (a JPEG's blocks and a BMP's rows padded to 4 bytes see their edges)
	w, h :: 13, 7
	img := image.create(w, h, allocator = context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := img.pixels[(y * w + x) * 4:][:4]
			p[0], p[1], p[2], p[3] = u8(x * 19), u8(y * 36), 90, 255
		}
	}
	return img
}

@(test)
the_format_comes_from_the_first_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, image.file_format([]u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'}), image.File_Format.Png)
	testing.expect_value(t, image.file_format([]u8{0xFF, 0xD8, 0xFF, 0xE0}), image.File_Format.Jpeg)
	testing.expect_value(t, image.file_format(transmute([]u8)string("RIFF\x00\x00\x00\x00WEBPVP8 ")), image.File_Format.Webp)
	testing.expect_value(t, image.file_format(transmute([]u8)string("BM\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")), image.File_Format.Bmp)
	testing.expect_value(t, image.file_format(transmute([]u8)string("GIF89a....")), image.File_Format.Unknown)
	testing.expect_value(t, image.file_format(nil), image.File_Format.Unknown)
}

@(test)
a_png_decodes_pixel_for_pixel :: proc(t: ^testing.T) {
	img := decode_sample()
	file := png.encode(img.pixels, img.width, img.height, .Fast, context.temp_allocator)
	back, format, ok := image.decode(file, context.temp_allocator)
	if !testing.expect(t, ok, "it reads") { return }
	testing.expect_value(t, format, image.File_Format.Png)
	testing.expect_value(t, back.width, img.width)
	testing.expect_value(t, back.height, img.height)
	testing.expect(t, string(back.pixels) == string(img.pixels), "the same pixels")
}

@(test)
a_jpeg_decodes_close_to_its_picture :: proc(t: ^testing.T) {
	img := decode_sample()
	file := image.jpeg_encode(img, 95, context.temp_allocator)
	back, format, ok := image.decode(file, context.temp_allocator)
	if !testing.expect(t, ok, "it reads") { return }
	testing.expect_value(t, format, image.File_Format.Jpeg)
	testing.expect_value(t, back.width, img.width)
	testing.expect_value(t, back.height, img.height)
	worst := 0
	for v, i in back.pixels { worst = max(worst, abs(int(v) - int(img.pixels[i]))) }
	testing.expectf(t, worst <= 24, "close to the picture (the largest difference: %d)", worst)
}

@(test)
a_bmp_decodes_pixel_for_pixel :: proc(t: ^testing.T) {
	img := decode_sample()
	// (the file written by the Odin core's own encoder, three channels: the decoder adds the alpha)
	rgb := core_image.Image{width = img.width, height = img.height, channels = 3, depth = 8}
	rgb.pixels = make([dynamic]u8, img.width * img.height * 3, context.temp_allocator)
	for i in 0 ..< img.width * img.height { copy(rgb.pixels[i * 3:][:3], img.pixels[i * 4:][:3]) }
	file := make([dynamic]u8, context.temp_allocator)
	if err := bmp.save_to_buffer(&file, &rgb, {}, context.temp_allocator); !testing.expectf(t, err == nil, "the BMP is written: %v", err) { return }
	back, format, ok := image.decode(file[:], context.temp_allocator)
	if !testing.expect(t, ok, "it reads") { return }
	testing.expect_value(t, format, image.File_Format.Bmp)
	testing.expect_value(t, back.width, img.width)
	testing.expect_value(t, back.height, img.height)
	testing.expect(t, string(back.pixels) == string(img.pixels), "the same pixels, the rows in their order")
}

@(test)
a_webp_decodes_where_libwebp_is :: proc(t: ^testing.T) {
	if !image.webp_available() { return }
	img := decode_sample()
	file := image.webp_encode(img, lossless = true, allocator = context.temp_allocator)
	back, format, ok := image.decode(file, context.temp_allocator)
	if !testing.expect(t, ok, "it reads") { return }
	testing.expect_value(t, format, image.File_Format.Webp)
	testing.expect(t, string(back.pixels) == string(img.pixels), "lossless: the same pixels")
}

@(test)
what_is_no_picture_is_refused :: proc(t: ^testing.T) {
	_, format, ok := image.decode(transmute([]u8)string("GIF89a, not read"), context.temp_allocator)
	testing.expect(t, !ok && format == .Unknown, "an unknown format")
	img := decode_sample()
	file := png.encode(img.pixels, img.width, img.height, .Fast, context.temp_allocator)
	_, format, ok = image.decode(file[:len(file) / 2], context.temp_allocator)
	testing.expect(t, !ok && format == .Png, "a PNG cut short: its format known, no picture")
	jfile := image.jpeg_encode(img, 90, context.temp_allocator)
	_, _, ok = image.decode(jfile[:12], context.temp_allocator)
	testing.expect(t, !ok, "a JPEG cut in its header")
}
