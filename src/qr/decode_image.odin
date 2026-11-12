package qr

// QR Code reading, the half that finds the modules in a picture. The picture is made black and white (one threshold
// for the whole picture by Otsu's method, else one per block from its neighbourhood, and each of these inverted for a
// light code on a dark ground). The finder patterns are the runs of dark, light, dark, light, dark in the ratios
// 1:1:3:1:1 along a row, checked down their column and again along their row. Three of them at the corners of a right
// isosceles triangle give the symbol's orientation, its module and its size; its modules are read at their centres
// through the affine map those three points make, and decode_modules reads them.
//
// The map is affine: a picture of a screen (scaled, turned a quarter, a half), not a photograph seen at an angle.

import "base:runtime"
import "core:math"
import "core:slice"

// How many triples of finder patterns, best first, are tried before the picture is given up.
@(private = "file") MAX_TRIPLES :: 6
// The finder patterns kept for the triples, the most often seen first.
@(private = "file") MAX_FINDERS :: 8
// The side of a block of the local threshold, in pixels, and how far apart its darkest and lightest pixels must be
// for its own mean to count (else it is a flat area, and takes its neighbours').
@(private = "file") BLOCK :: 8
@(private = "file") FLAT_RANGE :: 24

// A picture of 8-bit luminance (0 black, 255 white), `stride` bytes a row, into the data of the first QR Code found.
decode_gray :: proc(gray: []u8, width, height, stride: int, allocator := context.allocator) -> (result: Decoded, err: Decode_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if width < 21 || height < 21 || stride < width || len(gray) < (height - 1) * stride + width { return {}, .Not_Found }
	img := Gray{pixels = gray, width = width, height = height, stride = stride}
	err = .Not_Found
	for local in ([2]bool{false, true}) {
		dark := local ? threshold_local(img) : threshold_global(img)
		for invert in ([2]bool{false, true}) {
			b := Binary{width = width, height = height, dark = dark, invert = invert}
			d, e := decode_binary(&b, allocator)
			if e == .None { return d, .None }
			if e != .Not_Found { err = e }   // (a code was there and could not be read: that says more)
		}
	}
	return {}, err
}

// RGBA pixels (BGRA when `bgra`), 8 bits a channel, `stride` bytes a row; alpha is not looked at.
decode_rgba :: proc(pixels: []u8, width, height, stride: int, bgra := false, allocator := context.allocator) -> (Decoded, Decode_Error) {
	if width <= 0 || height <= 0 || stride < width * 4 || len(pixels) < (height - 1) * stride + width * 4 { return {}, .Not_Found }
	gray := make([]u8, width * height, context.temp_allocator)
	r, b := bgra ? 2 : 0, bgra ? 0 : 2
	for y in 0 ..< height {
		row := pixels[y * stride:]
		for x in 0 ..< width {
			p := row[x * 4:]
			gray[y * width + x] = u8((int(p[r]) * 77 + int(p[1]) * 150 + int(p[b]) * 29) >> 8)
		}
	}
	return decode_gray(gray, width, height, width, allocator)
}

@(private = "file")
Gray :: struct {
	pixels:                []u8,
	width, height, stride: int,
}

// The picture in black and white: `dark` one per pixel, read through `invert`.
@(private = "file")
Binary :: struct {
	width, height: int,
	dark:          []bool,
	invert:        bool,
}

@(private = "file")
is_dark :: #force_inline proc(b: ^Binary, x, y: int) -> bool {
	if x < 0 || y < 0 || x >= b.width || y >= b.height { return false }   // (outside: the light of a quiet zone)
	return b.dark[y * b.width + x] != b.invert
}

////////////////////////////////
// Thresholds

// One threshold for the picture, Otsu's: the one that separates its histogram best.
@(private = "file")
threshold_global :: proc(img: Gray) -> []bool {
	histogram: [256]int
	for y in 0 ..< img.height {
		for p in img.pixels[y * img.stride:][:img.width] { histogram[p] += 1 }
	}
	total := img.width * img.height
	sum_all: f64
	for n, i in histogram { sum_all += f64(i * n) }
	best, best_between := 0, -1.0
	below, sum_below: f64
	for n, t in histogram {
		below += f64(n)
		sum_below += f64(t * n)
		above := f64(total) - below
		if below == 0 || above == 0 { continue }
		d := sum_below / below - (sum_all - sum_below) / above
		if between := below * above * d * d; between > best_between { best, best_between = t, between }
	}
	dark := make([]bool, total, context.temp_allocator)
	for y in 0 ..< img.height {
		for p, x in img.pixels[y * img.stride:][:img.width] { dark[y * img.width + x] = int(p) <= best }
	}
	return dark
}

