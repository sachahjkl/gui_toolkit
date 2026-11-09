// QR Code generation (ISO/IEC 18004, model 2): text or bytes into a square of dark and light modules. Follows Project
// Nayuki's QR Code generator (https://www.nayuki.io/page/qr-code-generator-library, MIT): the same version choice, data
// layout, Reed–Solomon code, interleaving and mask penalty, so a text gives the very matrix its encode_text gives (without
// its ECC boost). Pure Odin, any target. See docs/qr.md.
package qr

import "base:runtime"

// How much of the symbol can be lost and still read: about 7, 15, 25 and 30 % of the codewords.
Ecc :: enum u8 { Low, Medium, Quartile, High }

Error :: enum u8 {
	None,
	Too_Long,   // the data does not fit version 40 at that level
}

// A QR Code: `size` x `size` modules, row-major, true = dark. The quiet zone (4 light modules around it) is not part of it.
Code :: struct {
	size:    int,    // 21 to 177: version * 4 + 17
	version: int,    // 1 to 40
	ecc:     Ecc,
	mask:    int,    // 0 to 7, the one with the lowest penalty
	modules: []bool,
}

QUIET_ZONE :: 4   // light modules a scanner needs on each side (the standard's minimum)
MIN_VERSION :: 1
MAX_VERSION :: 40

// `text` as a QR Code at the smallest version that holds it: numeric mode when it is all digits, alphanumeric when it is
// all in `0-9 A-Z space $%*+-./:`, else bytes (its UTF-8).
encode :: proc(text: string, ecc := Ecc.Medium, allocator := context.allocator) -> (Code, Error) {
	mode := Mode.Byte
	if is_numeric(text) { mode = .Numeric } else if is_alphanumeric(text) { mode = .Alphanumeric }
	return encode_mode(transmute([]u8)text, mode, ecc, allocator)
}

// `data` as a QR Code in byte mode, at the smallest version that holds it.
encode_bytes :: proc(data: []u8, ecc := Ecc.Medium, allocator := context.allocator) -> (Code, Error) {
	return encode_mode(data, .Byte, ecc, allocator)
}

// Whether the module at column x, row y is dark; outside the symbol (the quiet zone) it is light.
module :: proc(code: Code, x, y: int) -> bool {
	return x >= 0 && y >= 0 && x < code.size && y < code.size && code.modules[y * code.size + x]
}

destroy :: proc(code: ^Code, allocator := context.allocator) {
	delete(code.modules, allocator)
	code^ = {}
}

////////////////////////////////
// Segments and versions

@(private) Mode :: enum u8 { Numeric, Alphanumeric, Byte }

@(private = "file") MODE_BITS := [Mode]u32{.Numeric = 0x1, .Alphanumeric = 0x2, .Byte = 0x4}
// Bits of the character count, for versions 1-9, 10-26 and 27-40.
@(private = "file") COUNT_BITS := [Mode][3]int{.Numeric = {10, 12, 14}, .Alphanumeric = {9, 11, 13}, .Byte = {8, 16, 16}}
@(private = "file") ALPHANUMERIC :: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

@(private)
is_numeric :: proc(s: string) -> bool {
	for c in transmute([]u8)s { if c < '0' || c > '9' { return false } }
	return true
}

@(private)
is_alphanumeric :: proc(s: string) -> bool {
	for c in transmute([]u8)s { if alphanumeric_index(c) < 0 { return false } }
	return true
}

@(private = "file")
alphanumeric_index :: proc(c: u8) -> int {
	for a, i in transmute([]u8)string(ALPHANUMERIC) { if a == c { return i } }
	return -1
}

@(private = "file")
count_bits :: proc(mode: Mode, version: int) -> int { return COUNT_BITS[mode][(version + 7) / 17] }

// Bits of the one segment (header included) at that version; -1 when its length overflows the count field. An empty text
// has no segment at all.
@(private)
segment_bits :: proc(mode: Mode, n, version: int) -> int {
	if n == 0 { return 0 }
	cb := count_bits(mode, version)
	if n >= 1 << uint(cb) { return -1 }
	payload: int
	switch mode {
	case .Numeric:      payload = n / 3 * 10 + (n % 3 == 0 ? 0 : n % 3 * 3 + 1)   // 3 digits in 10 bits, 2 in 7, 1 in 4
	case .Alphanumeric: payload = n / 2 * 11 + n % 2 * 6
	case .Byte:         payload = n * 8
	}
	return 4 + cb + payload
}

// Every module that is not a function pattern nor format or version information: the data and ECC bits (and up to 7
// remainder bits).
@(private)
raw_data_modules :: proc(version: int) -> int {
	result := (16 * version + 128) * version + 64
	if version >= 2 {
		align := version / 7 + 2
		result -= (25 * align - 10) * align - 55
		if version >= 7 { result -= 36 }
	}
	return result
}

