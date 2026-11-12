package tk_image

// A WebP file of a picture, by libwebp's simple API (WebPEncodeRGBA, WebPEncodeLosslessRGBA), loaded when first asked
// (webp_<system>.odin): a program starts on a system without it, and says WebP is not available there. Nix: libwebp;
// Debian: libwebp7; Windows: libwebp.dll beside the program.

import "core:sync"

@(private)
Webp_Lib :: struct {
	encode_rgba:          proc "c" (rgba: [^]u8, width, height, stride: i32, quality: f32, output: ^[^]u8) -> uint,
	encode_lossless_rgba: proc "c" (rgba: [^]u8, width, height, stride: i32, output: ^[^]u8) -> uint,
	free:                 proc "c" (ptr: rawptr),
}

@(private) webp_lib: Webp_Lib
@(private) webp_once: sync.Once
@(private) webp_found: bool

// Whether this system can write WebP files (libwebp could be loaded).
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
