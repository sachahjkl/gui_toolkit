package tk_image

// A JPEG file of a picture: baseline, 8-bit, the colours not subsampled (4:4:4: the text of a screenshot keeps its edges
// sharp), the standard tables of the specification scaled by the quality, as libjpeg does. After stb_image_write's
// encoder (public domain, Jon Olick's jo_jpeg before it). Alpha is laid over white: JPEG has none.


// The file of `img` at `quality` (1 to 100: 90 is a good screenshot; 100 the least loss), in `allocator`. nil for a
// picture with no pixel.
jpeg_encode :: proc(img: Image, quality := 90, allocator := context.allocator) -> []u8 #no_bounds_check {
	if !valid(img) { return nil }
	w, h := img.width, img.height
	if w > 0xFFFF || h > 0xFFFF { return nil }   // (the frame header holds 16 bits a side)

	// the quantisation tables, in zigzag order, and the factors that take the DCT's scale out with them
	q := clamp(quality, 1, 100)
	scale := q < 50 ? 5000 / q : 200 - q * 2
	y_table, uv_table: [64]u8
	for i in 0 ..< 64 {
		y_table[ZIGZAG[i]] = u8(clamp((LUMA_QUANT[i] * scale + 50) / 100, 1, 255))
		uv_table[ZIGZAG[i]] = u8(clamp((CHROMA_QUANT[i] * scale + 50) / 100, 1, 255))
	}
	y_factor, uv_factor: [64]f32
	for row in 0 ..< 8 {
		for col in 0 ..< 8 {
			k := row * 8 + col
			y_factor[k] = 1 / (f32(y_table[ZIGZAG[k]]) * AAN_SCALE[row] * AAN_SCALE[col])
			uv_factor[k] = 1 / (f32(uv_table[ZIGZAG[k]]) * AAN_SCALE[row] * AAN_SCALE[col])
		}
	}
	y_dc, y_ac, uv_dc, uv_ac: Huffman
	huffman_make(&y_dc, LUMA_DC_BITS, LUMA_DC_VALUES[:])
	huffman_make(&y_ac, LUMA_AC_BITS, LUMA_AC_VALUES[:])
	huffman_make(&uv_dc, CHROMA_DC_BITS, CHROMA_DC_VALUES[:])
	huffman_make(&uv_ac, CHROMA_AC_BITS, CHROMA_AC_VALUES[:])

	out := make([dynamic]u8, 0, w * h / 4 + 1024, allocator)
	// SOI, APP0 (JFIF 1.1, no density), DQT (both tables)
	append(&out, 0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0)
	append(&out, 0xFF, 0xDB, 0, 132, 0)
	append(&out, ..y_table[:])
	append(&out, 1)
	append(&out, ..uv_table[:])
	// SOF0: 8 bits, the size, three components at 1x1 (Y on table 0, Cb and Cr on 1)
	append(&out, 0xFF, 0xC0, 0, 17, 8, u8(h >> 8), u8(h), u8(w >> 8), u8(w), 3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1)
	// DHT: the four standard tables
	append(&out, 0xFF, 0xC4, 0x01, 0xA2)
	dht :: proc(out: ^[dynamic]u8, class_id: u8, bits: [16]u8, values: []u8) {
		append(out, class_id)
		b := bits
		append(out, ..b[:])
		append(out, ..values)
	}
	dht(&out, 0x00, LUMA_DC_BITS, LUMA_DC_VALUES[:])
	dht(&out, 0x10, LUMA_AC_BITS, LUMA_AC_VALUES[:])
	dht(&out, 0x01, CHROMA_DC_BITS, CHROMA_DC_VALUES[:])
	dht(&out, 0x11, CHROMA_AC_BITS, CHROMA_AC_VALUES[:])
	// SOS: the three components, all of the spectrum
	append(&out, 0xFF, 0xDA, 0, 12, 3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0)

	bits := Bit_Writer{out = &out}
	y_block, u_block, v_block: [64]f32
	dc_y, dc_u, dc_v: i32
	for by := 0; by < h; by += 8 {
		for bx := 0; bx < w; bx += 8 {
			// the 8 x 8 block, its edge pixels repeated past the picture's edge
			for row in 0 ..< 8 {
				py := min(by + row, h - 1)
				for col in 0 ..< 8 {
					px := min(bx + col, w - 1)
					p := img.pixels[(py * w + px) * 4:][:4]
					a := f32(p[3]) / 255
					r := f32(p[0]) * a + 255 * (1 - a)
					g := f32(p[1]) * a + 255 * (1 - a)
					b := f32(p[2]) * a + 255 * (1 - a)
					k := row * 8 + col
					y_block[k] = 0.29900 * r + 0.58700 * g + 0.11400 * b - 128
					u_block[k] = -0.16874 * r - 0.33126 * g + 0.50000 * b
					v_block[k] = 0.50000 * r - 0.41869 * g - 0.08131 * b
				}
			}
			dc_y = block_encode(&bits, &y_block, &y_factor, dc_y, &y_dc, &y_ac)
			dc_u = block_encode(&bits, &u_block, &uv_factor, dc_u, &uv_dc, &uv_ac)
			dc_v = block_encode(&bits, &v_block, &uv_factor, dc_v, &uv_dc, &uv_ac)
		}
	}
	// the last byte filled with ones, then EOI
	bits_write(&bits, {0x7F, 7})
	append(&out, 0xFF, 0xD9)
	return out[:]
}