@(private)
data_codewords :: proc(version: int, ecc: Ecc) -> int {
	return raw_data_modules(version) / 8 - ECC_PER_BLOCK[ecc][version] * ECC_BLOCKS[ecc][version]
}

@(private = "file")
Bits :: struct { bytes: [dynamic]u8, n: int }

@(private = "file")
put :: proc(b: ^Bits, value: u32, count: int) {
	for i := count - 1; i >= 0; i -= 1 {
		if b.n % 8 == 0 { append(&b.bytes, 0) }
		if (value >> uint(i)) & 1 != 0 { b.bytes[b.n / 8] |= 0x80 >> uint(b.n % 8) }
		b.n += 1
	}
}

@(private = "file")
encode_mode :: proc(data: []u8, mode: Mode, ecc: Ecc, allocator: runtime.Allocator) -> (Code, Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	version, used := 0, 0
	for v in MIN_VERSION ..= MAX_VERSION {
		used = segment_bits(mode, len(data), v)
		if used >= 0 && used <= data_codewords(v, ecc) * 8 { version = v; break }
	}
	if version == 0 { return {}, .Too_Long }

	capacity := data_codewords(version, ecc) * 8
	b := Bits{bytes = make([dynamic]u8, 0, capacity / 8, context.temp_allocator)}
	if len(data) > 0 {
		put(&b, MODE_BITS[mode], 4)
		put(&b, u32(len(data)), count_bits(mode, version))
		switch mode {
		case .Numeric:
			for i := 0; i < len(data); i += 3 {
				n, v := min(3, len(data) - i), u32(0)
				for c in data[i:][:n] { v = v * 10 + u32(c - '0') }
				put(&b, v, n * 3 + 1)
			}
		case .Alphanumeric:
			i := 0
			for ; i + 1 < len(data); i += 2 {
				put(&b, u32(alphanumeric_index(data[i]) * 45 + alphanumeric_index(data[i + 1])), 11)
			}
			if i < len(data) { put(&b, u32(alphanumeric_index(data[i])), 6) }
		case .Byte:
			for c in data { put(&b, u32(c), 8) }
		}
	}
	assert(b.n == used)
	// the terminator (up to 4 zero bits), zeros to a whole byte, then the pad bytes 0xEC 0x11...
	put(&b, 0, min(4, capacity - b.n))
	put(&b, 0, (8 - b.n % 8) % 8)
	for pad := u32(0xEC); b.n < capacity; pad ~= 0xEC ~ 0x11 { put(&b, pad, 8) }

	m := Matrix{size = version * 4 + 17, version = version, ecc = ecc}
	m.modules = make([]bool, m.size * m.size, allocator)
	m.function = make([]bool, m.size * m.size, context.temp_allocator)
	draw_function_patterns(&m)
	draw_codewords(&m, add_ecc_and_interleave(b.bytes[:], version, ecc))

	best, best_penalty := 0, max(int)
	for mask in 0 ..< 8 {
		apply_mask(&m, mask)
		draw_format_bits(&m, mask)
		if p := penalty(&m); p < best_penalty { best, best_penalty = mask, p }
		apply_mask(&m, mask)   // (XOR: undone)
	}
	apply_mask(&m, best)
	draw_format_bits(&m, best)
	return Code{size = m.size, version = version, ecc = ecc, mask = best, modules = m.modules}, .None
}

////////////////////////////////
// The matrix

@(private = "file")
Matrix :: struct {
	size, version: int,
	ecc:           Ecc,
	modules:       []bool,
	function:      []bool,   // finder, timing, alignment, format and version modules: no data, no mask
}

@(private = "file")
set_function :: proc(m: ^Matrix, x, y: int, dark: bool) {
	m.modules[y * m.size + x] = dark
	m.function[y * m.size + x] = true
}

@(private = "file")
draw_function_patterns :: proc(m: ^Matrix) {
	for i in 0 ..< m.size {
		set_function(m, 6, i, i % 2 == 0)
		set_function(m, i, 6, i % 2 == 0)
	}
	for c in ([3][2]int{{3, 3}, {m.size - 4, 3}, {3, m.size - 4}}) {
		for dy in -4 ..= 4 {
			for dx in -4 ..= 4 {
				x, y := c.x + dx, c.y + dy
				d := max(abs(dx), abs(dy))
				if x >= 0 && y >= 0 && x < m.size && y < m.size { set_function(m, x, y, d != 2 && d != 4) }
			}
		}
	}
	positions := alignment_positions(m.version)
	n := len(positions)
	for i in 0 ..< n {
		for j in 0 ..< n {
			if (i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0) { continue }   // the finders
			for dy in -2 ..= 2 {
				for dx in -2 ..= 2 { set_function(m, positions[i] + dx, positions[j] + dy, max(abs(dx), abs(dy)) != 1) }
			}
		}
	}
	draw_format_bits(m, 0)   // (reserves them; the mask's are drawn at the end)
	if m.version >= 7 {
		rem := m.version
		for _ in 0 ..< 12 { rem = (rem << 1) ~ ((rem >> 11) * 0x1F25) }
		bits := m.version << 12 | rem
		for i in 0 ..< 18 {
			dark := (bits >> uint(i)) & 1 != 0
			a, b := m.size - 11 + i % 3, i / 3
			set_function(m, a, b, dark)
			set_function(m, b, a, dark)
		}
	}
}

