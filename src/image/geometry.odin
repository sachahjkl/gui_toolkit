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
