package platform

// Printing a picture through the system's print dialog, one page, the picture fitted to it (docs/printing.md):
//
//   status := platform.print_image(win, "Screenshot", rgba, {w, h})   // blocks until the person is done: a worker's
//
//   * Linux: the XDG print portal (org.freedesktop.portal.Print): PreparePrint shows the dialog (printer, paper,
//     copies) and answers with a token and the page setup; Print then gets the page as a PDF file (print_pdf), passed
//     as a file descriptor. Unsupported when the portal is absent or the bus cannot pass descriptors.
//   * Windows: the common Print dialog (PrintDlgW), then GDI on the printer's device context (StretchDIBits).
//   * Other systems: Unsupported.
//
// The picture is laid out at its natural size (PRINT_PICTURE_DPI pixels an inch), made smaller to fit inside the
// margins, never larger, and centred (print_fit). Alpha is laid over white: paper has no transparency.
//
// Printing a document of several pages (src/md/features/printing.md):
//
//   status := platform.print_document(win, doc)   // blocks as print_image does: a worker's
//
//   * Linux: the same portal; Print gets doc.pdf as it is when the program has it (the printer gets vectors), else a
//     PDF of the pages the program renders (print_document_pdf).
//   * Windows: the common Print dialog with its page range and copies (PrintDlgExW), then each page rendered at the
//     printer's resolution and drawn a band at a time (print_page_fit places it).

import "core:fmt"
import "core:io"
import "core:math"
import "core:strings"
import "../flate"

Print_Status :: enum u8 { Printed, Cancelled, Unsupported, Failed }

// The pixels of a picture in an inch of paper at its natural size: a screen's (96 at a scale of 100 %).
PRINT_PICTURE_DPI :: 96

// The margin on each side when the system says none, in points (1/72 inch): about 12 mm.
PRINT_MARGIN_PT :: 34

// A4, in points: the page when the system says none.
PRINT_A4_PT :: [2]f64{595.28, 841.89}

POINTS_PER_INCH :: 72
MM_PER_INCH :: 25.4

// Where a picture of `picture` pixels goes on a page of `page` units with `margin` on each side (the same units: points
// for the PDF, device pixels for GDI), at `units_per_inch`: its natural size, made smaller to fit, centred. x and y
// from the top left. Zero for a picture with no pixel or a page with no room.
print_fit :: proc(picture: [2]int, page: [2]f64, margin: f64, units_per_inch: f64) -> (x, y, w, h: f64) {
	if picture.x <= 0 || picture.y <= 0 { return }
	room := page - 2 * margin
	if room.x <= 0 || room.y <= 0 { return }
	k := units_per_inch / PRINT_PICTURE_DPI
	w, h = f64(picture.x) * k, f64(picture.y) * k
	if w > room.x || h > room.y {
		s := min(room.x / w, room.y / h)
		w, h = w * s, h * s
	}
	return (page.x - w) / 2, (page.y - h) / 2, w, h
}

