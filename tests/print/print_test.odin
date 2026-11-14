// The pure parts of printing (platform/print.odin): where a picture goes on its page (natural size, smaller to fit,
// never larger, centred), and the one-page PDF the print portal gets (its structure, its cross-reference table, its
// pixels laid over white). The system's print dialog needs a person: it is never shown here.
//   odin test tests/print -vet
package print_test

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../../src/flate"
import "../../src/platform"

@(test)
a_small_picture_keeps_its_natural_size_centred :: proc(t: ^testing.T) {
	// 96 pixels at 96 an inch: one inch, 72 points, in the middle of A4
	x, y, w, h := platform.print_fit({96, 48}, platform.PRINT_A4_PT, 34, 72)
	testing.expect_value(t, w, 72.0)
	testing.expect_value(t, h, 36.0)
	testing.expect(t, abs(x - (platform.PRINT_A4_PT.x - 72) / 2) < 1e-9 && abs(y - (platform.PRINT_A4_PT.y - 36) / 2) < 1e-9, "centred")
}

@(test)
a_large_picture_shrinks_to_the_margins :: proc(t: ^testing.T) {
	// a 4K screen, wider than the page: its width fills the room inside the margins, its ratio kept
	page := [2]f64{600, 800}
	x, y, w, h := platform.print_fit({3840, 2160}, page, 50, 72)
	testing.expect(t, abs(w - 500) < 1e-9, "as wide as the room")
	testing.expect(t, abs(h - 500 * 2160.0 / 3840) < 1e-9, "the ratio kept")
	testing.expect(t, abs(x - 50) < 1e-9 && y > 50, "inside the margins")
	// a tall one: its height fills the room
	_, _, w2, h2 := platform.print_fit({500, 20000}, page, 50, 72)
	testing.expect(t, abs(h2 - 700) < 1e-9 && w2 < 500, "as tall as the room")
}

@(test)
nothing_fits_nowhere :: proc(t: ^testing.T) {
	_, _, w, h := platform.print_fit({0, 10}, {600, 800}, 10, 72)
	testing.expect(t, w == 0 && h == 0, "no pixel")
	_, _, w, h = platform.print_fit({10, 10}, {100, 100}, 60, 72)
	testing.expect(t, w == 0 && h == 0, "margins larger than the page")
	testing.expect(t, platform.print_pdf(nil, {4, 4}, platform.PRINT_A4_PT, allocator = context.temp_allocator) == nil, "no pixels, no file")
}

@(test)
the_pdf_is_one_page_with_its_picture :: proc(t: ^testing.T) {
	// 2 x 1: an opaque red pixel, a transparent one (white on paper)
	rgba := []u8{255, 0, 0, 255, 0, 0, 0, 0}
	pdf := platform.print_pdf(rgba, {2, 1}, {200, 100}, 10, context.temp_allocator)
	text := string(pdf)
	testing.expect(t, strings.has_prefix(text, "%PDF-1.4\n"), "the header")
	testing.expect(t, strings.has_suffix(text, "%%EOF\n"), "the end")
	testing.expect(t, strings.contains(text, "/MediaBox [0 0 200.00 100.00]"), "the page's size")
	testing.expect(t, strings.contains(text, "/Width 2 /Height 1"), "the picture's size")

	// each offset of the cross-reference table is where its object starts
	xref := strings.last_index(text, "xref\n0 6\n")
	if !testing.expect(t, xref > 0, "a cross-reference table") { return }
	after := text[strings.last_index(text, "startxref\n") + len("startxref\n"):]
	start, _ := strconv.parse_int(after[:strings.index_byte(after, '\n')])
	testing.expect_value(t, start, xref)
	lines := strings.split_lines(text[xref:], context.temp_allocator)
	for n in 1 ..< 6 {
		off, _ := strconv.parse_int(lines[2 + n][:10])
		want := fmt.tprintf("%d 0 obj", n)
		testing.expectf(t, strings.has_prefix(text[off:], want), "object %d at its offset", n)
	}

	// the pixels, inflated: red, then white (the transparent pixel over the paper)
	at := strings.index(text, "stream\n") + len("stream\n")
	end := strings.index(text[at:], "\nendstream")
	pixels, err := flate.inflate(.Zlib, pdf[at:][:end], allocator = context.temp_allocator)
	testing.expect_value(t, err, flate.Error.None)
	want := [?]u8{255, 0, 0, 255, 255, 255}
	testing.expect(t, string(pixels) == string(want[:]), "RGB, alpha over white")
}
