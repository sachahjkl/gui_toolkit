// The pure parts of printing (platform/print.odin): where a picture goes on its page (natural size, smaller to fit,
// never larger, centred), and the one-page PDF the print portal gets (its structure, its cross-reference table, its
// pixels laid over white); where a document's page goes on a printer's sheet, and the PDF of a document's rendered
// pages. The system's print dialog needs a person: it is never shown here, and nothing goes to a printer.
//   odin test tests/print -collection:gt=src -vet
package print_test

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "gt:flate"
import "gt:platform"

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

@(test)
a_document_page_fits_the_printable_area_centred_on_the_sheet :: proc(t: ^testing.T) {
	// a small page at 300 dots an inch keeps its size, centred on the sheet (not on the printable area)
	x, y, w, h := platform.print_page_fit({200, 200}, {2550, 3300}, {50, 60}, {2450, 3180}, {300, 300})
	testing.expect(t, abs(w - 2500.0 / 3) < 1e-6 && abs(h - 2500.0 / 3) < 1e-6, "its natural size")
	testing.expect(t, abs(x - ((2550 - 2500.0 / 3) / 2 - 50)) < 1e-6 && abs(y - ((3300 - 2500.0 / 3) / 2 - 60)) < 1e-6, "centred on the sheet")
	// a full Letter page at 600 shrinks to the printable area, its ratio kept, and stays inside it
	x, y, w, h = platform.print_page_fit({612, 792}, {5100, 6600}, {100, 100}, {4900, 6400}, {600, 600})
	testing.expect(t, abs(w - 4900) < 1e-6, "as wide as the printable area")
	testing.expect(t, abs(w / h - 612.0 / 792) < 1e-9, "its ratio kept")
	testing.expect(t, x >= 0 && y >= 0 && x + w <= 4900 + 1e-6 && y + h <= 6400 + 1e-6, "inside the printable area")
	// a printer whose dots are not square: an inch is 600 dots across and 300 down
	_, _, w, h = platform.print_page_fit({72, 72}, {}, {}, {6000, 6000}, {600, 300})
	testing.expect(t, w == 600 && h == 300, "each axis at its own resolution")
	_, _, w, h = platform.print_page_fit({0, 72}, {}, {}, {6000, 6000}, {600, 600})
	testing.expect(t, w == 0 && h == 0, "a page with no size")
}

@(private = "file")
Two_Pages :: struct {
	rows_drawn: [2]int,
}

@(private = "file")
two_pages_size :: proc(user: rawptr, page: int) -> [2]f64 {
	if page == 0 { return {200, 100} }
	return {100, 300}
}

// page 0 red, page 1 blue, opaque
@(private = "file")
two_pages_render :: proc(user: rawptr, page: int, size: [2]int, rows: [2]int, out: []u8) -> bool {
	d := (^Two_Pages)(user)
	if len(out) != (rows[1] - rows[0]) * size.x * 4 { return false }
	for i in 0 ..< len(out) / 4 {
		out[i * 4 + 0] = page == 0 ? 255 : 0
		out[i * 4 + 1] = 0
		out[i * 4 + 2] = page == 0 ? 0 : 255
		out[i * 4 + 3] = 255
	}
	d.rows_drawn[page] += rows[1] - rows[0]
	return true
}

@(test)
a_document_becomes_a_pdf_of_its_rendered_pages :: proc(t: ^testing.T) {
	d: Two_Pages
	doc := platform.Print_Document{title = "Two", page_count = 2, user = &d, page_size = two_pages_size, render = two_pages_render}
	b := strings.builder_make(context.temp_allocator)
	// (72 dots an inch: a pixel a point, the sizes read back exactly)
	testing.expect(t, platform.print_document_pdf(doc, strings.to_writer(&b), 72), "written")
	text := strings.to_string(b)
	testing.expect(t, strings.has_prefix(text, "%PDF-1.4\n"), "the header")
	testing.expect(t, strings.has_suffix(text, "%%EOF\n"), "the end")
	testing.expect_value(t, strings.count(text, "/Type /Page /"), 2)
	testing.expect(t, strings.contains(text, "/Count 2"), "two pages counted")
	testing.expect(t, strings.contains(text, "/MediaBox [0 0 200.00 100.00]"), "the first page's size")
	testing.expect(t, strings.contains(text, "/MediaBox [0 0 100.00 300.00]"), "the second page's size")
	testing.expect(t, strings.contains(text, "/Width 200 /Height 100"), "the first page's pixels")
	testing.expect(t, strings.contains(text, "/Width 100 /Height 300"), "the second page's pixels")
	testing.expect(t, d.rows_drawn == {100, 300}, "every row rendered once")

	// each offset of the cross-reference table is where its object starts
	after := text[strings.last_index(text, "startxref\n") + len("startxref\n"):]
	xref, _ := strconv.parse_int(after[:strings.index_byte(after, '\n')])
	if !testing.expect(t, strings.has_prefix(text[xref:], "xref\n0 "), "startxref points at the table") { return }
	lines := strings.split_lines(text[xref:], context.temp_allocator)
	count, _ := strconv.parse_int(lines[1][2:])
	testing.expect(t, count > 5, "the objects of two pages")
	for n in 1 ..< count {
		off, _ := strconv.parse_int(lines[2 + n][:10])
		testing.expectf(t, strings.has_prefix(text[off:], fmt.tprintf("%d 0 obj", n)), "object %d at its offset", n)
	}
	testing.expect(t, strings.contains(text, fmt.tprintf("/Size %d ", count)), "the trailer's size")

	// the second page's pixels, inflated: blue
	at := strings.index(text, "/Width 100 /Height 300")
	at += strings.index(text[at:], "stream\n") + len("stream\n")
	end := strings.index(text[at:], "\nendstream")
	pixels, err := flate.inflate(.Zlib, transmute([]u8)text[at:][:end], allocator = context.temp_allocator)
	testing.expect_value(t, err, flate.Error.None)
	testing.expect_value(t, len(pixels), 100 * 300 * 3)
	testing.expect(t, len(pixels) >= 3 && pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 255, "blue")
}

@(test)
a_document_with_nothing_to_draw_is_no_pdf :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	testing.expect(t, !platform.print_document_pdf({page_count = 0, page_size = two_pages_size, render = two_pages_render}, strings.to_writer(&b)), "no page")
	testing.expect(t, !platform.print_document_pdf({page_count = 2}, strings.to_writer(&b)), "no render")
	testing.expect(t, platform.print_band_rows(1 << 30) == 1, "a band is at least a row")
}
