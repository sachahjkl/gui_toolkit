// DEFLATE (RFC 1951) in its three wrappings, gzip (RFC 1952), zlib (RFC 1950) and raw, compressed and decompressed as
// streams: the input comes in chunks of any size, each push gives the output it allows at once. Pure Odin, no platform
// code, no C library (Odin's core library only inflates whole buffers). See docs/flate.md.
//
// Inflater: the header, then one block at a time: a part of a block's start whose input has not all arrived (its code
// tables, a stored block) is read again from there with the next chunk; the symbols of its codes are output as they
// arrive, one complete symbol at a time, and decoding goes on from the last one. Back references read the last 32 KiB of
// output. The trailer's CRC-32 / Adler-32 and size are checked; input after the end is an error. `limit` bounds what one
// push may make (a decompression bomb is refused).
//
// Deflater: LZ77 over a 32 KiB window kept across pushes (hash chains, no lazy matching). Each push is emitted as blocks
// of at most BLOCK_SYMBOLS symbols, each in the cheapest of the three block types (stored, fixed Huffman codes, dynamic
// Huffman codes made for that block), so its output is never held back beyond the last few bits of a byte. An empty
// final block and the trailer come at the end.
//
// deflate_runs: a whole buffer at a high rate, for what repeats in known ways (the rows of a picture): flate_runs.odin.
package flate

import "base:intrinsics"
import "core:hash"
import "core:simd"

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

// What RFC 1951 fixes: the alphabets and the codes.
@(private) LIT_SYMBOLS :: 288        // literal / length alphabet, with the two symbols the fixed code has and no data uses
@(private) LIT_SYMBOLS_USED :: 286
@(private) END_OF_BLOCK :: 256
@(private) LEN_SYMBOL_FIRST :: 257   // the symbol of LEN_BASE[0]
@(private) LEN_CODES :: 29
@(private) DIST_CODES :: 30
@(private) CLEN_CODES :: 19          // code length alphabet
@(private) MAX_CODE_BITS :: 15
@(private) CLEN_MAX_CODE_BITS :: 7
@(private) HLIT_MIN :: 257           // what HLIT counts from
@(private) HCLEN_MIN :: 4            // what HCLEN counts from
@(private) MATCH_MIN :: 3
@(private) MATCH_MAX :: 258
@(private) STORED_MAX_BYTES :: 65535
// The first literal with a code of 9 bits, of 7 bits (the rest of the lengths), of 8 bits again; 5 bits for a distance.
@(private) FIXED_9BIT_FIRST :: 144
@(private) FIXED_7BIT_FIRST :: 256
@(private) FIXED_8BIT_FIRST :: 280
@(private) FIXED_DIST_BITS :: 5
// The repeat symbols of the code length alphabet and the runs they stand for.
@(private) CLEN_REPEAT_PREV :: 16
@(private) CLEN_REPEAT_ZERO :: 17
@(private) CLEN_REPEAT_ZERO_LONG :: 18
@(private) REPEAT_MIN :: 3
@(private) REPEAT_PREV_MAX :: 6
@(private) REPEAT_ZERO_LONG_MIN :: 11
@(private) REPEAT_ZERO_LONG_MAX :: 138
@(private) GZIP_HEADER_BYTES :: 10
// Room for the code lengths of one dynamic block (at most LIT_SYMBOLS_USED + DIST_CODES; the size puff.c has).
@(private) CODE_LENGTHS_CAP :: 320

@(private, rodata) LEN_BASE := [LEN_CODES]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private, rodata) LEN_EXTRA := [LEN_CODES]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private, rodata) DIST_BASE := [DIST_CODES]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private, rodata) DIST_EXTRA := [DIST_CODES]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
@(private, rodata) CLEN_ORDER := [CLEN_CODES]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// A canonical Huffman code (puff.c's representation): how many codes of each length, the symbols in code order.
@(private)
Huffman :: struct {
	count:  [MAX_CODE_BITS + 1]u16,
	symbol: [LIT_SYMBOLS]u16,
}

