package tk_image

// A picture file of any format a screenshot tool or a chat meets (PNG, JPEG, WebP, BMP, GIF), read by its first bytes,
// not by its name: a file renamed, or one a browser saved with the wrong extension, still opens. PNG is gt:png's
// decoder; JPEG (baseline and progressive) is zune-jpeg's in the native library when the program has it (IMAGE_JPEG,
// jpeg_native.odin), else the Odin core's; BMP is the Odin core's, as the clipboard reads it; WebP is libwebp's
// (webp.odin); GIF is gt:gif's, its first frame (src/md/features/image-decode.md).
//
// Before any pixel is allocated, the picture's size is read from its header (file_dimensions) and checked against the
// options' limits; a decode that will hold many bytes waits for them at the process's gate (gate.odin).

import "base:runtime"
import core_image "core:image"
import "core:image/bmp"
import "core:image/jpeg"
import exif "../exif"
import gif "../gif"
import png "../png"

// The formats decode reads.
File_Format :: enum u8 { Unknown, Png, Jpeg, Webp, Bmp, Gif }

// The most pixels decode makes when the caller says nothing (Decode_Options.max_pixels 0): the Odin core's cap (8192 x
// 8192, 256 MiB of RGBA), which its PNG, JPEG and BMP decoders refuse past anyway. A program that shows larger pictures
// raises both with -define:MAX_DIMENSIONS=<pixels> (toolbox.Project.defines) and passes max_pixels.
DECODE_MAX_PIXELS :: core_image.MAX_DIMENSIONS

// How a picture is decoded. The zero value is the picture as stored, whole, within DECODE_MAX_PIXELS, admitted by the
// process's gate.
Decode_Options :: struct {
	orient:     bool,         // the EXIF orientation applied: the picture as the camera was held (exif.orientation)
	// the longest side the caller shows (0: the whole picture). A JPEG decoded by the native library comes at 1/2, 1/4
	// or 1/8 of its size when that still covers it (a scaled IDCT: the time and memory of the smaller picture); the
	// other formats come whole. The caller still resizes to its exact size.
	need_side:  int,
	max_pixels: int,          // more pixels (width * height, as stored) is refused before any allocation; 0: DECODE_MAX_PIXELS
	max_bytes:  int,          // more bytes held by the decode (decode_bytes) is refused before any allocation; 0: no bound
	gate:       ^Decode_Gate, // where a large decode waits for its bytes; nil: the process's (decode_gate())
}

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
	case len(data) >= 6 && (string(data[0:6]) == "GIF87a" || string(data[0:6]) == "GIF89a"):
		return .Gif
	}
	return .Unknown
}

// The picture of a file of `data`, whatever its format (file_format), as straight RGBA8 in `allocator`; a GIF's first
// frame. ok is false for a format it does not read, a damaged file, a picture past the options' limits, or a WebP in a
// program built without WebP (IMAGE_WEBP). Blocks for the decode, and at the gate: a worker's call.
decode :: proc(data: []u8, allocator := context.allocator, o := Decode_Options{}) -> (img: Image, format: File_Format, ok: bool) {
	format = file_format(data)
	if format == .Unknown { return }
	size, sized := file_dimensions(data)
	if !sized { return }
	most := o.max_pixels > 0 ? o.max_pixels : DECODE_MAX_PIXELS
	if size.x * size.y > most { return }
	scale := 1
	when IMAGE_JPEG { if format == .Jpeg { scale = jpeg_scale_for(size, o.need_side) } }
	turn := o.orient ? exif.orientation(data) : 0
	held := decode_bytes(data, scale, turned = turn > 1)
	if o.max_bytes > 0 && held > o.max_bytes { return }
	gate := o.gate != nil ? o.gate : decode_gate()
	gate_acquire(gate, held)
	defer gate_release(gate, held)

	img, ok = decode_pixels(data, format, scale, allocator)
	if !ok { return }
	if turn > 1 {
		turned := orient(img, turn, allocator)
		destroy(&img, allocator)
		img = turned
	}
	return
}

@(private = "file")
decode_pixels :: proc(data: []u8, format: File_Format, scale: int, allocator: runtime.Allocator) -> (img: Image, ok: bool) {
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
		return {pixels = rgba, width = w, height = h}, true
	case .Gif:
		rgba, w, h, gif_ok := gif.decode(data, allocator)
		if !gif_ok { return }
		return {pixels = rgba, width = w, height = h}, true
	case .Webp:
		return webp_decode(data, allocator)
	case .Jpeg:
		when IMAGE_JPEG { return jpeg_native_decode(data, scale, allocator) }
		decoded, err = jpeg.load_from_bytes(data, {}, heap)
	case .Bmp:
		decoded, err = bmp.load_from_bytes(data, {}, heap)
	}
	defer core_image.destroy(decoded, heap)   // (what it made before a failure too)
	if err != nil || decoded == nil { return }
	rgba, w, h, rgba_ok := png.rgba8_of(decoded, allocator)
	if !rgba_ok { return }
	return {pixels = rgba, width = w, height = h}, true
}

