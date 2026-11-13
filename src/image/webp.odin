package tk_image

// A WebP file of a picture and back, by libwebp's simple API (WebPEncodeRGBA, WebPEncodeLosslessRGBA, WebPDecodeRGBA), loaded when first asked
// (webp_<system>.odin): a program starts on a system without it, and says WebP is not available there. Nix: libwebp;
// Debian: libwebp7; Windows: libwebp.dll beside the program.

import "core:sync"

@(private)
Webp_Lib :: struct {
	encode_rgba:          proc "c" (rgba: [^]u8, width, height, stride: i32, quality: f32, output: ^[^]u8) -> uint,
	encode_lossless_rgba: proc "c" (rgba: [^]u8, width, height, stride: i32, output: ^[^]u8) -> uint,
	decode_rgba:          proc "c" (data: [^]u8, size: uint, width, height: ^i32) -> [^]u8,
	free:                 proc "c" (ptr: rawptr),
}

@(private) webp_lib: Webp_Lib
@(private) webp_once: sync.Once
@(private) webp_found: bool

// Whether this system can write and read WebP files (libwebp could be loaded).
webp_available :: proc() -> bool {
	sync.once_do(&webp_once, webp_load)
	return webp_found
}

// The file of `img`: lossy at `quality` (0 to 100: 85 keeps a screenshot's text clean), or `lossless` (every pixel as it
// is, still far smaller than a PNG), in `allocator`. nil when libwebp is not there or refuses the picture.
webp_encode :: proc(img: Image, quality := 85, lossless := false, allocator := context.allocator) -> []u8 {
	if !valid(img) || !webp_available() { return nil }
	out: [^]u8
	n: uint
	if lossless {
		n = webp_lib.encode_lossless_rgba(raw_data(img.pixels), i32(img.width), i32(img.height), i32(img.width * 4), &out)
	} else {
		n = webp_lib.encode_rgba(raw_data(img.pixels), i32(img.width), i32(img.height), i32(img.width * 4), f32(clamp(quality, 0, 100)), &out)
	}
	if n == 0 || out == nil { return nil }
	defer webp_lib.free(out)
	file := make([]u8, int(n), allocator)
	copy(file, out[:n])
	return file
}

// The picture of a WebP `data` (lossy or lossless, with or without alpha), in `allocator`. ok is false when libwebp is
// not there or `data` is not a WebP file it reads.
webp_decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, ok: bool) {
	if len(data) == 0 || !webp_available() { return {}, false }
	w, h: i32
	px := webp_lib.decode_rgba(raw_data(data), uint(len(data)), &w, &h)
	if px == nil { return {}, false }
	// libwebp's buffer belongs to its own allocator: the picture is copied so that the caller frees it as any Image
	defer webp_lib.free(px)
	if w <= 0 || h <= 0 { return {}, false }
	n := int(w) * int(h) * 4
	img = Image{pixels = make([]u8, n, allocator), width = int(w), height = int(h)}
	copy(img.pixels, px[:n])
	return img, true
}
