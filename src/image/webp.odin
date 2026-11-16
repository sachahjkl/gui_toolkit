package tk_image

// A WebP file of a picture and back, by libwebp's simple API, built into the program: native/webp (libwebp's and
// sharpyuv's own sources), a part of the toolkit's one static library. A program with -define:IMAGE_WEBP=true links
// build/native/gt_native.lib (libgt_native.a elsewhere), built with the part webp (tools/tk build_native; a program's
// toolbox.Feature.Webp does both), and needs no libwebp beside it or on the system. Without the define, nothing is
// linked and WebP is not available.

IMAGE_WEBP :: #config(IMAGE_WEBP, false)
// false: the program's own Rust library carries native/webp (as a dependency: its gt_webp_* functions stay exported),
// as it carries native/text and native/mermaid (FONT_NATIVE_LINK, MERMAID_NATIVE_LINK): no second copy of Rust's
// standard library, nothing more to link.
IMAGE_WEBP_NATIVE_LINK :: #config(IMAGE_WEBP_NATIVE_LINK, true)

when IMAGE_WEBP {
	when !IMAGE_WEBP_NATIVE_LINK {
		// (the symbols come from the program's own Rust library, which every such program links already)
		when ODIN_OS == .Windows { foreign import gt_webp "system:kernel32.lib" } else { foreign import gt_webp "system:c" }
	} else when ODIN_OS == .Windows {
		foreign import gt_webp {
			"../../build/native/gt_native.lib",
			"system:ntdll.lib",
			"system:userenv.lib",
			"system:ws2_32.lib",
			"system:bcrypt.lib",
			"system:advapi32.lib",
			"system:kernel32.lib",
			"system:dbghelp.lib",
		}
	} else {
		foreign import gt_webp {
			"../../build/native/libgt_native.a",
			"system:dl",
			"system:pthread",
			"system:m",
		}
	}

	// (named gt_webp_*, never libwebp's own names: another libwebp linked into the same program cannot clash with them)
	@(private, default_calling_convention = "c")
	foreign gt_webp {
		gt_webp_encode_rgba :: proc(rgba: [^]u8, width, height, stride: i32, quality: f32, output: ^[^]u8) -> uint ---
		gt_webp_encode_lossless_rgba :: proc(rgba: [^]u8, width, height, stride: i32, output: ^[^]u8) -> uint ---
		gt_webp_decode_rgba :: proc(data: [^]u8, size: uint, width, height: ^i32) -> [^]u8 ---
		gt_webp_free :: proc(ptr: rawptr) ---
	}
}

// Whether this program writes and reads WebP files (built with -define:IMAGE_WEBP=true).
webp_available :: proc() -> bool {
	return IMAGE_WEBP
}

// The file of `img`: lossy at `quality` (0 to 100: 85 keeps a screenshot's text clean), or `lossless` (every pixel as it
// is, still far smaller than a PNG), in `allocator`. nil when WebP is not available or libwebp refuses the picture.
webp_encode :: proc(img: Image, quality := 85, lossless := false, allocator := context.allocator) -> []u8 {
	when IMAGE_WEBP {
		if !valid(img) { return nil }
		out: [^]u8
		n: uint
		if lossless {
			n = gt_webp_encode_lossless_rgba(raw_data(img.pixels), i32(img.width), i32(img.height), i32(img.width * 4), &out)
		} else {
			n = gt_webp_encode_rgba(raw_data(img.pixels), i32(img.width), i32(img.height), i32(img.width * 4), f32(clamp(quality, 0, 100)), &out)
		}
		if n == 0 || out == nil { return nil }
		defer gt_webp_free(out)
		file := make([]u8, int(n), allocator)
		copy(file, out[:n])
		return file
	} else {
		return nil
	}
}

// The picture of a WebP `data` (lossy or lossless, with or without alpha), in `allocator`. ok is false when WebP is not
// available or `data` is not a WebP file libwebp reads.
webp_decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, ok: bool) {
	when IMAGE_WEBP {
		if len(data) == 0 { return {}, false }
		w, h: i32
		px := gt_webp_decode_rgba(raw_data(data), uint(len(data)), &w, &h)
		if px == nil { return {}, false }
		// libwebp's buffer belongs to its own allocator: the picture is copied so that the caller frees it as any Image
		defer gt_webp_free(px)
		if w <= 0 || h <= 0 { return {}, false }
		n := int(w) * int(h) * 4
		img = Image{pixels = make([]u8, n, allocator), width = int(w), height = int(h)}
		copy(img.pixels, px[:n])
		return img, true
	} else {
		return {}, false
	}
}
