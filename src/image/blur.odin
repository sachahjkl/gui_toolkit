package tk_image

import "core:math"
import "core:math/linalg"

// A gaussian blur as three box blurs across, then three down: each box is a running sum, so a pass costs the same for any
// radius. The values are 16-bit, premultiplied by alpha (a transparent pixel lends no colour to its neighbours).

// `img` blurred: a gaussian whose standard deviation is half of `radius`, as a CSS shadow's blur radius (it fades out about
// `radius` pixels away). The edges repeat. A radius below 1 gives a copy.
blur :: proc(img: Image, radius: f32, allocator := context.allocator) -> Image {
	if !valid(img) { return {} }
	out := clone(img, allocator)
	if radius < 1 { return out }
	wide := to_wide(img, premultiplied = true)
	blur_wide(wide, img.width, img.height, boxes(radius / 2))
	from_wide(out, wide, premultiplied = true)
	return out
}

// `img` made crisper, in place: an unsharp mask, each colour pushed away from its neighbourhood's (a blur of radius 2) by
// `amount` (0: nothing; 1: as far again as it differs). Alpha stays.
sharpen :: proc(img: Image, amount: f32) #no_bounds_check {
	if !valid(img) || amount <= 0 { return }
	wide := to_wide(img, premultiplied = false)
	blur_wide(wide, img.width, img.height, boxes(1))
	k := i32(amount * 256 + 0.5)
	for &p, i in img.pixels[:img.width * img.height * 4] {
		if i & 3 == 3 { continue }
		v := i32(p)
		soft := i32(wide[i / 4][i & 3])
		// (soft is 257 times a colour: the difference keeps its 16 bits until the end)
		p = u8(clamp(v + ((v * 257 - soft) * k) / (257 * 256), 0, 255))
	}
}

// The half-widths of the three boxes whose sum is nearest a gaussian of `sigma` (Kovesi's widths: the two sizes around
// the ideal one, as many of each as gives the variance).
@(private)
boxes :: proc(sigma: f32) -> [3]int {
	if sigma <= 0 { return {} }
	ideal := math.sqrt(4 * sigma * sigma + 1)
	lower := int(ideal)
	if lower % 2 == 0 { lower -= 1 }
	lower = max(lower, 1)
	upper := lower + 2
	wl := f32(lower)
	m := int(math.round((12 * sigma * sigma - 3 * wl * wl - 12 * wl - 9) / (-4 * wl - 4)))
	out: [3]int
	for &r, i in out { r = ((i < m ? lower : upper) - 1) / 2 }
	return out
}

// How far the three boxes reach: a pixel lends to those this many pixels away at most.
@(private)
reach :: proc(radii: [3]int) -> int { return radii[0] + radii[1] + radii[2] }

// `img` as 16-bit values: premultiplied (colour * alpha, alpha * 255), or each byte * 257.
@(private)
to_wide :: proc(img: Image, premultiplied: bool) -> [][4]u16 #no_bounds_check {
	wide := make([][4]u16, img.width * img.height, context.temp_allocator)
	for &w, i in wide {
		p := img.pixels[i * 4:][:4]
		if premultiplied {
			a := u32(p[3])
			w = {u16(u32(p[0]) * a), u16(u32(p[1]) * a), u16(u32(p[2]) * a), u16(a * 255)}
		} else {
			w = {u16(p[0]) * 257, u16(p[1]) * 257, u16(p[2]) * 257, u16(p[3]) * 257}
		}
	}
	return wide
}

@(private)
from_wide :: proc(img: Image, wide: [][4]u16, premultiplied: bool) #no_bounds_check {
	for w, i in wide {
		p := img.pixels[i * 4:][:4]
		if premultiplied {
			a := u32(w[3])
			if a == 0 { p[0], p[1], p[2], p[3] = 0, 0, 0, 0; continue }
			p[0] = u8(min((u32(w[0]) * 255 + a / 2) / a, 255))
			p[1] = u8(min((u32(w[1]) * 255 + a / 2) / a, 255))
			p[2] = u8(min((u32(w[2]) * 255 + a / 2) / a, 255))
			p[3] = u8((a + 127) / 255)
		} else {
			for c in 0 ..< 4 { p[c] = u8((u32(w[c]) + 128) / 257) }
		}
	}
}

