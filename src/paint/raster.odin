package tk_paint

import "core:math"
import "core:slice"

Fill_Rule :: enum u8 {
	Non_Zero,   // inside where the figures wind around a point a number of times other than 0
	Even_Odd,   // inside where they cross an odd number of times (GDI+'s FillMode.Alternate)
}

// Sub-scanlines per row of pixels: the vertical steps of the coverage. Across a row, coverage is exact.
@(private)
SUBSAMPLES :: 16

@(private = "file")
Edge :: struct {
	x0, y0, x1, y1: f32,   // y0 < y1
	winding:        i32,   // +1 downward in the figure, -1 upward
}

@(private = "file")
Crossing :: struct {
	x:       f32,
	winding: i32,
}

// The coverage of polygons on a box of pixels: cov[(y - y0) * (x1 - x0) + (x - x0)], 0 to 1.
@(private)
Mask :: struct {
	x0, y0, x1, y1: int,
	cov:            []f32,
}

// The share of each pixel inside the polygons (device coordinates). Antialiased: SUBSAMPLES lines per row, exact areas
// across. Aliased: a pixel is in or out by its centre (GDI+'s regions without antialiasing).
@(private)
rasterize :: proc(points: [][2]f32, contours: []Contour, rule: Fill_Rule, width, height: int, antialias: bool, allocator := context.allocator) -> (m: Mask) {
	edges := make([dynamic]Edge, 0, len(points), context.temp_allocator)
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	for c in contours {
		for i in 0 ..< c.count {
			a := points[c.start + i]
			b := points[c.start + (i + 1) % c.count]   // (open or closed, a fill closes every figure)
			lo, hi = {min(lo.x, a.x), min(lo.y, a.y)}, {max(hi.x, a.x), max(hi.y, a.y)}
			if a.y == b.y { continue }
			if a.y < b.y { append(&edges, Edge{a.x, a.y, b.x, b.y, 1}) } else { append(&edges, Edge{b.x, b.y, a.x, a.y, -1}) }
		}
	}
	if len(edges) == 0 { return }
	m.x0, m.y0 = max(0, int(math.floor(lo.x))), max(0, int(math.floor(lo.y)))
	m.x1, m.y1 = min(width, int(math.ceil(hi.x)) + 1), min(height, int(math.ceil(hi.y)) + 1)
	if m.x0 >= m.x1 || m.y0 >= m.y1 { m = {}; return }
	w := m.x1 - m.x0
	m.cov = make([]f32, w * (m.y1 - m.y0), allocator)
	slice.sort_by(edges[:], proc(a, b: Edge) -> bool { return a.y0 < b.y0 })

	area := make([]f32, w + 2, context.temp_allocator)    // a span's ends: the share of their pixel
	cover := make([]f32, w + 2, context.temp_allocator)   // a span's whole pixels: +k at the first, -k after the last
	active := make([dynamic]Edge, 0, len(edges), context.temp_allocator)
	crossings := make([dynamic]Crossing, 0, len(edges), context.temp_allocator)
	next := 0
	subs := antialias ? SUBSAMPLES : 1
	k := 1 / f32(subs)
	left, right := f32(m.x0), f32(m.x1)
	for y in m.y0 ..< m.y1 {
		// the edges this row meets
		for i := 0; i < len(active); {
			if active[i].y1 <= f32(y) { unordered_remove(&active, i) } else { i += 1 }
		}
		for next < len(edges) && edges[next].y0 < f32(y + 1) {
			if edges[next].y1 > f32(y) { append(&active, edges[next]) }
			next += 1
		}
		if len(active) == 0 { continue }
		slice.zero(area)
		slice.zero(cover)
		for s in 0 ..< subs {
			sy := f32(y) + (f32(s) + 0.5) * k
			clear_dynamic_array(&crossings)
			for e in active {
				if sy < e.y0 || sy >= e.y1 { continue }
				append(&crossings, Crossing{e.x0 + (sy - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0), e.winding})
			}
			slice.sort_by(crossings[:], proc(a, b: Crossing) -> bool { return a.x < b.x })
			winding: i32
			for c, i in crossings {
				winding += c.winding
				inside := rule == .Non_Zero ? winding != 0 : winding & 1 != 0
				if !inside || i + 1 >= len(crossings) { continue }
				a, b := clamp(c.x, left, right) - left, clamp(crossings[i + 1].x, left, right) - left
				if antialias { add_span(area, cover, a, b, k) } else { add_centres(cover, a, b) }
			}
		}
		row := m.cov[(y - m.y0) * w:][:w]
		run: f32
		for x in 0 ..< w {
			run += cover[x]
			row[x] = clamp(run + area[x], 0, 1)
		}
	}
	return
}