// The bytes a decode of the picture file `data` holds at its peak, at 1/`scale` of its size, read from its header (0:
// no header read): its RGBA, and the decoder's own planes (the core's decoders make a picture of their own, then the
// RGBA copy: twice). `turned`: an orientation is applied after. What the gate admits and Decode_Options.max_bytes bounds.
decode_bytes :: proc(data: []u8, scale := 1, turned := false) -> int {
	size, sized := file_dimensions(data)
	if !sized { return 0 }
	s := max(scale, 1)
	pixels := ((size.x + s - 1) / s) * ((size.y + s - 1) / s)
	peak := 4 * pixels
	switch file_format(data) {
	case .Png, .Bmp: peak = 2 * 4 * pixels
	case .Jpeg:
		peak = IMAGE_JPEG ? 4 * pixels + 3 * pixels : 2 * 4 * pixels
		// (a progressive file keeps every coefficient of the whole picture, 2 bytes a sample, until its last scan, whatever
		// the scale: a 64-megapixel one holds 384 MB to give a thumbnail of 1 MB)
		if f := jpeg_frame(data); f.progressive { peak += 2 * f.components * size.x * size.y }
	case .Webp, .Gif, .Unknown:
	}
	// (the turn is a copy, a mirror then a turn two; the decoder's own planes are freed by then)
	if turned { peak = max(peak, 3 * 4 * pixels) }
	return peak
}

// A JPEG's first frame header, as file_dimensions reads it.
@(private)
Jpeg_Frame :: struct {
	size:        [2]int,
	components:  int,
	progressive: bool,   // SOF2, SOF6, SOF10, SOF14
	ok:          bool,
}

// The segments up to the first frame header: SOF0 to SOF15 but DHT (C4), JPG (C8) and DAC (CC). Both native decoders
// refuse a second frame header, so the first is the one they decode.
@(private)
jpeg_frame :: proc(data: []u8) -> (f: Jpeg_Frame) {
	be16 :: proc(b: []u8) -> int { return int(b[0]) << 8 | int(b[1]) }
	if len(data) < 2 || data[0] != 0xFF || data[1] != 0xD8 { return }
	for p := 2; p + 4 <= len(data); {
		if data[p] != 0xFF { return }
		marker := data[p + 1]
		if marker == 0xFF { p += 1; continue }
		if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { p += 2; continue }
		n := be16(data[p + 2:])
		if n < 2 || p + 2 + n > len(data) { return }
		if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
			if n < 8 { return }
			f.size = {be16(data[p + 7:]), be16(data[p + 5:])}
			f.components = int(data[p + 9])
			f.progressive = marker & 0x03 == 0x02
			f.ok = f.size.x > 0 && f.size.y > 0
			return
		}
		if marker == 0xDA { return }   // (a scan before any frame header)
		p += 2 + n
	}
	return
}

// The picture's size as its file's header says (as stored: before an EXIF orientation), without decoding it: PNG's IHDR,
// a JPEG's frame header, WebP's VP8, VP8L or VP8X header, BMP's header, a GIF's canvas (its logical screen grown to its
// first frame, as the decoder makes it). ok is false when the header is cut short or says no size.
file_dimensions :: proc(data: []u8) -> (size: [2]int, ok: bool) {
	le16 :: proc(b: []u8) -> int { return int(b[0]) | int(b[1]) << 8 }
	le32 :: proc(b: []u8) -> int { return int(b[0]) | int(b[1]) << 8 | int(b[2]) << 16 | int(b[3]) << 24 }
	switch file_format(data) {
	case .Unknown:
		return
	case .Png:
		if len(data) < 24 || string(data[12:16]) != "IHDR" { return }
		size = {int(u32(data[16]) << 24 | u32(data[17]) << 16 | u32(data[18]) << 8 | u32(data[19])),
		        int(u32(data[20]) << 24 | u32(data[21]) << 16 | u32(data[22]) << 8 | u32(data[23]))}
	case .Jpeg:
		f := jpeg_frame(data)
		if !f.ok { return }
		size = f.size
	case .Webp:
		if len(data) < 30 { return }
		switch string(data[12:16]) {
		case "VP8X": size = {1 + (le16(data[24:]) | int(data[26]) << 16), 1 + (le16(data[27:]) | int(data[29]) << 16)}
		case "VP8L":
			if data[20] != 0x2F { return }
			bits := le32(data[21:])
			size = {1 + bits & 0x3FFF, 1 + (bits >> 14) & 0x3FFF}
		case "VP8 ":
			if data[23] != 0x9D || data[24] != 0x01 || data[25] != 0x2A { return }
			size = {le16(data[26:]) & 0x3FFF, le16(data[28:]) & 0x3FFF}
		}
	case .Bmp:
		if len(data) < 26 { return }
		if le32(data[14:]) == 12 {   // (BITMAPCOREHEADER: 16-bit sides)
			size = {le16(data[18:]), le16(data[20:])}
		} else {
			w, h := i32(u32(le32(data[18:]))), i32(u32(le32(data[22:])))
			size = {int(abs(w)), int(abs(h))}
		}
	case .Gif:
		// (the canvas the decoder makes: the screen grown to the first frame, so a screen of one pixel does not pass a
		// frame of 8192 x 8192 under max_pixels)
		return gif.canvas_size(data)
	}
	return size, size.x > 0 && size.y > 0
}

// `img` as the EXIF orientation `o` (1 to 8, exif.orientation) says it was held: mirrored, then turned clockwise. A new
// picture in `allocator`; 0, 1 or a value past 8: a copy.
orient :: proc(img: Image, o: int, allocator := context.allocator) -> Image {
	t := exif.orientation_turn(o)
	if t == {} { return clone(img, allocator) }
	if !t.mirror { return rotate(img, t.quarters, allocator) }
	m := flip(img, true, allocator)
	if t.quarters % 4 == 0 { return m }
	defer destroy(&m, allocator)
	return rotate(m, t.quarters, allocator)
}
