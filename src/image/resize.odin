package tk_image

import "core:math"

// How resize weighs the source pixels. Each one widens with the reduction, so that every source pixel counts on a downscale.
Filter :: enum u8 {
	Lanczos3,   // the sharpest, the slowest (12 taps per axis at half size): a screenshot's text stays readable
	Bilinear,   // the triangle: softer, half the taps of Lanczos3
	Box,        // the average of the pixels each one covers: the fastest downscale; an upscale shows the pixels
}

// `img` at `width` x `height`. Colours are weighed by their alpha (a transparent pixel gives no colour) and the edges
// repeat. An empty picture when a size is below 1.
resize :: proc(img: Image, width, height: int, filter := Filter.Lanczos3, allocator := context.allocator) -> Image #no_bounds_check {
	if !valid(img) || width <= 0 || height <= 0 { return {} }
	if width == img.width && height == img.height { return clone(img, allocator) }
	sw, sh := img.width, img.height
	cols := taps(sw, width, filter)
	rows := taps(sh, height, filter)
	out := create(width, height, allocator = allocator)

	// The rows of the source resized across, as the rows of the output read them: their taps are consecutive and move
	// down, so a ring of `rows.stride` rows holds every row an output row needs and each is resized across once.
	ring := make([][4]f32, rows.stride * width, context.temp_allocator)
	held := make([]int, rows.stride, context.temp_allocator)
	for &h in held { h = -1 }
	line := make([][4]f32, sw, context.temp_allocator)
	acc := make([][4]f32, width, context.temp_allocator)
	for j in 0 ..< height {
		ring_row_sum(img, &cols, ring, held, line, rows.first[j], rows.weights[j * rows.stride:][:rows.stride], acc)
		o := out.pixels[j * width * 4:][:width * 4]
		for v, i in acc { o[i * 4], o[i * 4 + 1], o[i * 4 + 2], o[i * 4 + 3] = unpremultiply(v) }
	}
	return out
}

// `img` scaled by `factor` on both axes (rounded to whole pixels), with resize's filter.
scale :: proc(img: Image, factor: f32, filter := Filter.Lanczos3, allocator := context.allocator) -> Image {
	if !valid(img) || factor <= 0 { return {} }
	w := max(1, int(math.round(f32(img.width) * factor)))
	h := max(1, int(math.round(f32(img.height) * factor)))
	return resize(img, w, h, filter, allocator)
}

// One output row: the weighted sum of the ring's rows `first` + k, each resized across when the ring lacks it.
@(private = "file")
ring_row_sum :: proc(img: Image, cols: ^Taps, ring: [][4]f32, held: []int, line: [][4]f32, first: int, w: []f32, acc: [][4]f32) #no_bounds_check {
	stride, width := len(held), len(acc)
	for &v in acc { v = {} }
	for weight, k in w {
		if weight == 0 { continue }
		sy := first + k
		slot := sy % stride
		row := ring[slot * width:][:width]
		if held[slot] != sy {
			premultiplied_row(img, sy, line)
			across(line, cols, row)
			held[slot] = sy
		}
		for v, i in row { acc[i] += v * weight }
	}
}

// Row `y` of `img`, premultiplied, as f32 from 0 to 255.
@(private)
premultiplied_row :: proc(img: Image, y: int, line: [][4]f32) #no_bounds_check {
	src := img.pixels[y * img.width * 4:][:img.width * 4]
	for &v, x in line {
		p := src[x * 4:][:4]
		a := f32(p[3])
		k := a / 255
		v = {f32(p[0]) * k, f32(p[1]) * k, f32(p[2]) * k, a}
	}
}

// A premultiplied pixel (0 to 255) back to straight RGBA8, its overshoot (negative lobes) cut.
@(private)
unpremultiply :: #force_inline proc "contextless" (v: [4]f32) -> (r, g, b, a: u8) {
	alpha := clamp(v.a, 0, 255)
	if alpha < 0.5 { return 0, 0, 0, 0 }
	k := 255 / alpha
	r = u8(clamp(v.r * k, 0, 255) + 0.5)
	g = u8(clamp(v.g * k, 0, 255) + 0.5)
	b = u8(clamp(v.b * k, 0, 255) + 0.5)
	a = u8(alpha + 0.5)
	return
}

// A source row resized across into `out`.
@(private = "file")
across :: proc(line: [][4]f32, cols: ^Taps, out: [][4]f32) #no_bounds_check {
	for &o, i in out {
		src := line[cols.first[i]:][:cols.stride]
		w := cols.weights[i * cols.stride:][:cols.stride]
		sum: [4]f32
		for v, k in src { sum += v * w[k] }
		o = sum
	}
}

// For each of `n` output pixels, `stride` consecutive source pixels from first[i] and their weights (weights[i * stride:]):
// one stride for all, so the loops have no branch; the taps past an edge add to the edge pixel.
@(private = "file")
Taps :: struct {
	first:   []int,
	weights: []f32,
	stride:  int,
}

@(private = "file")
support_of :: proc(filter: Filter) -> f32 {
	switch filter {
	case .Lanczos3: return 3
	case .Bilinear: return 1
	case .Box:      return 0.5
	}
	return 1
}

@(private = "file")
kernel :: proc(filter: Filter, x: f32) -> f32 {
	switch filter {
	case .Lanczos3:
		if x == 0 { return 1 }
		if abs(x) >= 3 { return 0 }
		px := math.PI * x
		return 3 * math.sin(px) * math.sin(px / 3) / (px * px)
	case .Bilinear:
		return max(0, 1 - abs(x))
	case .Box:
		return x >= -0.5 && x < 0.5 ? 1 : 0
	}
	return 0
}

@(private = "file")
taps :: proc(source, n: int, filter: Filter) -> Taps {
	ratio := f32(source) / f32(n)
	stretch := max(ratio, 1)
	support := support_of(filter) * stretch
	stride := min(int(math.ceil(2 * support)) + 3, source)
	t := Taps{first = make([]int, n, context.temp_allocator), weights = make([]f32, n * stride, context.temp_allocator), stride = stride}
	for i in 0 ..< n {
		centre := (f32(i) + 0.5) * ratio
		lo := int(math.floor(centre - support))
		hi := int(math.ceil(centre + support))
		first := clamp(lo, 0, source - stride)
		w := t.weights[i * stride:][:stride]
		total: f32
		for k in lo ..= hi {
			v := kernel(filter, (f32(k) + 0.5 - centre) / stretch)
			if v == 0 { continue }
			w[clamp(k, 0, source - 1) - first] += v
			total += v
		}
		if total == 0 {
			// (a box narrower than the pixel spacing missed every centre: the nearest pixel)
			w[clamp(int(centre), 0, source - 1) - first] = 1
			total = 1
		}
		for &v in w { v /= total }
		t.first[i] = first
	}
	return t
}
