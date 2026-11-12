package qr

// QR Code reading, the half that works on modules: a square of dark and light modules into its data. The format
// information (level and mask) from the copy that is nearest a valid one, the version information past version 6, the
// mask removed, the codewords read in the encoder's zigzag, the blocks taken apart and each corrected by its
// Reed–Solomon code (Berlekamp–Massey, Chien search, Forney), then the segments: numeric, alphanumeric, bytes; ECI and
// FNC1 markers are skipped, kanji is refused. The other half, finding the modules in a picture, is in decode_image.odin.

import "base:runtime"

// Why a code could not be read.
Decode_Error :: enum u8 {
	None,
	Not_Found,          // no QR Code in the picture
	Bad_Size,           // the matrix is not 21 to 177 modules square, 4k + 17
	Bad_Format,         // the format information is too damaged
	Too_Damaged,        // a block has more errors than its Reed–Solomon code corrects
	Bad_Data,           // the corrected data does not parse
	Unsupported_Mode,   // kanji, or a mode the standard does not define
}

// What a code holds: its data as the segments give it (UTF-8 for a text encode wrote; the bytes of a byte segment
// as they are), and what the symbol says of itself.
Decoded :: struct {
	data:    []u8,
	version: int,
	ecc:     Ecc,
	mask:    int,
	errors:  int,   // codewords the Reed–Solomon code corrected
}

decoded_destroy :: proc(d: ^Decoded, allocator := context.allocator) {
	delete(d.data, allocator)
	d^ = {}
}

// A matrix of `size` x `size` modules (row-major, true = dark, no quiet zone) into its data.
decode_modules :: proc(modules: []bool, size: int, allocator := context.allocator) -> (result: Decoded, err: Decode_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if size < 21 || size > 177 || (size - 17) % 4 != 0 || len(modules) < size * size { return {}, .Bad_Size }
	version := (size - 17) / 4
	ecc, mask := read_format(modules, size) or_return

	// the function modules, then the data modules unmasked
	m := Matrix{size = size, version = version, ecc = ecc}
	m.modules = make([]bool, size * size, context.temp_allocator)
	m.function = make([]bool, size * size, context.temp_allocator)
	draw_function_patterns(&m)
	copy(m.modules, modules[:size * size])
	apply_mask(&m, mask)

	raw := make([]u8, raw_data_modules(version) / 8, context.temp_allocator)
	read_codewords(&m, raw)
	data, corrected := correct_blocks(raw, version, ecc) or_return
	text := parse_segments(data, version, allocator) or_return
	return {data = text, version = version, ecc = ecc, mask = mask, errors = corrected}, .None
}

////////////////////////////////
// Format and version information

// The 15 bits of the format, both copies, each compared with the 32 valid ones: the nearest, if 3 bits or fewer away.
@(private = "file")
read_format :: proc(modules: []bool, size: int) -> (ecc: Ecc, mask: int, err: Decode_Error) {
	at :: proc(modules: []bool, size, x, y: int) -> int { return int(modules[y * size + x]) }
	a, b: int
	for i in 0 ..< 6 { a |= at(modules, size, 8, i) << uint(i) }
	a |= at(modules, size, 8, 7) << 6
	a |= at(modules, size, 8, 8) << 7
	a |= at(modules, size, 7, 8) << 8
	for i in 9 ..< 15 { a |= at(modules, size, 14 - i, 8) << uint(i) }
	for i in 0 ..< 8 { b |= at(modules, size, size - 1 - i, 8) << uint(i) }
	for i in 8 ..< 15 { b |= at(modules, size, 8, size - 15 + i) << uint(i) }

	best, best_distance := -1, 4
	for data in 0 ..< 32 {
		rem := data
		for _ in 0 ..< 10 { rem = (rem << 1) ~ ((rem >> 9) * 0x537) }
		code := (data << 10 | rem) ~ 0x5412
		for got in ([2]int{a, b}) {
			if d := bit_count(code ~ got); d < best_distance { best, best_distance = data, d }
		}
	}
	if best < 0 { return {}, 0, .Bad_Format }
	levels := [4]Ecc{1 = .Low, 0 = .Medium, 3 = .Quartile, 2 = .High}
	return levels[best >> 3], best & 7, .None
}