// < 0: an over-subscribed set of lengths; > 0: an incomplete one (allowed for a single code only)
@(private)
huffman_build :: proc "contextless" (h: ^Huffman, lengths: []u8) -> (left: int) {
	h.count = {}
	for l in lengths { h.count[l] += 1 }
	if int(h.count[0]) == len(lengths) { return 0 }
	left = 1
	for i in 1 ..< MAX_CODE_BITS + 1 {
		left <<= 1
		left -= int(h.count[i])
		if left < 0 { return left }
	}
	offs: [MAX_CODE_BITS + 1]u16
	for i in 1 ..< MAX_CODE_BITS { offs[i + 1] = offs[i] + h.count[i] }
	for l, sym in lengths {
		if l != 0 { h.symbol[offs[l]] = u16(sym); offs[l] += 1 }
	}
	return left
}

////////////////////////////////
// Inflating

// Failed: a push answered an error; nothing more comes of the stream, every later call says the same.
@(private)
Inflate_State :: enum u8 { Header, Blocks, Codes, Trailer, Done, Failed }

Inflater :: struct {
	format:  Format,
	state:   Inflate_State,
	failure: Error,          // Failed: why
	input:   [dynamic]u8,    // what has not been consumed whole (the current block starts in it)
	bit:     int,            // the next bit to read in `input`
	window:  [dynamic]u8,    // the last WINDOW bytes of output
	crc:     u32,
	adler:   u32,
	size:    u32,            // output length, modulo 2^32 (gzip's ISIZE)
	limit:   int,            // most output one push may make (0: no bound)
	final:   bool,           // the current block is the last
	lit:     Huffman,        // the codes of the current block
	dist:    Huffman,
	made:    [dynamic]u8,    // the output of the current step of a push
}

// The output of one step of a push, at most about this: what is kept between pushes, and the window catches up as it goes.
@(private) INFLATE_STEP_BYTES :: 1 << 20

inflater_init :: proc(z: ^Inflater, format: Format, limit := 0, allocator := context.allocator) {
	z^ = Inflater{format = format, adler = 1, limit = limit}
	z.input = make([dynamic]u8, allocator)
	z.window = make([dynamic]u8, allocator)
	z.made = make([dynamic]u8, allocator)
}