// A PDF of one page of `page` points (width, height) showing the picture (straight RGBA, alpha over white) as
// print_fit places it: what the print portal is given. Lossless (the pixels deflated). nil for a picture with no pixel.
print_pdf :: proc(rgba: []u8, size: [2]int, page: [2]f64, margin: f64 = PRINT_MARGIN_PT, allocator := context.allocator) -> []u8 {
	w, h := size.x, size.y
	if w <= 0 || h <= 0 || len(rgba) < w * h * 4 { return nil }
	rgb := make([]u8, w * h * 3, context.temp_allocator)
	print_rgb_over_white(rgba[:w * h * 4], rgb)
	pixels := flate.deflate(.Zlib, rgb, context.temp_allocator)
	x, y, pw, ph := print_fit(size, page, margin, POINTS_PER_INCH)
	// (PDF's origin is the bottom left: the picture's top is page.y - y)
	content := fmt.tprintf("q %.3f 0 0 %.3f %.3f %.3f cm /Im0 Do Q\n", pw, ph, x, page.y - y - ph)

	out := strings.builder_make(allocator)
	offsets: [6]int
	strings.write_string(&out, "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n")
	object :: proc(out: ^strings.Builder, offsets: ^[6]int, n: int, text: string) {
		offsets[n] = strings.builder_len(out^)
		fmt.sbprintf(out, "%d 0 obj\n%s\nendobj\n", n, text)
	}
	object(&out, &offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>")
	object(&out, &offsets, 2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
	object(&out, &offsets, 3, fmt.tprintf("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>", page.x, page.y))
	offsets[4] = strings.builder_len(out)
	fmt.sbprintf(&out, "4 0 obj\n<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n", w, h, len(pixels))
	strings.write_bytes(&out, pixels)
	strings.write_string(&out, "\nendstream\nendobj\n")
	offsets[5] = strings.builder_len(out)
	fmt.sbprintf(&out, "5 0 obj\n<< /Length %d >>\nstream\n%sendstream\nendobj\n", len(content), content)
	xref := strings.builder_len(out)
	strings.write_string(&out, "xref\n0 6\n0000000000 65535 f \n")
	for n in 1 ..< 6 { fmt.sbprintf(&out, "%010d 00000 n \n", offsets[n]) }
	fmt.sbprintf(&out, "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", xref)
	return out.buf[:]
}

// A document to print: its pages, their sizes, and how to draw them. Pages count from 0.
//
// page_size and render run on the thread that calls print_document, never the interface's: they must be safe there
// for the program's engine. render draws the rows rows[0] ..< rows[1] of the page drawn at size pixels (the whole
// page's size, not the band's) into out, straight RGBA, rows from the top: out holds exactly
// (rows[1] - rows[0]) * size.x * 4 bytes. A band at a time keeps the memory bounded at a printer's resolution.
// False stops the job (Failed).
//
// pdf is the document as a PDF file, when the program has it: the Linux portal then prints it as it is, and its
// printer gets vectors. Windows always renders (GDI takes no PDF).
Print_Document :: struct {
	title:      string,
	page_count: int,
	user:       rawptr,
	page_size:  proc(user: rawptr, page: int) -> [2]f64,   // points (1/72 inch), width and height
	render:     proc(user: rawptr, page: int, size: [2]int, rows: [2]int, out: []u8) -> bool,
	pdf:        []u8,
}

// The resolution of the pages rendered into a PDF for the print portal: a printer's usual, text stays sharp.
PRINT_DOCUMENT_DPI :: 300

// The most RGBA bytes rendered at once: a band of a page. A4 at 300 dots an inch is one band; at 600, three.
PRINT_BAND_BYTES :: 64 << 20

// The most pixels on a side of a rendered page: a page of a poster's size is drawn coarser, not out of memory.
PRINT_PAGE_MAX_PX :: 20000

// The rows of a page `width` pixels wide in one band: at least one.
print_band_rows :: proc(width: int) -> int {
	return max(1, PRINT_BAND_BYTES / max(1, width * 4))
}

// Where a document's page of `page` points goes on a printer's sheet, in device dots from the top left of the
// printable area (`area` dots, `offset` dots from the sheet's corner, the sheet `paper` dots), at `dpi` dots an inch
// on each axis: its natural size, made smaller to fit the printable area, never larger; centred on the sheet when it
// fits there, else pushed inside the printable area. A `paper` of zero is the printable area. Zero for a page with
// no size or a device with no room.
print_page_fit :: proc(page: [2]f64, paper, offset, area: [2]f64, dpi: [2]f64) -> (x, y, w, h: f64) {
	if page.x <= 0 || page.y <= 0 || area.x <= 0 || area.y <= 0 || dpi.x <= 0 || dpi.y <= 0 { return }
	natural := page / POINTS_PER_INCH * dpi
	s := min(1, area.x / natural.x, area.y / natural.y)
	w, h = natural.x * s, natural.y * s
	sheet, at := paper, offset
	if sheet.x <= 0 || sheet.y <= 0 {
		sheet = area
		at = {}
	}
	x = clamp((sheet.x - w) / 2 - at.x, 0, area.x - w)
	y = clamp((sheet.y - h) / 2 - at.y, 0, area.y - h)
	return
}

// The pixels of a page of `page` points at `dpi` dots an inch, at most PRINT_PAGE_MAX_PX on a side (its ratio kept).
@(private)
print_page_pixels :: proc(page: [2]f64, dpi: f64) -> [2]int {
	px := page / POINTS_PER_INCH * dpi
	if big := max(px.x, px.y); big > PRINT_PAGE_MAX_PX { px *= PRINT_PAGE_MAX_PX / big }
	return {max(1, int(math.ceil(px.x))), max(1, int(math.ceil(px.y)))}
}

// Straight RGBA laid over white, into RGB: paper has no transparency.
@(private)
print_rgb_over_white :: proc(rgba: []u8, rgb: []u8) {
	for i in 0 ..< len(rgba) / 4 {
		p := rgba[i * 4:][:4]
		a := u32(p[3])
		for c in 0 ..< 3 { rgb[i * 3 + c] = u8((u32(p[c]) * a + 255 * (255 - a) + 127) / 255) }
	}
}

// A PDF writer that counts its bytes (the cross-reference table needs each object's offset) and stops at the first
// error of its output.
@(private = "file")
Pdf_Out :: struct {
	w:       io.Writer,
	at:      int,
	ok:      bool,
	offsets: [dynamic]int,
}

@(private = "file")
pdf_put :: proc(p: ^Pdf_Out, bytes: []u8) {
	if !p.ok || len(bytes) == 0 { return }
	n, err := io.write(p.w, bytes)
	p.at += n
	if err != nil || n != len(bytes) { p.ok = false }
}

@(private = "file")
pdf_putf :: proc(p: ^Pdf_Out, format: string, args: ..any) {
	buf: [256]u8
	pdf_put(p, transmute([]u8)fmt.bprintf(buf[:], format, ..args))
}

@(private = "file")
pdf_object :: proc(p: ^Pdf_Out, n: int) {
	for len(p.offsets) <= n { append(&p.offsets, 0) }
	p.offsets[n] = p.at
	pdf_putf(p, "%d 0 obj\n", n)
}

// The document as a PDF of pictures, written to `out` as it is made: each page at its size in points, its pixels
// rendered at `dpi` (PRINT_DOCUMENT_DPI by default) a band at a time, each band one image deflated (lossless), laid
// edge to edge. What the print portal gets when the program has no PDF of its own. False: no page, a page with no
// size, a render or the output failed.
print_document_pdf :: proc(doc: Print_Document, out: io.Writer, dpi: f64 = PRINT_DOCUMENT_DPI) -> bool {
	if doc.page_count <= 0 || doc.page_size == nil || doc.render == nil || dpi <= 0 { return false }
	p := Pdf_Out{w = out, ok = true}
	defer delete(p.offsets)
	kids := make([]int, doc.page_count)
	defer delete(kids)
	rgba, rgb: [dynamic]u8
	defer { delete(rgba); delete(rgb) }

	pdf_put(&p, transmute([]u8)string("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"))
	pdf_object(&p, 1)
	pdf_putf(&p, "<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
	next := 3
	for page in 0 ..< doc.page_count {
		size := doc.page_size(doc.user, page)
		if size.x <= 0 || size.y <= 0 { return false }
		px := print_page_pixels(size, dpi)
		band := print_band_rows(px.x)
		bands := (px.y + band - 1) / band
		page_n, content_n, first_image := next, next + 1, next + 2
		next += 2 + bands
		kids[page] = page_n

		pdf_object(&p, page_n)
		pdf_putf(&p, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] /Resources << /XObject <<", size.x, size.y)
		for b in 0 ..< bands { pdf_putf(&p, " /B%d %d 0 R", b, first_image + b) }
		pdf_putf(&p, " >> >> /Contents %d 0 R >>\nendobj\n", content_n)

		// each band where its rows fall (PDF's origin is the bottom left)
		content := strings.builder_make()
		defer strings.builder_destroy(&content)
		for b in 0 ..< bands {
			y0, y1 := b * band, min(px.y, (b + 1) * band)
			bh := size.y * f64(y1 - y0) / f64(px.y)
			bottom := size.y - size.y * f64(y1) / f64(px.y)
			fmt.sbprintf(&content, "q %.4f 0 0 %.4f 0 %.4f cm /B%d Do Q\n", size.x, bh, bottom, b)
		}
		pdf_object(&p, content_n)
		pdf_putf(&p, "<< /Length %d >>\nstream\n", strings.builder_len(content))
		pdf_put(&p, content.buf[:])
		pdf_putf(&p, "endstream\nendobj\n")

		for b in 0 ..< bands {
			y0, y1 := b * band, min(px.y, (b + 1) * band)
			n := (y1 - y0) * px.x
			resize(&rgba, n * 4)
			resize(&rgb, n * 3)
			// (a renderer that leaves pixels untouched leaves paper, not the last band)
			for &c in rgba { c = 255 }
			if !doc.render(doc.user, page, px, {y0, y1}, rgba[:]) { return false }
			print_rgb_over_white(rgba[:], rgb[:])
			pixels := flate.deflate(.Zlib, rgb[:])
			pdf_object(&p, first_image + b)
			pdf_putf(&p, "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n", px.x, y1 - y0, len(pixels))
			pdf_put(&p, pixels)
			delete(pixels)
			pdf_putf(&p, "\nendstream\nendobj\n")
		}
		if !p.ok { return false }
	}

	pdf_object(&p, 2)
	pdf_putf(&p, "<< /Type /Pages /Kids [")
	for k in kids { pdf_putf(&p, "%d 0 R ", k) }
	pdf_putf(&p, "] /Count %d >>\nendobj\n", doc.page_count)
	xref := p.at
	pdf_putf(&p, "xref\n0 %d\n0000000000 65535 f \n", next)
	for n in 1 ..< next { pdf_putf(&p, "%010d 00000 n \n", p.offsets[n]) }
	pdf_putf(&p, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", next, xref)
	return p.ok
}
