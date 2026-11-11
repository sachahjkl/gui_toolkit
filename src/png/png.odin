// The toolkit's PNG codec: straight RGBA8 rows to a PNG file and back. Encoding uses the toolkit's flate; decoding uses
// core:image/png (every colour type, bit depth, palette and transparency). Pure Odin, any target. See docs/png.md.
package tk_png

import "base:intrinsics"
import "base:runtime"
import "core:encoding/endian"
import "core:hash"
import "core:image"
import core_png "core:image/png"
import "core:simd"
import "../flate"

// How encode spends its time.
Compression :: enum u8 {
	Small,   // each row takes the filter whose bytes add up least as signed values, then flate.deflate: a file to keep
	Fast,    // every row filtered with Sub, then flate.deflate_runs: a picture taken while a program runs
}

// What a PNG holds besides the compressed rows.
@(private) SIGNATURE :: [8]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
@(private = "file") CONTAINER_BYTES :: 64   // the signature, IHDR and the chunks' lengths and CRCs: reserved at once
@(private) IHDR_BYTES :: 13
@(private = "file") BIT_DEPTH :: 8
@(private = "file") COLOR_RGBA :: 6
@(private) FILTERS :: 5            // None, Sub, Up, Average, Paeth
@(private = "file") FILTER_SUB :: 1
@(private) RGBA :: 4               // bytes of a pixel

// `width` x `height` straight RGBA8 pixels, rows from the top, as a PNG file (8 bits, colour type 6). nil when the size is
// empty or `rgba` is shorter than the size says.
encode :: proc(rgba: []u8, width, height: int, compression := Compression.Small, allocator := context.allocator) -> []u8 {
	if width <= 0 || height <= 0 || len(rgba) < width * height * RGBA { return nil }
	stride := width * RGBA
	z: []u8
	switch compression {
	case .Small: z = flate.deflate(.Zlib, filter_least_sum(rgba, width, height), context.temp_allocator)
	case .Fast:  z = flate.deflate_runs(.Zlib, filter_sub(rgba, width, height), stride + 1, context.temp_allocator)
	}
	buf := make([dynamic]u8, 0, len(z) + CONTAINER_BYTES, allocator)
	signature := SIGNATURE
	append(&buf, ..signature[:])
	ihdr: [IHDR_BYTES]u8
	endian.put_u32(ihdr[0:], .Big, u32(width))
	endian.put_u32(ihdr[4:], .Big, u32(height))
	ihdr[8], ihdr[9] = BIT_DEPTH, COLOR_RGBA
	chunk(&buf, "IHDR", ihdr[:])
	chunk(&buf, "IDAT", z)
	chunk(&buf, "IEND", nil)
	return buf[:]
}

// A PNG file as straight RGBA8 pixels, rows from the top: any colour type (grey, RGB, a palette, with or without alpha
// or tRNS), any bit depth (16 bits rounded to 8). ok is false for anything that is not a whole, valid PNG.
decode :: proc(data: []u8, allocator := context.allocator) -> (rgba: []u8, width, height: int, ok: bool) {
	// (the heap, freed here: a screenshot is tens of MB, and a caller's context allocator may be an arena)
	heap := runtime.heap_allocator()
	img, err := core_png.load_from_bytes(data, {.alpha_add_if_missing}, heap)
	defer image.destroy(img, heap)   // (what it made before a failure too)
	if err != nil || img == nil { return }
	return rgba8_of(img, allocator)
}

