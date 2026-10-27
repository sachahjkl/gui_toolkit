// DEFLATE (RFC 1951) in its three wrappings, gzip (RFC 1952), zlib (RFC 1950) and raw, compressed and decompressed as
// streams: the input comes in chunks of any size, each push gives the output it allows at once. Pure Odin, no platform
// code, no C library (Odin's core library only inflates whole buffers). See docs/flate.md.
//
// Inflater: the header, then one block at a time from the bit where it starts: a block whose input has not all arrived
// is decoded again from its start with the next chunk (its partial output is not kept), so a push never waits for more
// than one block's input. Back references read the last 32 KiB of output. The trailer's CRC-32 / Adler-32 and size are
// checked; input after the end is an error. `limit` bounds what one push may make (a decompression bomb is refused).
//
// Deflater: LZ77 over a 32 KiB window kept across pushes (hash chains, no lazy matching). Each push is emitted as blocks
// of at most BLOCK_SYMBOLS symbols, each in the cheapest of the three block types (stored, fixed Huffman codes, dynamic
// Huffman codes made for that block), so its output is never held back beyond the last few bits of a byte. An empty
// final block and the trailer come at the end.
package flate

import "core:hash"

Format :: enum u8 { Gzip, Zlib, Raw }

Error :: enum u8 { None, Bad_Data, Junk_After_End, Truncated, Too_Large }

WINDOW :: 32 * 1024

////////////////////////////////
// Whole buffers

// `data` inflated at once. Too_Large when the output passes `limit` bytes (0: no bound).
inflate :: proc(format: Format, data: []u8, limit := 0, allocator := context.allocator) -> (out: []u8, err: Error) {
	z: Inflater
	inflater_init(&z, format, limit)
	defer inflater_destroy(&z)
	buf := make([dynamic]u8, allocator)
	err = inflate_push(&z, data, &buf)
	if err == .None { err = inflate_finish(&z) }
	if err != .None { delete(buf); return nil, err }
	return buf[:], .None
}

// `data` compressed at once.
deflate :: proc(format: Format, data: []u8, allocator := context.allocator) -> []u8 {
	d: Deflater
	deflater_init(&d, format)
	defer deflater_destroy(&d)
	buf := make([dynamic]u8, allocator)
	deflate_push(&d, data, &buf)
	deflate_finish(&d, &buf)
	return buf[:]
}

////////////////////////////////
// Tables

@(private, rodata) LEN_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private, rodata) LEN_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private, rodata) DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private, rodata) DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
@(private, rodata) CLEN_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// A canonical Huffman code (puff.c's representation): how many codes of each length, the symbols in code order.
@(private)
Huffman :: struct {
	count:  [16]u16,
	symbol: [288]u16,
}

// < 0: an over-subscribed set of lengths; > 0: an incomplete one (allowed for a single code only)
@(private)
huffman_build :: proc "contextless" (h: ^Huffman, lengths: []u8) -> (left: int) {
	h.count = {}
	for l in lengths { h.count[l] += 1 }
	if int(h.count[0]) == len(lengths) { return 0 }
	left = 1
	for i in 1 ..< 16 {
		left <<= 1
		left -= int(h.count[i])
		if left < 0 { return left }
	}
	offs: [16]u16
	for i in 1 ..< 15 { offs[i + 1] = offs[i] + h.count[i] }
	for l, sym in lengths {
		if l != 0 { h.symbol[offs[l]] = u16(sym); offs[l] += 1 }
	}
	return left
}

////////////////////////////////
// Inflating

@(private)
Inflate_State :: enum u8 { Header, Blocks, Trailer, Done }

Inflater :: struct {
	format:  Format,
	state:   Inflate_State,
	input:   [dynamic]u8,    // what has not been consumed whole (the current block starts in it)
	bit:     int,            // the next bit to read in `input`
	window:  [dynamic]u8,    // the last WINDOW bytes of output
	crc:     u32,
	adler:   u32,
	size:    u32,            // output length, modulo 2^32 (gzip's ISIZE)
	limit:   int,            // most output one push may make (0: no bound)
}

inflater_init :: proc(z: ^Inflater, format: Format, limit := 0, allocator := context.allocator) {
	z^ = Inflater{format = format, adler = 1, limit = limit}
	z.input = make([dynamic]u8, allocator)
	z.window = make([dynamic]u8, allocator)
}