// A threshold per block of BLOCK pixels: the mean of the 5 x 5 blocks around it. A flat block (a part of a module, or
// a plain ground) takes a mean from its neighbours, so a large dark module stays dark.
@(private = "file")
threshold_local :: proc(img: Gray) -> []bool {
	bw, bh := (img.width + BLOCK - 1) / BLOCK, (img.height + BLOCK - 1) / BLOCK
	means := make([]int, bw * bh, context.temp_allocator)
	for by in 0 ..< bh {
		for bx in 0 ..< bw {
			sum, n, lo, hi := 0, 0, 255, 0
			for y in by * BLOCK ..< min((by + 1) * BLOCK, img.height) {
				for p in img.pixels[y * img.stride + bx * BLOCK:][:min(BLOCK, img.width - bx * BLOCK)] {
					sum += int(p)
					n += 1
					lo, hi = min(lo, int(p)), max(hi, int(p))
				}
			}
			mean := sum / max(n, 1)
			if hi - lo <= FLAT_RANGE {
				mean = lo / 2
				if bx > 0 && by > 0 {
					around := (means[(by - 1) * bw + bx] + 2 * means[by * bw + bx - 1] + means[(by - 1) * bw + bx - 1]) / 4
					if lo < around { mean = around }
				}
			}
			means[by * bw + bx] = mean
		}
	}
	dark := make([]bool, img.width * img.height, context.temp_allocator)
	for by in 0 ..< bh {
		for bx in 0 ..< bw {
			sum, n := 0, 0
			for ny in max(by - 2, 0) ..= min(by + 2, bh - 1) {
				for nx in max(bx - 2, 0) ..= min(bx + 2, bw - 1) {
					sum += means[ny * bw + nx]
					n += 1
				}
			}
			t := sum / n
			for y in by * BLOCK ..< min((by + 1) * BLOCK, img.height) {
				for x in bx * BLOCK ..< min((bx + 1) * BLOCK, img.width) {
					dark[y * img.width + x] = int(img.pixels[y * img.stride + x]) <= t
				}
			}
		}
	}
	return dark
}

////////////////////////////////
// Finder patterns

@(private = "file")
Finder :: struct {
	x, y:   f32,   // its centre, in pixels
	module: f32,   // its module, in pixels
	count:  int,   // the rows it was seen on
}

// Runs in the ratios 1:1:3:1:1, each within half a module.
@(private = "file")
finder_ratio :: proc(c: [5]int) -> bool {
	total := c[0] + c[1] + c[2] + c[3] + c[4]
	if total < 7 || c[0] == 0 || c[1] == 0 || c[2] == 0 || c[3] == 0 || c[4] == 0 { return false }
	m := f32(total) / 7
	tol := m / 2
	return abs(m - f32(c[0])) < tol && abs(m - f32(c[1])) < tol && abs(3 * m - f32(c[2])) < 3 * tol &&
		abs(m - f32(c[3])) < tol && abs(m - f32(c[4])) < tol
}

@(private = "file")
find_finders :: proc(b: ^Binary) -> []Finder {
	found := make([dynamic]Finder, context.temp_allocator)
	for y in 0 ..< b.height {
		c: [5]int
		state := 0
		for x in 0 ..= b.width {
			if x < b.width && is_dark(b, x, y) {
				if state & 1 == 1 { state += 1 }
				c[state] += 1
				continue
			}
			// a light pixel (or the end of the row)
			if state & 1 == 1 { c[state] += 1; continue }
			if state < 4 {
				if c[state] > 0 { state += 1; c[state] += 1 }   // (no dark yet: the row's light start is skipped)
				continue
			}
			if finder_ratio(c) { finder_check(b, c, x, y, &found) }
			// the last two runs may start the next pattern
			c = {c[2], c[3], c[4], 1, 0}
			state = 3
		}
	}
	return found[:]
}

