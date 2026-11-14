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

import "core:fmt"
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
	for i in 0 ..< w * h {
		p := rgba[i * 4:][:4]
		a := u32(p[3])
		for c in 0 ..< 3 { rgb[i * 3 + c] = u8((u32(p[c]) * a + 255 * (255 - a) + 127) / 255) }
	}
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