// The centres of the alignment patterns along each axis, in increasing order (none at version 1).
@(private = "file")
alignment_positions :: proc(version: int) -> []int {
	if version == 1 { return nil }
	n := version / 7 + 2
	step := version == 32 ? 26 : (version * 4 + n * 2 + 1) / (n * 2 - 2) * 2
	result := make([]int, n, context.temp_allocator)
	result[0] = 6
	for i in 1 ..< n { result[n - i] = version * 4 + 17 - 7 - (i - 1) * step }
	return result
}

@(private = "file")
draw_format_bits :: proc(m: ^Matrix, mask: int) {
	level := [Ecc]int{.Low = 1, .Medium = 0, .Quartile = 3, .High = 2}
	data := level[m.ecc] << 3 | mask
	rem := data
	for _ in 0 ..< 10 { rem = (rem << 1) ~ ((rem >> 9) * 0x537) }
	bits := (data << 10 | rem) ~ 0x5412
	bit :: proc(bits, i: int) -> bool { return (bits >> uint(i)) & 1 != 0 }
	// the copy around the top left finder
	for i in 0 ..< 6 { set_function(m, 8, i, bit(bits, i)) }
	set_function(m, 8, 7, bit(bits, 6))
	set_function(m, 8, 8, bit(bits, 7))
	set_function(m, 7, 8, bit(bits, 8))
	for i in 9 ..< 15 { set_function(m, 14 - i, 8, bit(bits, i)) }
	// the copy split between the two other finders
	for i in 0 ..< 8 { set_function(m, m.size - 1 - i, 8, bit(bits, i)) }
	for i in 8 ..< 15 { set_function(m, 8, m.size - 15 + i, bit(bits, i)) }
	set_function(m, 8, m.size - 8, true)   // the dark module
}

// The data codewords cut in blocks, each followed by its Reed–Solomon codewords, then interleaved: the first byte of
// every block, the second... (the short blocks have one data byte less).
@(private = "file")
add_ecc_and_interleave :: proc(data: []u8, version: int, ecc: Ecc) -> []u8 {
	blocks, ecc_len := ECC_BLOCKS[ecc][version], ECC_PER_BLOCK[ecc][version]
	raw := raw_data_modules(version) / 8
	short_blocks := blocks - raw % blocks
	short_len := raw / blocks
	divisor := rs_divisor(ecc_len)
	block := make([][]u8, blocks, context.temp_allocator)
	k := 0
	for i in 0 ..< blocks {
		n := short_len - ecc_len + (i < short_blocks ? 0 : 1)
		blk := make([]u8, short_len + 1, context.temp_allocator)
		copy(blk, data[k:][:n])
		rs_remainder(data[k:][:n], divisor, blk[short_len + 1 - ecc_len:])
		k += n
		block[i] = blk
	}
	result := make([]u8, raw, context.temp_allocator)
	at := 0
	for i in 0 ..< short_len + 1 {
		for blk, j in block {
			if i == short_len - ecc_len && j < short_blocks { continue }   // (the byte a short block lacks)
			result[at] = blk[i]
			at += 1
		}
	}
	return result
}

// The data bits in the zigzag of two-column strips, from the bottom right, skipping the function modules and column 6.
@(private = "file")
draw_codewords :: proc(m: ^Matrix, data: []u8) {
	i := 0
	for right := m.size - 1; right >= 1; right -= 2 {
		if right == 6 { right = 5 }
		for vert in 0 ..< m.size {
			for j in 0 ..< 2 {
				x := right - j
				upward := (right + 1) & 2 == 0
				y := upward ? m.size - 1 - vert : vert
				if !m.function[y * m.size + x] && i < len(data) * 8 {
					m.modules[y * m.size + x] = (data[i >> 3] >> uint(7 - (i & 7))) & 1 != 0
					i += 1
				}
			}
		}
	}
}