@(private = "file")
bit_count :: proc(v: int) -> int {
	n := 0
	for x := v; x != 0; x &= x - 1 { n += 1 }
	return n
}

// The version information of a symbol of version 7 or more (both copies): the nearest valid one, 3 bits or fewer away;
// 0 when neither is near one. The image reader checks the version it guessed from the symbol's size with it.
@(private)
read_version :: proc(modules: []bool, size: int) -> int {
	if size < 45 { return (size - 17) / 4 }
	a, b: int
	for i in 0 ..< 18 {
		x, y := size - 11 + i % 3, i / 3
		a |= int(modules[y * size + x]) << uint(i)
		b |= int(modules[x * size + y]) << uint(i)
	}
	best, best_distance := 0, 4
	for v in 7 ..= MAX_VERSION {
		rem := v
		for _ in 0 ..< 12 { rem = (rem << 1) ~ ((rem >> 11) * 0x1F25) }
		code := v << 12 | rem
		for got in ([2]int{a, b}) {
			if d := bit_count(code ~ got); d < best_distance { best, best_distance = v, d }
		}
	}
	return best
}

////////////////////////////////
// Codewords and blocks

// The data modules in the encoder's zigzag (draw_codewords), into bytes.
@(private = "file")
read_codewords :: proc(m: ^Matrix, out: []u8) {
	i := 0
	for right := m.size - 1; right >= 1; right -= 2 {
		if right == 6 { right = 5 }
		for vert in 0 ..< m.size {
			for j in 0 ..< 2 {
				x := right - j
				upward := (right + 1) & 2 == 0
				y := upward ? m.size - 1 - vert : vert
				if m.function[y * m.size + x] || i >= len(out) * 8 { continue }
				if m.modules[y * m.size + x] { out[i >> 3] |= 0x80 >> uint(i & 7) }
				i += 1
			}
		}
	}
}

// The interleaved codewords back into their blocks (add_ecc_and_interleave's layout), each corrected, their data
// joined.
@(private = "file")
correct_blocks :: proc(raw: []u8, version: int, ecc: Ecc) -> (data: []u8, corrected: int, err: Decode_Error) {
	blocks, ecc_len := ECC_BLOCKS[ecc][version], ECC_PER_BLOCK[ecc][version]
	short_blocks := blocks - len(raw) % blocks
	short_len := len(raw) / blocks
	block := make([][]u8, blocks, context.temp_allocator)
	for &blk in block { blk = make([]u8, short_len + 1, context.temp_allocator) }
	at := 0
	for i in 0 ..< short_len + 1 {
		for j in 0 ..< blocks {
			if i == short_len - ecc_len && j < short_blocks { continue }   // (the byte a short block lacks)
			block[j][i] = raw[at]
			at += 1
		}
	}
	gf := gf_make()
	out := make([dynamic]u8, 0, data_codewords(version, ecc), context.temp_allocator)
	for blk, j in block {
		n := short_len - ecc_len + (j < short_blocks ? 0 : 1)
		// the codeword: its data, then its ECC (a short block's gap left out)
		word := make([]u8, n + ecc_len, context.temp_allocator)
		copy(word, blk[:n])
		copy(word[n:], blk[short_len + 1 - ecc_len:])
		fixed, ok := rs_correct(&gf, word, ecc_len)
		if !ok { return nil, 0, .Too_Damaged }
		corrected += fixed
		append(&out, ..word[:n])
	}
	return out[:], corrected, .None
}

////////////////////////////////
// Reed–Solomon decoding over GF(2^8), polynomial 0x11D, the generator's roots α^0 .. α^(n-1)

@(private)
Gf :: struct {
	exp: [512]u8,   // α^i, twice over: a product's exponents add without a modulo
	log: [256]int,
}

@(private)
gf_make :: proc() -> (gf: Gf) {
	x := 1
	for i in 0 ..< 255 {
		gf.exp[i] = u8(x)
		gf.log[x] = i
		x <<= 1
		if x & 0x100 != 0 { x ~= 0x11D }
	}
	for i in 255 ..< 512 { gf.exp[i] = gf.exp[i - 255] }
	return
}

@(private = "file")
gf_mul :: proc(gf: ^Gf, a, b: u8) -> u8 {
	if a == 0 || b == 0 { return 0 }
	return gf.exp[gf.log[a] + gf.log[b]]
}