inflater_destroy :: proc(z: ^Inflater) {
	delete(z.input)
	delete(z.window)
}

// The bit reader of one attempt: `short` once it ran past the input (the attempt is dropped and tried again later).
@(private)
Bits :: struct {
	data:  []u8,
	bit:   int,
	short: bool,
}

@(private)
need :: #force_inline proc(b: ^Bits, n: int) -> bool {
	if b.bit + n > len(b.data) * 8 { b.short = true; return false }
	return true
}

// n <= 24 bits, least significant first
@(private)
bits :: proc(b: ^Bits, n: int) -> u32 {
	if n == 0 { return 0 }
	if !need(b, n) { return 0 }
	at := b.bit >> 3
	v: u32
	for k in 0 ..< 4 {
		if at + k >= len(b.data) { break }
		v |= u32(b.data[at + k]) << uint(8 * k)
	}
	v >>= uint(b.bit & 7)
	b.bit += n
	return v & (1 << uint(n) - 1)
}

@(private)
decode :: proc(b: ^Bits, h: ^Huffman) -> int {
	code, first, index := 0, 0, 0
	for l in 1 ..< 16 {
		if !need(b, 1) { return -1 }
		code |= int((b.data[b.bit >> 3] >> uint(b.bit & 7)) & 1)
		b.bit += 1
		count := int(h.count[l])
		if code - count < first { return int(h.symbol[index + (code - first)]) }
		index += count
		first += count
		first <<= 1
		code <<= 1
	}
	return -2   // ran out of codes: bad data
}

// The fixed codes (RFC 1951 §3.2.6), for decoding and encoding: made once at start-up (no lazy init to race on).
@(private) fixed_len, fixed_dist: Huffman
@(private) fixed_lit_code, fixed_dist_code: Code