inflater_destroy :: proc(z: ^Inflater) {
	delete(z.input)
	delete(z.window)
	delete(z.made)
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
	for l in 1 ..< MAX_CODE_BITS + 1 {
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
	l: [LIT_SYMBOLS]u8
	for i in 0 ..< LIT_SYMBOLS { l[i] = i < FIXED_9BIT_FIRST ? 8 : i < FIXED_7BIT_FIRST ? 9 : i < FIXED_8BIT_FIRST ? 7 : 8 }
	huffman_build(&fixed_len, l[:])
	d: [DIST_CODES]u8
	for i in 0 ..< DIST_CODES { d[i] = FIXED_DIST_BITS }
	huffman_build(&fixed_dist, d[:])
	fixed_lit_code.length = l
	code_assign(&fixed_lit_code, LIT_SYMBOLS)
	for i in 0 ..< DIST_CODES { fixed_dist_code.length[i] = FIXED_DIST_BITS }
	code_assign(&fixed_dist_code, DIST_CODES)
}

// The start of a block: a stored block's bytes go to `out`; `coded`: its codes are ready for `codes`.
@(private)
block :: proc(b: ^Bits, z: ^Inflater, out: ^[dynamic]u8) -> (coded: bool, err: Error) {
	z.final = bits(b, 1) == 1
	kind := bits(b, 2)
	if b.short { return }
	switch kind {
	case 0:
		b.bit = (b.bit + 7) &~ 7
		if !need(b, 32) { return }
		at := b.bit >> 3
		n := int(b.data[at]) | int(b.data[at + 1]) << 8
		nn := int(b.data[at + 2]) | int(b.data[at + 3]) << 8
		if n != (~nn & 0xFFFF) { return false, .Bad_Data }
		b.bit += 32
		if !need(b, n * 8) { return }
		at = b.bit >> 3
		append(out, ..b.data[at:at + n])
		b.bit += n * 8
		if z.limit > 0 && len(out) > z.limit { return false, .Too_Large }
		return
	case 1:
		z.lit, z.dist = fixed_len, fixed_dist
		return true, .None
	case 2:
		nlen := int(bits(b, 5)) + HLIT_MIN
		ndist := int(bits(b, 5)) + 1
		ncode := int(bits(b, 4)) + HCLEN_MIN
		if b.short { return }
		if nlen > LIT_SYMBOLS_USED || ndist > DIST_CODES { return false, .Bad_Data }
		lengths: [CODE_LENGTHS_CAP]u8
		for i in 0 ..< ncode { lengths[CLEN_ORDER[i]] = u8(bits(b, 3)) }
		if b.short { return }
		lencode: Huffman
		if huffman_build(&lencode, lengths[:CLEN_CODES]) != 0 { return false, .Bad_Data }
		i := 0
		for i < nlen + ndist {
			sym := decode(b, &lencode)
			if b.short { return }
			if sym < 0 { return false, .Bad_Data }
			if sym < CLEN_REPEAT_PREV { lengths[i] = u8(sym); i += 1; continue }
			l: u8 = 0
			rep := 0
			switch sym {
			case CLEN_REPEAT_PREV:
				if i == 0 { return false, .Bad_Data }
				l = lengths[i - 1]
				rep = REPEAT_MIN + int(bits(b, 2))
			case CLEN_REPEAT_ZERO: rep = REPEAT_MIN + int(bits(b, 3))
			case: rep = REPEAT_ZERO_LONG_MIN + int(bits(b, 7))
			}
			if b.short { return }
			if i + rep > nlen + ndist { return false, .Bad_Data }
			for _ in 0 ..< rep { lengths[i] = l; i += 1 }
		}
		if lengths[END_OF_BLOCK] == 0 { return false, .Bad_Data }
		left := huffman_build(&z.lit, lengths[:nlen])
		if left < 0 || (left > 0 && nlen - int(z.lit.count[0]) != 1) { return false, .Bad_Data }
		left = huffman_build(&z.dist, lengths[nlen:nlen + ndist])
		if left < 0 || (left > 0 && ndist - int(z.dist.count[0]) != 1) { return false, .Bad_Data }
		return true, .None
	case:
		return false, .Bad_Data
	}
}

// The symbols of the current block, into `out` (the window before it for back references), up to about
// INFLATE_STEP_BYTES. `done`: the end of the block came. When the input ends in a symbol, `b` stays at its start, short.
@(private)
codes :: proc(b: ^Bits, z: ^Inflater, out: ^[dynamic]u8) -> (done: bool, err: Error) {
	for len(out) < INFLATE_STEP_BYTES {
		start := b.bit
		sym := decode(b, &z.lit)
		if b.short { b.bit = start; return false, .None }
		if sym < 0 { return false, .Bad_Data }
		if sym < END_OF_BLOCK {
			append(out, u8(sym))
			if z.limit > 0 && len(out) > z.limit { return false, .Too_Large }
			continue
		}
		if sym == END_OF_BLOCK { return true, .None }
		sym -= LEN_SYMBOL_FIRST
		if sym >= LEN_CODES { return false, .Bad_Data }
		length := int(LEN_BASE[sym]) + int(bits(b, int(LEN_EXTRA[sym])))
		ds := decode(b, &z.dist)
		if b.short { b.bit = start; return false, .None }
		if ds < 0 || ds >= DIST_CODES { return false, .Bad_Data }
		dist := int(DIST_BASE[ds]) + int(bits(b, int(DIST_EXTRA[ds])))
		if b.short { b.bit = start; return false, .None }
		have := len(z.window) + len(out)
		if dist > have { return false, .Bad_Data }
		for _ in 0 ..< length {
			// the byte `dist` back, in this block's output or in the window before it
			back := len(out) - dist
			c := back >= 0 ? out[back] : z.window[len(z.window) + back]
			append(out, c)
		}
		if z.limit > 0 && len(out) > z.limit { return false, .Too_Large }
	}
	return false, .None
}

// The end of the current block: the next one, or the trailer.
@(private)
block_end :: proc(z: ^Inflater) {
	z.state = .Blocks
	if z.final {
		z.bit = (z.bit + 7) &~ 7
		z.state = .Trailer
	}
}

// Takes `input`; appends what it allows to `out`. An error ends the stream.
inflate_push :: proc(z: ^Inflater, input: []u8, out: ^[dynamic]u8) -> Error {
	if z.state == .Failed { return z.failure }
	err := inflate_steps(z, input, out)
	if err != .None { z.state, z.failure = .Failed, err }
	return err
}

@(private)
inflate_steps :: proc(z: ^Inflater, input: []u8, out: ^[dynamic]u8) -> Error {
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
			clear(&z.made)
			coded, err := block(&b, z, &z.made)
			if err != .None { return err }
			if b.short { return compact(z) }
			if z.limit > 0 && len(out) - start + len(z.made) > z.limit { return .Too_Large }
			append(out, ..z.made[:])
			keep(z, z.made[:])
			z.bit = b.bit
			if coded { z.state = .Codes } else { block_end(z) }
		case .Codes:
			clear(&z.made)
			done, err := codes(&b, z, &z.made)
			if err != .None { return err }
			if z.limit > 0 && len(out) - start + len(z.made) > z.limit { return .Too_Large }
			append(out, ..z.made[:])
			keep(z, z.made[:])
			z.bit = b.bit
			if b.short { return compact(z) }
			if done { block_end(z) }
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
		case .Failed:
			return z.failure
		}
	}
}

