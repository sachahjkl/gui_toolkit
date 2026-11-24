package tk_marks

// The picture with its marks, flattened: what a program gets at Done. It reads and writes every pixel: the widget runs
// it on the chores. Each shape is painted with gt:paint on a canvas of its own bounds (16 bytes a pixel: a canvas of a
// whole 4K picture would hold 130 MB), then laid over the picture's bytes, source over.
//
// Pixelate draws a mosaic: the picture's mean colour by cells of its pixel size, on one grid for the whole picture.
// Blur draws a blurred copy of the picture: a mosaic of cells a quarter of its radius, blurred, stretched back (a blur
// hides the detail that a smaller copy loses anyway; the copy is small and quick to make). Both read the picture as it
// came, as the screen shows them.

import "base:runtime"
import "core:math"
import "core:sync"
import paint "../paint"

BLUR_DOWN :: 4   // a blurred copy's cell, in parts of its radius

// A Pixelate's cell, a Blur's radius: in whole picture pixels, as the mosaics and the blurred copies are made.
pixel_cell :: proc(doc: ^Doc, style: Style) -> int { return max(int(math.round(style.pixel_size * doc.scale)), 1) }
blur_px :: proc(doc: ^Doc, style: Style) -> int { return max(int(math.round(style.blur_radius * doc.scale)), 1) }

// The mean colour of each cell of the picture (sRGB, row by row; owned).
Mosaic :: struct {
	cell:       int,   // picture pixels
	cols, rows: int,
	colors:     [][4]u8,
}

// cancel (atomic, may be nil): set from another thread, the work stops at the next row of cells (the mosaic is then
// partial).
mosaic_make :: proc(rgba: []u8, size: [2]int, cell: int, cancel: ^bool = nil, allocator := context.allocator) -> Mosaic {
	c := max(cell, 1)
	m := Mosaic{cell = c, cols = (size.x + c - 1) / c, rows = (size.y + c - 1) / c}
	if size.x <= 0 || size.y <= 0 || len(rgba) < size.x * size.y * 4 { return {cell = c} }
	m.colors = make([][4]u8, m.cols * m.rows, allocator)
	sums := make([][4]u32, m.cols, allocator)
	defer delete(sums, allocator)
	for gy in 0 ..< m.rows {
		if cancel != nil && sync.atomic_load(cancel) { break }
		for &s in sums { s = {} }
		y0, y1 := gy * c, min(gy * c + c, size.y)
		for y in y0 ..< y1 {
			row := rgba[y * size.x * 4:][:size.x * 4]
			for x in 0 ..< size.x {
				s := &sums[x / c]
				s[0] += u32(row[x * 4])
				s[1] += u32(row[x * 4 + 1])
				s[2] += u32(row[x * 4 + 2])
				s[3] += 1
			}
		}
		for gx in 0 ..< m.cols {
			s := sums[gx]
			if s[3] == 0 { continue }
			m.colors[gy * m.cols + gx] = {u8(s[0] / s[3]), u8(s[1] / s[3]), u8(s[2] / s[3]), 255}
		}
	}
	return m
}

mosaic_destroy :: proc(m: ^Mosaic, allocator := context.allocator) {
	delete(m.colors, allocator)
	m^ = {}
}

// A blurred copy of the picture for a blur of radius picture pixels: RGBA of size, each pixel cell picture pixels
// (owned; nil when the picture is empty).
Blurred :: struct {
	radius: int,
	cell:   int,
	size:   [2]int,
	pixels: []u8,
}

