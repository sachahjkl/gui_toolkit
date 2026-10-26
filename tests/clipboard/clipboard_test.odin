// The conversions of the rich clipboard (platform/clipboard.odin): bitmaps (every header, depth and orientation) to and
// from RGBA, the file list of CF_HDROP, the "HTML Format" offsets and source URL, PNG. The user's clipboard is never
// touched: the calls that read or write it are thin layers over these conversions.
//   odin test tests/clipboard -vet
package clipboard_test

import "core:strconv"
import "core:strings"
import "core:testing"
import "../../platform"

@(private = "file")
put32 :: proc(b: []u8, at: int, v: u32) { b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }

// A BITMAPINFOHEADER-based DIB: header (40), then `extra` (masks or palette), then the rows given (already padded).
@(private = "file")
dib :: proc(w, h: int, bpp: int, compression: u32, extra: []u8, rows: []u8, colors := 0) -> []u8 {
	out := make([]u8, 40 + len(extra) + len(rows), context.temp_allocator)
	put32(out, 0, 40)
	put32(out, 4, u32(i32(w)))
	put32(out, 8, u32(i32(h)))
	out[12], out[14] = 1, u8(bpp)
	put32(out, 16, compression)
	put32(out, 32, u32(colors))
	copy(out[40:], extra)
	copy(out[40 + len(extra):], rows)
	return out
}

@(private = "file")
px :: proc(img: platform.Clipboard_Image, x, y: int) -> [4]u8 {
	p := img.rgba[(y * img.size.x + x) * 4:]
	return {p[0], p[1], p[2], p[3]}
}

@(test)
v5_round_trip_keeps_alpha :: proc(t: ^testing.T) {
	src := []u8{255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 40, 1, 2, 3, 4, 200, 100, 50, 25}
	img := platform.Clipboard_Image{src, {3, 2}}
	b := platform.rgba_to_dib(img, .Alpha_V5)
	defer delete(b)
	testing.expect_value(t, len(b), 124 + 3 * 2 * 4)
	out, ok := platform.dib_to_rgba(b)
	defer delete(out.rgba)
	testing.expect(t, ok)
	testing.expect_value(t, out.size, [2]int{3, 2})
	testing.expect(t, string(out.rgba) == string(src), "same pixels")
}

@(test)
opaque_dib_is_over_white :: proc(t: ^testing.T) {
	src := []u8{255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 128}
	b := platform.rgba_to_dib({src, {3, 1}}, .Opaque_Over_White)
	defer delete(b)
	out, ok := platform.dib_to_rgba(b)
	defer delete(out.rgba)
	testing.expect(t, ok)
	testing.expect_value(t, px(out, 0, 0), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(out, 1, 0), [4]u8{255, 255, 255, 255})   // transparent: white
	testing.expect_value(t, px(out, 2, 0), [4]u8{127, 127, 127, 255})   // half black over white
	testing.expect(t, platform.rgba_to_dib({src[:4], {3, 1}}, .Opaque_Over_White) == nil, "too few pixels")
}