@(private, init)
make_fixed_codes :: proc "contextless" () {
	l: [288]u8
	for i in 0 ..< 288 { l[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8 }
	huffman_build(&fixed_len, l[:])
	d: [30]u8
	for i in 0 ..< 30 { d[i] = 5 }
	huffman_build(&fixed_dist, d[:])
	fixed_lit_code.length = l
	code_assign(&fixed_lit_code, 288)
	for i in 0 ..< 30 { fixed_dist_code.length[i] = 5 }
	code_assign(&fixed_dist_code, 30)
}

@(private)
fixed_codes :: proc() -> (^Huffman, ^Huffman) { return &fixed_len, &fixed_dist }

// The output of one block, in `out` (with the window before it for back references).
@(private)
block :: proc(b: ^Bits, z: ^Inflater, out: ^[dynamic]u8) -> (final: bool, err: Error) {
	final = bits(b, 1) == 1
	kind := bits(b, 2)
	if b.short { return }
	switch kind {
	case 0:
		b.bit = (b.bit + 7) &~ 7
		if !need(b, 32) { return }
		at := b.bit >> 3
		n := int(b.data[at]) | int(b.data[at + 1]) << 8
		nn := int(b.data[at + 2]) | int(b.data[at + 3]) << 8
		if n != (~nn & 0xFFFF) { return final, .Bad_Data }
		b.bit += 32
		if !need(b, n * 8) { return }
		at = b.bit >> 3
		append(out, ..b.data[at:at + n])
		b.bit += n * 8
		if z.limit > 0 && len(out) > z.limit { return final, .Too_Large }
		return
	case 1:
		lc, dc := fixed_codes()
		return final, codes(b, z, out, lc, dc)
	case 2:
		nlen := int(bits(b, 5)) + 257
		ndist := int(bits(b, 5)) + 1
		ncode := int(bits(b, 4)) + 4
		if b.short { return }
		if nlen > 286 || ndist > 30 { return final, .Bad_Data }
		lengths: [320]u8
		for i in 0 ..< ncode { lengths[CLEN_ORDER[i]] = u8(bits(b, 3)) }
		if b.short { return }
		lencode, distcode: Huffman
		if huffman_build(&lencode, lengths[:19]) != 0 { return final, .Bad_Data }
		i := 0
		for i < nlen + ndist {
			sym := decode(b, &lencode)
			if b.short { return }
			if sym < 0 { return final, .Bad_Data }
			if sym < 16 { lengths[i] = u8(sym); i += 1; continue }
			l: u8 = 0
			rep := 0
			switch sym {
			case 16:
				if i == 0 { return final, .Bad_Data }
				l = lengths[i - 1]
				rep = 3 + int(bits(b, 2))
			case 17: rep = 3 + int(bits(b, 3))
			case: rep = 11 + int(bits(b, 7))
			}
			if b.short { return }
			if i + rep > nlen + ndist { return final, .Bad_Data }
			for _ in 0 ..< rep { lengths[i] = l; i += 1 }
		}
		if lengths[256] == 0 { return final, .Bad_Data }
		left := huffman_build(&lencode, lengths[:nlen])
		if left < 0 || (left > 0 && nlen - int(lencode.count[0]) != 1) { return final, .Bad_Data }
		left = huffman_build(&distcode, lengths[nlen:nlen + ndist])
		if left < 0 || (left > 0 && ndist - int(distcode.count[0]) != 1) { return final, .Bad_Data }
		return final, codes(b, z, out, &lencode, &distcode)
	case:
		return final, .Bad_Data
	}
}

@(private)
codes :: proc(b: ^Bits, z: ^Inflater, out: ^[dynamic]u8, lencode, distcode: ^Huffman) -> Error {
	for {
		sym := decode(b, lencode)
		if b.short { return .None }
		if sym < 0 { return .Bad_Data }
		if sym < 256 {
			append(out, u8(sym))
			if z.limit > 0 && len(out) > z.limit { return .Too_Large }
			continue
		}
		if sym == 256 { return .None }
		sym -= 257
		if sym >= 29 { return .Bad_Data }
		length := int(LEN_BASE[sym]) + int(bits(b, int(LEN_EXTRA[sym])))
		ds := decode(b, distcode)
		if b.short { return .None }
		if ds < 0 || ds >= 30 { return .Bad_Data }
		dist := int(DIST_BASE[ds]) + int(bits(b, int(DIST_EXTRA[ds])))
		if b.short { return .None }
		have := len(z.window) + len(out)
		if dist > have { return .Bad_Data }
		for _ in 0 ..< length {
			// the byte `dist` back, in this block's output or in the window before it
			back := len(out) - dist
			c := back >= 0 ? out[back] : z.window[len(z.window) + back]
			append(out, c)
		}
		if z.limit > 0 && len(out) > z.limit { return .Too_Large }
	}
}

// Takes `input`; appends what it allows to `out`.
inflate_push :: proc(z: ^Inflater, input: []u8, out: ^[dynamic]u8) -> Error {
	append(&z.input, ..input)
	start := len(out)
	for {
		b := Bits{data = z.input[:], bit = z.bit}
		switch z.state {
		case .Header:
			ok, err := header(z, &b)
			if err != .None { return err }
			if !ok { return compact(z) }
			z.bit = b.bit
			z.state = .Blocks
		case .Blocks:
			produced := make([dynamic]u8, context.temp_allocator)
			final, err := block(&b, z, &produced)
			if err != .None { return err }
			if b.short { return compact(z) }
			if z.limit > 0 && len(out) - start + len(produced) > z.limit { return .Too_Large }
			append(out, ..produced[:])
			keep(z, produced[:])
			z.bit = b.bit
			if final {
				z.bit = (z.bit + 7) &~ 7
				z.state = .Trailer
			}
		case .Trailer:
			at := z.bit >> 3
			switch z.format {
			case .Gzip:
				if len(z.input) - at < 8 { return compact(z) }
				d := z.input[at:]
				crc := u32(d[0]) | u32(d[1]) << 8 | u32(d[2]) << 16 | u32(d[3]) << 24
				size := u32(d[4]) | u32(d[5]) << 8 | u32(d[6]) << 16 | u32(d[7]) << 24
				if crc != z.crc || size != z.size { return .Bad_Data }
				z.bit += 64
			case .Zlib:
				if len(z.input) - at < 4 { return compact(z) }
				d := z.input[at:]
				ad := u32(d[0]) << 24 | u32(d[1]) << 16 | u32(d[2]) << 8 | u32(d[3])
				if ad != z.adler { return .Bad_Data }
				z.bit += 32
			case .Raw:
			}
			z.state = .Done
		case .Done:
			if z.bit >> 3 < len(z.input) { return .Junk_After_End }
			return compact(z)
		}
	}
}

// The end of the input: Truncated when the data had not ended.
inflate_finish :: proc(z: ^Inflater) -> Error {
	return z.state == .Done ? .None : .Truncated
}

// Drops the input consumed whole.
@(private)
compact :: proc(z: ^Inflater) -> Error {
	n := z.bit >> 3
	if n > 0 {
		remove_range(&z.input, 0, n)
		z.bit -= n * 8
	}
	return .None
}

// Output made: the checksums, and the window keeps the last WINDOW bytes.
@(private)
keep :: proc(z: ^Inflater, out: []u8) {
	switch z.format {
	case .Gzip: z.crc = hash.crc32(out, z.crc)
	case .Zlib: z.adler = hash.adler32(out, z.adler)
	case .Raw:
	}
	z.size += u32(len(out))
	if len(out) >= WINDOW {
		clear(&z.window)
		append(&z.window, ..out[len(out) - WINDOW:])
		return
	}
	append(&z.window, ..out)
	if len(z.window) > 2 * WINDOW { remove_range(&z.window, 0, len(z.window) - WINDOW) }
}

// The gzip or zlib header: ok false while it has not all arrived.
@(private)
header :: proc(z: ^Inflater, b: ^Bits) -> (ok: bool, err: Error) {
	d := z.input[:]
	switch z.format {
	case .Raw: return true, .None
	case .Zlib:
		if len(d) < 2 { return false, .None }
		cmf, flg := d[0], d[1]
		if cmf & 0x0F != 8 || cmf >> 4 > 7 || (u16(cmf) << 8 | u16(flg)) % 31 != 0 || flg & 0x20 != 0 { return false, .Bad_Data }
		b.bit = 16
		return true, .None
	case .Gzip:
		if len(d) < 10 { return false, .None }
		if d[0] != 0x1F || d[1] != 0x8B || d[2] != 8 || d[3] & 0xE0 != 0 { return false, .Bad_Data }
		flags := d[3]
		at := 10
		if flags & 4 != 0 {   // FEXTRA
			if len(d) < at + 2 { return false, .None }
			at += 2 + (int(d[at]) | int(d[at + 1]) << 8)
		}
		for f in ([2]u8{8, 16}) {   // FNAME, FCOMMENT: zero-terminated
			if flags & f == 0 { continue }
			for {
				if at >= len(d) { return false, .None }
				at += 1
				if d[at - 1] == 0 { break }
			}
		}
		if flags & 2 != 0 { at += 2 }   // FHCRC
		if at > len(d) { return false, .None }
		b.bit = at * 8
		return true, .None
	}
	return false, .None
}

////////////////////////////////
// Deflating

Deflater :: struct {
	format:  Format,
	started: bool,
	window:  [dynamic]u8,    // the last input (up to WINDOW bytes before each push)
	head:    []i32,          // hash -> last position (in `window` coordinates + base)
	prev:    []i32,          // position -> previous position with the same hash (modulo WINDOW)
	base:    int,            // the absolute position of window[0]
	acc:     u64,            // bits not yet written
	nacc:    uint,
	crc:     u32,
	adler:   u32,
	size:    u32,
	syms:    [dynamic]u32,   // the symbols of the block being made (Symbol: a literal, or a match's length and distance)
}

// The most symbols in one block: a block's codes fit what it holds (smaller blocks adapt to changing data, bigger ones
// spend less on their code tables).
BLOCK_SYMBOLS :: 16 * 1024

@(private) HASH_BITS :: 15
@(private) MAX_CHAIN :: 64
@(private) MATCH_BIT :: u32(1) << 31

deflater_init :: proc(d: ^Deflater, format: Format, allocator := context.allocator) {
	d^ = Deflater{format = format, adler = 1}
	d.window = make([dynamic]u8, allocator)
	d.head = make([]i32, 1 << HASH_BITS, allocator)
	d.prev = make([]i32, WINDOW, allocator)
	d.syms = make([dynamic]u32, allocator)
	for &h in d.head { h = -1 }
}

deflater_destroy :: proc(d: ^Deflater) {
	delete(d.window)
	delete(d.head)
	delete(d.prev)
	delete(d.syms)
}

@(private)
put :: proc(d: ^Deflater, out: ^[dynamic]u8, v: u32, n: uint) {
	d.acc |= u64(v) << d.nacc
	d.nacc += n
	for d.nacc >= 8 {
		append(out, u8(d.acc))
		d.acc >>= 8
		d.nacc -= 8
	}
}

// A Huffman code is written from its most significant bit.
@(private)
put_code :: proc(d: ^Deflater, out: ^[dynamic]u8, code: u32, n: uint) {
	r: u32
	for i in 0 ..< n { r |= ((code >> i) & 1) << (n - 1 - i) }
	put(d, out, r, n)
}

@(private)
hash3 :: #force_inline proc(p: []u8, i: int) -> int {
	return int(((u32(p[i]) << 16 | u32(p[i + 1]) << 8 | u32(p[i + 2])) * 2654435761) >> (32 - HASH_BITS))
}