// Any picture core:image read (PNG, JPEG, BMP...: 1 to 4 channels, 8 or 16 bits, straight alpha) as straight RGBA8.
rgba8_of :: proc(img: ^image.Image, allocator := context.allocator) -> (rgba: []u8, width, height: int, ok: bool) #no_bounds_check {
	if img == nil || img.width <= 0 || img.height <= 0 || img.channels < 1 || img.channels > 4 { return }
	if img.depth != 8 && img.depth != 16 { return }
	n := img.width * img.height
	ch := img.channels
	if len(img.pixels) < n * ch * img.depth / 8 { return }
	rgba = make([]u8, n * RGBA, allocator)
	if ch == RGBA && img.depth == 8 {   // (what it is already)
		copy(rgba, img.pixels[:n * RGBA])
		return rgba, img.width, img.height, true
	}
	for i in 0 ..< n {
		s: [4]u8
		for c in 0 ..< ch {
			if img.depth == 8 {
				s[c] = img.pixels[i * ch + c]
			} else {
				v := (cast([^]u16)raw_data(img.pixels))[i * ch + c]   // (native order: core:image/png swaps them)
				s[c] = u8((u32(v) * 255 + 32767) / 65535)
			}
		}
		o := rgba[i * RGBA:][:RGBA]
		switch ch {
		case 1: o[0], o[1], o[2], o[3] = s[0], s[0], s[0], 255
		case 2: o[0], o[1], o[2], o[3] = s[0], s[0], s[0], s[1]
		case 3: o[0], o[1], o[2], o[3] = s[0], s[1], s[2], 255
		case 4: o[0], o[1], o[2], o[3] = s[0], s[1], s[2], s[3]
		}
	}
	return rgba, img.width, img.height, true
}

// The rows, each after its filter byte, every one filtered with Sub (neighbouring pixels of an interface are often
// equal: runs of zeros that deflate_runs packs fast).
@(private = "file")
filter_sub :: proc(rgba: []u8, width, height: int) -> []u8 #no_bounds_check {
	stride := width * RGBA
	raw := make([]u8, (stride + 1) * height, context.temp_allocator)
	for y in 0 ..< height {
		out := raw[y * (stride + 1):]
		out[0] = FILTER_SUB
		filter_row(FILTER_SUB, raw_data(rgba[y * stride:]), nil, raw_data(out[1:]), stride)
	}
	return raw
}

// The rows, each after its filter byte, each with the filter whose bytes add up least as signed values (the usual guess
// at what compresses best; of two filters with the same sum, the first).
@(private = "file")
filter_least_sum :: proc(rgba: []u8, width, height: int) -> []u8 #no_bounds_check {
	stride := width * RGBA
	raw := make([]u8, (stride + 1) * height, context.temp_allocator)
	zero := make([]u8, stride, context.temp_allocator)
	for y in 0 ..< height {
		row := raw_data(rgba[y * stride:])
		up := raw_data(y > 0 ? rgba[(y - 1) * stride:] : zero)
		out := raw[y * (stride + 1):]
		sums := filter_sums(row, up, stride)
		best := 0
		for f in 1 ..< FILTERS { if sums[f] < sums[best] { best = f } }
		out[0] = u8(best)
		filter_row(best, row, up, raw_data(out[1:]), stride)
	}
	return raw
}

// The bytes a row is filtered by at once: one SSE or NEON register, 4 pixels.
@(private) LANES :: 16
@(private) Bytes :: #simd[LANES]u8

@(private = "file")
load :: #force_inline proc "contextless" (p: [^]u8, at: int) -> Bytes { return intrinsics.unaligned_load((^Bytes)(&p[at])) }

// A byte through filter `f`: `a` the byte a pixel before it, `b` the byte above, `c` the byte above `a`.
@(private)
filter_byte :: #force_inline proc "contextless" (f: int, v, a, b, c: u8) -> u8 {
	switch f {
	case 1: return v - a
	case 2: return v - b
	case 3: return v - u8((int(a) + int(b)) / 2)
	case 4: return v - paeth(a, b, c)
	}
	return v
}

// filter_byte, LANES bytes at once.
@(private = "file")
filter_bytes :: #force_inline proc "contextless" (f: int, v, a, b, c: Bytes) -> Bytes {
	switch f {
	case 1: return v - a
	case 2: return v - b
	case 3: return v - ((a & b) + simd.shr(a ~ b, Bytes(1)))   // (the half of a sum that does not fit a byte)
	case 4: return v - paeth_bytes(a, b, c)
	}
	return v
}

// How far a filtered byte is from 0, as a signed value: 0x80 is 128 from it.
@(private)
magnitude :: #force_inline proc "contextless" (v: u8) -> int { return int(min(v, -v)) }