@(test)
dib_depths :: proc(t: ^testing.T) {
	// 24 bits, 3 x 2, bottom-up: rows padded to 12 bytes; the bottom row comes first
	rows24 := []u8{
		0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0,          // bottom: red green blue
		255, 255, 255, 0, 0, 0, 128, 128, 128, 0, 0, 0,    // top: white black grey
	}
	img, ok := platform.dib_to_rgba(dib(3, 2, 24, 0, nil, rows24))
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, px(img, 2, 0), [4]u8{128, 128, 128, 255})
	testing.expect_value(t, px(img, 0, 1), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(img, 2, 1), [4]u8{0, 0, 255, 255})
	delete(img.rgba)

	// top-down (negative height)
	img, ok = platform.dib_to_rgba(dib(3, -2, 24, 0, nil, rows24))
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{255, 0, 0, 255})
	delete(img.rgba)

	// 8 bits with a palette of 2 colours (biClrUsed)
	pal := []u8{0, 0, 255, 0, 0, 255, 0, 0}   // red, green (BGRX)
	img, ok = platform.dib_to_rgba(dib(2, 1, 8, 0, pal, []u8{1, 0, 0, 0}, colors = 2))
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, px(img, 1, 0), [4]u8{255, 0, 0, 255})
	delete(img.rgba)

	// 1 bit: black and white, most significant bit first
	pal1 := []u8{0, 0, 0, 0, 255, 255, 255, 0}
	img, ok = platform.dib_to_rgba(dib(3, 1, 1, 0, pal1, []u8{0b1010_0000, 0, 0, 0}))
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, px(img, 1, 0), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, px(img, 2, 0), [4]u8{255, 255, 255, 255})
	delete(img.rgba)

	// 16 bits 5-5-5 (BI_RGB): pure red 0x7C00
	img, ok = platform.dib_to_rgba(dib(1, 1, 16, 0, nil, []u8{0x00, 0x7C, 0, 0}))
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{255, 0, 0, 255})
	delete(img.rgba)

	// 16 bits 5-6-5 (BI_BITFIELDS, masks after a 40-byte header): green 0x07E0
	masks := make([]u8, 12, context.temp_allocator)
	put32(masks, 0, 0xF800); put32(masks, 4, 0x07E0); put32(masks, 8, 0x001F)
	img, ok = platform.dib_to_rgba(dib(1, 1, 16, 3, masks, []u8{0xE0, 0x07, 0, 0}))
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{0, 255, 0, 255})
	delete(img.rgba)
	free_all(context.temp_allocator)
}

@(test)
dib_32_bit_alpha_byte :: proc(t: ^testing.T) {
	// BI_RGB 32 bits with every fourth byte zero: opaque
	img, ok := platform.dib_to_rgba(dib(2, 1, 32, 0, nil, []u8{10, 20, 30, 0, 40, 50, 60, 0}))
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{30, 20, 10, 255})
	delete(img.rgba)
	// ... with some set: they are the alpha
	img, ok = platform.dib_to_rgba(dib(2, 1, 32, 0, nil, []u8{10, 20, 30, 0, 40, 50, 60, 77}))
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{30, 20, 10, 0})
	testing.expect_value(t, px(img, 1, 0), [4]u8{60, 50, 40, 77})
	delete(img.rgba)
	free_all(context.temp_allocator)
}

// A V5 header with the three masks repeated after it (seen from some writers): the rows are found after them.
@(test)
dib_v5_with_trailing_masks :: proc(t: ^testing.T) {
	b := platform.rgba_to_dib({[]u8{1, 2, 3, 4}, {1, 1}}, .Alpha_V5)
	defer delete(b)
	quirk := make([]u8, len(b) + 12)
	defer delete(quirk)
	copy(quirk, b[:124])
	put32(quirk, 124, 0x00FF0000); put32(quirk, 128, 0x0000FF00); put32(quirk, 132, 0x000000FF)
	copy(quirk[136:], b[124:])
	img, ok := platform.dib_to_rgba(quirk)
	defer delete(img.rgba)
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{1, 2, 3, 4})
}

@(test)
dib_refused :: proc(t: ^testing.T) {
	_, ok := platform.dib_to_rgba(dib(2, 2, 8, 1, nil, []u8{0, 0}))   // BI_RLE8
	testing.expect(t, !ok, "compressed")
	_, ok = platform.dib_to_rgba(dib(4, 4, 24, 0, nil, []u8{0, 0, 0}))
	testing.expect(t, !ok, "truncated rows")
	_, ok = platform.dib_to_rgba([]u8{1, 2, 3})
	testing.expect(t, !ok, "no header")
	_, ok = platform.dib_to_rgba(dib(0, 2, 24, 0, nil, nil))
	testing.expect(t, !ok, "no width")
	free_all(context.temp_allocator)
}

