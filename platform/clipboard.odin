package platform

// The clipboard beyond plain text, behind an API of our own (Windows: clipboard_win32.odin; other systems:
// clipboard_stub.odin answers "nothing there" / "not supported"). get_clipboard / set_clipboard (platform_win32.odin)
// stay the plain text calls.
//
//   * clipboard_set writes several flavours at once with one owner (text, HTML with its source URL, an image, files);
//     clipboard_set_html / _image / _files are shorthands.
//   * clipboard_get_image (RGBA8), clipboard_get_html (the fragment and its source URL), clipboard_get_files (paths).
//   * clipboard_formats says what is there without reading it (a Paste item enabled or not); clipboard_sequence changes
//     whenever another program (or this one) writes the clipboard; clipboard_watch makes the window wake when that
//     happens and clipboard_changed tells it once.
//
// The conversions are pure and shared by every system: device-independent bitmaps (the header variants, bit depths,
// palettes, masks, bottom-up or top-down) to and from RGBA, the file list of CF_HDROP, and the "HTML Format" header
// (html_format_wrap / html_format_fragment, dragdrop.odin).

import "core:strings"
import "core:unicode/utf16"

@(private = "file") DIB_CORE_HEADER_BYTES :: 12     // BITMAPCOREHEADER
@(private = "file") DIB_INFO_HEADER_BYTES :: 40     // BITMAPINFOHEADER
@(private = "file") DIB_V2_HEADER_BYTES :: 52       // with the colour masks
@(private = "file") DIB_V3_HEADER_BYTES :: 56       // with the alpha mask too
@(private = "file") DIB_V5_HEADER_BYTES :: 124      // BITMAPV5HEADER
@(private = "file") DIB_BI_BITFIELDS :: 3
@(private = "file") DIB_BI_ALPHABITFIELDS :: 6
@(private = "file") DIB_72_DPI_PELS_PER_METER :: 2835
@(private = "file") DIB_MASKS_BYTES :: 12           // three u32 masks
@(private = "file") DIB_MAX_SIDE_PX :: 1 << 15      // larger than any real bitmap: a header that says more is malformed
@(private) DROPFILES_BYTES :: 20                    // the header of CF_HDROP
@(private = "file") DROPFILES_FWIDE_AT :: 16
@(private = "file") UTF16_FIRST_PAIR_RUNE :: 0x10000   // from here on a rune takes a surrogate pair

Clipboard_Format :: enum u8 { Text, Html, Image, Files }
Clipboard_Formats :: bit_set[Clipboard_Format; u8]

// Straight (not premultiplied) RGBA8 pixels in sRGB, rows of size.x * 4 bytes, top row first.
Clipboard_Image :: struct {
	rgba: []u8,
	size: [2]int,
}

clipboard_image_destroy :: proc(img: ^Clipboard_Image, allocator := context.allocator) {
	delete(img.rgba, allocator)
	img^ = {}
}

// What clipboard_set writes: every flavour given ("" / nil: not written). `html` is a fragment of markup (the header of
// the system's format is added); `image` is written as PNG (with alpha), as a bitmap with alpha (CF_DIBV5) and as an
// opaque bitmap over white for the programs that ignore alpha.
Clipboard_Content :: struct {
	text:       string,
	html:       string,
	source_url: string,          // the page the HTML comes from (resolves its relative links)
	image:      Maybe(Clipboard_Image),
	files:      []string,        // absolute paths
}

// How rgba_to_dib writes the pixels.
Dib_Kind :: enum u8 {
	Opaque_Over_White,   // BITMAPINFOHEADER, 32 bits, composited over white, alpha 255 (what every program reads right)
	Alpha_V5,            // BITMAPV5HEADER, 32 bits with an alpha mask, straight alpha, sRGB (CF_DIBV5)
}

