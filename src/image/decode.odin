package tk_image

// A picture file of any format a screenshot tool meets (PNG, JPEG, WebP, BMP), read by its first bytes, not by its
// name: a file renamed, or one a browser saved with the wrong extension, still opens. PNG is gt:png's decoder; JPEG
// (baseline and progressive) and BMP are the Odin core's, as the clipboard reads them; WebP is libwebp's (webp.odin).

import "base:runtime"
import core_image "core:image"
import "core:image/bmp"
import "core:image/jpeg"
import png "../png"

// The formats decode reads.
File_Format :: enum u8 { Unknown, Png, Jpeg, Webp, Bmp }

// The format of a picture file from its signature, Unknown when it is none decode reads. Pure: no decoding.
file_format :: proc(data: []u8) -> File_Format {
	switch {
	case len(data) >= 8 && data[0] == 0x89 && string(data[1:4]) == "PNG" && data[4] == '\r' && data[5] == '\n':
		return .Png
	case len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF:
		return .Jpeg
	case len(data) >= 12 && string(data[0:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		return .Webp
	case len(data) >= 14 && data[0] == 'B' && data[1] == 'M':
		return .Bmp
	}
	return .Unknown
}

// The picture of a file of `data`, whatever its format (file_format), as straight RGBA8 in `allocator`. ok is false
// for a format it does not read, a damaged file, or a WebP where libwebp is not there.
decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, format: File_Format, ok: bool) {
	format = file_format(data)
	// (the decoders' own pictures in the heap, freed here: a photo is tens of MB, and the caller's allocator may be an arena)
	heap := runtime.heap_allocator()
	decoded: ^core_image.Image
	err: core_image.Error
	switch format {
	case .Unknown:
		return
	case .Png:
		rgba, w, h, png_ok := png.decode(data, allocator)
		if !png_ok { return }
		return {pixels = rgba, width = w, height = h}, format, true
	case .Webp:
		img, ok = webp_decode(data, allocator)
		return
	case .Jpeg:
		decoded, err = jpeg.load_from_bytes(data, {}, heap)
	case .Bmp:
		decoded, err = bmp.load_from_bytes(data, {}, heap)
	}
	defer core_image.destroy(decoded, heap)   // (what it made before a failure too)
	if err != nil || decoded == nil { return }
	rgba, w, h, rgba_ok := png.rgba8_of(decoded, allocator)
	if !rgba_ok { return }
	return {pixels = rgba, width = w, height = h}, format, true
}
