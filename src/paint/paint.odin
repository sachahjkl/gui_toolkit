// paint: a vector rasterizer on the CPU for pictures made ahead of time (logos, icons): an RGBA canvas, paths of lines,
// Béziers and arcs, filled and stroked with antialiasing, solid colours and gradients, a clip, one canvas drawn into another
// at another size, PNG and .ico files. Pure Odin, no platform code, deterministic: the same calls make the same bytes on
// every system. See docs/paint.md.
//
// A canvas holds premultiplied colours as f32, so that layers and resampling add no rounding of their own; 8 bits come
// only when a file is written.
package tk_paint

import "base:runtime"
import "core:math"

// A colour, not premultiplied: red, green, blue and alpha, from 0 to 1.
Color :: [4]f32

TRANSPARENT :: Color{}

// 0xRRGGBB and an alpha of 0 to 255, as a Color.
hex :: proc(rgb: u32, alpha := 255) -> Color {
	return {f32((rgb >> 16) & 0xFF) / 255, f32((rgb >> 8) & 0xFF) / 255, f32(rgb & 0xFF) / 255, f32(alpha) / 255}
}

// An affine transform: x' = xx*x + xy*y + x, y' = yx*x + yy*y + y.
Matrix :: struct {
	xx, yx, xy, yy, x, y: f32,
}

IDENTITY :: Matrix{xx = 1, yy = 1}

// Where GDI+ puts a shape drawn with antialiasing and its default pixel offset mode, relative to this package: its pixel i
// covers [i - 0.5, i + 0.5), and its samples sit an eighth of a pixel off the centre (measured against its pictures). A
// picture made to match one GDI+ drew starts from translate(IDENTITY, GDIPLUS_OFFSET, GDIPLUS_OFFSET).
GDIPLUS_OFFSET :: 0.625

apply :: proc(m: Matrix, p: [2]f32) -> [2]f32 {
	return {m.xx * p.x + m.xy * p.y + m.x, m.yx * p.x + m.yy * p.y + m.y}
}

// The transform that applies `first`, then `then`.
multiply :: proc(first, then: Matrix) -> Matrix {
	return {
		xx = then.xx * first.xx + then.xy * first.yx,
		yx = then.yx * first.xx + then.yy * first.yx,
		xy = then.xx * first.xy + then.xy * first.yy,
		yy = then.yx * first.xy + then.yy * first.yy,
		x  = then.xx * first.x + then.xy * first.y + then.x,
		y  = then.yx * first.x + then.yy * first.y + then.y,
	}
}

// translate, scale and rotate_at put their step before `m`: points go through the step first, then through `m`. A chain
// built from IDENTITY therefore reads in the order of GDI+'s Matrix calls (the default MatrixOrder.Prepend).
translate :: proc(m: Matrix, dx, dy: f32) -> Matrix { return multiply({xx = 1, yy = 1, x = dx, y = dy}, m) }

scale :: proc(m: Matrix, sx, sy: f32) -> Matrix { return multiply({xx = sx, yy = sy}, m) }

// A rotation by `degrees` about (cx, cy); a positive angle turns clockwise on a canvas, whose y axis points down.
rotate_at :: proc(m: Matrix, degrees, cx, cy: f32) -> Matrix {
	a := math.to_radians(degrees)
	s, c := math.sin(a), math.cos(a)
	r := Matrix{xx = c, yx = s, xy = -s, yy = c}
	r.x = cx - (c * cx - s * cy)
	r.y = cy - (s * cx + c * cy)
	return multiply(r, m)
}

invert :: proc(m: Matrix) -> Matrix {
	det := m.xx * m.yy - m.xy * m.yx
	if det == 0 { return {} }
	i := Matrix{xx = m.yy / det, yx = -m.yx / det, xy = -m.xy / det, yy = m.xx / det}
	i.x = -(i.xx * m.x + i.xy * m.y)
	i.y = -(i.yx * m.x + i.yy * m.y)
	return i
}

// How much a transform scales lengths, on average over directions (its area's square root).
@(private)
matrix_scale :: proc(m: Matrix) -> f32 {
	return math.sqrt(abs(m.xx * m.yy - m.xy * m.yx))
}

// A picture of premultiplied colours. `transform` takes the coordinates of paths, gradients and pens to pixels; pixel
// (i, j) covers [i, i+1) x [j, j+1). `clip`: what share of each pixel drawing reaches (nil: all of it).
Canvas :: struct {
	width, height: int,
	pixels:        [][4]f32,
	transform:     Matrix,
	clip:          []f32,
	allocator:     runtime.Allocator,
}

// A transparent canvas.
canvas_make :: proc(width, height: int, allocator := context.allocator) -> Canvas {
	return {width = width, height = height, pixels = make([][4]f32, width * height, allocator), transform = IDENTITY, allocator = allocator}
}

canvas_destroy :: proc(c: ^Canvas) {
	delete(c.pixels, c.allocator)
	delete(c.clip, c.allocator)
	c^ = {}
}

// Every pixel the clip reaches becomes `color` (the clip's edge in proportion), as GDI+'s Graphics.Clear does.
clear :: proc(c: ^Canvas, color := TRANSPARENT) {
	p := premultiply(color)
	for &px, i in c.pixels {
		k := c.clip == nil ? 1 : c.clip[i]
		px = p * k + px * (1 - k)
	}
}

@(private)
premultiply :: proc(c: Color) -> [4]f32 { return {c.r * c.a, c.g * c.a, c.b * c.a, c.a} }

// A figure's points, as the rasterizer and the stroker take them: a closed one returns to its first point.
@(private)
Contour :: struct {
	start, count: int,
	closed:       bool,
}

// What one segment of a flattened curve may stray from the curve, in pixels.
@(private)
TOLERANCE :: 0.05
