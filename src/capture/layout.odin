package capture

// The pure parts of the backends that start from physical pixels (Windows): the logical layout of the outputs, a
// physical rect on the desktop given in logical pixels, and the picture of one output drawn into the desktop's. No call
// to the system here: tests/capture runs them on every system.

import "core:math"

// The logical rects of outputs given by their physical rects (on a desktop in physical pixels, as Windows' virtual
// desktop is to a per-monitor DPI aware thread) and their scales. `logical` is as long as `physical`.
//
// An output's logical origin is its physical origin divided by the smallest scale of all; its logical size is its
// physical size divided by its own scale. With one scale for every output this is the exact division: no gap, no
// overlap. With mixed scales no single division keeps the outputs apart; this one keeps each logical rect inside the
// physical layout shrunk by the smallest scale, where outputs never overlap: gaps may appear (transparent in desktop),
// overlaps never. Both values are rounded down, which keeps that property.
layout_logical :: proc(physical: []Rect, scales: []f32, logical: []Rect) {
	assert(len(scales) == len(physical) && len(logical) == len(physical))
	smallest := f64(0)
	for s in scales {
		v := scale_or_one(s)
		if smallest == 0 || v < smallest { smallest = v }
	}
	for r, i in physical {
		s := scale_or_one(scales[i])
		logical[i] = Rect{
			x = i32(math.floor(f64(r.x) / smallest)),
			y = i32(math.floor(f64(r.y) / smallest)),
			w = i32(math.floor(f64(r.w) / s)),
			h = i32(math.floor(f64(r.h) / s)),
		}
	}
}

// A physical rect `r` of the desktop in logical pixels, through the output it is on (its physical and logical rects and
// its scale): the inverse of what a Frame of that output says (origin + offset / scale). A rect across two outputs is
// converted through one of them: output_of picks the one that holds most of it.
physical_to_logical :: proc(r: Rect, output_physical, output_logical: Rect, scale: f32) -> Rect {
	s := scale_or_one(scale)
	return Rect{
		x = output_logical.x + i32(math.floor(f64(r.x - output_physical.x) / s)),
		y = output_logical.y + i32(math.floor(f64(r.y - output_physical.y) / s)),
		w = i32(math.round(f64(r.w) / s)),
		h = i32(math.round(f64(r.h) / s)),
	}
}

// The index of the output that holds most of `r` (physical rects both), else the nearest one by their centres; -1 when
// there is no output. What MonitorFromRect(MONITOR_DEFAULTTONEAREST) answers, without asking the system.
output_of :: proc(r: Rect, outputs: []Rect) -> int {
	best, best_area := -1, i64(0)
	for o, i in outputs {
		if a := intersection_area(r, o); a > best_area { best, best_area = i, a }
	}
	if best >= 0 { return best }
	best_distance := max(i64)
	cx, cy := i64(r.x) + i64(r.w) / 2, i64(r.y) + i64(r.h) / 2
	for o, i in outputs {
		dx := clamp(cx, i64(o.x), i64(o.x) + i64(max(o.w - 1, 0))) - cx
		dy := clamp(cy, i64(o.y), i64(o.y) + i64(max(o.h - 1, 0))) - cy
		if d := dx * dx + dy * dy; d < best_distance { best, best_distance = i, d }
	}
	return best
}

// The smallest rect that holds every rect of `rects`; zero when there is none.
bounding_rect :: proc(rects: []Rect) -> Rect {
	if len(rects) == 0 { return {} }
	x0, y0 := rects[0].x, rects[0].y
	x1, y1 := rects[0].x + rects[0].w, rects[0].y + rects[0].h
	for r in rects[1:] {
		x0, y0 = min(x0, r.x), min(y0, r.y)
		x1, y1 = max(x1, r.x + r.w), max(y1, r.y + r.h)
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

// Draws `src` into `dst`, filling the physical rect `at` of `dst` (clipped to it). The same size: plain row copies;
// another size (an output of a smaller scale in a desktop at the largest one): bilinear filtering, which keeps text
// legible where nearest neighbour would double every other pixel.
frame_draw :: proc(dst: ^Frame, src: Frame, at: Rect) {
	if at.w <= 0 || at.h <= 0 || src.width <= 0 || src.height <= 0 { return }
	x0, y0 := max(at.x, 0), max(at.y, 0)
	x1, y1 := min(at.x + at.w, dst.width), min(at.y + at.h, dst.height)
	if x0 >= x1 || y0 >= y1 { return }
	if at.w == src.width && at.h == src.height {
		n := int(x1 - x0) * 4
		for y in y0 ..< y1 {
			from := src.pixels[int((y - at.y) * src.stride + (x0 - at.x) * 4):][:n]
			copy(dst.pixels[int(y * dst.stride + x0 * 4):][:n], from)
		}
		return
	}
	// The centre of a destination pixel, in source pixels.
	fx := f32(src.width) / f32(at.w)
	fy := f32(src.height) / f32(at.h)
	for y in y0 ..< y1 {
		sy := (f32(y - at.y) + 0.5) * fy - 0.5
		sy = clamp(sy, 0, f32(src.height - 1))
		ry0 := i32(sy)
		ry1 := min(ry0 + 1, src.height - 1)
		wy := sy - f32(ry0)
		row := dst.pixels[int(y * dst.stride):]
		for x in x0 ..< x1 {
			sx := (f32(x - at.x) + 0.5) * fx - 0.5
			sx = clamp(sx, 0, f32(src.width - 1))
			rx0 := i32(sx)
			rx1 := min(rx0 + 1, src.width - 1)
			wx := sx - f32(rx0)
			p00 := src.pixels[int(ry0 * src.stride + rx0 * 4):]
			p10 := src.pixels[int(ry0 * src.stride + rx1 * 4):]
			p01 := src.pixels[int(ry1 * src.stride + rx0 * 4):]
			p11 := src.pixels[int(ry1 * src.stride + rx1 * 4):]
			for c in 0 ..< 4 {
				top := f32(p00[c]) + (f32(p10[c]) - f32(p00[c])) * wx
				bottom := f32(p01[c]) + (f32(p11[c]) - f32(p01[c])) * wx
				row[int(x * 4) + c] = u8(clamp(top + (bottom - top) * wy + 0.5, 0, 255))
			}
		}
	}
}

@(private = "file")
scale_or_one :: proc(s: f32) -> f64 { return s > 0 ? f64(s) : 1 }

@(private = "file")
intersection_area :: proc(a, b: Rect) -> i64 {
	w := i64(min(a.x + a.w, b.x + b.w)) - i64(max(a.x, b.x))
	h := i64(min(a.y + a.h, b.y + b.h)) - i64(max(a.y, b.y))
	if w <= 0 || h <= 0 { return 0 }
	return w * h
}
