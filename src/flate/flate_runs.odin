package flate

import "base:intrinsics"
import "core:hash"

// Compression for pictures being taken while a program runs, where the rate matters and the size less: several hundred
// MB/s where deflate makes about ten (a picture of 2310x1505 pixels takes 1.3 s there). No search: at each position, what
// follows the byte before (a run) and what stands a row above, in one block of the fixed Huffman codes. On the rows of a
// PNG's Sub filter an interface's flat areas are runs of zeros, and rows like the last are matches. The output is a few
// times larger than deflate's, and what a decoder expects.
//
//   z := flate.deflate_runs(.Zlib, rows, row = stride + 1, allocator)
//
// `row`: the distance of the second kind of match, ignored over the window (0: none).

@(private = "file")
Code :: struct { bits: u32, n: u32 }   // (bits first in, as the stream takes them)

@(private = "file")
lit_codes: [LIT_SYMBOLS]Code
@(private = "file")
len_codes: [MATCH_MAX + 1]Code   // the code and extra bits of a match's length, as one

// What the output of deflate_runs may take on top of 9 bits a byte: the header, the trailer, the last bits.
@(private = "file")
RUNS_SLACK_BYTES :: 64
// The shortest match taken from the row above (a run takes MATCH_MIN).
@(private = "file")
ROW_MATCH_MIN :: 4

@(private = "file")
reverse :: proc "contextless" (v, n: u32) -> (r: u32) {
	for i in 0 ..< n { if v & (1 << i) != 0 { r |= 1 << (n - 1 - i) } }
	return
}

// The tables, made once at start-up (as the fixed codes: no lazy init to race on).
@(private = "file", init)
runs_tables :: proc "contextless" () {
	for i in 0 ..< LIT_SYMBOLS {
		v := u32(i)
		switch {
		case i < FIXED_9BIT_FIRST: lit_codes[i] = {reverse(0x30 + v, 8), 8}
		case i < FIXED_7BIT_FIRST: lit_codes[i] = {reverse(0x190 + v - FIXED_9BIT_FIRST, 9), 9}
		case i < FIXED_8BIT_FIRST: lit_codes[i] = {reverse(v - FIXED_7BIT_FIRST, 7), 7}
		case:         lit_codes[i] = {reverse(0xC0 + v - FIXED_8BIT_FIRST, 8), 8}
		}
	}
	for l in MATCH_MIN ..= MATCH_MAX {
		k := LEN_CODES - 1
		for int(LEN_BASE[k]) > l { k -= 1 }
		c := lit_codes[LEN_SYMBOL_FIRST + k]
		len_codes[l] = {c.bits | (u32(l) - u32(LEN_BASE[k])) << c.n, c.n + u32(LEN_EXTRA[k])}
	}
}

// A distance's code and extra bits, as one.
@(private = "file")
dist_code :: proc "contextless" (dist: u32) -> Code {
	k := DIST_CODES - 1
	for u32(DIST_BASE[k]) > dist { k -= 1 }
	return {reverse(u32(k), FIXED_DIST_BITS) | (dist - u32(DIST_BASE[k])) << FIXED_DIST_BITS, FIXED_DIST_BITS + u32(DIST_EXTRA[k])}
}

// How far p and q are the same, up to `limit` bytes.
@(private = "file")
same :: #force_inline proc "contextless" (p, q: [^]u8, limit: int) -> int {
	n := 0
	for n + 8 <= limit {
		a := intrinsics.unaligned_load((^u64)(&p[n]))
		b := intrinsics.unaligned_load((^u64)(&q[n]))
		if a != b { return n + int(intrinsics.count_trailing_zeros(a ~ b)) / 8 }   // (little endian: the targets the toolkit has)
		n += 8
	}
	for n < limit && p[n] == q[n] { n += 1 }
	return n
}

// Worst case 9 bits a byte, so the output never outgrows what is made here.
deflate_runs :: proc(format: Format, data: []u8, row := 0, allocator := context.allocator) -> []u8 #no_bounds_check {
	out := make([]u8, len(data) + len(data) / 8 + RUNS_SLACK_BYTES, allocator)
	o := 0
	switch format {
	case .Zlib:
		out[0], out[1] = 0x78, 0x01
		o = 2
	case .Gzip:
		h := [GZIP_HEADER_BYTES]u8{0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255}
		copy(out, h[:])
		o = GZIP_HEADER_BYTES
	case .Raw:
	}
	acc: u64 = 0b011   // the last block; fixed codes
	nacc: u32 = 3
	flush :: #force_inline proc "contextless" (out: [^]u8, o: ^int, acc: ^u64, nacc: ^u32) {
		for nacc^ >= 8 {
			out[o^] = u8(acc^)
			o^ += 1
			acc^ >>= 8
			nacc^ -= 8
		}
	}
	d1 := dist_code(1)
	use_row := row > 0 && row <= WINDOW
	drow := use_row ? dist_code(u32(row)) : Code{}
	p := raw_data(data)
	dst := raw_data(out)
	n := len(data)
	i := 0
	for i < n {
		limit := min(n - i, MATCH_MAX)
		best, dist := 0, d1
		if i >= 1 && p[i] == p[i - 1] { best = same(&p[i], &p[i - 1], limit) }
		if use_row && i >= row && p[i] == p[i - row] && best < limit {
			if m := same(&p[i], &p[i - row], limit); m > best && m >= ROW_MATCH_MIN { best, dist = m, drow }
		}
		if best >= MATCH_MIN {
			c := len_codes[best]
			acc |= u64(c.bits) << nacc
			nacc += c.n
			acc |= u64(dist.bits) << nacc
			nacc += dist.n
			i += best
		} else {
			c := lit_codes[p[i]]
			acc |= u64(c.bits) << nacc
			nacc += c.n
			i += 1
		}
		flush(dst, &o, &acc, &nacc)
	}
	eob := lit_codes[END_OF_BLOCK]
	acc |= u64(eob.bits) << nacc
	nacc += eob.n
	flush(dst, &o, &acc, &nacc)
	if nacc > 0 {
		out[o] = u8(acc)
		o += 1
	}
	put :: proc(out: []u8, o: ^int, v: u32, big: bool) {
		for k in 0 ..< 4 {
			out[o^] = u8(v >> uint(big ? 24 - 8 * k : 8 * k))
			o^ += 1
		}
	}
	switch format {
	case .Zlib: put(out, &o, hash.adler32(data), true)
	case .Gzip:
		put(out, &o, hash.crc32(data), false)
		put(out, &o, u32(len(data)), false)
	case .Raw:
	}
	return out[:o]
}
