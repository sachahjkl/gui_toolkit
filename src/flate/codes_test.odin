package flate

import "core:testing"

// len_index and dist_index give the code whose range holds the value: every length and every distance.
@(test)
indices_are_the_codes_of_the_tables :: proc(t: ^testing.T) {
	wrong := 0
	for length in MATCH_MIN ..= MATCH_MAX {
		li := len_index(length)
		if li < 0 || li >= LEN_CODES || int(LEN_BASE[li]) > length || (li + 1 < LEN_CODES && int(LEN_BASE[li + 1]) <= length) { wrong += 1 }
	}
	testing.expectf(t, wrong == 0, "%d lengths with another code", wrong)
	wrong = 0
	for dist in 1 ..= WINDOW {
		di := dist_index(dist)
		if di < 0 || di >= DIST_CODES || int(DIST_BASE[di]) > dist || (di + 1 < DIST_CODES && int(DIST_BASE[di + 1]) <= dist) { wrong += 1 }
	}
	testing.expectf(t, wrong == 0, "%d distances with another code", wrong)
}

// `reversed` against the bits taken one by one.
@(test)
reversed_turns_the_low_bits :: proc(t: ^testing.T) {
	wrong := 0
	for n in uint(1) ..= MAX_CODE_BITS {
		for code in u32(0) ..< 1 << n {
			want: u32
			for i in 0 ..< n { want |= ((code >> i) & 1) << (n - 1 - i) }
			if reversed(code, n) != want { wrong += 1 }
		}
	}
	testing.expect_value(t, wrong, 0)
}

// copy_match against the bytes taken one by one: every length at distances inside the output, across the window's end,
// and shorter than the length (the match then repeats its own bytes).
@(test)
copy_match_repeats_what_is_behind :: proc(t: ^testing.T) {
	WINDOW_BYTES :: 40
	OUT_BYTES :: 12
	window: [WINDOW_BYTES]u8
	for &b, i in window { b = u8(i * 13 + 5) }
	out := make([dynamic]u8, context.temp_allocator)
	want := make([dynamic]u8, context.temp_allocator)
	for dist in 1 ..= WINDOW_BYTES + OUT_BYTES {
		for length in MATCH_MIN ..= 3 * OUT_BYTES {
			clear(&out)
			clear(&want)
			for i in 0 ..< OUT_BYTES { append(&out, u8(200 + i)); append(&want, u8(200 + i)) }
			for _ in 0 ..< length {
				back := len(want) - dist
				append(&want, back >= 0 ? want[back] : window[len(window) + back])
			}
			copy_match(&out, window[:], length, dist)
			testing.expectf(t, string(out[:]) == string(want[:]), "length %d, distance %d: %v, want %v", length, dist, out[:], want[:])
		}
	}
}

// A code of every length from 1 to MAX_CODE_BITS: decode gives each symbol from the table (short codes, with 4 bytes to
// read) and bit by bit (long codes, or the last bytes of the input), and stays short when the input ends in a code.
@(test)
decode_reads_short_and_long_codes :: proc(t: ^testing.T) {
	// (lengths 1, 2, ... 14, 15, 15: a complete code)
	lengths: [MAX_CODE_BITS + 1]u8
	for &l, i in lengths { l = u8(min(i + 1, MAX_CODE_BITS)) }
	h: Huffman
	testing.expect_value(t, huffman_build(&h, lengths[:]), 0)
	c: Code
	copy(c.length[:], lengths[:])
	code_assign(&c, len(lengths))
	// every symbol, then every symbol again in the other order
	order: [2 * len(lengths)]int
	for &s, i in order { s = i < len(lengths) ? i : 2 * len(lengths) - 1 - i }
	data: [64]u8
	nbits := 0
	for s in order {
		r := reversed(u32(c.code[s]), uint(c.length[s]))
		for k in 0 ..< int(c.length[s]) {
			if r >> uint(k) & 1 != 0 { data[nbits >> 3] |= 1 << uint(nbits & 7) }
			nbits += 1
		}
	}
	for padding in ([2]int{0, 8}) {   // (the input ending with the codes, and with bytes to spare)
		b := Bits{data = data[:(nbits + 7) / 8 + padding]}
		for s, i in order { testing.expectf(t, decode(&b, &h) == s && !b.short, "symbol %d of %d bytes more", i, padding) }
		testing.expect_value(t, b.bit, nbits)
	}
	// the input cut inside the last code
	b := Bits{data = data[:(nbits - 3) / 8]}
	for _ in 0 ..< len(order) - 1 { decode(&b, &h) }
	decode(&b, &h)
	testing.expect(t, b.short, "short inside a code")
}