// A packed device-independent bitmap (a header, its masks or palette, the rows) of RGBA pixels, bottom-up.
rgba_to_dib :: proc(img: Clipboard_Image, kind: Dib_Kind, allocator := context.allocator) -> []u8 {
	w, h := img.size.x, img.size.y
	if w <= 0 || h <= 0 || len(img.rgba) < w * h * 4 { return nil }
	header := kind == .Alpha_V5 ? DIB_V5_HEADER_BYTES : DIB_INFO_HEADER_BYTES
	out := make([]u8, header + w * h * 4, allocator)
	put32(out, 0, u32(header))
	put32(out, 4, u32(i32(w)))
	put32(out, 8, u32(i32(h)))   // positive: bottom-up (what most readers expect, top-down V5 is often misread)
	out[12], out[14] = 1, 32     // planes, bits per pixel
	put32(out, 20, u32(w * h * 4))
	put32(out, 24, DIB_72_DPI_PELS_PER_METER); put32(out, 28, DIB_72_DPI_PELS_PER_METER)
	if kind == .Alpha_V5 {
		put32(out, 16, DIB_BI_BITFIELDS)
		put32(out, 40, 0x00FF0000); put32(out, 44, 0x0000FF00); put32(out, 48, 0x000000FF); put32(out, 52, 0xFF000000)
		put32(out, 56, 0x73524742)   // LCS_sRGB
		put32(out, 108, 4)           // LCS_GM_IMAGES
	}
	for y in 0 ..< h {
		src := img.rgba[y * w * 4:][:w * 4]
		row := out[header + (h - 1 - y) * w * 4:][:w * 4]
		for x in 0 ..< w {
			r, g, b, a := u32(src[4 * x]), u32(src[4 * x + 1]), u32(src[4 * x + 2]), u32(src[4 * x + 3])
			if kind == .Opaque_Over_White {
				over :: proc(c, a: u32) -> u8 { return u8((c * a + 255 * (255 - a) + 127) / 255) }
				row[4 * x], row[4 * x + 1], row[4 * x + 2], row[4 * x + 3] = over(b, a), over(g, a), over(r, a), 255
			} else {
				row[4 * x], row[4 * x + 1], row[4 * x + 2], row[4 * x + 3] = u8(b), u8(g), u8(r), u8(a)
			}
		}
	}
	return out
}

