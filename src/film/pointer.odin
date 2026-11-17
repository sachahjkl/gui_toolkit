package film

import "core:math"

// The pointer a film draws over each frame (the program draws none: a headless window has no system pointer): an arrow,
// white with a dark outline and a soft shadow, a little smaller while a button is down, and a ring that spreads from
// each click. Its place is in the window's client pixels.
Pointer :: struct {
	at:      [2]f32,
	shown:   bool,
	down:    bool,
	press_t: f32,              // 0 up .. 1 down, eased by pointer_draw
	scale:   f32,
	sprite:  [][4]f32,         // premultiplied B, G, R, A
	side:    [2]int,
	hot:     [2]f32,           // the tip, in the sprite
	rings:   [dynamic]Ring,
}

Ring :: struct {
	at:    [2]f32,
	start: f64,                // the clock at the click, ms
}

@(private) RING_MS :: 450
@(private) PRESS_RATE :: 0.35   // of the way to the press's size, each frame

// The arrow, in pixels at scale 1, its tip at (0, 0).
@(private, rodata)
ARROW := [?][2]f32{{0, 0}, {0, 16.5}, {4, 12.8}, {6.9, 19.6}, {9.4, 18.6}, {6.5, 11.9}, {11.8, 11.9}}

@(private)
pointer_init :: proc(p: ^Pointer, scale: f32) {
	p.scale = max(scale, 1) * 1.15
	s := p.scale
	pad := math.ceil(6 * s)
	p.hot = {pad, pad}
	p.side = {int(math.ceil(12 * s + 2 * pad)), int(math.ceil(20 * s + 2 * pad))}
	n := p.side.x * p.side.y
	p.sprite = make([][4]f32, n)
	dark := make([]f32, n, context.temp_allocator)
	white := make([]f32, n, context.temp_allocator)
	edge := 1.3 * s
	SUB :: 4
	for y in 0 ..< p.side.y {
		for x in 0 ..< p.side.x {
			d, w: f32
			for sy in 0 ..< SUB {
				for sx in 0 ..< SUB {
					q := ([2]f32{f32(x) + (f32(sx) + 0.5) / SUB, f32(y) + (f32(sy) + 0.5) / SUB} - p.hot) / s
					inside := in_polygon(q, ARROW[:])
					dist := edge_distance(q, ARROW[:]) * s
					if inside || dist < edge { d += 1 }
					if inside && dist >= edge * 0.45 { w += 1 }
				}
			}
			dark[y * p.side.x + x] = d / (SUB * SUB)
			white[y * p.side.x + x] = w / (SUB * SUB)
		}
	}
	shadow := blur(dark, p.side, int(math.ceil(1.6 * s)))
	off := [2]int{int(math.round(1.2 * s)), int(math.round(2.2 * s))}
	for y in 0 ..< p.side.y {
		for x in 0 ..< p.side.x {
			i := y * p.side.x + x
			sh: f32
			if sx, sy := x - off.x, y - off.y; sx >= 0 && sy >= 0 { sh = shadow[sy * p.side.x + sx] * 0.4 }
			// (shadow, then the dark outline over it, then the white over both; premultiplied)
			c := [4]f32{0, 0, 0, sh}
			c = over({0.08, 0.08, 0.08, dark[i]}, c)
			c = over({1, 1, 1, white[i]}, c)
			p.sprite[i] = c
		}
	}
}

@(private)
pointer_destroy :: proc(p: ^Pointer) {
	delete(p.sprite)
	delete(p.rings)
}

// `src` (straight colour, its alpha) over `dst` (premultiplied).
@(private)
over :: proc(src, dst: [4]f32) -> [4]f32 {
	a := src.a
	return {src.r * a + dst.r * (1 - a), src.g * a + dst.g * (1 - a), src.b * a + dst.b * (1 - a), a + dst.a * (1 - a)}
}

@(private)
in_polygon :: proc(q: [2]f32, poly: [][2]f32) -> bool {
	inside := false
	j := len(poly) - 1
	for i in 0 ..< len(poly) {
		a, b := poly[i], poly[j]
		if (a.y > q.y) != (b.y > q.y) && q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside = !inside }
		j = i
	}
	return inside
}

@(private)
edge_distance :: proc(q: [2]f32, poly: [][2]f32) -> f32 {
	best := f32(math.F32_MAX)
	j := len(poly) - 1
	for i in 0 ..< len(poly) {
		a, b := poly[j], poly[i]
		ab := b - a
		t := clamp(((q.x - a.x) * ab.x + (q.y - a.y) * ab.y) / (ab.x * ab.x + ab.y * ab.y), 0, 1)
		best = min(best, math.hypot(q.x - (a.x + ab.x * t), q.y - (a.y + ab.y * t)))
		j = i
	}
	return best
}

