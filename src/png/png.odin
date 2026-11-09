// The toolkit's PNG codec: straight RGBA8 rows to a PNG file and back. Encoding uses the toolkit's flate; decoding uses
// core:image/png (every colour type, bit depth, palette and transparency). Pure Odin, any target. See docs/png.md.
package tk_png

import "base:runtime"
import "core:encoding/endian"
import "core:hash"
import "core:image"
import core_png "core:image/png"
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
@(private = "file") FILTERS :: 5            // None, Sub, Up, Average, Paeth
@(private = "file") FILTER_SUB :: 1
@(private = "file") RGBA :: 4               // bytes of a pixel

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
		row := rgba[y * stride:][:stride]
		out := raw[y * (stride + 1):][:stride + 1]
		out[0] = FILTER_SUB
		for x in 0 ..< stride { out[1 + x] = row[x] - (x >= RGBA ? row[x - RGBA] : 0) }
	}
	return raw
}

// The rows, each after its filter byte, each with the filter whose bytes add up least as signed values (the usual guess
// at what compresses best).
@(private = "file")
filter_least_sum :: proc(rgba: []u8, width, height: int) -> []u8 {
	stride := width * RGBA
	raw := make([]u8, (stride + 1) * height, context.temp_allocator)
	trial := make([]u8, stride, context.temp_allocator)
	zero := make([]u8, stride, context.temp_allocator)
	for y in 0 ..< height {
		row := rgba[y * stride:][:stride]
		up := y > 0 ? rgba[(y - 1) * stride:][:stride] : zero
		out := raw[y * (stride + 1):][:stride + 1]
		best := max(int)
		for f in 0 ..< FILTERS {
			score := 0
			for x in 0 ..< stride {
				a := x >= RGBA ? row[x - RGBA] : 0
				b := up[x]
				c := x >= RGBA ? up[x - RGBA] : 0
				v: u8
				switch f {
				case 0: v = row[x]
				case 1: v = row[x] - a
				case 2: v = row[x] - b
				case 3: v = row[x] - u8((int(a) + int(b)) / 2)
				case 4: v = row[x] - paeth(a, b, c)
				}
				trial[x] = v
				score += int(abs(i8(v)))
			}
			if score < best {
				best = score
				out[0] = u8(f)
				copy(out[1:], trial)
			}
		}
	}
	return raw
}

@(private = "file")
paeth :: proc(a, b, c: u8) -> u8 {
	p := int(a) + int(b) - int(c)
	pa, pb, pc := abs(p - int(a)), abs(p - int(b)), abs(p - int(c))
	if pa <= pb && pa <= pc { return a }
	if pb <= pc { return b }
	return c
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
