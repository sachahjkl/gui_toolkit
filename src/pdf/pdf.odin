// Package pdf: PDF files opened, their pages rendered, and new files written from pages arranged by the program
// (turned, removed, added, moved, imported from other files, with text stamped on top). The engine is hayro, in
// native/pdf, a part of the toolkit's one native library: a program with toolbox.Feature.Pdf builds it in
// (-define:GT_PDF=true, tools/tk build_native with the part pdf) and needs nothing beside it. Without the define,
// `available` is false and `open` says .Unavailable.
//
// A document is the program's list of Page values, not an object of the engine: an edit changes the list, an undo
// keeps the old value, `write` makes the file. src/md/features/pdf.md says why; docs/pdf.md how.
//
// Every procedure may run on any thread (the sources are shared and locked); none is for the interface's thread:
// opening, rendering and writing take as long as the file asks.
package tk_pdf

@(require) import "core:slice"   // (used only with GT_PDF)

GT_PDF :: #config(GT_PDF, false)

when GT_PDF {
	when ODIN_OS == .Windows {
		foreign import gt_pdf {
			"../../build/native/gt_native.lib",
			"system:ntdll.lib",
			"system:userenv.lib",
			"system:ws2_32.lib",
			"system:bcrypt.lib",
			"system:advapi32.lib",
			"system:kernel32.lib",
			"system:dbghelp.lib",
			"system:Synchronization.lib",   // (WaitOnAddress: Rust's standard library locks with it)
		}
	} else {
		foreign import gt_pdf {
			"../../build/native/libgt_native.a",
			"system:dl",
			"system:pthread",
			"system:m",
		}
	}

	@(private, default_calling_convention = "c")
	foreign gt_pdf {
		gt_pdf_open :: proc(data: [^]u8, len: uint, password: [^]u8, password_len: uint, out: ^u32) -> i32 ---
		gt_pdf_close :: proc(id: u32) ---
		gt_pdf_page_count :: proc(id: u32) -> i32 ---
		gt_pdf_page_size :: proc(id, index: u32, width, height: ^f32) -> bool ---
		gt_pdf_render :: proc(page: ^C_Page, width, height: u32, layer: bool, out: [^]u8) -> bool ---
		gt_pdf_write :: proc(pages: [^]C_Page, count: uint, base: u32, out: ^[^]u8) -> uint ---
		gt_pdf_free :: proc(ptr: [^]u8, len: uint) ---
		gt_pdf_stamp_measure :: proc(stamp: ^C_Stamp, width, height: ^f32) ---
	}
}

// An open file. 0 is none: a blank page's source.
Source :: distinct u32

// Why a file did not open.
Error :: enum u8 {
	None,
	Format,       // not a PDF, or too damaged to read
	Password,     // a password is needed, or the one given is wrong
	Security,     // an encryption the engine does not know
	Failed,       // the engine failed (a bug of the engine: it was caught)
	Unavailable,  // this program was built without GT_PDF
}

// The standard fonts of PDF a stamp can take: Helvetica, Times, Courier. Every reader has them; nothing is embedded.
Family :: enum u8 { Sans, Serif, Mono }

Font :: struct {
	family: Family,
	bold:   bool,
	italic: bool,
}

// Text on a page. `at`: its top-left corner in points, in the page as its source shows it (before the page's turns),
// y down. `turns`: quarter turns clockwise of the text about that corner; a stamp placed on a page shown turned by k
// takes (4 - k) % 4 to read upright. `background`: alpha 0 for none (any other alpha: opaque). Its characters are
// written in WinAnsi (the Western European ones); another is written as "?".
Stamp :: struct {
	at:         [2]f32,
	turns:      int,
	font:       Font,
	size:       f32,
	color:      [3]u8,
	background: [4]u8,
	text:       string,
}

// What a shape is.
Shape_Kind :: enum u8 { Rect, Ellipse, Line, Arrow, Ink }

// A shape drawn on a page: its points in points, in the page as its source shows it (before the page's turns), y down:
// two corners (Rect, Ellipse: the box it fills), two ends (Line; Arrow: from, then to, where its head is), or the
// free line's points (Ink). `stroke` and `fill`: alpha 0 for none; a colour less than opaque is laid over the page by
// multiplication, as a highlighter's ink (the words under it stay readable). `fill` is for Rect and Ellipse. `width`:
// the stroke's, in points. Shapes are drawn under the page's stamps.
Shape :: struct {
	kind:   Shape_Kind,
	points: [][2]f32,
	stroke: [4]u8,
	fill:   [4]u8,
	width:  f32,
}

// A page of the program's list: page `index` of `source`, or a blank page of `size` points when `source` is 0.
// `turns`: quarter turns clockwise, added to the page's own rotation.
Page :: struct {
	source: Source,
	index:  int,
	turns:  int,
	size:   [2]f32,
	stamps: []Stamp,
	shapes: []Shape,
}

@(private)
C_Stamp :: struct {
	x, y, size:        f32,
	turns, font:       u32,
	color, background: u32,
	text:              [^]u8,
	text_len:          uint,
}

@(private)
C_Shape :: struct {
	kind:          u32,
	stroke, fill:  u32,
	width:         f32,
	points:        [^]f32,
	point_count:   uint,
}

@(private)
C_Page :: struct {
	source, index, turns: u32,
	width, height:        f32,
	stamps:               [^]C_Stamp,
	stamp_count:          uint,
	shapes:               [^]C_Shape,
	shape_count:          uint,
}

// Whether this program has the engine (built with -define:GT_PDF=true).
available :: proc() -> bool { return GT_PDF }