// Two box blurs of `r` pixels, across then down (temp memory).
@(private)
blur :: proc(v: []f32, side: [2]int, r: int) -> []f32 {
	cur := v
	for _ in 0 ..< 2 {
		a := make([]f32, len(v), context.temp_allocator)
		for y in 0 ..< side.y {
			for x in 0 ..< side.x {
				s: f32
				for k in -r ..= r { if xx := x + k; xx >= 0 && xx < side.x { s += cur[y * side.x + xx] } }
				a[y * side.x + x] = s / f32(2 * r + 1)
			}
		}
		b := make([]f32, len(v), context.temp_allocator)
		for y in 0 ..< side.y {
			for x in 0 ..< side.x {
				s: f32
				for k in -r ..= r { if yy := y + k; yy >= 0 && yy < side.y { s += a[yy * side.x + x] } }
				b[y * side.x + x] = s / f32(2 * r + 1)
			}
		}
		cur = b
	}
	return cur
}

// The pointer and its rings over the film's frame `px` (B8G8R8X8 of `film`), the window at `window_at` on it.
@(private)
pointer_draw :: proc(p: ^Pointer, px: []u8, film: [2]int, window_at: [2]int, clock: f64) {
	origin := p.at + [2]f32{f32(window_at.x), f32(window_at.y)}
	// the rings, under the arrow
	for i := 0; i < len(p.rings); {
		g := &p.rings[i]
		e := f32((clock - g.start) / RING_MS)
		if e >= 1 { unordered_remove(&p.rings, i); continue }
		ease := 1 - (1 - e) * (1 - e)
		radius := (5 + 24 * ease) * p.scale
		alpha := 0.6 * (1 - e)
		ring_draw(px, film, g.at + [2]f32{f32(window_at.x), f32(window_at.y)}, radius, 2.4 * p.scale, alpha)
		i += 1
	}
	if !p.shown { return }
	target: f32 = p.down ? 1 : 0
	p.press_t += (target - p.press_t) * PRESS_RATE
	k := 1 - 0.12 * p.press_t   // (smaller while down)
	// each pixel of the frame under the sprite samples it about the tip, scaled by k
	x0 := int(math.floor(origin.x - p.hot.x * k))
	y0 := int(math.floor(origin.y - p.hot.y * k))
	x1 := int(math.ceil(origin.x + (f32(p.side.x) - p.hot.x) * k))
	y1 := int(math.ceil(origin.y + (f32(p.side.y) - p.hot.y) * k))
	for y in max(y0, 0) ..< min(y1, film.y) {
		for x in max(x0, 0) ..< min(x1, film.x) {
			sp := ([2]f32{f32(x) + 0.5, f32(y) + 0.5} - origin) / k + p.hot - 0.5
			c := sample(p, sp)
			if c.a <= 0.002 { continue }
			o := (y * film.x + x) * 4
			// (premultiplied B, G, R over the frame)
			for ch in 0 ..< 3 { px[o + ch] = u8(clamp(c[ch] * 255 + f32(px[o + ch]) * (1 - c.a) + 0.5, 0, 255)) }
		}
	}
}

// The sprite at `q` (its pixels' centres at whole numbers), bilinear; transparent outside.
@(private)
sample :: proc(p: ^Pointer, q: [2]f32) -> [4]f32 {
	fx, fy := math.floor(q.x), math.floor(q.y)
	tx, ty := q.x - fx, q.y - fy
	at :: proc(p: ^Pointer, x, y: int) -> [4]f32 {
		if x < 0 || y < 0 || x >= p.side.x || y >= p.side.y { return {} }
		return p.sprite[y * p.side.x + x]
	}
	ix, iy := int(fx), int(fy)
	a := at(p, ix, iy) * (1 - tx) + at(p, ix + 1, iy) * tx
	b := at(p, ix, iy + 1) * (1 - tx) + at(p, ix + 1, iy + 1) * tx
	return a * (1 - ty) + b * ty
}

// A white ring of `radius` and `width` at `c`, at `alpha`.
@(private)
ring_draw :: proc(px: []u8, film: [2]int, c: [2]f32, radius, width, alpha: f32) {
	reach := int(math.ceil(radius + width))
	for y in max(int(c.y) - reach, 0) ..< min(int(c.y) + reach + 1, film.y) {
		for x in max(int(c.x) - reach, 0) ..< min(int(c.x) + reach + 1, film.x) {
			d := math.hypot(f32(x) + 0.5 - c.x, f32(y) + 0.5 - c.y)
			a := clamp(width * 0.5 - abs(d - radius) + 0.5, 0, 1) * alpha
			if a <= 0 { continue }
			o := (y * film.x + x) * 4
			for ch in 0 ..< 3 { px[o + ch] = u8(255 * a + f32(px[o + ch]) * (1 - a) + 0.5) }
		}
	}
}
