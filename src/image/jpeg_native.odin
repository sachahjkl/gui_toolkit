package tk_image

// JPEG decoded by the toolkit's native library (native/jpeg, a part of gt_native): zune-jpeg for a picture at its size,
// jpeg-decoder's scaled IDCT for 1/2, 1/4 or 1/8 of it. A program with -define:IMAGE_JPEG=true links
// build/native/gt_native.lib (libgt_native.a elsewhere), built with the part jpeg (tools/tk build_native; a program's
// toolbox.Feature.Jpeg does both). Without the define, nothing is linked and decode reads JPEG with the Odin core's
// decoder, whole. src/md/features/image-decode.md, "Fast JPEG", has the measures.

IMAGE_JPEG :: #config(IMAGE_JPEG, false)
// false: the program's own Rust library carries native/jpeg (as a dependency: its gt_jpeg_* functions stay exported), as
// with IMAGE_WEBP_NATIVE_LINK.
IMAGE_JPEG_NATIVE_LINK :: #config(IMAGE_JPEG_NATIVE_LINK, true)

when IMAGE_JPEG {
	when !IMAGE_JPEG_NATIVE_LINK {
		when ODIN_OS == .Windows { foreign import gt_jpeg "system:kernel32.lib" } else { foreign import gt_jpeg "system:c" }
	} else when ODIN_OS == .Windows {
		foreign import gt_jpeg {
			"../../build/native/gt_native.lib",
			"system:ntdll.lib",
			"system:userenv.lib",
			"system:ws2_32.lib",
			"system:bcrypt.lib",
			"system:advapi32.lib",
			"system:kernel32.lib",
			"system:dbghelp.lib",
			"system:Synchronization.lib",
			"system:ole32.lib",
			"system:rpcrt4.lib",
			"system:shell32.lib",
			"system:winhttp.lib",
			"system:crypt32.lib",
			"system:secur32.lib",
		}
	} else {
		foreign import gt_jpeg {
			"../../build/native/libgt_native.a",
			"system:dl",
			"system:pthread",
			"system:m",
		}
	}

	@(private, default_calling_convention = "c")
	foreign gt_jpeg {
		gt_jpeg_size :: proc(data: [^]u8, size: uint, scale: i32, width, height: ^i32) -> i32 ---
		gt_jpeg_decode_rgba :: proc(data: [^]u8, size: uint, scale: i32, out: [^]u8, out_len: uint, width, height: ^i32) -> i32 ---
	}
}

// Whether this program decodes JPEG with the native library (built with -define:IMAGE_JPEG=true).
jpeg_native_available :: proc() -> bool { return IMAGE_JPEG }

// The largest of 1, 2, 4, 8 by which a picture of `size` still has `need_side` pixels on its longer side (0: 1, the
// whole picture).
jpeg_scale_for :: proc(size: [2]int, need_side: int) -> int {
	if need_side <= 0 { return 1 }
	longest := max(size.x, size.y)
	scale := 1
	for scale < 8 && (longest + 2 * scale - 1) / (2 * scale) >= need_side { scale *= 2 }
	return scale
}

// The JPEG of `data` at 1/`scale` (1, 2, 4, 8; another value is the next lower of them) as straight RGBA8 in
// `allocator`. ok is false without IMAGE_JPEG, or for a file the native decoder refuses or reads at another size than
// its first frame header says (file_dimensions: the size the caller checked its limits against).
jpeg_native_decode :: proc(data: []u8, scale: int, allocator := context.allocator) -> (img: Image, ok: bool) {
	when IMAGE_JPEG {
		stored, sized := file_dimensions(data)
		if !sized { return }
		s := scale >= 8 ? 8 : scale >= 4 ? 4 : scale >= 2 ? 2 : 1
		w, h: i32
		if gt_jpeg_size(raw_data(data), uint(len(data)), i32(s), &w, &h) == 0 { return }
		// (a crafted file whose decoder finds another frame than the header walk would have its pixels allocated at a size
		// no limit was checked against: up to 65535 x 65535)
		if int(w) != (stored.x + s - 1) / s || int(h) != (stored.y + s - 1) / s { return }
		pixels, err := make([]u8, int(w) * int(h) * 4, allocator)
		if err != nil { return }
		gw, gh: i32
		if gt_jpeg_decode_rgba(raw_data(data), uint(len(data)), i32(s), raw_data(pixels), uint(len(pixels)), &gw, &gh) == 0 || gw != w || gh != h {
			delete(pixels, allocator)
			return
		}
		return {pixels = pixels, width = int(w), height = int(h)}, true
	} else {
		return
	}
}
