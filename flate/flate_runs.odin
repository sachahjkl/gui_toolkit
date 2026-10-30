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
lit_codes: [288]Code
@(private = "file")
len_codes: [259]Code   // the code and extra bits of a match's length, as one
@(private = "file")
RUNS_READY :: 1
@(private = "file")
runs_ready: i32

@(private = "file")
reverse :: proc "contextless" (v, n: u32) -> (r: u32) {
	for i in 0 ..< n { if v & (1 << i) != 0 { r |= 1 << (n - 1 - i) } }
	return
}

@(private = "file")
runs_tables :: proc "contextless" () {
	if intrinsics.atomic_load(&runs_ready) == RUNS_READY { return }
	// (made the same by any thread that gets here at once: the last store changes nothing)
	for i in 0 ..< 288 {
		v := u32(i)
		switch {
		case i < 144: lit_codes[i] = {reverse(0x30 + v, 8), 8}
		case i < 256: lit_codes[i] = {reverse(0x190 + v - 144, 9), 9}
		case i < 280: lit_codes[i] = {reverse(v - 256, 7), 7}
		case:         lit_codes[i] = {reverse(0xC0 + v - 280, 8), 8}
		}
	}
	BASE := [29]u32{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
	EXTRA := [29]u32{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
	for l in 3 ..= 258 {
		k := 28
		for BASE[k] > u32(l) { k -= 1 }
		c := lit_codes[257 + k]
		len_codes[l] = {c.bits | (u32(l) - BASE[k]) << c.n, c.n + EXTRA[k]}
	}
	intrinsics.atomic_store(&runs_ready, RUNS_READY)
}

// A distance's code and extra bits, as one.
@(private = "file")
dist_code :: proc "contextless" (dist: u32) -> Code {
	BASE := [30]u32{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
	EXTRA := [30]u32{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
	k := 29
	for BASE[k] > dist { k -= 1 }
	return {reverse(u32(k), 5) | (dist - BASE[k]) << 5, 5 + EXTRA[k]}
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
	runs_tables()
	out := make([]u8, len(data) + len(data) / 8 + 64, allocator)
	o := 0
	switch format {
	case .Zlib:
		out[0], out[1] = 0x78, 0x01
		o = 2
	case .Gzip:
		h := [10]u8{0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255}
		copy(out, h[:])
		o = 10
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
		limit := min(n - i, 258)
		best, dist := 0, d1
		if i >= 1 && p[i] == p[i - 1] { best = same(&p[i], &p[i - 1], limit) }
		if use_row && i >= row && p[i] == p[i - row] && best < limit {
			if m := same(&p[i], &p[i - row], limit); m > best && m >= 4 { best, dist = m, drow }
		}
		if best >= 3 {
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
	eob := lit_codes[256]
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