@(private = "file")
gf_div :: proc(gf: ^Gf, a, b: u8) -> u8 {
	if a == 0 { return 0 }
	return gf.exp[gf.log[a] + 255 - gf.log[b]]
}

// α^e for any e >= 0, and its inverse.
@(private = "file")
gf_alpha :: proc(gf: ^Gf, e: int) -> u8 { return gf.exp[e % 255] }
@(private = "file")
gf_alpha_inv :: proc(gf: ^Gf, e: int) -> u8 { return gf.exp[(255 - e % 255) % 255] }

// Corrects `word` (its first byte the highest power) in place. fixed: the codewords changed. ok is false when it has
// more errors than `nsym` check codewords correct (what is then left in `word` is not to be used).
@(private)
rs_correct :: proc(gf: ^Gf, word: []u8, nsym: int) -> (fixed: int, ok: bool) {
	n := len(word)
	synd := make([]u8, nsym, context.temp_allocator)
	if !syndromes(gf, word, synd) { return 0, true }

	// Berlekamp–Massey: the error locator Λ (lowest degree first)
	lambda := make([]u8, nsym + 1, context.temp_allocator)
	prev := make([]u8, nsym + 1, context.temp_allocator)
	tmp := make([]u8, nsym + 1, context.temp_allocator)
	lambda[0], prev[0] = 1, 1
	l, m, b := 0, 1, u8(1)
	for k in 0 ..< nsym {
		d := synd[k]
		for i in 1 ..= l { d ~= gf_mul(gf, lambda[i], synd[k - i]) }
		if d == 0 { m += 1; continue }
		coef := gf_div(gf, d, b)
		grow := 2 * l <= k
		if grow { copy(tmp, lambda) }
		for i in 0 ..= nsym - m { lambda[i + m] ~= gf_mul(gf, coef, prev[i]) }
		if grow {
			l = k + 1 - l
			copy(prev, tmp)
			b, m = d, 1
		} else {
			m += 1
		}
	}
	if l == 0 || 2 * l > nsym { return 0, false }

	// Chien search: the codeword j is the power n-1-j; it is in error when Λ(α^-(n-1-j)) = 0
	positions := make([dynamic]int, 0, l, context.temp_allocator)
	for j in 0 ..< n {
		x := gf_alpha_inv(gf, n - 1 - j)
		v: u8
		for i := l; i >= 0; i -= 1 { v = gf_mul(gf, v, x) ~ lambda[i] }
		if v == 0 { append(&positions, j) }
	}
	if len(positions) != l { return 0, false }

	// Forney: Ω = S Λ mod x^nsym; the error at X is X Ω(X^-1) / Λ'(X^-1) (the first root α^0)
	omega := make([]u8, nsym, context.temp_allocator)
	for i in 0 ..< nsym {
		for j in 0 ..= min(i, l) { omega[i] ~= gf_mul(gf, synd[i - j], lambda[j]) }
	}
	for j in positions {
		e := n - 1 - j
		x, x_inv := gf_alpha(gf, e), gf_alpha_inv(gf, e)
		om: u8
		for i := nsym - 1; i >= 0; i -= 1 { om = gf_mul(gf, om, x_inv) ~ omega[i] }
		// Λ'(x): the odd terms, one degree down (in GF(2^k) 2 = 0)
		dl, x2: u8 = 0, gf_mul(gf, x_inv, x_inv)
		pow := u8(1)
		for i := 1; i <= l; i += 2 {
			dl ~= gf_mul(gf, lambda[i], pow)
			pow = gf_mul(gf, pow, x2)
		}
		if dl == 0 { return 0, false }
		word[j] ~= gf_mul(gf, x, gf_div(gf, om, dl))
	}
	if syndromes(gf, word, synd) { return 0, false }   // (a locator that pointed wrong: more errors than it says)
	return l, true
}

// The syndromes word(α^i), i < len(out). True when one is not zero: the word has an error.
@(private = "file")
syndromes :: proc(gf: ^Gf, word, out: []u8) -> bool {
	any := false
	for i in 0 ..< len(out) {
		a := gf_alpha(gf, i)
		s: u8
		for c in word { s = gf_mul(gf, s, a) ~ c }
		out[i] = s
		any ||= s != 0
	}
	return any
}

