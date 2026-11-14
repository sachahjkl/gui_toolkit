package tk_image

// The part of `img` in the rectangle (cut to the picture). Empty when nothing of it is inside.
crop :: proc(img: Image, x, y, w, h: int, allocator := context.allocator) -> Image #no_bounds_check {
	if !valid(img) { return {} }
	r := clip_rect(img, {x, y, w, h})
	if r.w == 0 { return {} }
	out := create(r.w, r.h, allocator = allocator)
	for j in 0 ..< r.h {
		copy(out.pixels[j * r.w * 4:][:r.w * 4], img.pixels[((r.y + j) * img.width + r.x) * 4:][:r.w * 4])
	}
	return out
}

// (a square of pixels that fits the caches whole, read and written: a turn reads rows and writes columns)
@(private = "file")
TILE :: 64

// `img` turned by `quarter_turns` quarters of a turn, clockwise (negative: counterclockwise).
rotate :: proc(img: Image, quarter_turns: int, allocator := context.allocator) -> Image #no_bounds_check {
	if !valid(img) { return {} }
	turns := ((quarter_turns % 4) + 4) % 4
	if turns == 0 { return clone(img, allocator) }
	w, h := img.width, img.height
	out := turns == 2 ? create(w, h, allocator = allocator) : create(h, w, allocator = allocator)
	src, dst := words(img), words(out)
	if turns == 2 {
		n := w * h
		for i in 0 ..< n { dst[n - 1 - i] = src[i] }
		return out
	}
	// out is h wide: source (x, y) goes to (h-1-y, x) clockwise, to (y, w-1-x) counterclockwise
	for ty := 0; ty < h; ty += TILE {
		for tx := 0; tx < w; tx += TILE {
			for y in ty ..< min(ty + TILE, h) {
				row := src[y * w:]
				if turns == 1 {
					for x in tx ..< min(tx + TILE, w) { dst[x * h + (h - 1 - y)] = row[x] }
				} else {
					for x in tx ..< min(tx + TILE, w) { dst[(w - 1 - x) * h + y] = row[x] }
				}
			}
		}
	}
	return out
}

// `img` mirrored: left to right when `horizontal`, else top to bottom.
flip :: proc(img: Image, horizontal: bool, allocator := context.allocator) -> Image #no_bounds_check {
	if !valid(img) { return {} }
	w, h := img.width, img.height
	out := create(w, h, allocator = allocator)
	src, dst := words(img), words(out)
	for y in 0 ..< h {
		if horizontal {
			s, d := src[y * w:][:w], dst[y * w:][:w]
			for x in 0 ..< w { d[w - 1 - x] = s[x] }
		} else {
			copy(dst[(h - 1 - y) * w:][:w], src[y * w:][:w])
		}
	}
	return out
}

// `img` with a margin of `color` around it: `left`, `top`, `right` and `bottom` pixels (a negative one counts as 0).
pad :: proc(img: Image, left, top, right, bottom: int, color := TRANSPARENT, allocator := context.allocator) -> Image {
	if !valid(img) { return {} }
	l, t, r, b := max(left, 0), max(top, 0), max(right, 0), max(bottom, 0)
	out := create(img.width + l + r, img.height + t + b, color, allocator)
	place(out, img, l, t)
	return out
}

// `img` without a band: the columns from `at` to `at + size` when `columns`, else those rows; what is on either side of
// it is joined. The band is cut to the picture; a band that covers all of it gives an empty picture.
cut_out :: proc(img: Image, at, size: int, columns: bool, allocator := context.allocator) -> Image #no_bounds_check {
	if !valid(img) { return {} }
	w, h := img.width, img.height
	n := columns ? w : h
	a, b := clamp(at, 0, n), clamp(at + max(size, 0), 0, n)
	if b - a >= n { return {} }
	if b == a { return clone(img, allocator) }
	if columns {
		out := create(w - (b - a), h, allocator = allocator)
		for y in 0 ..< h {
			row := img.pixels[y * w * 4:][:w * 4]
			dst := out.pixels[y * out.width * 4:][:out.width * 4]
			copy(dst, row[:a * 4])
			copy(dst[a * 4:], row[b * 4:])
		}
		return out
	}
	out := create(w, h - (b - a), allocator = allocator)
	copy(out.pixels, img.pixels[:a * w * 4])
	copy(out.pixels[a * w * 4:], img.pixels[b * w * 4:][:(h - b) * w * 4])
	return out
}