@(private)
start :: proc(d: ^Deflater, out: ^[dynamic]u8) {
	if d.started { return }
	d.started = true
	switch d.format {
	case .Gzip: append(out, 0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF)
	case .Zlib: append(out, 0x78, 0x9C)
	case .Raw:
	}
}

// The length and distance codes of a match (indices into LEN_BASE and DIST_BASE).
@(private)
len_index :: proc(length: int) -> int {
	li := 28
	for li > 0 && int(LEN_BASE[li]) > length { li -= 1 }
	return li
}

@(private)
dist_index :: proc(dist: int) -> int {
	di := 29
	for di > 0 && int(DIST_BASE[di]) > dist { di -= 1 }
	return di
}

// Takes `input`; appends its compressed form (one or more non-final blocks) to `out`.
deflate_push :: proc(d: ^Deflater, input: []u8, out: ^[dynamic]u8) {
	start(d, out)
	if len(input) == 0 { return }
	switch d.format {
	case .Gzip: d.crc = hash.crc32(input, d.crc)
	case .Zlib: d.adler = hash.adler32(input, d.adler)
	case .Raw:
	}
	d.size += u32(len(input))
	from := len(d.window)
	append(&d.window, ..input)
	w := d.window[:]
	clear(&d.syms)
	block_from := from
	i := from
	for i < len(w) {
		best_len, best_dist := 0, 0
		if i + 3 <= len(w) {
			h := hash3(w, i)
			cand := int(d.head[h]) - d.base
			for chain := 0; chain < MAX_CHAIN && cand >= 0 && i - cand <= WINDOW - 262 && cand < i; chain += 1 {
				l := 0
				for l < 258 && i + l < len(w) && w[cand + l] == w[i + l] { l += 1 }
				if l > best_len { best_len, best_dist = l, i - cand; if l == 258 { break } }
				nxt := int(d.prev[(cand + d.base) % WINDOW]) - d.base
				if nxt >= cand { break }
				cand = nxt
			}
		}
		n := best_len >= 3 ? best_len : 1
		if best_len >= 3 { append(&d.syms, MATCH_BIT | u32(best_len) << 16 | u32(best_dist)) } else { append(&d.syms, u32(w[i])) }
		for k in 0 ..< n {
			p := i + k
			if p + 3 <= len(w) {
				h := hash3(w, p)
				d.prev[(p + d.base) % WINDOW] = d.head[h]
				d.head[h] = i32(p + d.base)
			}
		}
		i += n
		if len(d.syms) >= BLOCK_SYMBOLS || i >= len(w) {
			emit_block(d, out, w[block_from:i])
			clear(&d.syms)
			block_from = i
		}
	}
	// the window keeps the last WINDOW bytes
	if len(d.window) > WINDOW {
		drop := len(d.window) - WINDOW
		remove_range(&d.window, 0, drop)
		d.base += drop
	}
}