////////////////////////////////
// Segments

@(private = "file")
Bit_Reader :: struct { data: []u8, at: int }

@(private = "file")
bits_left :: proc(r: ^Bit_Reader) -> int { return len(r.data) * 8 - r.at }

@(private = "file")
take :: proc(r: ^Bit_Reader, count: int) -> (v: int, ok: bool) {
	if count > bits_left(r) { return 0, false }
	for _ in 0 ..< count {
		v = v << 1 | int((r.data[r.at >> 3] >> uint(7 - (r.at & 7))) & 1)
		r.at += 1
	}
	return v, true
}

// The bit stream into the data its segments hold. It ends at a terminator, or where fewer than 4 bits are left.
@(private = "file")
parse_segments :: proc(data: []u8, version: int, allocator: runtime.Allocator) -> (out: []u8, err: Decode_Error) {
	r := Bit_Reader{data = data}
	text := make([dynamic]u8, 0, len(data), context.temp_allocator)
	for bits_left(&r) >= 4 {
		mode, _ := take(&r, 4)
		switch mode {
		case 0x0:   // terminator
			return clone_bytes(text[:], allocator), .None
		case 0x1:
			read_numeric(&r, &text, version) or_return
		case 0x2:
			read_alphanumeric(&r, &text, version) or_return
		case 0x4:
			read_bytes(&r, &text, version) or_return
		case 0x7:   // ECI: the designator's length is in its first bits (the bytes are kept as they are)
			first, ok := take(&r, 8)
			if !ok { return nil, .Bad_Data }
			extra := first & 0x80 == 0 ? 0 : first & 0xC0 == 0x80 ? 8 : 16
			if _, ok2 := take(&r, extra); !ok2 { return nil, .Bad_Data }
		case 0x5:   // FNC1, first position: nothing follows it
		case 0x9:   // FNC1, second position: an application indicator
			if _, ok := take(&r, 8); !ok { return nil, .Bad_Data }
		case 0x3:   // structured append: this symbol's place and the parity of the whole
			if _, ok := take(&r, 16); !ok { return nil, .Bad_Data }
		case 0x8:
			return nil, .Unsupported_Mode
		case:
			return nil, .Unsupported_Mode
		}
	}
	return clone_bytes(text[:], allocator), .None
}

@(private = "file")
clone_bytes :: proc(b: []u8, allocator: runtime.Allocator) -> []u8 {
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return out
}

@(private = "file")
read_numeric :: proc(r: ^Bit_Reader, text: ^[dynamic]u8, version: int) -> Decode_Error {
	n, ok := take(r, count_bits(.Numeric, version))
	if !ok { return .Bad_Data }
	for n > 0 {
		digits := min(n, 3)
		v, got := take(r, digits * 3 + 1)
		limit := [4]int{0, 10, 100, 1000}
		if !got || v >= limit[digits] { return .Bad_Data }
		buf: [3]u8
		for i := digits - 1; i >= 0; i -= 1 {
			buf[i] = u8('0' + v % 10)
			v /= 10
		}
		append(text, ..buf[:digits])
		n -= digits
	}
	return .None
}

@(private = "file")
read_alphanumeric :: proc(r: ^Bit_Reader, text: ^[dynamic]u8, version: int) -> Decode_Error {
	n, ok := take(r, count_bits(.Alphanumeric, version))
	if !ok { return .Bad_Data }
	table := ALPHANUMERIC
	for n >= 2 {
		v, got := take(r, 11)
		if !got || v >= 45 * 45 { return .Bad_Data }
		append(text, table[v / 45], table[v % 45])
		n -= 2
	}
	if n == 1 {
		v, got := take(r, 6)
		if !got || v >= 45 { return .Bad_Data }
		append(text, table[v])
	}
	return .None
}

@(private = "file")
read_bytes :: proc(r: ^Bit_Reader, text: ^[dynamic]u8, version: int) -> Decode_Error {
	n, ok := take(r, count_bits(.Byte, version))
	if !ok || n * 8 > bits_left(r) { return .Bad_Data }
	for _ in 0 ..< n {
		v, _ := take(r, 8)
		append(text, u8(v))
	}
	return .None
}
