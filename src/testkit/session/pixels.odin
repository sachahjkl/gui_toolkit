package tk_session

import "core:fmt"
import "core:os"
import png "../../png"
import "../../render"

// Pixels: the last frame of the real renderer, read back from its offscreen target.

// Straight RGBA8 in sRGB, rows of width * 4 bytes, top row first.
Image :: struct {
	rgba:          []u8,
	width, height: int,
}

Color :: distinct [4]u8

// The share of pixels two images may differ on, and by how much a channel must differ for a pixel to count, when a test does not say.
PIXEL_DELTA :: 32
MAX_SHARE :: 0.004

// The last frame (the test's temporary memory).
capture :: proc(s: ^Session, loc := #caller_location) -> Image {
	if s.renderer == nil { failed(s, "capture: this session has no renderer", loc) }
	px := render.read_pixels(s.renderer, s.test.temp_allocator)
	if px == nil { failed(s, "capture: the frame could not be read", loc) }
	return {px, s.renderer.size.x, s.renderer.size.y}
}

// The values a frame holds as they are stored: RGBA, premultiplied, top row first. In a half-float frame (Options.half_float)
// nothing is clamped: a value past [0, 1], an infinity or a NaN is there as the window would get it.
Float_Image :: struct {
	rgba:          [][4]f32,
	width, height: int,
}

// The last frame's values (the test's temporary memory).
capture_float :: proc(s: ^Session, loc := #caller_location) -> Float_Image {
	if s.renderer == nil { failed(s, "capture_float: this session has no renderer", loc) }
	px := render.read_pixels_float(s.renderer, s.test.temp_allocator)
	if px == nil { failed(s, "capture_float: the frame could not be read", loc) }
	return {px, s.renderer.size.x, s.renderer.size.y}
}

// The first pixel of `img` with a value that is not finite or out of [0, 1] by more than `margin` (a half's rounding of a
// blend), or whose alpha is under `least_alpha` (1 - margin for a frame that must be opaque), and how many there are.
// at = {-1, -1}: none.
out_of_range :: proc(img: Float_Image, least_alpha: f32 = 0, margin: f32 = 1e-3) -> (n: int, at: [2]int, value: [4]f32) {
	at = {-1, -1}
	for v, i in img.rgba {
		bad := v[3] < least_alpha
		for c in v { if c != c || c < -margin || c > 1 + margin { bad = true } }   // (c != c: a NaN; an infinity is out of range)
		if !bad { continue }
		if n == 0 { at, value = {i % img.width, i / img.width}, v }
		n += 1
	}
	return
}

// The colour of a pixel (a point outside the image: all zero).
pixel :: proc(img: Image, x, y: int) -> Color {
	if x < 0 || y < 0 || x >= img.width || y >= img.height { return {} }
	p := img.rgba[(y * img.width + x) * 4:][:4]
	return {p[0], p[1], p[2], p[3]}
}

// Whether two colours are within `tolerance` of each other on every channel.
near :: proc(a, b: Color, tolerance := 3) -> bool {
	for i in 0 ..< 4 { if abs(int(a[i]) - int(b[i])) > tolerance { return false } }
	return true
}

// The pixels of a rectangle (client pixels, min inclusive, max exclusive) close to `c`.
count_color :: proc(img: Image, min, max: [2]int, c: Color, tolerance := 3) -> (n: int) {
	for y in min.y ..< max.y {
		for x in min.x ..< max.x { if near(pixel(img, x, y), c, tolerance) { n += 1 } }
	}
	return
}

// The pixels of a rectangle that differ from `c`.
count_other :: proc(img: Image, min, max: [2]int, c: Color, tolerance := 3) -> int {
	return (max.y - min.y) * (max.x - min.x) - count_color(img, min, max, c, tolerance)
}

// How many pixels differ between two images of one size (by more than `delta` on some channel), -1 when their sizes do.
count_different :: proc(a, b: Image, delta := PIXEL_DELTA) -> (n: int) {
	if a.width != b.width || a.height != b.height { return -1 }
	for i := 0; i < len(a.rgba); i += 4 {
		for k in 0 ..< 4 {
			if abs(int(a.rgba[i + k]) - int(b.rgba[i + k])) > delta { n += 1; break }
		}
	}
	return
}

// The last frame to a PNG of this test's folder.
save_png :: proc(s: ^Session, name: string, loc := #caller_location) {
	if s.renderer == nil { failed(s, "save_png: this session has no renderer", loc) }
	px := render.read_pixels(s.renderer, s.test.temp_allocator)
	if px == nil { return }
	data := png.encode(px, s.renderer.size.x, s.renderer.size.y, .Fast)
	defer delete(data)
	_ = os.write_entire_file(out_path(s, name), data)
}

// An image file (the test's temporary memory). ok = false: it cannot be read.
load_png :: proc(s: ^Session, path: string) -> (img: Image, ok: bool) {
	data, err := os.read_entire_file(path, s.test.temp_allocator)
	if err != nil { return }
	rgba, w, h := png.decode(data, s.test.temp_allocator) or_return
	return {rgba, w, h}, true
}

// The last frame looks like the reference image `path`: on at most `max_share` of its pixels by more than `delta`. What differs is left
// in this test's folder. With TOOLKIT_TEST_UPDATE=1 in the environment the reference is written instead (review them like code).
expect_like :: proc(s: ^Session, path: string, delta := PIXEL_DELTA, max_share := MAX_SHARE, loc := #caller_location) {
	got := capture(s, loc)
	if v, _ := os.lookup_env("TOOLKIT_TEST_UPDATE", s.test.temp_allocator); v == "1" {
		data := png.encode(got.rgba, got.width, got.height, .Fast)
		defer delete(data)
		_ = os.write_entire_file(path, data)
		return
	}
	want, ok := load_png(s, path)
	if !ok { save_png(s, "actual.png"); failed(s, fmt.tprintf("no reference image %s", path), loc) }
	n := count_different(got, want, delta)
	if n < 0 { save_png(s, "actual.png"); failed(s, fmt.tprintf("%s is %dx%d, the frame %dx%d", path, want.width, want.height, got.width, got.height), loc) }
	share := f64(n) / f64(got.width * got.height)
	if share > max_share {
		save_png(s, "actual.png")
		failed(s, fmt.tprintf("%.3f%% of the pixels differ from %s", share * 100, path), loc)
	}
}