@(private = "file")
apply_mask :: proc(m: ^Matrix, mask: int) {
	for y in 0 ..< m.size {
		for x in 0 ..< m.size {
			flip: bool
			switch mask {
			case 0: flip = (x + y) % 2 == 0
			case 1: flip = y % 2 == 0
			case 2: flip = x % 3 == 0
			case 3: flip = (x + y) % 3 == 0
			case 4: flip = (x / 3 + y / 2) % 2 == 0
			case 5: flip = x * y % 2 + x * y % 3 == 0
			case 6: flip = (x * y % 2 + x * y % 3) % 2 == 0
			case 7: flip = ((x + y) % 2 + x * y % 3) % 2 == 0
			}
			i := y * m.size + x
			if flip && !m.function[i] { m.modules[i] = !m.modules[i] }
		}
	}
}

////////////////////////////////
// The mask penalty (N1 runs, N2 2x2 blocks, N3 finder-like patterns, N4 balance)

@(private = "file") N1 :: 3
@(private = "file") N2 :: 3
@(private = "file") N3 :: 40
@(private = "file") N4 :: 10

@(private = "file")
penalty :: proc(m: ^Matrix) -> int {
	size := m.size
	result := 0
	for horizontal in ([2]bool{true, false}) {
		for a in 0 ..< size {
			color, run := false, 0
			history: [7]int
			for b in 0 ..< size {
				dark := horizontal ? m.modules[a * size + b] : m.modules[b * size + a]
				if dark == color {
					run += 1
					if run == 5 { result += N1 } else if run > 5 { result += 1 }
				} else {
					history_add(&history, run, size)
					if !color { result += finder_count(history, size) * N3 }
					color, run = dark, 1
				}
			}
			// the end of the line: the run in progress, then the light border beyond it
			if color { history_add(&history, run, size); run = 0 }
			history_add(&history, run + size, size)
			result += finder_count(history, size) * N3
		}
	}
	for y in 0 ..< size - 1 {
		for x in 0 ..< size - 1 {
			c := m.modules[y * size + x]
			if c == m.modules[y * size + x + 1] && c == m.modules[(y + 1) * size + x] && c == m.modules[(y + 1) * size + x + 1] {
				result += N2
			}
		}
	}
	dark := 0
	for c in m.modules { if c { dark += 1 } }
	total := size * size
	k := (abs(dark * 20 - total * 10) + total - 1) / total - 1
	return result + k * N4
}

// The newest run first; the first run of a line also counts the light border before it.
@(private = "file")
history_add :: proc(h: ^[7]int, run, size: int) {
	run := run
	if h[0] == 0 { run += size }
	for i := 6; i > 0; i -= 1 { h[i] = h[i - 1] }
	h[0] = run
}

// Light-dark-light-dark(3)-light-dark-light runs of 1:1:3:1:1, with 4 light on either side: 0, 1 or 2 such patterns.
@(private = "file")
finder_count :: proc(h: [7]int, size: int) -> int {
	n := h[1]
	core := n > 0 && h[2] == n && h[4] == n && h[5] == n && h[3] == n * 3
	return int(core && h[0] >= n * 4 && h[6] >= n) + int(core && h[6] >= n * 4 && h[0] >= n)
}

////////////////////////////////
// Reed–Solomon over GF(2^8), polynomial 0x11D

@(private = "file")
rs_multiply :: proc(x, y: u8) -> u8 {
	z: u32
	for i := 7; i >= 0; i -= 1 {
		z = (z << 1) ~ ((z >> 7) * 0x11D)
		z ~= u32((y >> uint(i)) & 1) * u32(x)
	}
	return u8(z)
}

// The generator polynomial of that degree, highest coefficient first, the leading 1 left out.
@(private = "file")
rs_divisor :: proc(degree: int) -> []u8 {
	result := make([]u8, degree, context.temp_allocator)
	result[degree - 1] = 1
	root := u8(1)
	for _ in 0 ..< degree {
		for j in 0 ..< degree {
			result[j] = rs_multiply(result[j], root)
			if j + 1 < degree { result[j] ~= result[j + 1] }
		}
		root = rs_multiply(root, 0x02)
	}
	return result
}

@(private = "file")
rs_remainder :: proc(data, divisor: []u8, out: []u8) {
	for &r in out { r = 0 }
	for b in data {
		factor := b ~ out[0]
		copy(out, out[1:])
		out[len(out) - 1] = 0
		for c, i in divisor { out[i] ~= rs_multiply(c, factor) }
	}
}

////////////////////////////////
// Tables (ISO/IEC 18004 table 9), by version; index 0 is unused

@(private) ECC_PER_BLOCK := [Ecc][41]int{
	.Low      = {-1,  7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
	.Medium   = {-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28},
	.Quartile = {-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
	.High     = {-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
}

@(private) ECC_BLOCKS := [Ecc][41]int{
	.Low      = {-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4,  4,  4,  4,  4,  6,  6,  6,  6,  7,  8,  8,  9,  9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25},
	.Medium   = {-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5,  5,  8,  9,  9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49},
	.Quartile = {-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8,  8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68},
	.High     = {-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81},
}