// cancel as mosaic_make's (the copy is then partial).
blur_make :: proc(rgba: []u8, size: [2]int, radius: int, cancel: ^bool = nil, allocator := context.allocator) -> Blurred {
	out := Blurred{radius = radius, cell = max(radius / BLUR_DOWN, 1)}
	mos := mosaic_make(rgba, size, out.cell, cancel, allocator)
	defer mosaic_destroy(&mos, allocator)
	if len(mos.colors) == 0 { return out }
	w, h := mos.cols, mos.rows
	// (three box blurs of half width r: a Gaussian of sigma about sqrt(r (r + 1)), the radius in cells)
	sigma := f32(radius) / f32(out.cell)
	r := max(int(math.round(math.sqrt(sigma * sigma + 0.25) - 0.5)), 1)
	a := make([][4]f32, w * h, allocator)
	defer delete(a, allocator)
	b := make([][4]f32, w * h, allocator)
	defer delete(b, allocator)
	for v, i in mos.colors { a[i] = {f32(v[0]), f32(v[1]), f32(v[2]), 255} }
	for _ in 0 ..< 3 {
		box_pass(a, b, w, h, r, true)
		box_pass(b, a, w, h, r, false)
	}
	out.size = {w, h}
	out.pixels = make([]u8, w * h * 4, allocator)
	for v, i in a {
		for k in 0 ..< 4 { out.pixels[i * 4 + k] = u8(clamp(math.round(v[k]), 0, 255)) }
	}
	return out
}

blur_destroy :: proc(b: ^Blurred, allocator := context.allocator) {
	delete(b.pixels, allocator)
	b^ = {}
}

// One box blur of half width r along a row (across) or a column: its ends repeat the edge.
@(private = "file")
box_pass :: proc(src, dst: [][4]f32, w, h, r: int, across: bool) {
	n, lines := across ? w : h, across ? h : w
	k := 1 / f32(2 * r + 1)
	for line in 0 ..< lines {
		at :: proc(i, line, w: int, across: bool) -> int { return across ? line * w + i : i * w + line }
		sum: [4]f32
		for i in -r ..= r { sum += src[at(clamp(i, 0, n - 1), line, w, across)] }
		for i in 0 ..< n {
			dst[at(i, line, w, across)] = sum * k
			sum += src[at(min(i + r + 1, n - 1), line, w, across)] - src[at(max(i - r, 0), line, w, across)]
		}
	}
}

// A text's letters as a path in the picture's pixels: the widget takes the glyphs' outlines on the interface's thread,
// where the fonts are.
Flatten_Text :: struct {
	shape:  int,          // its index in Flatten_Input.shapes
	glyphs: paint.Path,
}

// What the flattening reads. The picture is read only; the rest is the input's own (flatten_input_make).
Flatten_Input :: struct {
	rgba:     []u8,
	size:     [2]int,
	scale:    f32,
	shapes:   []Shape,
	crop:     Box,
	has_crop: bool,
	texts:    [dynamic]Flatten_Text,
	allocator: runtime.Allocator,
}

// The model's shapes and crop, copied in allocator, over the picture rgba of size (not copied: it must outlive the
// flattening).
flatten_input_make :: proc(m: ^Model, rgba: []u8, size: [2]int, allocator := context.allocator) -> Flatten_Input {
	context.allocator = allocator
	in_ := Flatten_Input{rgba = rgba, size = size, scale = m.doc.scale, crop = m.doc.crop, has_crop = m.doc.has_crop, allocator = allocator}
	in_.shapes = make([]Shape, len(m.doc.shapes))
	for s, i in m.doc.shapes { in_.shapes[i] = shape_clone(s) }
	in_.texts = make([dynamic]Flatten_Text)
	return in_
}

flatten_input_destroy :: proc(in_: ^Flatten_Input) {
	context.allocator = in_.allocator
	shapes_free(in_.shapes)
	delete(in_.shapes)
	for &t in in_.texts { paint.path_destroy(&t.glyphs) }
	delete(in_.texts)
	in_^ = {}
}

