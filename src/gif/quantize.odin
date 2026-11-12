// A frame's colours to palette indices: the exact colours when there are few enough, else a median cut (Heckbert, "Color
// Image Quantization for Frame Buffer Display", 1982) on a 5-5-5 histogram, or the fixed table; then each colour to its
// nearest entry, through a cache by 5-6-5 colour.
package gif

import "base:runtime"
import "core:mem"

// A pixel of the changed rectangle that equals the last frame's: the transparent index. (A colour is 0x00RRGGBB.)
@(private) UNCHANGED :: u32(0xFF000000)

@(private)
Palette :: struct {
	rgb:         [256][3]u8,
	count:       int,   // entries used, the transparent one included
	transparent: int,   // its index, -1: none
}

@(private)
Quantize_State :: struct {
	mode:      Quantizer,
	palette:   Palette,      // the frame's
	fixed:     Palette,      // Fixed's table
	counts:    []u32,        // Median_Cut: pixels by 5-5-5 colour (zero between frames: only the cells used are reset)
	sums:      [][3]u64,     // ... and the sum of their 8-bit channels
	cells:     []u16,        // the 5-5-5 colours present, cut into boxes
	sorted:    []u16,        // (the counting sort's other half)
	nearest:   []u16,        // by 5-6-5 colour: its palette index, NO_INDEX unknown
	allocator: runtime.Allocator,
}

@(private = "file") CELLS :: 1 << 15         // 5-5-5
@(private = "file") NEAREST_KEYS :: 1 << 16  // 5-6-5
@(private = "file") NO_INDEX :: 0xFFFF
@(private = "file") EXACT_SLOTS :: 1024      // a hash of at most 256 colours: a quarter full
@(private = "file") OCCUPIED :: u32(1 << 24)
// Channel weights of the distance and of the box to cut: the eye tells greens apart best, blues least.
@(private = "file") WEIGHT_R :: 3
@(private = "file") WEIGHT_G :: 4
@(private = "file") WEIGHT_B :: 2
// How far ordered dithering moves a channel, in 8-bit steps, at most about half of it each way.
@(private = "file") SPREAD_FIXED :: 48       // (the fixed table's steps are 42 to 51)
@(private = "file") SPREAD_MEDIAN_CUT :: 24
@(private = "file") BAYER :: [16]u8{0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5}
@(private = "file") FIXED_GREYS :: [3]u8{64, 128, 192}

@(private)
quantize_init :: proc(q: ^Quantize_State, mode: Quantizer, allocator: runtime.Allocator) {
	q.mode, q.allocator = mode, allocator
	q.nearest = make([]u16, NEAREST_KEYS, allocator)
	mem.set(raw_data(q.nearest), 0xFF, len(q.nearest) * size_of(u16))
	switch mode {
	case .Median_Cut:
		q.counts = make([]u32, CELLS, allocator)
		q.sums = make([][3]u64, CELLS, allocator)
		q.cells = make([]u16, CELLS, allocator)
		q.sorted = make([]u16, CELLS, allocator)
	case .Fixed:
		f := &q.fixed
		for r in 0 ..< 6 {
			for g in 0 ..< 7 {
				for b in 0 ..< 6 { f.rgb[r * 42 + g * 6 + b] = {u8(r * 255 / 5), u8(g * 255 / 6), u8(b * 255 / 5)} }
			}
		}
		greys := FIXED_GREYS
		for v, i in greys { f.rgb[252 + i] = {v, v, v} }
		f.count, f.transparent = 256, 255   // (index 255 is never a colour, even in a frame with no transparency)
	}
}

@(private)
quantize_destroy :: proc(q: ^Quantize_State) {
	context.allocator = q.allocator
	delete(q.nearest)
	delete(q.counts)
	delete(q.sums)
	delete(q.cells)
	delete(q.sorted)
}