////////////////////////////////
// Inside

@(private = "file")
Code :: struct { bits: u16, length: u16 }   // a Huffman code, or a value's own bits, and how many

@(private = "file")
Huffman :: struct { codes: [256]Code }

// The codes of a table given as the specification gives it: how many codes of each length, then the values in order.
@(private = "file")
huffman_make :: proc(t: ^Huffman, counts: [16]u8, values: []u8) {
	code: u16
	at := 0
	for length in 1 ..= 16 {
		for _ in 0 ..< int(counts[length - 1]) {
			t.codes[values[at]] = {code, u16(length)}
			code += 1
			at += 1
		}
		code <<= 1
	}
}

@(private = "file")
Bit_Writer :: struct {
	out:   ^[dynamic]u8,
	buf:   u32,
	count: u32,
}

// Bits out, most significant first; a byte 0xFF is followed by a 0 (a marker otherwise).
@(private = "file")
bits_write :: proc(w: ^Bit_Writer, c: Code) {
	w.count += u32(c.length)
	w.buf |= u32(c.bits) << (24 - w.count)
	for w.count >= 8 {
		b := u8(w.buf >> 16)
		append(w.out, b)
		if b == 0xFF { append(w.out, 0) }
		w.buf <<= 8
		w.count -= 8
	}
}

// A coefficient as its category (how many bits) and those bits (a negative one, one's complement).
@(private = "file")
value_bits :: proc(v: i32) -> Code {
	magnitude := v < 0 ? -v : v
	length: u16 = 1
	for m := magnitude >> 1; m != 0; m >>= 1 { length += 1 }
	vv := v < 0 ? v - 1 : v
	return {u16(vv & ((1 << length) - 1)), length}
}

// One 8 x 8 block: its DCT, quantised, in zigzag order, written. The DC coefficient, the next block's reference.
@(private = "file")
block_encode :: proc(w: ^Bit_Writer, block: ^[64]f32, factor: ^[64]f32, prev_dc: i32, dc, ac: ^Huffman) -> i32 #no_bounds_check {
	for row in 0 ..< 8 { dct(block, row * 8, 1) }
	for col in 0 ..< 8 { dct(block, col, 8) }
	coef: [64]i32
	for k in 0 ..< 64 {
		v := block[k] * factor[k]
		coef[ZIGZAG[k]] = i32(v < 0 ? v - 0.5 : v + 0.5)
	}
	diff := coef[0] - prev_dc
	if diff == 0 {
		bits_write(w, dc.codes[0])
	} else {
		b := value_bits(diff)
		bits_write(w, dc.codes[b.length])
		bits_write(w, b)
	}
	last := 63
	for last > 0 && coef[last] == 0 { last -= 1 }
	if last == 0 {
		bits_write(w, ac.codes[0x00])   // (end of block)
		return coef[0]
	}
	for i := 1; i <= last; i += 1 {
		start := i
		for coef[i] == 0 && i <= last { i += 1 }
		zeros := i - start
		for zeros >= 16 {
			bits_write(w, ac.codes[0xF0])   // (sixteen zeros)
			zeros -= 16
		}
		b := value_bits(coef[i])
		bits_write(w, ac.codes[(zeros << 4) + int(b.length)])
		bits_write(w, b)
	}
	if last != 63 { bits_write(w, ac.codes[0x00]) }
	return coef[0]
}