// Opens the PDF in `bytes` (the engine keeps its own copy) with `password` ("" for none).
open :: proc(bytes: []u8, password := "") -> (source: Source, err: Error) {
	when GT_PDF {
		id: u32
		r := gt_pdf_open(raw_data(bytes), uint(len(bytes)), raw_data(password), uint(len(password)), &id)
		switch r {
		case 0: return Source(id), .None
		case 1: return 0, .Format
		case 2: return 0, .Password
		case 3: return 0, .Security
		}
		return 0, .Failed
	} else {
		return 0, .Unavailable
	}
}

// Closes a source. A page of it in a program's list then renders nothing: close it when no list holds it.
close :: proc(source: Source) {
	when GT_PDF { if source != 0 { gt_pdf_close(u32(source)) } }
}

// The pages of a source (0 when it is not open).
page_count :: proc(source: Source) -> int {
	when GT_PDF { return max(int(gt_pdf_page_count(u32(source))), 0) } else { return 0 }
}

// A page's size in points as its source shows it: its own rotation applied, before a program's turns.
page_size :: proc(source: Source, index: int) -> (size: [2]f32, ok: bool) {
	when GT_PDF {
		if index < 0 { return }
		ok = gt_pdf_page_size(u32(source), u32(index), &size.x, &size.y)
		return
	} else {
		return
	}
}

// The size a page of the list is shown at, in points: its source's (or its own when blank), its sides swapped by an
// odd number of turns.
shown_size :: proc(page: Page) -> [2]f32 {
	size := page.size
	if page.source != 0 { size, _ = page_size(page.source, page.index) }
	if ((page.turns % 4) + 4) % 4 % 2 == 1 { size = {size.y, size.x} }
	return size
}

@(private)
c_stamps :: proc(stamps: []Stamp, allocator := context.temp_allocator) -> []C_Stamp {
	out := make([]C_Stamp, len(stamps), allocator)
	for s, i in stamps {
		code := u32(s.font.family) + (s.font.bold ? 4 : 0) + (s.font.italic ? 8 : 0)
		out[i] = C_Stamp{
			x = s.at.x, y = s.at.y, size = s.size, turns = u32(((s.turns % 4) + 4) % 4), font = code,
			color = u32(s.color[0]) << 16 | u32(s.color[1]) << 8 | u32(s.color[2]),
			background = u32(s.background[0]) << 24 | u32(s.background[1]) << 16 | u32(s.background[2]) << 8 | u32(s.background[3]),
			text = raw_data(s.text), text_len = uint(len(s.text)),
		}
	}
	return out
}

@(private)
c_shapes :: proc(shapes: []Shape, allocator := context.temp_allocator) -> []C_Shape {
	out := make([]C_Shape, len(shapes), allocator)
	rgba :: proc(c: [4]u8) -> u32 { return u32(c[0]) << 24 | u32(c[1]) << 16 | u32(c[2]) << 8 | u32(c[3]) }
	for s, i in shapes {
		// ([2]f32 is two f32 in a row: the engine reads the points as x, y pairs)
		out[i] = C_Shape{
			kind = u32(s.kind), stroke = rgba(s.stroke), fill = rgba(s.fill), width = s.width,
			points = cast([^]f32)raw_data(s.points), point_count = uint(len(s.points)),
		}
	}
	return out
}

@(private)
c_page :: proc(p: Page) -> C_Page {
	stamps := c_stamps(p.stamps)
	shapes := c_shapes(p.shapes)
	return C_Page{
		source = u32(p.source), index = u32(max(p.index, 0)), turns = u32(((p.turns % 4) + 4) % 4),
		width = p.size.x, height = p.size.y, stamps = raw_data(stamps), stamp_count = uint(len(stamps)),
		shapes = raw_data(shapes), shape_count = uint(len(shapes)),
	}
}

// The page's picture: `width` by `height` RGBA pixels on white (the page's shown size scaled to them), its
// annotations, form widgets and signatures' appearances drawn only when `layer`. nil when it cannot be drawn.
render :: proc(page: Page, width, height: int, layer := false, allocator := context.allocator) -> []u8 {
	when GT_PDF {
		if width <= 0 || height <= 0 { return nil }
		out := make([]u8, width * height * 4, allocator)
		cp := c_page(page)
		if !gt_pdf_render(&cp, u32(width), u32(height), layer, raw_data(out)) {
			delete(out, allocator)
			return nil
		}
		return out
	} else {
		return nil
	}
}

// A new PDF of `pages`, in order. With `base` (the source the person opened), its catalog is kept: outlines, the
// form, the structure, the page labels, the metadata; a reference to a page the list does not hold names nothing.
// Without, a new file of the pages and their annotations (an extract). The file is never encrypted.
write :: proc(pages: []Page, base: Source = 0, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	when GT_PDF {
		if len(pages) == 0 { return }
		list := make([]C_Page, len(pages), context.temp_allocator)
		for p, i in pages { list[i] = c_page(p) }
		out: [^]u8
		n := gt_pdf_write(raw_data(list), uint(len(list)), u32(base), &out)
		if n == 0 { return }
		defer gt_pdf_free(out, n)
		return slice.clone(out[:n], allocator), true   // (the engine's memory goes back to it)
	} else {
		return
	}
}

// A stamp's box in points, before its turns: its lines with their margin.
stamp_size :: proc(stamp: Stamp) -> (size: [2]f32) {
	when GT_PDF {
		cs := c_stamps({stamp})
		gt_pdf_stamp_measure(&cs[0], &size.x, &size.y)
	}
	return
}
