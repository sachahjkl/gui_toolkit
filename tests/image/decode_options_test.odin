package image_test

// image.decode's options: the EXIF orientation applied (each of the eight, every pixel where the tag puts it), the size
// read from the header before any allocation and the limits it is held to, the gate that admits large decodes within a
// budget, and the native JPEG decoder (tools/run_tests passes -define:IMAGE_JPEG=true) whole and at 1/2, 1/4, 1/8.

import "core:hash"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import exif "gt:exif"
import image "gt:image"
import png "gt:png"

// 16 x 16 of rgb(200, 60, 30), CMYK, as ImageMagick writes it (magick -size 16x16 'xc:rgb(200,60,30)' -colorspace CMYK
// -strip -quality 95): its Adobe segment says the inks are stored inverted.
@(private = "file", rodata)
CMYK_FLAT := [?]u8{
	0xFF, 0xD8, 0xFF, 0xEE, 0x00, 0x0E, 0x41, 0x64, 0x6F, 0x62, 0x65, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x02, 0xFF, 0xDB,
	0x00, 0x43, 0x00, 0x02, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02, 0x02, 0x04, 0x03,
	0x02, 0x02, 0x02, 0x02, 0x05, 0x04, 0x04, 0x03, 0x04, 0x06, 0x05, 0x06, 0x06, 0x06, 0x05, 0x06, 0x06, 0x06, 0x07, 0x09,
	0x08, 0x06, 0x07, 0x09, 0x07, 0x06, 0x06, 0x08, 0x0B, 0x08, 0x09, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x06, 0x08, 0x0B, 0x0C,
	0x0B, 0x0A, 0x0C, 0x09, 0x0A, 0x0A, 0x0A, 0xFF, 0xDB, 0x00, 0x43, 0x01, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x05, 0x03,
	0x03, 0x05, 0x0A, 0x07, 0x06, 0x07, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A,
	0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A,
	0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0xFF, 0xC0, 0x00, 0x14,
	0x08, 0x00, 0x10, 0x00, 0x10, 0x04, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0x04, 0x11, 0x00, 0xFF, 0xC4,
	0x00, 0x16, 0x00, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x03, 0x09, 0xFF, 0xC4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0xFF, 0xC4, 0x00, 0x16, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x09, 0xFF, 0xC4, 0x00, 0x14, 0x11, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xDA, 0x00, 0x0E, 0x04, 0x01, 0x00, 0x02, 0x11, 0x03,
	0x11, 0x04, 0x00, 0x00, 0x3F, 0x00, 0xA2, 0xC8, 0x64, 0x7B, 0x48, 0x00, 0x00, 0x00, 0x1F, 0xFF, 0xD9,
}

// A picture whose every pixel says where it is: red its column, green its row.
@(private = "file")
coded :: proc(w, h: int) -> image.Image {
	img := image.create(w, h, {0, 0, 0, 255}, context.temp_allocator)
	for y in 0 ..< h { for x in 0 ..< w {
		o := (y * w + x) * 4
		img.pixels[o], img.pixels[o + 1], img.pixels[o + 2] = u8(x * 40), u8(y * 60), 7
	} }
	return img
}

// A PNG of `img` with an eXIf chunk that says orientation `o` (before its pixels, as the format asks).
@(private = "file")
png_oriented :: proc(img: image.Image, o: int) -> []u8 {
	data := png.encode(img.pixels, img.width, img.height, allocator = context.temp_allocator)
	tiff := [?]u8{'M', 'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, u8(o), 0, 0, 0, 0, 0, 0}
	chunk := make([dynamic]u8, context.temp_allocator)
	n := len(tiff)
	append(&chunk, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n), 'e', 'X', 'I', 'f')
	append(&chunk, ..tiff[:])
	crc := hash.crc32(chunk[4:])
	append(&chunk, u8(crc >> 24), u8(crc >> 16), u8(crc >> 8), u8(crc))
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..data[:33])   // (the signature and IHDR)
	append(&out, ..chunk[:])
	append(&out, ..data[33:])
	return out[:]
}

// Each of the eight orientations shows the picture as EXIF says; without the option, as stored.
@(test)
every_orientation_shows_upright :: proc(t: ^testing.T) {
	w, h := 6, 4
	img := coded(w, h)
	for o in 1 ..= 8 {
		file := png_oriented(img, o)
		testing.expect_value(t, exif.orientation(file), o)
		stored, _, ok0 := image.decode(file, context.temp_allocator)
		testing.expect(t, ok0 && stored.width == w && string(stored.pixels) == string(img.pixels), "as stored without the option")
		p, _, ok := image.decode(file, context.temp_allocator, {orient = true})
		if !testing.expect(t, ok) { continue }
		lying := o >= 5
		testing.expect_value(t, [2]int{p.width, p.height}, lying ? [2]int{h, w} : [2]int{w, h})
		wrong := 0
		for y in 0 ..< p.height { for x in 0 ..< p.width {
			// (where the shown pixel x, y is in the stored picture)
			sx, sy: int
			switch o {
			case 1: sx, sy = x, y
			case 2: sx, sy = w - 1 - x, y
			case 3: sx, sy = w - 1 - x, h - 1 - y
			case 4: sx, sy = x, h - 1 - y
			case 5: sx, sy = y, x
			case 6: sx, sy = y, h - 1 - x
			case 7: sx, sy = w - 1 - y, h - 1 - x
			case 8: sx, sy = w - 1 - y, x
			}
			c := p.pixels[(y * p.width + x) * 4:][:4]
			if c[0] != u8(sx * 40) || c[1] != u8(sy * 60) { wrong += 1 }
		} }
		testing.expectf(t, wrong == 0, "orientation %d: %d pixels misplaced", o, wrong)
	}
}

