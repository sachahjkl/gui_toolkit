package tk_image

import "core:math"

// `img` with a frame of `color`, `width` pixels thick: around it (the picture grows), or over its outer pixels when
// `inside` (the size stays).
border :: proc(img: Image, width: int, color: Color, inside := false, allocator := context.allocator) -> Image {
	if !valid(img) { return {} }
	if width <= 0 { return clone(img, allocator) }
	if !inside { return pad(img, width, width, width, width, color, allocator) }
	out := clone(img, allocator)
	w, h := out.width, out.height
	fill_rect(out, {0, 0, w, width}, color)
	fill_rect(out, {0, h - width, w, width}, color)
	fill_rect(out, {0, 0, width, h}, color)
	fill_rect(out, {w - width, 0, width, h}, color)
	return out
}

// `img` with its corners cut round, of `radius` pixels (at most half its smaller side): what is outside the arcs becomes
// transparent, their edge antialiased.
round_corners :: proc(img: Image, radius: f32, allocator := context.allocator) -> Image #no_bounds_check {
	if !valid(img) { return {} }
	out := clone(img, allocator)
	r := min(radius, f32(min(img.width, img.height)) / 2)
	if r <= 0 { return out }
	n := int(math.ceil(r))
	w, h := img.width, img.height
	for y in 0 ..< n {
		for x in 0 ..< n {
			// the share of the pixel inside the arc: its centre's distance from the arc, within half a pixel
			dx, dy := r - (f32(x) + 0.5), r - (f32(y) + 0.5)
			if dx <= 0 && dy <= 0 { continue }
			d := math.sqrt(max(dx, 0) * max(dx, 0) + max(dy, 0) * max(dy, 0))
			k := clamp(r - d + 0.5, 0, 1)
			if k >= 1 { continue }
			corners := [4][2]int{{x, y}, {w - 1 - x, y}, {x, h - 1 - y}, {w - 1 - x, h - 1 - y}}
			for corner, i in corners {
				// (on an odd side the middle pixel is two corners' at once: it is cut once)
				if (i & 1 == 1 && corner.x == x) || (i >= 2 && corner.y == y) { continue }
				a := &out.pixels[(corner.y * w + corner.x) * 4 + 3]
				a^ = u8(f32(a^) * k + 0.5)
			}
		}
	}
	return out
}

// `img` over its shadow: its shape in `color`, moved by `offset` and blurred by `radius` (as blur's). The picture grows to
// hold the whole shadow; `img` keeps its pixels.
drop_shadow :: proc(img: Image, offset: [2]int, radius: f32, color: Color, allocator := context.allocator) -> Image #no_bounds_check {
	if !valid(img) { return {} }
	radii := radius >= 1 ? boxes(radius / 2) : [3]int{}
	e := reach(radii)
	w, h := img.width, img.height
	x0, y0 := min(0, offset.x - e), min(0, offset.y - e)
	x1, y1 := max(w, offset.x + w + e), max(h, offset.y + h + e)
	out := create(x1 - x0, y1 - y0, allocator = allocator)
	ow, oh := out.width, out.height

	// the shadow is one channel: the picture's alpha times the colour's, blurred
	layer := make([][1]u16, ow * oh, context.temp_allocator)
	sx, sy := offset.x - x0, offset.y - y0
	ca := u32(color[3])
	for y in 0 ..< h {
		row := layer[(sy + y) * ow + sx:][:w]
		src := img.pixels[y * w * 4:][:w * 4]
		for &v, x in row { v = {u16(u32(src[x * 4 + 3]) * ca)} }
	}
	blur_wide(layer, ow, oh, radii)
	px := words(out)
	for v, i in layer {
		if v[0] == 0 { continue }
		px[i] = word_of({color[0], color[1], color[2], u8((u32(v[0]) + 127) / 255)})
	}
	draw_over(out, img, -x0, -y0)
	return out
}

// What background paints: a linear gradient from `from` to `to`, its direction `angle` degrees as CSS's (0 upward, 90
// to the right). The same colour twice is a flat fill: solid(color).
Fill :: struct {
	from, to: Color,
	angle:    f32,
}

solid :: proc(color: Color) -> Fill { return {from = color, to = color} }

// `img` on a background of `fill`, `margin` pixels of it around it: the picture grows by twice the margin.
background :: proc(img: Image, margin: int, fill: Fill, allocator := context.allocator) -> Image {
	if !valid(img) { return {} }
	m := max(margin, 0)
	out := create(img.width + 2 * m, img.height + 2 * m, allocator = allocator)
	paint_fill(out, fill)
	draw_over(out, img, m, m)
	return out
}

// Every pixel of `img` the colour of `fill` at its place. The gradient line crosses the picture from corner to corner
// as CSS's does: its ends touch the two corners farthest along it.
@(private)
paint_fill :: proc(img: Image, fill: Fill) #no_bounds_check {
	if fill.from == fill.to {
		fill_rect(img, {0, 0, img.width, img.height}, fill.from)
		return
	}
	// 256 steps: two colours of 8 bits never differ by more
	table: [256]u32
	for &v, i in table {
		t := f32(i) / 255
		c: Color
		for k in 0 ..< 4 { c[k] = u8(math.lerp(f32(fill.from[k]), f32(fill.to[k]), t) + 0.5) }
		v = word_of(c)
	}
	a := math.to_radians(fill.angle)
	dx, dy := math.sin(a), -math.cos(a)
	w, h := f32(img.width), f32(img.height)
	length := abs(w * dx) + abs(h * dy)
	px := words(img)
	for y in 0 ..< img.height {
		row := px[y * img.width:][:img.width]
		cy := f32(y) + 0.5 - h / 2
		for &p, x in row {
			cx := f32(x) + 0.5 - w / 2
			t := (cx * dx + cy * dy) / length + 0.5
			p = table[int(clamp(t, 0, 1) * 255 + 0.5)]
		}
	}
}