// The end of the input: Truncated when the data had not ended, what went wrong when a push failed.
inflate_finish :: proc(z: ^Inflater) -> Error {
	#partial switch z.state {
	case .Done:   return .None
	case .Failed: return z.failure
	}
	return .Truncated
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
		if len(d) < GZIP_HEADER_BYTES { return false, .None }
		if d[0] != 0x1F || d[1] != 0x8B || d[2] != 8 || d[3] & 0xE0 != 0 { return false, .Bad_Data }
		flags := d[3]
		at := GZIP_HEADER_BYTES
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

// Fresh -> Writing (the header is out) -> Finished (the trailer is out: what follows would be after the end of the stream).
@(private)
Deflate_State :: enum u8 { Fresh, Writing, Finished }

Deflater :: struct {
	format:  Format,
	state:   Deflate_State,
	window:  [dynamic]u8,    // the last input (up to WINDOW bytes before each push)
	head:    []i64,          // hash -> last position (in `window` coordinates + base)
	prev:    []i64,          // position -> previous position with the same hash (modulo WINDOW)
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
// A match symbol: MATCH_BIT, then its length, then its distance.
@(private) SYM_LEN_SHIFT :: 16
@(private) SYM_LEN_MASK :: 0x1FF
@(private) SYM_DIST_MASK :: 0xFFFF
// The multiplicative hash of Knuth: 2^32 / the golden ratio.
@(private) HASH_MULTIPLIER :: 2654435761
// How far inside the window a match must start (MIN_LOOKAHEAD of zlib: MATCH_MAX + MATCH_MIN + 1).
@(private) MATCH_LOOKAHEAD :: 262

deflater_init :: proc(d: ^Deflater, format: Format, allocator := context.allocator) {
	d^ = Deflater{format = format, adler = 1}
	d.window = make([dynamic]u8, allocator)
	d.head = make([]i64, 1 << HASH_BITS, allocator)
	d.prev = make([]i64, WINDOW, allocator)
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
	return int(((u32(p[i]) << 16 | u32(p[i + 1]) << 8 | u32(p[i + 2])) * HASH_MULTIPLIER) >> (32 - HASH_BITS))
}

@(private)
start :: proc(d: ^Deflater, out: ^[dynamic]u8) {
	if d.state != .Fresh { return }
	d.state = .Writing
	switch d.format {
	case .Gzip: append(out, 0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF)
	case .Zlib: append(out, 0x78, 0x9C)
	case .Raw:
	}
}

// The length and distance codes of a match (indices into LEN_BASE and DIST_BASE).
@(private)
len_index :: proc(length: int) -> int {
	li := LEN_CODES - 1
	for li > 0 && int(LEN_BASE[li]) > length { li -= 1 }
	return li
}

@(private)
dist_index :: proc(dist: int) -> int {
	di := DIST_CODES - 1
	for di > 0 && int(DIST_BASE[di]) > dist { di -= 1 }
	return di
}

// How far p and q are the same, up to `limit` bytes: a register of bytes at once, then the place of the first that differs.
@(private)
same :: #force_inline proc "contextless" (p, q: [^]u8, limit: int) -> int #no_bounds_check {
	LANES :: 16
	Bytes :: #simd[LANES]u8
	n := 0
	for ; n + LANES <= limit; n += LANES {
		a := intrinsics.unaligned_load((^Bytes)(&p[n]))
		b := intrinsics.unaligned_load((^Bytes)(&q[n]))
		differ := transmute(u16)simd.extract_lsbs(simd.lanes_ne(a, b))
		if differ != 0 { return n + int(intrinsics.count_trailing_zeros(differ)) }
	}
	for n < limit && p[n] == q[n] { n += 1 }
	return n
}