// The end: an empty final block, the remaining bits, the trailer.
deflate_finish :: proc(d: ^Deflater, out: ^[dynamic]u8) {
	start(d, out)
	put(d, out, 1, 1)   // BFINAL
	put(d, out, 1, 2)   // fixed
	put_code(d, out, 0, 7)   // end of block (fixed code of 256)
	if d.nacc > 0 { put(d, out, 0, 8 - d.nacc) }
	switch d.format {
	case .Gzip:
		for v in ([2]u32{d.crc, d.size}) { append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)) }
	case .Zlib:
		a := d.adler
		append(out, u8(a >> 24), u8(a >> 16), u8(a >> 8), u8(a))
	case .Raw:
	}
}

////////////////////////////////
// Blocks

// The code lengths and codes of one alphabet (canonical: RFC 1951 §3.2.2).
@(private)
Code :: struct {
	length: [288]u8,
	code:   [288]u16,
}

@(private)
code_assign :: proc "contextless" (c: ^Code, n: int) {
	count: [16]int
	for i in 0 ..< n { count[c.length[i]] += 1 }
	count[0] = 0
	next: [16]int
	v := 0
	for bits in 1 ..< 16 {
		v = (v + count[bits - 1]) << 1
		next[bits] = v
	}
	for i in 0 ..< n {
		if l := c.length[i]; l != 0 { c.code[i] = u16(next[l]); next[l] += 1 }
	}
}

