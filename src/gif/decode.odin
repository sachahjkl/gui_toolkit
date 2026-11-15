// The first picture of a GIF file (GIF87a or GIF89a), as a browser shows it before any animation: its frame laid on the
// logical screen, the rest of the screen transparent. Only the first frame: a program shows a GIF as a still texture
// (src/md/features/image-decode.md says why there is no frames API). Every read is checked against the data's end, so
// a file cut short or damaged is refused, never read past.
package gif

import "base:runtime"

// The most pixels decode makes (8192 x 8192: 256 MiB of RGBA). A file declares its sides (up to 65535 each) before any
// pixel: a larger canvas is refused before it is allocated.
MAX_DECODE_PIXELS :: 1 << 26

@(private = "file") BLOCK_EXTENSION :: 0x21
@(private = "file") BLOCK_IMAGE :: 0x2C
@(private = "file") LABEL_GRAPHIC_CONTROL :: 0xF9
@(private = "file") FLAG_TABLE :: 0x80        // a global or a local colour table follows
@(private = "file") FLAG_INTERLACED :: 0x40   // in an image descriptor
@(private = "file") DECODE_MAX_BITS :: 12
@(private = "file") DECODE_MAX_CODES :: 1 << DECODE_MAX_BITS

// The first frame of a GIF file as straight RGBA8 in `allocator`, `width` x `height` (the logical screen, grown to the
// frame when the frame passes its edge, as browsers do). The frame's transparent index, and every pixel outside the
// frame, is transparent black; an index past the colour table too. ok is false for no GIF, a file cut before the
// first frame's data ends, a damaged code stream, a frame with no colour table, or a canvas past MAX_DECODE_PIXELS. A
// stream that ends before it fills its frame keeps what came, the rest transparent (browsers show such files).
decode :: proc(data: []u8, allocator := context.allocator) -> (rgba: []u8, width, height: int, ok: bool) {
	r := Reader{data = data}
	signature := take(&r, 6)
	if r.failed || (string(signature) != "GIF87a" && string(signature) != "GIF89a") { return }
	screen_w, screen_h := read_u16(&r), read_u16(&r)
	packed := read_byte(&r)
	_ = read_byte(&r)   // (the background colour: browsers clear to transparent, so does this)
	_ = read_byte(&r)   // (the pixel aspect ratio: no decoder applies it)
	global: []u8
	if packed & FLAG_TABLE != 0 { global = take(&r, 3 << uint(packed & 7 + 1)) }

	transparent := -1
	for !r.failed {
		switch read_byte(&r) {
		case BLOCK_EXTENSION:
			label := read_byte(&r)
			if label == LABEL_GRAPHIC_CONTROL {
				// (the last control before the frame is its own: a file may hold several)
				if gce := take(&r, read_byte(&r)); len(gce) >= 4 {
					transparent = gce[0] & 1 != 0 ? int(gce[3]) : -1
				}
			}
			skip_blocks(&r)
		case BLOCK_IMAGE:
			return decode_frame(&r, screen_w, screen_h, global, transparent, allocator)
		case:
			return   // (the trailer before any frame, or a byte that starts no block)
		}
	}
	return
}

@(private = "file")
decode_frame :: proc(r: ^Reader, screen_w, screen_h: int, global: []u8, transparent: int, allocator: runtime.Allocator) -> (rgba: []u8, width, height: int, ok: bool) {
	left, top, fw, fh := read_u16(r), read_u16(r), read_u16(r), read_u16(r)
	flags := read_byte(r)
	palette := global
	if flags & FLAG_TABLE != 0 { palette = take(r, 3 << uint(flags & 7 + 1)) }
	min_size := read_byte(r)
	if r.failed || palette == nil || min_size < 1 || min_size > 8 { return }
	w, h := max(screen_w, left + fw), max(screen_h, top + fh)
	if w == 0 || h == 0 || w * h > MAX_DECODE_PIXELS { return }

	// (the heap, freed here: the caller's allocator may be an arena)
	heap := runtime.heap_allocator()
	indices := make([]u8, fw * fh, heap)
	defer delete(indices, heap)
	count, lzw_ok := lzw_decode(r, min_size, indices)
	if !lzw_ok { return }
	width, height = w, h

	rgba = make([]u8, width * height * 4, allocator)
	interlaced := flags & FLAG_INTERLACED != 0
	for row in 0 ..< (fw > 0 ? (count + fw - 1) / fw : 0) {
		y := top + (interlaced ? interlaced_row(row, fh) : row)
		line := indices[row * fw:][:min(fw, count - row * fw)]
		out := rgba[(y * width + left) * 4:]
		for index, x in line {
			i := int(index)
			if i == transparent || i * 3 + 2 >= len(palette) { continue }
			out[x * 4], out[x * 4 + 1], out[x * 4 + 2], out[x * 4 + 3] = palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2], 255
		}
	}
	return rgba, width, height, true
}