// [a, b) of a sub-scanline, weighed k: its end pixels get the share they cover, the pixels between all of k.
@(private = "file")
add_span :: proc(area, cover: []f32, a, b, k: f32) {
	if b <= a { return }
	ia, ib := int(a), int(b)
	if ia == ib { area[ia] += (b - a) * k; return }
	area[ia] += (f32(ia + 1) - a) * k
	cover[ia + 1] += k
	cover[ib] -= k
	area[ib] += (b - f32(ib)) * k
}

// The pixels whose centre is in [a, b).
@(private = "file")
add_centres :: proc(cover: []f32, a, b: f32) {
	ia, ib := int(math.ceil(a - 0.5)), int(math.ceil(b - 0.5))
	if ib <= ia { return }
	cover[ia] += 1
	cover[ib] -= 1
}

// The path's figures, through the canvas's transform, as device polygons.
@(private)
device_polygons :: proc(c: ^Canvas, p: Path) -> (points: [dynamic][2]f32, contours: [dynamic]Contour) {
	points = make([dynamic][2]f32, context.temp_allocator)
	contours = make([dynamic]Contour, context.temp_allocator)
	flatten(p, c.transform, TOLERANCE, &points, &contours)
	return
}

// The path, filled with `paint`, over what is there.
fill :: proc(c: ^Canvas, p: Path, paint: Paint, rule := Fill_Rule.Non_Zero) {
	points, contours := device_polygons(c, p)
	m := rasterize(points[:], contours[:], rule, c.width, c.height, true)
	defer delete(m.cov)
	composite(c, m, paint)
}

// The path's outline, drawn with `pen` and filled with `paint`.
stroke :: proc(c: ^Canvas, p: Path, pen: Pen, paint: Paint) {
	s := matrix_scale(c.transform)
	outline := widen(p, pen, s > 0 ? TOLERANCE / s : TOLERANCE, context.temp_allocator)
	fill(c, outline, paint, .Non_Zero)
}

// From now on, drawing reaches only the inside of the path (and `clear` clears only there). Antialiased or not: GDI+'s clip
// regions are not, which a picture made to match one of its pictures may need.
set_clip :: proc(c: ^Canvas, p: Path, rule := Fill_Rule.Non_Zero, antialias := true) {
	points, contours := device_polygons(c, p)
	m := rasterize(points[:], contours[:], rule, c.width, c.height, antialias)
	defer delete(m.cov)
	if c.clip == nil { c.clip = make([]f32, c.width * c.height, c.allocator) } else { slice.zero(c.clip) }
	w := m.x1 - m.x0
	for y in m.y0 ..< m.y1 { copy(c.clip[y * c.width + m.x0:][:w], m.cov[(y - m.y0) * w:][:w]) }
}

reset_clip :: proc(c: ^Canvas) {
	delete(c.clip, c.allocator)
	c.clip = nil
}

// The paint over each pixel of the mask, in proportion to its coverage and to the clip.
@(private = "file")
composite :: proc(c: ^Canvas, m: Mask, paint: Paint) {
	w := m.x1 - m.x0
	inverse := invert(c.transform)
	solid := premultiply(paint.color)
	for y in m.y0 ..< m.y1 {
		for x in m.x0 ..< m.x1 {
			k := m.cov[(y - m.y0) * w + x - m.x0]
			i := y * c.width + x
			if c.clip != nil { k *= c.clip[i] }
			if k <= 0 { continue }
			src := solid
			if paint.kind != .Solid { src = premultiply(shade(paint, apply(inverse, {f32(x) + 0.5, f32(y) + 0.5}))) }
			src *= k
			c.pixels[i] = src + c.pixels[i] * (1 - src.a)
		}
	}
}