@(private)
fixed_code :: proc() -> (^Code, ^Code) { return &fixed_lit_code, &fixed_dist_code }

// Huffman code lengths of `freq` (n symbols), none longer than `limit`: a Huffman tree, its frequencies halved (and
// kept at least 1 where non-zero) while it is too deep. At least two symbols get a code (a single code is incomplete,
// which some decoders refuse), symbol 0 and 1 taking the empty places.
@(private)
huffman_lengths :: proc(freq: []u32, lengths: []u8, limit: int) {
	n := len(freq)
	f := make([]u32, n, context.temp_allocator)
	copy(f, freq)
	used := 0
	for v in f { if v != 0 { used += 1 } }
	for k := 0; used < 2 && k < n; k += 1 { if f[k] == 0 { f[k] = 1; used += 1 } }
	// nodes 0..n-1 the symbols, then the inner nodes
	weight := make([]u64, 2 * n, context.temp_allocator)
	parent := make([]int, 2 * n, context.temp_allocator)
	alive := make([]bool, 2 * n, context.temp_allocator)
	for {
		nodes := n
		for i in 0 ..< n { weight[i], alive[i], parent[i] = u64(f[i]), f[i] != 0, -1 }
		for left := used; left > 1; left -= 1 {
			a, b := -1, -1
			for i in 0 ..< nodes {
				if !alive[i] { continue }
				if a < 0 || weight[i] < weight[a] { b = a; a = i } else if b < 0 || weight[i] < weight[b] { b = i }
			}
			weight[nodes], alive[nodes], parent[nodes] = weight[a] + weight[b], true, -1
			alive[a], alive[b] = false, false
			parent[a], parent[b] = nodes, nodes
			nodes += 1
		}
		deepest := 0
		for i in 0 ..< n {
			lengths[i] = 0
			if f[i] == 0 { continue }
			depth := 0
			for p := parent[i]; p >= 0; p = parent[p] { depth += 1 }
			lengths[i] = u8(depth)
			deepest = max(deepest, depth)
		}
		if deepest <= limit { return }
		for &v in f { if v != 0 { v = max(v / 2, 1) } }
	}
}