// The frame's palette and each pixel's index. `r` places the pixels on the screen (the dither pattern stays put from
// frame to frame).
@(private)
map_colors :: proc(q: ^Quantize_State, px: []u32, r: Rect, has_unchanged, dither: bool, palette: ^Palette, indices: []u8) {
	switch q.mode {
	case .Fixed:
		palette^ = q.fixed
		palette.transparent = has_unchanged ? 255 : -1
		map_nearest(q, palette, px, r, dither ? SPREAD_FIXED : 0, indices)   // (the cache stays: the table does)
	case .Median_Cut:
		if exact(px, has_unchanged, palette, indices) { return }
		median_cut(q, px, has_unchanged, palette)
		mem.set(raw_data(q.nearest), 0xFF, len(q.nearest) * size_of(u16))
		map_nearest(q, palette, px, r, dither ? SPREAD_MEDIAN_CUT : 0, indices)
	}
}

// Every colour its own entry, in the order met; false when there are more than fit (256, the transparent one included).
@(private = "file")
exact :: proc(px: []u32, has_unchanged: bool, palette: ^Palette, indices: []u8) -> bool #no_bounds_check {
	keys: [EXACT_SLOTS]u32
	slots: [EXACT_SLOTS]u8
	n := 0
	if has_unchanged {
		palette.rgb[0] = {}
		n = 1
	}
	last, last_index := ~u32(0), u8(0)   // (screen content comes in runs: the hash is skipped along one)
	for p, i in px {
		if p != last {
			last = p
			if p == UNCHANGED {
				last_index = 0
			} else {
				key := p | OCCUPIED
				h := (p * 0x9E3779B1) >> (32 - 10)   // (Fibonacci hashing to EXACT_SLOTS)
				for {
					if keys[h] == key { last_index = slots[h]; break }
					if keys[h] == 0 {
						if n == 256 { return false }
						keys[h], slots[h] = key, u8(n)
						palette.rgb[n] = {u8(p >> 16), u8(p >> 8), u8(p)}
						last_index = u8(n)
						n += 1
						break
					}
					h = (h + 1) & (EXACT_SLOTS - 1)
				}
			}
		}
		indices[i] = last_index
	}
	palette.count = n
	palette.transparent = has_unchanged ? 0 : -1
	return true
}

@(private = "file")
Box :: struct {
	lo, hi:  int,   // its cells, in q.cells
	channel: int,   // the one to cut: 0 red, 1 green, 2 blue
	score:   u64,   // pixels x weighted extent along it: the box cut first; 0: a single cell
}

@(private = "file")
channel_of :: #force_inline proc "contextless" (cell: u16, c: int) -> int { return int(cell >> uint(10 - 5 * c)) & 31 }

@(private = "file")
measure :: proc(q: ^Quantize_State, lo, hi: int) -> Box #no_bounds_check {
	low, high := [3]int{31, 31, 31}, [3]int{0, 0, 0}
	pixels: u64
	for cell in q.cells[lo:hi] {
		for c in 0 ..< 3 {
			v := channel_of(cell, c)
			low[c], high[c] = min(low[c], v), max(high[c], v)
		}
		pixels += u64(q.counts[cell])
	}
	weights := [3]int{WEIGHT_R, WEIGHT_G, WEIGHT_B}
	b := Box{lo = lo, hi = hi}
	best := -1
	for c in 0 ..< 3 {
		if extent := (high[c] - low[c]) * weights[c]; extent > best { best, b.channel = extent, c }
	}
	if hi - lo > 1 { b.score = pixels * u64(best) }
	return b
}