// The RGBA pixels of a packed device-independent bitmap: BITMAPCOREHEADER, BITMAPINFOHEADER, V4 and V5 headers; 1, 4
// and 8 bits with a palette, 16 (5-5-5 or masks), 24 and 32 bits (masks, an alpha mask or none); bottom-up or
// top-down. A 32-bit bitmap without an alpha mask whose fourth bytes are all zero is opaque (that byte is unused then);
// otherwise they are its alpha. ok = false for compressed (RLE, JPEG, PNG) or malformed data.
dib_to_rgba :: proc(dib: []u8, allocator := context.allocator) -> (img: Clipboard_Image, ok: bool) {
	if len(dib) < DIB_CORE_HEADER_BYTES { return }
	hs := int(get32(dib, 0))
	w, h, bpp: int
	compression: u32
	colors := 0
	masks: [4]u32
	has_masks := false
	pal_entry := 4
	switch {
	case hs == DIB_CORE_HEADER_BYTES:
		w, h = int(get16(dib, 4)), int(i16(get16(dib, 6)))
		bpp = int(get16(dib, 10))
		pal_entry = 3
	case hs >= DIB_INFO_HEADER_BYTES && hs <= len(dib):
		w, h = int(i32(get32(dib, 4))), int(i32(get32(dib, 8)))
		bpp = int(get16(dib, 14))
		compression = get32(dib, 16)
		colors = int(get32(dib, 32))
		if hs >= DIB_V2_HEADER_BYTES { masks = {get32(dib, 40), get32(dib, 44), get32(dib, 48), 0}; has_masks = compression == DIB_BI_BITFIELDS || compression == DIB_BI_ALPHABITFIELDS }
		if hs >= DIB_V3_HEADER_BYTES { masks[3] = get32(dib, 52) }
	case:
		return
	}
	top_down := h < 0
	h = abs(h)
	if w <= 0 || h <= 0 || w > DIB_MAX_SIDE_PX || h > DIB_MAX_SIDE_PX { return }
	if compression != 0 && compression != DIB_BI_BITFIELDS && compression != DIB_BI_ALPHABITFIELDS { return }   // BI_RLE8 / RLE4 / JPEG / PNG
	at := hs
	if hs == DIB_INFO_HEADER_BYTES && (compression == DIB_BI_BITFIELDS || compression == DIB_BI_ALPHABITFIELDS) {
		n := compression == DIB_BI_ALPHABITFIELDS ? 4 : 3
		if len(dib) < at + n * 4 { return }
		for i in 0 ..< n { masks[i] = get32(dib, at + i * 4) }
		has_masks = true
		at += n * 4
	}
	if bpp <= 8 {
		if bpp != 1 && bpp != 4 && bpp != 8 { return }
		if colors == 0 || colors > 1 << uint(bpp) { colors = 1 << uint(bpp) }
	} else {
		colors = 0
	}
	palette := at
	at += colors * pal_entry
	stride := ((w * bpp + 31) / 32) * 4
	if bpp > 8 && bpp != 16 && bpp != 24 && bpp != 32 { return }
	// some writers put the three masks after a V5 header as well: the rows are then 12 bytes further
	if hs > DIB_INFO_HEADER_BYTES && has_masks && len(dib) - at == stride * h + DIB_MASKS_BYTES { at += DIB_MASKS_BYTES }
	if len(dib) < at + stride * h { return }
	if !has_masks {
		switch bpp {
		case 16: masks = {0x7C00, 0x03E0, 0x001F, 0}
		case 32: masks = {0x00FF0000, 0x0000FF00, 0x000000FF, 0}
		}
	}
	use_alpha_byte := false
	if bpp == 32 && masks[3] == 0 && !has_masks {
		// BI_RGB 32 bits: the fourth byte is alpha only when some pixel sets it
		for y in 0 ..< h {
			row := dib[at + y * stride:][:w * 4]
			for x in 0 ..< w { if row[4 * x + 3] != 0 { use_alpha_byte = true; break } }
			if use_alpha_byte { break }
		}
	}
	out := make([]u8, w * h * 4, allocator)
	for y in 0 ..< h {
		row := dib[at + (top_down ? y : h - 1 - y) * stride:][:stride]
		dst := out[y * w * 4:][:w * 4]
		for x in 0 ..< w {
			r, g, b, a: u8 = 0, 0, 0, 255
			switch bpp {
			case 1, 4, 8:
				bits := uint(bpp)
				byte_i := x * bpp / 8
				shift := 8 - bits - uint(x * bpp % 8)
				idx := int(row[byte_i] >> shift) & ((1 << bits) - 1)
				if idx < colors {
					p := dib[palette + idx * pal_entry:]
					b, g, r = p[0], p[1], p[2]
				}
			case 24:
				b, g, r = row[3 * x], row[3 * x + 1], row[3 * x + 2]
			case 16, 32:
				v: u32
				if bpp == 16 { v = u32(row[2 * x]) | u32(row[2 * x + 1]) << 8 } else { v = get32(row, 4 * x) }
				r, g, b = channel(v, masks[0]), channel(v, masks[1]), channel(v, masks[2])
				if masks[3] != 0 { a = channel(v, masks[3]) } else if use_alpha_byte { a = u8(v >> 24) }
			}
			dst[4 * x], dst[4 * x + 1], dst[4 * x + 2], dst[4 * x + 3] = r, g, b, a
		}
	}
	return {out, {w, h}}, true
}