// One block of `syms` (the symbols of `raw`), in the cheapest of stored, fixed and dynamic codes.
@(private)
emit_block :: proc(d: ^Deflater, out: ^[dynamic]u8, raw: []u8) {
	lit_freq: [286]u32
	dist_freq: [30]u32
	extra_bits := 0
	for s in d.syms {
		if s & MATCH_BIT == 0 { lit_freq[s] += 1; continue }
		length, dist := int((s >> 16) & 0x1FF), int(s & 0xFFFF)
		li, di := len_index(length), dist_index(dist)
		lit_freq[257 + li] += 1
		dist_freq[di] += 1
		extra_bits += int(LEN_EXTRA[li]) + int(DIST_EXTRA[di])
	}
	lit_freq[256] = 1

	// dynamic: the codes, then the code lengths run-length coded with the code length alphabet
	dyn_lit, dyn_dist: Code
	huffman_lengths(lit_freq[:], dyn_lit.length[:286], 15)
	huffman_lengths(dist_freq[:], dyn_dist.length[:30], 15)
	code_assign(&dyn_lit, 286)
	code_assign(&dyn_dist, 30)
	hlit := 286
	for hlit > 257 && dyn_lit.length[hlit - 1] == 0 { hlit -= 1 }
	hdist := 30
	for hdist > 1 && dyn_dist.length[hdist - 1] == 0 { hdist -= 1 }
	all: [316]u8
	copy(all[:hlit], dyn_lit.length[:hlit])
	copy(all[hlit:hlit + hdist], dyn_dist.length[:hdist])
	runs: [316][2]u8   // (symbol of the code length alphabet, its extra bits' value)
	nruns := 0
	for i := 0; i < hlit + hdist; {
		l := all[i]
		r := 1
		for i + r < hlit + hdist && all[i + r] == l { r += 1 }
		i += r
		if l == 0 {
			for r >= 11 { k := min(r, 138); runs[nruns] = {18, u8(k - 11)}; nruns += 1; r -= k }
			if r >= 3 { runs[nruns] = {17, u8(r - 3)}; nruns += 1; r = 0 }
		} else {
			runs[nruns] = {l, 0}; nruns += 1; r -= 1
			for r >= 3 { k := min(r, 6); runs[nruns] = {16, u8(k - 3)}; nruns += 1; r -= k }
		}
		for _ in 0 ..< r { runs[nruns] = {l, 0}; nruns += 1 }
	}
	cl_freq: [19]u32
	for k in 0 ..< nruns { cl_freq[runs[k][0]] += 1 }
	cl: Code
	huffman_lengths(cl_freq[:], cl.length[:19], 7)
	code_assign(&cl, 19)
	hclen := 19
	for hclen > 4 && cl.length[CLEN_ORDER[hclen - 1]] == 0 { hclen -= 1 }

	RUN_EXTRA := [19]int{16 = 2, 17 = 3, 18 = 7}
	dyn_cost := 3 + 5 + 5 + 4 + 3 * hclen + extra_bits
	for k in 0 ..< nruns { dyn_cost += int(cl.length[runs[k][0]]) + RUN_EXTRA[runs[k][0]] }
	fix_lit, fix_dist := fixed_code()
	fix_cost := 3 + extra_bits
	for v, s in lit_freq {
		dyn_cost += int(v) * int(dyn_lit.length[s])
		fix_cost += int(v) * int(fix_lit.length[s])
	}
	for v, s in dist_freq {
		dyn_cost += int(v) * int(dyn_dist.length[s])
		fix_cost += int(v) * 5
	}
	stored_cost := (len(raw) + 65534) / 65535 * (3 + 7 + 32) + len(raw) * 8   // (at most: the padding to a byte)

	switch {
	case stored_cost < fix_cost && stored_cost < dyn_cost:
		for at := 0; at < len(raw) || at == 0; {
			n := min(len(raw) - at, 65535)
			put(d, out, 0, 1)
			put(d, out, 0, 2)
			if d.nacc > 0 { put(d, out, 0, 8 - d.nacc) }
			append(out, u8(n), u8(n >> 8), u8(~n), u8(~n >> 8))
			append(out, ..raw[at:at + n])
			at += n
			if n == 0 { break }
		}
	case dyn_cost < fix_cost:
		put(d, out, 0, 1)
		put(d, out, 2, 2)
		put(d, out, u32(hlit - 257), 5)
		put(d, out, u32(hdist - 1), 5)
		put(d, out, u32(hclen - 4), 4)
		for k in 0 ..< hclen { put(d, out, u32(cl.length[CLEN_ORDER[k]]), 3) }
		for k in 0 ..< nruns {
			s := runs[k][0]
			put_code(d, out, u32(cl.code[s]), uint(cl.length[s]))
			if RUN_EXTRA[s] > 0 { put(d, out, u32(runs[k][1]), uint(RUN_EXTRA[s])) }
		}
		emit_symbols(d, out, &dyn_lit, &dyn_dist)
	case:
		put(d, out, 0, 1)
		put(d, out, 1, 2)
		emit_symbols(d, out, fix_lit, fix_dist)
	}
}

@(private)
emit_symbols :: proc(d: ^Deflater, out: ^[dynamic]u8, lit, dist: ^Code) {
	for s in d.syms {
		if s & MATCH_BIT == 0 { put_code(d, out, u32(lit.code[s]), uint(lit.length[s])); continue }
		length, distance := int((s >> 16) & 0x1FF), int(s & 0xFFFF)
		li, di := len_index(length), dist_index(distance)
		put_code(d, out, u32(lit.code[257 + li]), uint(lit.length[257 + li]))
		put(d, out, u32(length - int(LEN_BASE[li])), uint(LEN_EXTRA[li]))
		put_code(d, out, u32(dist.code[di]), uint(dist.length[di]))
		put(d, out, u32(distance - int(DIST_BASE[di])), uint(DIST_EXTRA[di]))
	}
	put_code(d, out, u32(lit.code[256]), uint(lit.length[256]))
}