// Cuts the cells into `256 - first` boxes at most, each time the box of the highest score across its widest channel at
// the median pixel; each box's entry is the mean of its pixels.
@(private = "file")
median_cut :: proc(q: ^Quantize_State, px: []u32, has_unchanged: bool, palette: ^Palette) #no_bounds_check {
	n := 0
	for p in px {
		if p == UNCHANGED { continue }
		cell := (p >> 9) & 0x7C00 | (p >> 6) & 0x03E0 | (p >> 3) & 0x001F
		if q.counts[cell] == 0 {
			q.cells[n] = u16(cell)
			n += 1
		}
		q.counts[cell] += 1
		s := &q.sums[cell]
		s[0] += u64(p >> 16 & 0xFF)
		s[1] += u64(p >> 8 & 0xFF)
		s[2] += u64(p & 0xFF)
	}
	first := has_unchanged ? 1 : 0
	boxes: [256]Box
	count := 1
	boxes[0] = measure(q, 0, n)
	for count < 256 - first {
		best := -1
		for i in 0 ..< count {
			if boxes[i].score > 0 && (best < 0 || boxes[i].score > boxes[best].score) { best = i }
		}
		if best < 0 { break }
		b := boxes[best]
		mid := cut(q, b)
		boxes[best] = measure(q, b.lo, mid)
		boxes[count] = measure(q, mid, b.hi)
		count += 1
	}
	palette.rgb[0] = {}
	for b, i in boxes[:count] {
		sum: [3]u64
		pixels: u64
		for cell in q.cells[b.lo:b.hi] {
			sum += q.sums[cell]
			pixels += u64(q.counts[cell])
		}
		palette.rgb[first + i] = {u8((sum[0] + pixels / 2) / pixels), u8((sum[1] + pixels / 2) / pixels), u8((sum[2] + pixels / 2) / pixels)}
	}
	palette.count = first + count
	palette.transparent = has_unchanged ? 0 : -1
	for cell in q.cells[:n] {
		q.counts[cell] = 0
		q.sums[cell] = {}
	}
}

// Sorts the box's cells along its channel (a counting sort: 32 values) and returns where half of its pixels are below.
@(private = "file")
cut :: proc(q: ^Quantize_State, b: Box) -> int #no_bounds_check {
	starts: [33]int
	for cell in q.cells[b.lo:b.hi] { starts[channel_of(cell, b.channel) + 1] += 1 }
	for v in 1 ..= 32 { starts[v] += starts[v - 1] }
	for cell in q.cells[b.lo:b.hi] {
		v := channel_of(cell, b.channel)
		q.sorted[b.lo + starts[v]] = cell
		starts[v] += 1
	}
	copy(q.cells[b.lo:b.hi], q.sorted[b.lo:b.hi])
	total: u64
	for cell in q.cells[b.lo:b.hi] { total += u64(q.counts[cell]) }
	below: u64
	for i in b.lo ..< b.hi - 1 {
		below += u64(q.counts[q.cells[i]])
		if below * 2 >= total { return i + 1 }
	}
	return b.hi - 1
}

// Each pixel to its palette's nearest entry (not the transparent one), the colour first moved by the dither pattern
// when `spread` > 0.
@(private = "file")
map_nearest :: proc(q: ^Quantize_State, palette: ^Palette, px: []u32, r: Rect, spread: int, indices: []u8) #no_bounds_check {
	bayer := BAYER
	last, last_index := ~u32(0), u8(0)
	k := 0
	for y in 0 ..< r.h {
		for x in 0 ..< r.w {
			p := px[k]
			switch {
			case p == UNCHANGED:
				indices[k] = u8(palette.transparent)
			case spread == 0 && p == last:
				indices[k] = last_index
			case:
				red, green, blue := int(p >> 16 & 0xFF), int(p >> 8 & 0xFF), int(p & 0xFF)
				if spread > 0 {
					off := (int(bayer[((r.y + y) & 3) * 4 + ((r.x + x) & 3)]) * 2 - 15) * spread / 32
					red, green, blue = clamp(red + off, 0, 255), clamp(green + off, 0, 255), clamp(blue + off, 0, 255)
				}
				key := (red >> 3) << 11 | (green >> 2) << 5 | blue >> 3
				v := q.nearest[key]
				if v == NO_INDEX {
					// (the middle of the 5-6-5 cell: the cached answer does not depend on which pixel came first)
					v = u16(nearest(palette, red & 0xF8 | 4, green & 0xFC | 2, blue & 0xF8 | 4))
					q.nearest[key] = v
				}
				indices[k] = u8(v)
				last, last_index = p, u8(v)
			}
			k += 1
		}
	}
}

@(private = "file")
nearest :: proc "contextless" (palette: ^Palette, red, green, blue: int) -> int #no_bounds_check {
	best, best_distance := 0, max(int)
	for c, i in palette.rgb[:palette.count] {
		if i == palette.transparent { continue }
		dr, dg, db := int(c[0]) - red, int(c[1]) - green, int(c[2]) - blue
		if d := WEIGHT_R * dr * dr + WEIGHT_G * dg * dg + WEIGHT_B * db * db; d < best_distance { best, best_distance = i, d }
	}
	return best
}