// CF_HDROP's bytes for a list of paths: a DROPFILES header, then the paths in UTF-16, each ended by a zero, and a last
// zero.
hdrop_encode :: proc(paths: []string, allocator := context.allocator) -> []u8 {
	units := 1
	for p in paths { units += utf16_count(p) + 1 }
	out := make([]u8, DROPFILES_BYTES + units * 2, allocator)
	put32(out, 0, DROPFILES_BYTES)   // pFiles
	put32(out, DROPFILES_FWIDE_AT, 1)
	at := DROPFILES_BYTES
	for p in paths {
		for r in p {
			buf: [2]u16
			n := utf16.encode(buf[:], []rune{r})
			for i in 0 ..< n { out[at], out[at + 1] = u8(buf[i]), u8(buf[i] >> 8); at += 2 }
		}
		at += 2
	}
	return out
}

// The paths of CF_HDROP's bytes (UTF-16 or, from old programs, the system's ANSI code page read as Latin-1). Each path
// and the slice are allocated with `allocator`.
hdrop_decode :: proc(b: []u8, allocator := context.allocator) -> []string {
	if len(b) < DROPFILES_BYTES { return nil }
	at := int(get32(b, 0))
	wide := get32(b, DROPFILES_FWIDE_AT) != 0
	if at < DROPFILES_BYTES || at > len(b) { return nil }
	out := make([dynamic]string, allocator)
	for at < len(b) {
		sb := strings.builder_make(allocator)
		if wide {
			start := at
			for at + 1 < len(b) && (b[at] != 0 || b[at + 1] != 0) { at += 2 }
			units := make([]u16, (at - start) / 2, context.temp_allocator)
			for i in 0 ..< len(units) { units[i] = u16(b[start + 2 * i]) | u16(b[start + 2 * i + 1]) << 8 }
			runes := make([]rune, len(units), context.temp_allocator)
			n := utf16.decode(runes, units)
			for r in runes[:n] { strings.write_rune(&sb, r) }
			at += 2
		} else {
			for at < len(b) && b[at] != 0 { strings.write_rune(&sb, rune(b[at])); at += 1 }
			at += 1
		}
		s := strings.to_string(sb)
		if s == "" { strings.builder_destroy(&sb); break }
		append(&out, s)
	}
	return out[:]
}

// The SourceURL of an "HTML Format" block's header ("" when none): a view into `s`.
html_format_source_url :: proc(s: string) -> string {
	end := len(s)
	if h := index_of(s, "<"); h >= 0 { end = h }   // (the header ends where the markup starts)
	i := index_of(s[:end], "SourceURL:")
	if i < 0 { return "" }
	rest := s[i + len("SourceURL:"):end]
	j := 0
	for j < len(rest) && rest[j] != '\r' && rest[j] != '\n' { j += 1 }
	return rest[:j]
}

@(private)
utf16_count :: proc(s: string) -> int {
	n := 0
	for r in s { n += r >= UTF16_FIRST_PAIR_RUNE ? 2 : 1 }
	return n
}

@(private)
channel :: proc(v, mask: u32) -> u8 {
	if mask == 0 { return 0 }
	shift: u32 = 0
	for (mask >> shift) & 1 == 0 { shift += 1 }
	bits: u32 = 0
	for bits + shift < 32 && (mask >> (shift + bits)) & 1 == 1 { bits += 1 }
	x := (v & mask) >> shift
	maxv := (u32(1) << bits) - 1
	if bits >= 32 { maxv = max(u32) }
	return u8((u64(x) * 255 + u64(maxv) / 2) / u64(maxv))
}

@(private)
put32 :: proc(b: []u8, at: int, v: u32) { b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
@(private)
get32 :: proc(b: []u8, at: int) -> u32 { return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24 }
@(private)
get16 :: proc(b: []u8, at: int) -> u16 { return u16(b[at]) | u16(b[at + 1]) << 8 }