@(test)
core_header :: proc(t: ^testing.T) {
	b := make([]u8, 12 + 4, context.temp_allocator)
	put32(b, 0, 12)
	b[4], b[6], b[8], b[10] = 1, 1, 1, 24   // 1 x 1, 24 bits
	b[12], b[13], b[14] = 9, 8, 7
	img, ok := platform.dib_to_rgba(b)
	testing.expect(t, ok)
	testing.expect_value(t, px(img, 0, 0), [4]u8{7, 8, 9, 255})
	delete(img.rgba)
	free_all(context.temp_allocator)
}

@(test)
hdrop_round_trip :: proc(t: ^testing.T) {
	paths := []string{`C:\Users\Zoë\notes.txt`, `D:\photos\🌄 dawn.png`, `\\server\share\a b`}
	b := platform.hdrop_encode(paths)
	defer delete(b)
	testing.expect_value(t, b[0], 20)   // pFiles
	testing.expect_value(t, b[16], 1)   // fWide
	back := platform.hdrop_decode(b)
	defer { for p in back { delete(p) }; delete(back) }
	if testing.expect_value(t, len(back), 3) { for p, i in paths { testing.expect_value(t, back[i], p) } }

	// an old program's ANSI list
	ansi := make([]u8, 20 + 12, context.temp_allocator)
	put32(ansi, 0, 20)
	copy(ansi[20:], "C:\\a\x00C:\\b\x00\x00")
	back2 := platform.hdrop_decode(ansi)
	defer { for p in back2 { delete(p) }; delete(back2) }
	if testing.expect_value(t, len(back2), 2) { testing.expect_value(t, back2[1], `C:\b`) }
	testing.expect(t, platform.hdrop_decode([]u8{1, 2}) == nil)
	free_all(context.temp_allocator)
}

@(test)
html_format_offsets :: proc(t: ^testing.T) {
	frag := "<b>caf\u00e9</b> & co"
	s := platform.html_format_wrap(frag, "https://example.test/page")
	defer delete(s)
	field :: proc(s, name: string) -> int {
		i := strings.index(s, name)
		if i < 0 { return -1 }
		v, _ := strconv.parse_int(s[i + len(name):i + len(name) + 10])
		return v
	}
	sf, ef := field(s, "StartFragment:"), field(s, "EndFragment:")
	sh, eh := field(s, "StartHTML:"), field(s, "EndHTML:")
	testing.expect_value(t, s[sf:ef], frag)
	testing.expect(t, strings.has_prefix(s[sh:], "<html>"), "StartHTML is the markup")
	testing.expect_value(t, eh, len(s))
	testing.expect_value(t, platform.html_format_fragment(s), frag)
	testing.expect_value(t, platform.html_format_source_url(s), "https://example.test/page")

	// another program's block: offsets off by a few bytes, the comments still mark the fragment
	other := "Version:1.0\r\nStartHTML:-1\r\nEndHTML:-1\r\nStartFragment:999999\r\nEndFragment:999999\r\n<html><body><!--StartFragment--><i>x</i><!--EndFragment--></body></html>"
	testing.expect_value(t, platform.html_format_fragment(other), "<i>x</i>")
	testing.expect_value(t, platform.html_format_source_url(other), "")
	// a "SourceURL:" inside the markup is not the header's
	testing.expect_value(t, platform.html_format_source_url("Version:0.9\r\n<p>SourceURL:x</p>"), "")
}

@(test)
png_round_trip :: proc(t: ^testing.T) {
	src := []u8{255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 255, 255, 255, 255}
	png := platform.png_encode({src, {2, 2}})
	defer delete(png)
	testing.expect(t, len(png) > 8 && string(png[1:4]) == "PNG", "a PNG file")
	img, ok := platform.png_decode(png)
	defer delete(img.rgba)
	testing.expect(t, ok)
	testing.expect_value(t, img.size, [2]int{2, 2})
	testing.expect(t, string(img.rgba) == string(src), "same pixels")
	_, bad := platform.png_decode([]u8{0x89, 'P', 'N', 'G', 0, 0, 0, 0, 1})
	testing.expect(t, !bad)
}