// The header says the size before any pixel: each format's, and a picture past the limits is refused.
@(test)
the_size_comes_from_the_header :: proc(t: ^testing.T) {
	img := coded(13, 7)
	files := [?][]u8{
		png.encode(img.pixels, 13, 7, .Fast, context.temp_allocator),
		image.jpeg_encode(img, 90, context.temp_allocator),
	}
	for f in files {
		size, ok := image.file_dimensions(f)
		testing.expect(t, ok)
		testing.expect_value(t, size, [2]int{13, 7})
		_, _, small := image.decode(f, context.temp_allocator, {max_pixels = 13 * 7 - 1})
		testing.expect(t, !small, "one pixel past max_pixels: refused")
		_, _, fits := image.decode(f, context.temp_allocator, {max_pixels = 13 * 7})
		testing.expect(t, fits, "at max_pixels: read")
		_, _, heavy := image.decode(f, context.temp_allocator, {max_bytes = 100})
		testing.expect(t, !heavy, "past max_bytes: refused")
	}
	when image.IMAGE_WEBP {
		lossy := image.webp_encode(img, allocator = context.temp_allocator)
		lossless := image.webp_encode(img, lossless = true, allocator = context.temp_allocator)
		for f in ([][]u8{lossy, lossless}) {
			size, ok := image.file_dimensions(f)
			testing.expect(t, ok && size == {13, 7}, "WebP's header")
		}
	}
	// (a GIF's canvas: its screen, grown to its first frame as the decoder grows it)
	gif_file := [?]u8{'G', 'I', 'F', '8', '9', 'a', 3, 1, 2, 0, 0, 0, 0, 0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0}
	gsize, gok := image.file_dimensions(gif_file[:])
	testing.expect(t, gok && gsize == {259, 2})
	_, gcut := image.file_dimensions(gif_file[:13])
	testing.expect(t, !gcut, "a GIF cut before its first frame says no size")
	// a screen of one pixel and a frame of 8000 x 8000 after a graphic control: the frame's size is what is checked
	wide := [?]u8{'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0, 0, 0,
		0x21, 0xF9, 4, 0, 0, 0, 0, 0,
		0x2C, 0, 0, 0, 0, 0x40, 0x1F, 0x40, 0x1F, 0}
	wsize, wok := image.file_dimensions(wide[:])
	testing.expect(t, wok && wsize == {8000, 8000}, "the frame grows the canvas")
	_, _, wide_ok := image.decode(wide[:], context.temp_allocator, {max_pixels = 1000})
	testing.expect(t, !wide_ok, "past max_pixels by its frame: refused")

	// a progressive JPEG keeps every coefficient of the whole picture whatever the scale: the gate is told
	baseline := files[1]
	progressive := make([]u8, len(baseline), context.temp_allocator)
	copy(progressive, baseline)
	for i in 2 ..< len(progressive) - 1 {
		if progressive[i] == 0xFF && progressive[i + 1] == 0xC0 { progressive[i + 1] = 0xC2; break }
	}
	testing.expect_value(t, image.decode_bytes(progressive, 8) - image.decode_bytes(baseline, 8), 2 * 3 * 13 * 7)
	testing.expect_value(t, image.decode_bytes(baseline, 1, turned = true), max(image.decode_bytes(baseline, 1), 3 * 4 * 13 * 7))
	// (a header cut short, a JPEG whose scan comes before any frame header)
	_, cut := image.file_dimensions(files[0][:20])
	testing.expect(t, !cut)
	_, none := image.file_dimensions([]u8{0xFF, 0xD8, 0xFF, 0xDA, 0, 2})
	testing.expect(t, !none)
}