// Three box passes across, then three down, in place.
@(private)
blur_wide :: proc(data: [][$C]u16, width, height: int, radii: [3]int) {
	for r in radii { if r > 0 { box_across(data, width, height, r) } }
	for r in radii { if r > 0 { box_down(data, width, height, r) } }
}

// Each pixel the mean of the 2r + 1 pixels of its row around it (the row's ends repeat).
@(private = "file")
box_across :: proc(data: [][$C]u16, width, height, r: int) #no_bounds_check {
	line := make([][C]u16, width, context.temp_allocator)
	n := u32(2 * r + 1)
	for y in 0 ..< height {
		row := data[y * width:][:width]
		copy(line, row)
		sum := linalg.array_cast(line[0], u32) * u32(r + 1)
		for i in 1 ..= r { sum += linalg.array_cast(line[min(i, width - 1)], u32) }
		for x in 0 ..< width {
			row[x] = linalg.array_cast((sum + n / 2) / n, u16)
			// (unsigned: the subtraction wraps and the addition brings it back)
			sum += linalg.array_cast(line[min(x + r + 1, width - 1)], u32)
			sum -= linalg.array_cast(line[max(x - r, 0)], u32)
		}
	}
	delete(line, context.temp_allocator)
}

// Each pixel the mean of the 2r + 1 pixels of its column around it (the column's ends repeat). One sum per column, moved
// down a row at a time, so the rows are read in order; the r + 1 rows above that the sums still drop are kept as they were.
@(private = "file")
box_down :: proc(data: [][$C]u16, width, height, r: int) #no_bounds_check {
	n := u32(2 * r + 1)
	sums := make([][C]u32, width, context.temp_allocator)
	kept := make([][C]u16, (r + 1) * width, context.temp_allocator)
	for x in 0 ..< width {
		s := linalg.array_cast(data[x], u32) * u32(r + 1)
		for i in 1 ..= r { s += linalg.array_cast(data[min(i, height - 1) * width + x], u32) }
		sums[x] = s
	}
	for y in 0 ..< height {
		row := data[y * width:][:width]
		copy(kept[(y % (r + 1)) * width:][:width], row)
		below := data[min(y + r + 1, height - 1) * width:][:width]
		above := kept[(max(y - r, 0) % (r + 1)) * width:][:width]
		for x in 0 ..< width {
			s := sums[x]
			row[x] = linalg.array_cast((s + n / 2) / n, u16)
			sums[x] = s + linalg.array_cast(below[x], u32) - linalg.array_cast(above[x], u32)
		}
	}
	delete(kept, context.temp_allocator)
	delete(sums, context.temp_allocator)
}

// The rectangle (cut to the picture; the whole picture by default) made of squares of `cell` pixels, each the mean of
// its pixels (weighed by alpha), in place. The squares start at the rectangle's top-left corner.
pixelate :: proc(img: Image, cell: int, rect: Maybe(Rect) = nil) #no_bounds_check {
	if !valid(img) || cell <= 1 { return }
	r := clip_rect(img, rect.? or_else Rect{0, 0, img.width, img.height})
	if r.w == 0 { return }
	px := words(img)
	for cy := r.y; cy < r.y + r.h; cy += cell {
		y1 := min(cy + cell, r.y + r.h)
		for cx := r.x; cx < r.x + r.w; cx += cell {
			x1 := min(cx + cell, r.x + r.w)
			sum: [4]u64
			for y in cy ..< y1 {
				for x in cx ..< x1 {
					p := transmute(Color)px[y * img.width + x]
					a := u64(p[3])
					sum += {u64(p[0]) * a, u64(p[1]) * a, u64(p[2]) * a, a}
				}
			}
			count := u64((y1 - cy) * (x1 - cx))
			mean: Color
			if sum[3] > 0 {
				for c in 0 ..< 3 { mean[c] = u8((sum[c] + sum[3] / 2) / sum[3]) }
				mean[3] = u8((sum[3] + count / 2) / count)
			}
			fill_rect(img, {cx, cy, x1 - cx, y1 - cy}, mean)
		}
	}
}