// A pattern seen on row `y`, ending before `end`: checked down its column, then along its row through its centre;
// merged with the one already seen there, or added.
@(private = "file")
finder_check :: proc(b: ^Binary, c: [5]int, end, y: int, found: ^[dynamic]Finder) {
	total := c[0] + c[1] + c[2] + c[3] + c[4]
	cx := f32(end - c[4] - c[3]) - f32(c[2]) / 2
	cy, vtotal, ok := cross_check(b, int(cx), y, false, total)
	if !ok { return }
	hx, htotal, ok2 := cross_check(b, int(cx), int(cy), true, total)
	if !ok2 { return }
	module := f32(htotal + vtotal) / 14
	for &f in found {
		if abs(f.x - hx) > f.module || abs(f.y - cy) > f.module || abs(f.module - module) > max(f.module, 1) / 2 { continue }
		n := f32(f.count)
		f.x = (f.x * n + hx) / (n + 1)
		f.y = (f.y * n + cy) / (n + 1)
		f.module = (f.module * n + module) / (n + 1)
		f.count += 1
		return
	}
	append(found, Finder{x = hx, y = cy, module = module, count = 1})
}

// The five runs through (x, y) along a row (`horizontal`) or a column: the centre of the middle one, and the
// pattern's length, which must be near `expect`.
@(private = "file")
cross_check :: proc(b: ^Binary, x, y: int, horizontal: bool, expect: int) -> (center: f32, total: int, ok: bool) {
	at :: proc(b: ^Binary, x, y, d: int, horizontal: bool) -> bool {
		return horizontal ? is_dark(b, x + d, y) : is_dark(b, x, y + d)
	}
	if !at(b, x, y, 0, horizontal) { return }
	c: [5]int
	// back from the centre: the middle run, the light, the outer dark
	d := 0
	for at(b, x, y, d, horizontal) && c[2] <= expect { c[2] += 1; d -= 1 }
	start := d + 1
	for !at(b, x, y, d, horizontal) && c[1] <= expect && in_picture(b, x, y, d, horizontal) { c[1] += 1; d -= 1 }
	for at(b, x, y, d, horizontal) && c[0] <= expect { c[0] += 1; d -= 1 }
	// forward
	d = 1
	for at(b, x, y, d, horizontal) && c[2] <= expect { c[2] += 1; d += 1 }
	stop := d
	for !at(b, x, y, d, horizontal) && c[3] <= expect && in_picture(b, x, y, d, horizontal) { c[3] += 1; d += 1 }
	for at(b, x, y, d, horizontal) && c[4] <= expect { c[4] += 1; d += 1 }
	total = c[0] + c[1] + c[2] + c[3] + c[4]
	if !finder_ratio(c) || 5 * abs(total - expect) >= 2 * expect { return 0, 0, false }
	// (pixel i covers [i, i + 1): the run covers [start, stop) from the pixel checked)
	return f32(horizontal ? x : y) + f32(start + stop) / 2, total, true
}

@(private = "file")
in_picture :: proc(b: ^Binary, x, y, d: int, horizontal: bool) -> bool {
	return horizontal ? x + d >= 0 && x + d < b.width : y + d >= 0 && y + d < b.height
}

////////////////////////////////
// The symbol

@(private = "file")
Triple :: struct {
	top_left, top_right, bottom_left: Finder,
	score:                            f32,   // how far from a right isosceles triangle of like patterns: 0 is perfect
}

@(private = "file")
decode_binary :: proc(b: ^Binary, allocator: runtime.Allocator) -> (result: Decoded, err: Decode_Error) {
	finders := find_finders(b)
	if len(finders) < 3 { return {}, .Not_Found }
	// the patterns seen on several rows first (a stray 1:1:3:1:1 run is seen on one)
	slice.sort_by(finders, proc(a, b: Finder) -> bool { return a.count > b.count })
	n := min(len(finders), MAX_FINDERS)
	triples := make([dynamic]Triple, context.temp_allocator)
	for i in 0 ..< n {
		for j in i + 1 ..< n {
			for k in j + 1 ..< n {
				if t, ok := triple_of(finders[i], finders[j], finders[k]); ok { append(&triples, t) }
			}
		}
	}
	if len(triples) == 0 { return {}, .Not_Found }
	slice.sort_by(triples[:], proc(a, b: Triple) -> bool { return a.score < b.score })
	err = .Not_Found
	for t in triples[:min(len(triples), MAX_TRIPLES)] {
		d, e := decode_triple(b, t, allocator)
		if e == .None { return d, .None }
		if err == .Not_Found || e != .Bad_Format { err = e }
	}
	return {}, err
}