// The sum of the magnitudes of LANES filtered bytes.
@(private = "file")
magnitudes :: #force_inline proc "contextless" (v: Bytes) -> int {
	return int(simd.reduce_add_ordered(cast(#simd[LANES]u16)simd.min(v, -v)))
}

// What each filter makes of a row, as the sum of its bytes' magnitudes. `up`: the row above (zeros above the first).
@(private)
filter_sums :: proc "contextless" (row, up: [^]u8, stride: int) -> (sums: [FILTERS]int) #no_bounds_check {
	x := 0
	for ; x < min(RGBA, stride); x += 1 {
		for f in 0 ..< FILTERS { sums[f] += magnitude(filter_byte(f, row[x], 0, up[x], 0)) }
	}
	for ; x + LANES <= stride; x += LANES {
		v, a, b, c := load(row, x), load(row, x - RGBA), load(up, x), load(up, x - RGBA)
		#unroll for f in 0 ..< FILTERS { sums[f] += magnitudes(filter_bytes(f, v, a, b, c)) }
	}
	for ; x < stride; x += 1 {
		for f in 0 ..< FILTERS { sums[f] += magnitude(filter_byte(f, row[x], row[x - RGBA], up[x], up[x - RGBA])) }
	}
	return
}

// A row through filter `f`, into `out`. `up` is read by the filters that use the row above only.
@(private)
filter_row :: proc "contextless" (f: int, row, up, out: [^]u8, stride: int) #no_bounds_check {
	one :: #force_inline proc "contextless" ($F: int, row, up, out: [^]u8, stride: int) #no_bounds_check {
		ABOVE :: F >= 2
		x := 0
		for ; x < min(RGBA, stride); x += 1 { out[x] = filter_byte(F, row[x], 0, ABOVE ? up[x] : 0, 0) }
		for ; x + LANES <= stride; x += LANES {
			b, c: Bytes
			when ABOVE { b, c = load(up, x), load(up, x - RGBA) }
			intrinsics.unaligned_store((^Bytes)(&out[x]), filter_bytes(F, load(row, x), load(row, x - RGBA), b, c))
		}
		for ; x < stride; x += 1 {
			out[x] = filter_byte(F, row[x], row[x - RGBA], ABOVE ? up[x] : 0, ABOVE ? up[x - RGBA] : 0)
		}
	}
	switch f {
	case 0: intrinsics.mem_copy_non_overlapping(out, row, stride)
	case 1: one(1, row, up, out, stride)
	case 2: one(2, row, up, out, stride)
	case 3: one(3, row, up, out, stride)
	case 4: one(4, row, up, out, stride)
	}
}

// Of a, b and c, the nearest to a + b - c; of two as near, the first.
@(private)
paeth :: proc "contextless" (a, b, c: u8) -> u8 {
	p := int(a) + int(b) - int(c)
	pa, pb, pc := abs(p - int(a)), abs(p - int(b)), abs(p - int(c))
	if pa <= pb && pa <= pc { return a }
	if pb <= pc { return b }
	return c
}

// paeth, LANES bytes at once, in bytes: the distances pa = |b - c| and pb = |a - c| fit one; pc = |(a - c) + (b - c)| is
// their difference when a and b lie on two sides of c, else their sum, which is compared right when it stops at 255.
@(private)
paeth_bytes :: #force_inline proc "contextless" (a, b, c: Bytes) -> Bytes {
	pa := simd.max(b, c) - simd.min(b, c)
	pb := simd.max(a, c) - simd.min(a, c)
	two_sides := simd.lanes_lt(a, c) ~ simd.lanes_lt(b, c)
	pc := simd.select(two_sides, simd.max(pa, pb) - simd.min(pa, pb), simd.saturating_add(pa, pb))
	take_a := simd.lanes_le(pa, pb) & simd.lanes_le(pa, pc)
	return simd.select(take_a, a, simd.select(simd.lanes_le(pb, pc), b, c))
}

@(private)
chunk :: proc(buf: ^[dynamic]u8, kind: string, data: []u8) {
	n: [4]u8
	endian.put_u32(n[:], .Big, u32(len(data)))
	append(buf, ..n[:])
	start := len(buf)
	append(buf, kind)
	append(buf, ..data)
	endian.put_u32(n[:], .Big, hash.crc32(buf[start:]))
	append(buf, ..n[:])
}