// Three decodes of 40 MiB each in a budget of 100 MiB: two are held at once, the third waits until one gives its bytes
// back. A decode under GATE_FROM_BYTES never waits; one past the whole budget is admitted alone.
@(test)
the_gate_admits_within_its_budget :: proc(t: ^testing.T) {
	g: image.Decode_Gate
	image.gate_set_budget(&g, 100 << 20)
	big := 40 << 20
	image.gate_acquire(&g, big)
	image.gate_acquire(&g, big)
	image.gate_acquire(&g, image.GATE_FROM_BYTES - 1)   // (small: passes, holds nothing)
	held, _ := image.gate_counts(&g)
	testing.expect_value(t, held, 2 * big)

	Third :: struct { g: ^image.Decode_Gate, bytes: int, in_: sync.Sema }
	third := Third{g = &g, bytes = big}
	th := thread.create_and_start_with_poly_data(&third, proc(x: ^Third) {
		image.gate_acquire(x.g, x.bytes)
		sync.sema_post(&x.in_)
	})
	defer thread.destroy(th)
	// (the third waits: wait until the gate says so, with a bound)
	began := time.tick_now()
	for {
		_, waiting := image.gate_counts(&g)
		if waiting == 1 || time.tick_since(began) > 5 * time.Second { break }
		thread.yield()
	}
	_, waiting := image.gate_counts(&g)
	testing.expect_value(t, waiting, 1)
	testing.expect(t, !sync.sema_wait_with_timeout(&third.in_, 0), "not admitted while two are held")
	image.gate_release(&g, big)
	testing.expect(t, sync.sema_wait_with_timeout(&third.in_, 5 * time.Second), "admitted once one is given back")
	thread.join(th)
	image.gate_release(&g, big)
	image.gate_release(&g, big)
	held, _ = image.gate_counts(&g)
	testing.expect_value(t, held, 0)

	// (one decode past the whole budget, nothing else held: admitted alone)
	image.gate_acquire(&g, 200 << 20)
	held, _ = image.gate_counts(&g)
	testing.expect_value(t, held, 200 << 20)
	image.gate_release(&g, 200 << 20)
}

// The native JPEG decoder: whole, close to the picture; at 1/2, 1/4, 1/8 when the side asked allows, each the mean of
// its block; turned by its orientation as the core's decode is.
@(test)
the_native_jpeg_decoder_reads_whole_and_scaled :: proc(t: ^testing.T) {
	when !image.IMAGE_JPEG {
		testing.expect(t, !image.jpeg_native_available())
		return
	} else {
		testing.expect(t, image.jpeg_native_available())
		// 64 x 48 in flat blocks of 8 x 8, each its own colour: a scaled decode keeps each block's colour
		w, h := 64, 48
		img := image.create(w, h, {0, 0, 0, 255}, context.temp_allocator)
		for y in 0 ..< h { for x in 0 ..< w {
			o := (y * w + x) * 4
			img.pixels[o], img.pixels[o + 1], img.pixels[o + 2] = u8((x / 8) * 30), u8((y / 8) * 40), 128
		} }
		file := image.jpeg_encode(img, 95, context.temp_allocator)
		testing.expect_value(t, image.jpeg_scale_for({w, h}, 0), 1)
		testing.expect_value(t, image.jpeg_scale_for({w, h}, 32), 2)
		testing.expect_value(t, image.jpeg_scale_for({w, h}, 16), 4)
		testing.expect_value(t, image.jpeg_scale_for({w, h}, 8), 8)
		testing.expect_value(t, image.jpeg_scale_for({w, h}, 1), 8)
		testing.expect_value(t, image.jpeg_scale_for({w, h}, 33), 1)
		for need in ([]int{0, 32, 16, 8}) {
			scale := image.jpeg_scale_for({w, h}, need)
			p, format, ok := image.decode(file, context.temp_allocator, {need_side = need})
			if !testing.expectf(t, ok, "need %d decodes", need) { continue }
			testing.expect_value(t, format, image.File_Format.Jpeg)
			testing.expect_value(t, [2]int{p.width, p.height}, [2]int{w / scale, h / scale})
			worst := 0
			for y in 0 ..< p.height { for x in 0 ..< p.width {
				c := p.pixels[(y * p.width + x) * 4:][:4]
				want := [3]int{((x * scale) / 8) * 30, ((y * scale) / 8) * 40, 128}
				for k in 0 ..< 3 { worst = max(worst, abs(int(c[k]) - want[k])) }
				testing.expect_value(t, c[3], 255)
			} }
			testing.expectf(t, worst <= 12, "need %d: off by %d at most", need, worst)
		}
		turned, _ := exif.set_orientation(file, 6, context.temp_allocator)
		p, _, ok := image.decode(turned, context.temp_allocator, {orient = true, need_side = 16})
		testing.expect(t, ok && p.width == 12 && p.height == 16, "a quarter turned, at 1/4")
		// a CMYK file (Adobe's, as Photoshop and ImageMagick write it) of one colour: the same colour whole and at 1/8
		for need in ([]int{0, 2}) {
			flat, _, flat_ok := image.decode(CMYK_FLAT[:], context.temp_allocator, {need_side = need})
			if !testing.expectf(t, flat_ok, "CMYK, need %d", need) { continue }
			c := flat.pixels[:4]
			want := [3]int{200, 60, 30}
			for k in 0 ..< 3 { testing.expectf(t, abs(int(c[k]) - want[k]) <= 12, "CMYK, need %d (%dx%d): %v", need, flat.width, flat.height, c) }
		}
		// (damage: every cut of the file is refused or read, never a crash)
		for cut in 0 ..< len(file) {
			_, _, _ = image.decode(file[:cut], context.temp_allocator)
			_, _, _ = image.decode(file[:cut], context.temp_allocator, {need_side = 8})
		}
	}
}
