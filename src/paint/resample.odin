package tk_paint

import "core:math"

Filter :: enum u8 {
	Cubic,     // a cubic convolution widened by the reduction (GDI+'s HighQualityBicubic): no aliasing down to 16 px
	Nearest,   // each pixel the source pixel under its centre: a magnified picture shows its pixels
}

Rect :: struct {
	x, y, w, h: int,
}

// The `from` part of `src` drawn into the `to` part of `dst`, over what is there; the canvas's transform and clip play no
// part. Cubic: the source outside `from` counts as transparent, so a whole picture's edge fades as GDI+'s does.
draw_canvas :: proc(dst: ^Canvas, src: Canvas, to, from: Rect, filter := Filter.Cubic) {
	if to.w <= 0 || to.h <= 0 || from.w <= 0 || from.h <= 0 { return }
	switch filter {
	case .Nearest:
		for j in 0 ..< to.h {
			y := to.y + j
			if y < 0 || y >= dst.height { continue }
			sy := from.y + int((f32(j) + 0.5) * f32(from.h) / f32(to.h))
			for i in 0 ..< to.w {
				x := to.x + i
				if x < 0 || x >= dst.width { continue }
				sx := from.x + int((f32(i) + 0.5) * f32(from.w) / f32(to.w))
				over(dst, x, y, pixel(src, sx, sy))
			}
		}
	case .Cubic:
		cols := weights(from.x, from.w, to.w)
		rows := weights(from.y, from.h, to.h)
		// across first: each source row that a destination row reads, at the destination's width
		lo, hi := max(rows[0].first, 0), min(rows[len(rows) - 1].first + len(rows[len(rows) - 1].w), src.height)
		across := make([][4]f32, max(hi - lo, 0) * to.w, context.temp_allocator)
		for y in lo ..< hi {
			for c, i in cols {
				sum: [4]f32
				for w, k in c.w { sum += pixel(src, c.first + k, y) * w }
				across[(y - lo) * to.w + i] = sum
			}
		}
		for r, j in rows {
			y := to.y + j
			if y < 0 || y >= dst.height { continue }
			for i in 0 ..< to.w {
				x := to.x + i
				if x < 0 || x >= dst.width { continue }
				sum: [4]f32
				for w, k in r.w {
					sy := r.first + k
					if sy >= lo && sy < hi { sum += across[(sy - lo) * to.w + i] * w }
				}
				// (the negative lobes can overshoot)
				sum.a = clamp(sum.a, 0, 1)
				sum.rgb = {clamp(sum.r, 0, sum.a), clamp(sum.g, 0, sum.a), clamp(sum.b, 0, sum.a)}
				over(dst, x, y, sum)
			}
		}
	}
}

// A new canvas of `width` x `height`, the whole of `src` drawn into it.
resize :: proc(src: Canvas, width, height: int, filter := Filter.Cubic, allocator := context.allocator) -> Canvas {
	out := canvas_make(width, height, allocator)
	draw_canvas(&out, src, {0, 0, width, height}, {0, 0, src.width, src.height}, filter)
	return out
}

// A source pixel; outside the canvas, transparent.
@(private = "file")
pixel :: proc(c: Canvas, x, y: int) -> [4]f32 {
	if x < 0 || y < 0 || x >= c.width || y >= c.height { return {} }
	return c.pixels[y * c.width + x]
}

@(private = "file")
over :: proc(c: ^Canvas, x, y: int, src: [4]f32) {
	i := y * c.width + x
	c.pixels[i] = src + c.pixels[i] * (1 - src.a)
}

// The source pixels one destination pixel reads, from `first`, and their weights.
@(private = "file")
Taps :: struct {
	first: int,
	w:     []f32,
}

// Keys' cubic convolution with a = -0.75: of the values tried (-0.5 to -1), the one whose pictures are nearest GDI+'s
// HighQualityBicubic, from 4 times down to 25 times smaller.
@(private = "file")
CUBIC_A :: -0.75

@(private = "file")
cubic :: proc(v: f32) -> f32 {
	x := abs(v)
	if x < 1 { return ((CUBIC_A + 2) * x - (CUBIC_A + 3)) * x * x + 1 }
	if x < 2 { return ((CUBIC_A * x - 5 * CUBIC_A) * x + 8 * CUBIC_A) * x - 4 * CUBIC_A }
	return 0
}

// For each of `n` destination pixels, the taps over the source span [start, start + count): the kernel stretched by the
// reduction, so that each source pixel counts; normalized over all of its taps, the ones outside the span then dropped.
@(private = "file")
weights :: proc(start, count, n: int) -> []Taps {
	out := make([]Taps, n, context.temp_allocator)
	ratio := f32(count) / f32(n)
	stretch := max(ratio, 1)
	support := 2 * stretch
	for &t, i in out {
		centre := f32(start) + (f32(i) + 0.5) * ratio
		first := int(math.floor(centre - support))
		last := int(math.ceil(centre + support))
		w := make([]f32, last - first, context.temp_allocator)
		total: f32
		for &v, k in w {
			v = cubic((f32(first + k) + 0.5 - centre) / stretch)
			total += v
		}
		for &v, k in w {
			v /= total
			if first + k < start || first + k >= start + count { v = 0 }
		}
		t = {first, w}
	}
	return out
}
