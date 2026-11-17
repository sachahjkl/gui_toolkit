package pdf_test

// gt:pdf through the native library: a file written from a blank page with a stamp opens, its page renders the stamp
// where it was put, and a list that turns and repeats its pages writes a file of those pages.

import "core:testing"
import pdf "gt:pdf"

@(private = "file")
dark :: proc(px: []u8, w, x, y: int) -> bool {
	i := (y * w + x) * 4
	return px[i] < 64 && px[i + 1] < 64 && px[i + 2] < 64
}

@(test)
a_written_page_opens_renders_and_writes_again :: proc(t: ^testing.T) {
	testing.expect(t, pdf.available(), "built with GT_PDF")
	stamp := pdf.Stamp{at = {20, 30}, size = 20, font = {family = .Serif, bold = true}, color = {255, 255, 255}, background = {0, 0, 0, 255}, text = "Été €"}
	size := pdf.stamp_size(stamp)
	testing.expectf(t, size.x > 40 && size.y > 20, "a stamp has its size (%v)", size)

	bytes, ok := pdf.write({{size = {200, 100}, stamps = {stamp}}})
	defer delete(bytes)
	testing.expect(t, ok && len(bytes) > 100, "a blank page with a stamp is written")
	src, err := pdf.open(bytes)
	defer pdf.close(src)
	testing.expectf(t, err == .None, "the file opens (%v)", err)
	testing.expect_value(t, pdf.page_count(src), 1)
	got, sized := pdf.page_size(src, 0)
	testing.expect(t, sized && got == {200, 100}, "the page keeps its size")

	px := pdf.render({source = src}, 200, 100)
	defer delete(px)
	testing.expect(t, px != nil, "the page renders")
	testing.expect(t, !dark(px, 200, 5, 5), "the paper is white")
	testing.expect(t, dark(px, 200, 22, 32), "the stamp's background is at its corner")

	twice, written := pdf.write({{source = src, index = 0, turns = 1}, {source = src, index = 0}}, base = src)
	defer delete(twice)
	testing.expect(t, written, "a list of the same page twice is written")
	again, err2 := pdf.open(twice)
	defer pdf.close(again)
	testing.expect(t, err2 == .None && pdf.page_count(again) == 2, "it has the two pages")
	first, _ := pdf.page_size(again, 0)
	testing.expectf(t, first == {100, 200}, "the turned one is turned (%v)", first)
	testing.expect_value(t, pdf.shown_size({source = again, index = 1, turns = 3}), [2]f32{100, 200})
}

@(test)
what_is_not_a_pdf_is_refused :: proc(t: ^testing.T) {
	src, err := pdf.open(transmute([]u8)string("not a pdf"))
	testing.expect(t, src == 0 && err == .Format, "refused as not a PDF")
}