// The picture with its shapes, cropped: RGBA, straight alpha, in allocator. cancel as mosaic_make's (the result is
// then nil).
flatten :: proc(in_: ^Flatten_Input, cancel: ^bool = nil, allocator := context.allocator) -> (rgba: []u8, size: [2]int) {
	W, H := in_.size.x, in_.size.y
	if W <= 0 || H <= 0 || len(in_.rgba) < W * H * 4 { return nil, {} }
	out := make([]u8, W * H * 4, allocator)
	copy(out, in_.rgba[:W * H * 4])
	doc := Doc{size = {f32(W), f32(H)}, scale = in_.scale}
	blurs := make([dynamic]Blurred, context.allocator)
	defer {
		for &b in blurs { blur_destroy(&b) }
		delete(blurs)
	}
	for &s, i in in_.shapes {
		if cancel != nil && sync.atomic_load(cancel) { delete(out, allocator); return nil, {} }
		switch s.kind {
		case .Pixelate:
			flatten_mosaic(out, in_.rgba, in_.size, box_of(s.a, s.b), pixel_cell(&doc, s.style))
		case .Blur:
			radius := blur_px(&doc, s.style)
			found := -1
			for b, k in blurs { if b.radius == radius { found = k } }
			if found < 0 {
				append(&blurs, blur_make(in_.rgba, in_.size, radius))
				found = len(blurs) - 1
			}
			flatten_blur(out, in_.size, box_of(s.a, s.b), &blurs[found])
		case .Rectangle, .Ellipse, .Arrow, .Line, .Pen, .Highlighter, .Text:
			glyphs: ^paint.Path
			for &t in in_.texts { if t.shape == i { glyphs = &t.glyphs } }
			flatten_shape(out, in_.size, &doc, &s, glyphs)
		}
	}
	x, y, w, h := crop_pixels(doc.size, in_.crop, in_.has_crop)
	if x == 0 && y == 0 && w == W && h == H { return out, {W, H} }
	cropped := make([]u8, w * h * 4, allocator)
	for row in 0 ..< h { copy(cropped[row * w * 4:][:w * 4], out[((y + row) * W + x) * 4:][:w * 4]) }
	delete(out, allocator)
	return cropped, {w, h}
}

// The box cut to the picture, in whole pixels; ok false: nothing of it is inside.
@(private = "file")
pixel_box :: proc(box: Box, size: [2]int) -> (x0, y0, x1, y1: int, ok: bool) {
	x0 = clamp(int(math.floor(box.min.x)), 0, size.x)
	y0 = clamp(int(math.floor(box.min.y)), 0, size.y)
	x1 = clamp(int(math.ceil(box.max.x)), 0, size.x)
	y1 = clamp(int(math.ceil(box.max.y)), 0, size.y)
	return x0, y0, x1, y1, x1 > x0 && y1 > y0
}

// The cells of the mosaic of cell that the box covers, each the mean of its whole cell of the picture as it came.
@(private = "file")
flatten_mosaic :: proc(out, src: []u8, size: [2]int, box: Box, cell: int) {
	x0, y0, x1, y1, inside := pixel_box(box, size)
	if !inside { return }
	W := size.x
	for gy := y0 / cell; gy * cell < y1; gy += 1 {
		for gx := x0 / cell; gx * cell < x1; gx += 1 {
			cx0, cy0 := gx * cell, gy * cell
			cx1, cy1 := min(cx0 + cell, W), min(cy0 + cell, size.y)
			sum: [3]u32
			for y in cy0 ..< cy1 {
				for x in cx0 ..< cx1 {
					i := (y * W + x) * 4
					sum += {u32(src[i]), u32(src[i + 1]), u32(src[i + 2])}
				}
			}
			n := u32((cx1 - cx0) * (cy1 - cy0))
			if n == 0 { continue }
			c := sum / n
			for y in max(cy0, y0) ..< min(cy1, y1) {
				for x in max(cx0, x0) ..< min(cx1, x1) {
					i := (y * W + x) * 4
					out[i], out[i + 1], out[i + 2], out[i + 3] = u8(c[0]), u8(c[1]), u8(c[2]), 255
				}
			}
		}
	}
}