// The part of `img` that is not its border: the rows and columns at its edges whose every pixel is the colour of the
// top-left corner (each channel within `tolerance`) are left out. A picture of one colour gives an empty Rect.
trim_bounds :: proc(img: Image, tolerance := 0) -> Rect #no_bounds_check {
	if !valid(img) { return {} }
	w, h := img.width, img.height
	c := Color{img.pixels[0], img.pixels[1], img.pixels[2], img.pixels[3]}
	same :: #force_inline proc "contextless" (p: []u8, i: int, c: Color, tolerance: int) -> bool {
		for k in 0 ..< 4 { if abs(int(p[i * 4 + k]) - int(c[k])) > tolerance { return false } }
		return true
	}
	row_same :: proc(img: Image, y: int, c: Color, tolerance: int) -> bool {
		for x in 0 ..< img.width { if !same(img.pixels, y * img.width + x, c, tolerance) { return false } }
		return true
	}
	col_same :: proc(img: Image, x, y0, y1: int, c: Color, tolerance: int) -> bool {
		for y in y0 ..< y1 { if !same(img.pixels, y * img.width + x, c, tolerance) { return false } }
		return true
	}
	top := 0
	for top < h && row_same(img, top, c, tolerance) { top += 1 }
	if top == h { return {} }
	bottom := h
	for bottom > top && row_same(img, bottom - 1, c, tolerance) { bottom -= 1 }
	left := 0
	for left < w && col_same(img, left, top, bottom, c, tolerance) { left += 1 }
	right := w
	for right > left && col_same(img, right - 1, top, bottom, c, tolerance) { right -= 1 }
	return {left, top, right - left, bottom - top}
}

// The mean colour of the pixels on the edge of `r` (cut to the picture): what is around a rectangle, to fill it with.
// Transparent when nothing of `r` is inside.
edge_mean :: proc(img: Image, r: Rect) -> Color #no_bounds_check {
	if !valid(img) { return {} }
	c := clip_rect(img, r)
	if c.w == 0 { return {} }
	sum: [4]u64
	n: u64
	add :: #force_inline proc "contextless" (img: Image, x, y: int, sum: ^[4]u64, n: ^u64) {
		p := img.pixels[(y * img.width + x) * 4:][:4]
		for k in 0 ..< 4 { sum[k] += u64(p[k]) }
		n^ += 1
	}
	for x in c.x ..< c.x + c.w {
		add(img, x, c.y, &sum, &n)
		if c.h > 1 { add(img, x, c.y + c.h - 1, &sum, &n) }
	}
	for y in c.y + 1 ..< c.y + c.h - 1 {
		add(img, c.x, y, &sum, &n)
		if c.w > 1 { add(img, c.x + c.w - 1, y, &sum, &n) }
	}
	return {u8((sum[0] + n / 2) / n), u8((sum[1] + n / 2) / n), u8((sum[2] + n / 2) / n), u8((sum[3] + n / 2) / n)}
}

// `src` copied into `dst` with its top-left corner at (x, y), replacing what is there; the part outside `dst` is left out.
@(private)
place :: proc(dst, src: Image, x, y: int) #no_bounds_check {
	r := clip_rect(dst, {x, y, src.width, src.height})
	if r.w == 0 { return }
	for j in 0 ..< r.h {
		sy, sx := r.y + j - y, r.x - x
		copy(dst.pixels[((r.y + j) * dst.width + r.x) * 4:][:r.w * 4], src.pixels[(sy * src.width + sx) * 4:][:r.w * 4])
	}
}