// Three patterns as the corners of a symbol: the one at the right angle is the top left; the turn from it says which
// of the others is the top right (the symbol may be turned, not mirrored).
@(private = "file")
triple_of :: proc(a, b, c: Finder) -> (t: Triple, ok: bool) {
	dist :: proc(p, q: Finder) -> f32 { return math.hypot(p.x - q.x, p.y - q.y) }
	p := [3]Finder{a, b, c}
	// the corner is the one opposite the longest side
	sides := [3]f32{dist(b, c), dist(a, c), dist(a, b)}
	corner := 0
	for i in 1 ..< 3 { if sides[i] > sides[corner] { corner = i } }
	tl, s1, s2 := p[corner], p[(corner + 1) % 3], p[(corner + 2) % 3]
	l1, l2 := dist(tl, s1), dist(tl, s2)
	hyp := sides[corner]
	modules := [3]f32{a.module, b.module, c.module}
	lo, hi := slice.min(modules[:]), slice.max(modules[:])
	if lo <= 0 || hi > lo * 1.5 { return }
	legs := abs(l1 - l2) / max(l1, l2)
	angle := abs(hyp - math.sqrt(l1 * l1 + l2 * l2)) / hyp
	if legs > 0.2 || angle > 0.1 || min(l1, l2) < 14 * lo { return }   // (two finders are 14 modules apart at least)
	cross := (s1.x - tl.x) * (s2.y - tl.y) - (s1.y - tl.y) * (s2.x - tl.x)
	if cross > 0 { t.top_right, t.bottom_left = s1, s2 } else { t.top_right, t.bottom_left = s2, s1 }
	t.top_left = tl
	t.score = legs + angle + (hi - lo) / lo
	return t, true
}

// The symbol the three patterns frame, at the size their distance says, else at the sizes next to it; past version 6
// the version information it holds says its size.
@(private = "file")
decode_triple :: proc(b: ^Binary, t: Triple, allocator: runtime.Allocator) -> (result: Decoded, err: Decode_Error) {
	module := (t.top_left.module + t.top_right.module + t.bottom_left.module) / 3
	across := (math.hypot(t.top_right.x - t.top_left.x, t.top_right.y - t.top_left.y) +
		math.hypot(t.bottom_left.x - t.top_left.x, t.bottom_left.y - t.top_left.y)) / 2
	guess := int(math.round(across / module)) + 7
	// the nearest 4k + 1, then its neighbours
	guess = (guess - 17 + 2) / 4 * 4 + 17
	sizes := make([dynamic]int, 0, 4, context.temp_allocator)
	if guess >= 45 {
		// (past version 6 the version information is the better ruler, when it reads)
		if v := read_version(sample(b, t, guess), guess); v != 0 && v * 4 + 17 != guess { append(&sizes, v * 4 + 17) }
	}
	append(&sizes, guess, guess + 4, guess - 4)
	err = .Not_Found
	for size in sizes {
		if size < 21 || size > 177 { continue }
		d, e := decode_modules(sample(b, t, size), size, allocator)
		if e == .None { return d, .None }
		if err == .Not_Found || e != .Bad_Format { err = e }
	}
	return {}, err
}

// The modules of a `size` symbol at their centres, through the map that puts the finders' centres (module 3.5 from
// the corners) on the three patterns.
@(private = "file")
sample :: proc(b: ^Binary, t: Triple, size: int) -> []bool {
	span := f32(size - 7)
	ux, uy := (t.top_right.x - t.top_left.x) / span, (t.top_right.y - t.top_left.y) / span
	vx, vy := (t.bottom_left.x - t.top_left.x) / span, (t.bottom_left.y - t.top_left.y) / span
	modules := make([]bool, size * size, context.temp_allocator)
	for my in 0 ..< size {
		for mx in 0 ..< size {
			fx, fy := f32(mx) - 3, f32(my) - 3   // (a module's centre is mx + 0.5; the finder's is 3.5)
			px := t.top_left.x + fx * ux + fy * vx
			py := t.top_left.y + fx * uy + fy * vy
			modules[my * size + mx] = is_dark(b, int(math.floor(px)), int(math.floor(py)))
		}
	}
	return modules
}