// Takes `input`; appends its compressed form (one or more non-final blocks) to `out`.
deflate_push :: proc(d: ^Deflater, input: []u8, out: ^[dynamic]u8) {
	if d.state == .Finished { return }
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
		if i + MATCH_MIN <= len(w) {
			h := hash3(w, i)
			cand := int(d.head[h]) - d.base
			for chain := 0; chain < MAX_CHAIN && cand >= 0 && i - cand <= WINDOW - MATCH_LOOKAHEAD && cand < i; chain += 1 {
				l := same(&w[i], &w[cand], min(MATCH_MAX, len(w) - i))
				if l > best_len { best_len, best_dist = l, i - cand; if l == MATCH_MAX { break } }
				nxt := int(d.prev[(cand + d.base) % WINDOW]) - d.base
				if nxt >= cand { break }
				cand = nxt
			}
		}
		n := best_len >= MATCH_MIN ? best_len : 1
		if best_len >= MATCH_MIN { append(&d.syms, MATCH_BIT | u32(best_len) << SYM_LEN_SHIFT | u32(best_dist)) } else { append(&d.syms, u32(w[i])) }
		for k in 0 ..< n {
			p := i + k
			if p + MATCH_MIN <= len(w) {
				h := hash3(w, p)
				d.prev[(p + d.base) % WINDOW] = d.head[h]
				d.head[h] = i64(p + d.base)
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

// The end: an empty final block, the remaining bits, the trailer. Once only: after it, nothing more is written.
deflate_finish :: proc(d: ^Deflater, out: ^[dynamic]u8) {
	if d.state == .Finished { return }
	start(d, out)
	d.state = .Finished
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
	length: [LIT_SYMBOLS]u8,
	code:   [LIT_SYMBOLS]u16,
}

@(private)
code_assign :: proc "contextless" (c: ^Code, n: int) {
	count: [MAX_CODE_BITS + 1]int
	for i in 0 ..< n { count[c.length[i]] += 1 }
	count[0] = 0
	next: [MAX_CODE_BITS + 1]int
	v := 0
	for bits in 1 ..< MAX_CODE_BITS + 1 {
		v = (v + count[bits - 1]) << 1
		next[bits] = v
	}
	for i in 0 ..< n {
		if l := c.length[i]; l != 0 { c.code[i] = u16(next[l]); next[l] += 1 }
	}
}

// Huffman code lengths of `freq` (n symbols), none longer than `limit`: a Huffman tree, its frequencies halved (and
// kept at least 1 where non-zero) while it is too deep. At least two symbols get a code (a single code is incomplete,
// which some decoders refuse), symbol 0 and 1 taking the empty places.
@(private)
huffman_lengths :: proc(freq: []u32, lengths: []u8, limit: int) {
	n := len(freq)
	assert(n <= LIT_SYMBOLS_USED)
	f: [LIT_SYMBOLS_USED]u32
	copy(f[:], freq)
	used := 0
	for v in f { if v != 0 { used += 1 } }
	for k := 0; used < 2 && k < n; k += 1 { if f[k] == 0 { f[k] = 1; used += 1 } }
	// nodes 0..n-1 the symbols, then the inner nodes
	weight: [2 * LIT_SYMBOLS_USED]u64
	parent: [2 * LIT_SYMBOLS_USED]int
	alive: [2 * LIT_SYMBOLS_USED]bool
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

// The code lengths `all` run-length coded with the code length alphabet: (symbol, its extra bits' value). Returns how many.
@(private)
clen_runs :: proc(all: []u8, runs: [][2]u8) -> (nruns: int) {
	for i := 0; i < len(all); {
		l := all[i]
		r := 1
		for i + r < len(all) && all[i + r] == l { r += 1 }
		i += r
		if l == 0 {
			for r >= REPEAT_ZERO_LONG_MIN { k := min(r, REPEAT_ZERO_LONG_MAX); runs[nruns] = {CLEN_REPEAT_ZERO_LONG, u8(k - REPEAT_ZERO_LONG_MIN)}; nruns += 1; r -= k }
			if r >= REPEAT_MIN { runs[nruns] = {CLEN_REPEAT_ZERO, u8(r - REPEAT_MIN)}; nruns += 1; r = 0 }
		} else {
			runs[nruns] = {l, 0}; nruns += 1; r -= 1
			for r >= REPEAT_MIN { k := min(r, REPEAT_PREV_MAX); runs[nruns] = {CLEN_REPEAT_PREV, u8(k - REPEAT_MIN)}; nruns += 1; r -= k }
		}
		for _ in 0 ..< r { runs[nruns] = {l, 0}; nruns += 1 }
	}
	return
}

// `raw` as stored blocks.
@(private)
emit_stored :: proc(d: ^Deflater, out: ^[dynamic]u8, raw: []u8) {
	for at := 0; at < len(raw) || at == 0; {
		n := min(len(raw) - at, STORED_MAX_BYTES)
		put(d, out, 0, 1)
		put(d, out, 0, 2)
		if d.nacc > 0 { put(d, out, 0, 8 - d.nacc) }
		append(out, u8(n), u8(n >> 8), u8(~n), u8(~n >> 8))
		append(out, ..raw[at:at + n])
		at += n
		if n == 0 { break }
	}
}

// One block of `syms` (the symbols of `raw`), in the cheapest of stored, fixed and dynamic codes.
@(private)
emit_block :: proc(d: ^Deflater, out: ^[dynamic]u8, raw: []u8) {
	lit_freq: [LIT_SYMBOLS_USED]u32
	dist_freq: [DIST_CODES]u32
	extra_bits := 0
	for s in d.syms {
		if s & MATCH_BIT == 0 { lit_freq[s] += 1; continue }
		length, dist := int((s >> SYM_LEN_SHIFT) & SYM_LEN_MASK), int(s & SYM_DIST_MASK)
		li, di := len_index(length), dist_index(dist)
		lit_freq[LEN_SYMBOL_FIRST + li] += 1
		dist_freq[di] += 1
		extra_bits += int(LEN_EXTRA[li]) + int(DIST_EXTRA[di])
	}
	lit_freq[END_OF_BLOCK] = 1

	// dynamic: the codes, then the code lengths run-length coded with the code length alphabet
	dyn_lit, dyn_dist: Code
	huffman_lengths(lit_freq[:], dyn_lit.length[:LIT_SYMBOLS_USED], MAX_CODE_BITS)
	huffman_lengths(dist_freq[:], dyn_dist.length[:DIST_CODES], MAX_CODE_BITS)
	code_assign(&dyn_lit, LIT_SYMBOLS_USED)
	code_assign(&dyn_dist, DIST_CODES)
	hlit := LIT_SYMBOLS_USED
	for hlit > HLIT_MIN && dyn_lit.length[hlit - 1] == 0 { hlit -= 1 }
	hdist := DIST_CODES
	for hdist > 1 && dyn_dist.length[hdist - 1] == 0 { hdist -= 1 }
	all: [LIT_SYMBOLS_USED + DIST_CODES]u8
	copy(all[:hlit], dyn_lit.length[:hlit])
	copy(all[hlit:hlit + hdist], dyn_dist.length[:hdist])
	runs: [LIT_SYMBOLS_USED + DIST_CODES][2]u8
	nruns := clen_runs(all[:hlit + hdist], runs[:])
	cl_freq: [CLEN_CODES]u32
	for k in 0 ..< nruns { cl_freq[runs[k][0]] += 1 }
	cl: Code
	huffman_lengths(cl_freq[:], cl.length[:CLEN_CODES], CLEN_MAX_CODE_BITS)
	code_assign(&cl, CLEN_CODES)
	hclen := CLEN_CODES
	for hclen > HCLEN_MIN && cl.length[CLEN_ORDER[hclen - 1]] == 0 { hclen -= 1 }

	RUN_EXTRA := [CLEN_CODES]int{CLEN_REPEAT_PREV = 2, CLEN_REPEAT_ZERO = 3, CLEN_REPEAT_ZERO_LONG = 7}
	dyn_cost := 3 + 5 + 5 + 4 + 3 * hclen + extra_bits
	for k in 0 ..< nruns { dyn_cost += int(cl.length[runs[k][0]]) + RUN_EXTRA[runs[k][0]] }
	fix_lit, fix_dist := &fixed_lit_code, &fixed_dist_code
	fix_cost := 3 + extra_bits
	for v, s in lit_freq {
		dyn_cost += int(v) * int(dyn_lit.length[s])
		fix_cost += int(v) * int(fix_lit.length[s])
	}
	for v, s in dist_freq {
		dyn_cost += int(v) * int(dyn_dist.length[s])
		fix_cost += int(v) * FIXED_DIST_BITS
	}
	stored_cost := (len(raw) + STORED_MAX_BYTES - 1) / STORED_MAX_BYTES * (3 + 7 + 32) + len(raw) * 8   // (at most: the padding to a byte)

	switch {
	case stored_cost < fix_cost && stored_cost < dyn_cost:
		emit_stored(d, out, raw)
	case dyn_cost < fix_cost:
		put(d, out, 0, 1)
		put(d, out, 2, 2)
		put(d, out, u32(hlit - HLIT_MIN), 5)
		put(d, out, u32(hdist - 1), 5)
		put(d, out, u32(hclen - HCLEN_MIN), 4)
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
		length, distance := int((s >> SYM_LEN_SHIFT) & SYM_LEN_MASK), int(s & SYM_DIST_MASK)
		li, di := len_index(length), dist_index(distance)
		put_code(d, out, u32(lit.code[LEN_SYMBOL_FIRST + li]), uint(lit.length[LEN_SYMBOL_FIRST + li]))
		put(d, out, u32(length - int(LEN_BASE[li])), uint(LEN_EXTRA[li]))
		put_code(d, out, u32(dist.code[di]), uint(dist.length[di]))
		put(d, out, u32(distance - int(DIST_BASE[di])), uint(DIST_EXTRA[di]))
	}
	put_code(d, out, u32(lit.code[END_OF_BLOCK]), uint(lit.length[END_OF_BLOCK]))
}