// The blurred copy under the box, stretched back to the picture's pixels (bilinear, as a texture is sampled).
@(private = "file")
flatten_blur :: proc(out: []u8, size: [2]int, box: Box, b: ^Blurred) {
	if len(b.pixels) == 0 { return }
	x0, y0, x1, y1, inside := pixel_box(box, size)
	if !inside { return }
	c := f32(b.cell)
	w, h := b.size.x, b.size.y
	for y in y0 ..< y1 {
		v := (f32(y) + 0.5) / c - 0.5
		j0 := clamp(int(math.floor(v)), 0, h - 1)
		j1 := min(j0 + 1, h - 1)
		fy := clamp(v - f32(j0), 0, 1)
		for x in x0 ..< x1 {
			u := (f32(x) + 0.5) / c - 0.5
			i0 := clamp(int(math.floor(u)), 0, w - 1)
			i1 := min(i0 + 1, w - 1)
			fx := clamp(u - f32(i0), 0, 1)
			o := (y * size.x + x) * 4
			for k in 0 ..< 3 {
				p00, p10 := f32(b.pixels[(j0 * w + i0) * 4 + k]), f32(b.pixels[(j0 * w + i1) * 4 + k])
				p01, p11 := f32(b.pixels[(j1 * w + i0) * 4 + k]), f32(b.pixels[(j1 * w + i1) * 4 + k])
				top := p00 + (p10 - p00) * fx
				bottom := p01 + (p11 - p01) * fx
				out[o + k] = u8(clamp(math.round(top + (bottom - top) * fy), 0, 255))
			}
			out[o + 3] = 255
		}
	}
}

// A shape's figures (and a text's letters) painted on a canvas of its bounds, laid over out.
@(private = "file")
flatten_shape :: proc(out: []u8, size: [2]int, doc: ^Doc, s: ^Shape, glyphs: ^paint.Path) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	x0, y0, x1, y1, inside := pixel_box(box_pad(shape_box(doc, s), reach(doc, s)), size)
	if !inside { return }
	w, h := x1 - x0, y1 - y0
	canvas := paint.canvas_make(w, h)
	defer paint.canvas_destroy(&canvas)
	canvas.transform = paint.translate(paint.IDENTITY, -f32(x0), -f32(y0))
	figs := make([dynamic]Figure, context.temp_allocator)
	figures(doc, s, &figs, context.temp_allocator)
	for f in figs {
		path := polyline_path(f.points, f.kind == .Fill || f.closed)
		switch f.kind {
		case .Fill:   paint.fill(&canvas, path, paint.solid(f.color))
		case .Stroke: paint.stroke(&canvas, path, paint.Pen{width = f.width, join = .Round, cap = .Round}, paint.solid(f.color))
		}
	}
	if s.kind == .Text && glyphs != nil {
		color := color_of(s.style.color)
		if s.style.text_look == .Outline {
			paint.stroke(&canvas, glyphs^, paint.Pen{width = text_px(doc, s) * TEXT_OUTLINE, join = .Round, cap = .Round}, paint.solid(text_under(s.style)))
		}
		paint.fill(&canvas, glyphs^, paint.solid(color))
	}
	W := size.x
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := canvas.pixels[y * w + x]
			if p.a <= 0 { continue }
			i := ((y0 + y) * W + x0 + x) * 4
			da := f32(out[i + 3]) / 255
			ra := p.a + da * (1 - p.a)
			if ra <= 0 { continue }
			for k in 0 ..< 3 {
				d := f32(out[i + k]) / 255 * da
				out[i + k] = u8(clamp(math.round((p[k] + d * (1 - p.a)) / ra * 255), 0, 255))
			}
			out[i + 3] = u8(clamp(math.round(ra * 255), 0, 255))
		}
	}
}

// A polyline as a path of gt:paint (temp allocator).
@(private = "file")
polyline_path :: proc(pts: [][2]f32, closed: bool) -> paint.Path {
	p := paint.Path{verbs = make([dynamic]paint.Verb, context.temp_allocator), points = make([dynamic][2]f32, context.temp_allocator)}
	for q, i in pts {
		if i == 0 { paint.move_to(&p, q.x, q.y) } else { paint.line_to(&p, q.x, q.y) }
	}
	if closed { paint.close(&p) }
	return p
}