// The frame's row that the `i`-th row of an interlaced stream is: every 8th row from 0, every 8th from 4, every 4th
// from 2, every 2nd from 1.
@(private = "file")
interlaced_row :: proc(i, height: int) -> int {
	i := i
	if n := (height + 7) / 8; i < n { return i * 8 } else { i -= n }
	if n := (height + 3) / 8; i < n { return 4 + i * 8 } else { i -= n }
	if n := (height + 1) / 4; i < n { return 2 + i * 4 } else { i -= n }
	return 1 + i * 2
}

// The indices of the code stream's sub-blocks into `out`; `count` is how many came (at most len(out): what is past the
// frame is dropped). False for a stream cut short or a code that names no string. Each string is written from its
// last index to its first by its chain of prefixes: every prefix is a smaller code, so the walk ends.
@(private = "file")
lzw_decode :: proc(r: ^Reader, min_size: int, out: []u8) -> (count: int, ok: bool) {
	prefix: [DECODE_MAX_CODES]u16
	suffix: [DECODE_MAX_CODES]u8
	first: [DECODE_MAX_CODES]u8
	length: [DECODE_MAX_CODES]u16
	clear_code := 1 << uint(min_size)
	end_code := clear_code + 1
	for c in 0 ..< clear_code { suffix[c], first[c], length[c] = u8(c), u8(c), 1 }

	width := uint(min_size + 1)
	next := end_code + 1
	previous := -1
	bits: u32
	held: uint
	block_left := 0
	for count < len(out) {
		for held < width {
			if block_left == 0 {
				block_left = read_byte(r)
				if r.failed { return count, false }
				if block_left == 0 { return count, true }   // (the terminator before the end code)
			}
			bits |= u32(read_byte(r)) << held
			if r.failed { return count, false }
			block_left -= 1
			held += 8
		}
		code := int(bits & (1 << width - 1))
		bits >>= width
		held -= width

		switch {
		case code == clear_code:
			width, next, previous = uint(min_size + 1), end_code + 1, -1
			continue
		case code == end_code:
			return count, true
		case previous < 0:
			if code > clear_code { return count, false }   // (after a clear, only a single index has a string)
			out[count] = u8(code)
			count += 1
			previous = code
			continue
		case code > next:
			return count, false
		}

		// (code == next: the string being defined, the previous one and its own first index)
		n := code < next ? int(length[code]) : int(length[previous]) + 1
		c := code
		i := n - 1
		if code == next {
			if count + i < len(out) { out[count + i] = first[previous] }
			c = previous
			i -= 1
		}
		for ; i >= 0; i -= 1 {
			if count + i < len(out) { out[count + i] = suffix[c] }
			c = int(prefix[c])
		}
		count = min(count + n, len(out))

		if next < DECODE_MAX_CODES {
			start := code < next ? first[code] : first[previous]
			prefix[next], suffix[next], first[next], length[next] = u16(previous), start, first[previous], length[previous] + 1
			next += 1
			if next == 1 << width && width < DECODE_MAX_BITS { width += 1 }
		}
		previous = code
	}
	return count, true
}

@(private = "file")
Reader :: struct {
	data:   []u8,
	at:     int,
	failed: bool,   // a read past the end: every later read gives 0 and nil
}

@(private = "file")
read_byte :: proc(r: ^Reader) -> int {
	if r.failed || r.at >= len(r.data) { r.failed = true; return 0 }
	r.at += 1
	return int(r.data[r.at - 1])
}

@(private = "file")
read_u16 :: proc(r: ^Reader) -> int {
	low := read_byte(r)
	return low | read_byte(r) << 8
}

@(private = "file")
take :: proc(r: ^Reader, n: int) -> []u8 {
	if r.failed || n > len(r.data) - r.at { r.failed = true; return nil }
	r.at += n
	return r.data[r.at - n:r.at]
}

// Past the sub-blocks up to their terminator.
@(private = "file")
skip_blocks :: proc(r: ^Reader) {
	for !r.failed {
		n := read_byte(r)
		if n == 0 { return }
		take(r, n)
	}
}