// The forward DCT of eight values `stride` apart from `at` (Arai, Agui and Nakajima's: its scale is in AAN_SCALE).
@(private = "file")
dct :: proc(b: ^[64]f32, at, stride: int) #no_bounds_check {
	d0, d1, d2, d3 := b[at], b[at + stride], b[at + 2 * stride], b[at + 3 * stride]
	d4, d5, d6, d7 := b[at + 4 * stride], b[at + 5 * stride], b[at + 6 * stride], b[at + 7 * stride]
	t0, t7 := d0 + d7, d0 - d7
	t1, t6 := d1 + d6, d1 - d6
	t2, t5 := d2 + d5, d2 - d5
	t3, t4 := d3 + d4, d3 - d4
	// even part
	t10, t13 := t0 + t3, t0 - t3
	t11, t12 := t1 + t2, t1 - t2
	b[at] = t10 + t11
	b[at + 4 * stride] = t10 - t11
	z1 := (t12 + t13) * 0.707106781
	b[at + 2 * stride] = t13 + z1
	b[at + 6 * stride] = t13 - z1
	// odd part
	o10, o11, o12 := t4 + t5, t5 + t6, t6 + t7
	z5 := (o10 - o12) * 0.382683433
	z2 := o10 * 0.541196100 + z5
	z4 := o12 * 1.306562965 + z5
	z3 := o11 * 0.707106781
	z11, z13 := t7 + z3, t7 - z3
	b[at + 5 * stride] = z13 + z2
	b[at + 3 * stride] = z13 - z2
	b[at + 1 * stride] = z11 + z4
	b[at + 7 * stride] = z11 - z4
}

// The place in zigzag order of each coefficient in natural order.
@(private = "file", rodata)
ZIGZAG := [64]u8{
	0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42, 3, 8, 12, 17, 25, 30, 41, 43, 9, 11, 18, 24, 31, 40, 44, 53,
	10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60, 21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63,
}

@(private = "file", rodata)
AAN_SCALE := [8]f32{
	1.0 * 2.828427125, 1.387039845 * 2.828427125, 1.306562965 * 2.828427125, 1.175875602 * 2.828427125,
	1.0 * 2.828427125, 0.785694958 * 2.828427125, 0.541196100 * 2.828427125, 0.275899379 * 2.828427125,
}

// The specification's tables (ITU T.81, Annex K): quantisation in natural order, Huffman as counts and values.
@(private = "file", rodata)
LUMA_QUANT := [64]int{
	16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
	18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
}
@(private = "file", rodata)
CHROMA_QUANT := [64]int{
	17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
}
@(private = "file") LUMA_DC_BITS   :: [16]u8{0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0}
@(private = "file") CHROMA_DC_BITS :: [16]u8{0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0}
@(private = "file") LUMA_AC_BITS   :: [16]u8{0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D}
@(private = "file") CHROMA_AC_BITS :: [16]u8{0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77}
@(private = "file", rodata)
LUMA_DC_VALUES := [12]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}
@(private = "file", rodata)
CHROMA_DC_VALUES := [12]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}
@(private = "file", rodata)
LUMA_AC_VALUES := [162]u8{
	0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
	0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
	0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
	0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
	0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
	0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
	0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
}
@(private = "file", rodata)
CHROMA_AC_VALUES := [162]u8{
	0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
	0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
	0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
	0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
	0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
	0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
	0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
}

