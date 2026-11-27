// A GIF file's pictures (GIF87a or GIF89a) as a browser shows them: decode gives the first frame alone (a still
// texture: a thumbnail, the clipboard); a Decoder gives every frame of an animation in turn, each drawn over what the
// one before left (its disposal: kept, cleared to transparent, or the picture before it put back), with its delay;
// decode_frames gives them all at once within a byte budget. Every read is checked against the data's end, so a file
// cut short or damaged is refused (or, past its first frame, ends there), never read past
// (src/md/features/image-decode.md).
package gif

import "base:runtime"

// The most pixels a canvas or a frame has (8192 x 8192: 256 MiB of RGBA). A file declares its sides (up to 65535 each)
// before any pixel: a larger canvas or frame is refused before it is allocated.
MAX_DECODE_PIXELS :: 1 << 26
// A delay shorter than this, or none, is shown as browsers show it: SLOW_DELAY_MS.
FAST_DELAY_MS :: 20
SLOW_DELAY_MS :: 100
// The pixels of every frame together that decode_frames keeps when its options say none (Frames_Options.max_bytes).
FRAMES_BYTES_DEFAULT :: 768 << 20

@(private = "file") BLOCK_EXTENSION :: 0x21
@(private = "file") BLOCK_IMAGE :: 0x2C
@(private = "file") BLOCK_TRAILER :: 0x3B
@(private = "file") LABEL_GRAPHIC_CONTROL :: 0xF9
@(private = "file") FLAG_TABLE :: 0x80        // a global or a local colour table follows
@(private = "file") FLAG_INTERLACED :: 0x40   // in an image descriptor
@(private = "file") DECODE_MAX_BITS :: 12
@(private = "file") DECODE_MAX_CODES :: 1 << DECODE_MAX_BITS

// What a frame leaves for the next (the graphic control's disposal method).
Disposal :: enum u8 {
	None,         // 0: not said: kept
	Keep,         // 1: the frame stays under the next
	Background,   // 2: its rectangle cleared to transparent (browsers ignore the background colour)
	Previous,     // 3: the picture before it put back
}

// One picture of an animation: the whole canvas, straight RGBA8, and how long it shows.
Frame :: struct {
	pixels:   []u8,
	delay_ms: int,
}

// Reads a GIF's frames one after the other (decoder_init, next_frame until it says no more, decoder_destroy). Its
// fields are its own.
Decoder :: struct {
	width, height: int,        // the canvas: the logical screen, grown to the first frame when it passes its edge
	frames:        int,        // the frames given so far
	r:             Reader,
	screen:        [2]int,
	global:        []u8,
	canvas:        []u8,       // (allocator) what next_frame gives
	before:        []u8,       // (allocator) the canvas before a frame whose disposal puts it back
	codes:         [dynamic]u8,
	indices:       [dynamic]u8,
	pending:       Disposal,   // what the last frame given leaves
	rect:          [4]int,     // the last frame's rectangle on the canvas: x, y, w, h
	failed:        bool,       // damage after a frame: no more frames
	allocator:     runtime.Allocator,
}

// Reads the header of `data` (kept, not copied: it must outlive the decoder). False for no GIF or a header cut short.
decoder_init :: proc(d: ^Decoder, data: []u8, allocator := context.allocator) -> bool {
	d^ = {r = {data = data}, allocator = allocator}
	r := &d.r
	signature := take(r, 6)
	if r.failed || (string(signature) != "GIF87a" && string(signature) != "GIF89a") { return false }
	d.screen = {read_u16(r), read_u16(r)}
	packed := read_byte(r)
	_ = read_byte(r)   // (the background colour: browsers clear to transparent, so does this)
	_ = read_byte(r)   // (the pixel aspect ratio: no decoder applies it)
	if packed & FLAG_TABLE != 0 { d.global = take(r, 3 << uint(packed & 7 + 1)) }
	d.codes = make([dynamic]u8, runtime.heap_allocator())
	d.indices = make([dynamic]u8, runtime.heap_allocator())
	return !r.failed
}

decoder_destroy :: proc(d: ^Decoder) {
	delete(d.canvas, d.allocator)
	delete(d.before, d.allocator)
	delete(d.codes)
	delete(d.indices)
	d^ = {}
}

// The canvas after the next frame (d.width x d.height, straight RGBA8: the decoder's own, valid until the next call)
// and its delay. ok is false at the trailer, at damage, or when the canvas or a frame passes MAX_DECODE_PIXELS. The
// first frame fails as decode does; a later frame that fails ends the animation with the frames before it.
next_frame :: proc(d: ^Decoder) -> (pixels: []u8, delay_ms: int, ok: bool) {
	if d.failed { return }
	r := &d.r
	transparent, delay := -1, 0
	disposal := Disposal.None
	for !r.failed {
		switch read_byte(r) {
		case BLOCK_EXTENSION:
			if read_byte(r) == LABEL_GRAPHIC_CONTROL {
				// (the last control before the frame is its own: a file may hold several)
				if gce := take(r, read_byte(r)); len(gce) >= 4 {
					disposal = Disposal(min(int(gce[0] >> 2) & 7, 3))
					transparent = gce[0] & 1 != 0 ? int(gce[3]) : -1
					delay = (int(gce[1]) | int(gce[2]) << 8) * 10
				}
			}
			skip_blocks(r)
		case BLOCK_IMAGE:
			if !frame_read(d, transparent, disposal) { d.failed = true; return }
			d.frames += 1
			return d.canvas, delay < FAST_DELAY_MS ? SLOW_DELAY_MS : delay, true
		case:
			d.failed = true   // (the trailer, or a byte that starts no block)
			return
		}
	}
	d.failed = true
	return
}

// The first frame of a GIF file as straight RGBA8 in `allocator`, `width` x `height` (the logical screen, grown to the
// frame when the frame passes its edge, as browsers do). The frame's transparent index, and every pixel outside the
// frame, is transparent black; an index past the colour table too. ok is false for no GIF, a file cut before the
// first frame's data ends, a damaged code stream, a frame with no colour table, or a canvas past MAX_DECODE_PIXELS. A
// stream that ends before it fills its frame keeps what came, the rest transparent (browsers show such files).
decode :: proc(data: []u8, allocator := context.allocator) -> (rgba: []u8, width, height: int, ok: bool) {
	d: Decoder
	if !decoder_init(&d, data, allocator) { decoder_destroy(&d); return }
	if _, _, first := next_frame(&d); !first { decoder_destroy(&d); return }
	rgba, width, height = d.canvas, d.width, d.height
	d.canvas = nil   // (the caller's now)
	decoder_destroy(&d)
	return rgba, width, height, true
}

// The canvas decode makes, from the header and the first frame's descriptor, nothing decoded: the logical screen, grown
// to the first frame when it passes its edge. What a caller checks against its limits before any pixel is allocated. ok
// is false for no GIF, or a file cut before its first frame's descriptor.
canvas_size :: proc(data: []u8) -> (size: [2]int, ok: bool) {
	d: Decoder
	defer decoder_destroy(&d)
	if !decoder_init(&d, data, runtime.heap_allocator()) { return }
	r := &d.r
	for !r.failed {
		switch read_byte(r) {
		case BLOCK_EXTENSION:
			_ = read_byte(r)   // (its label)
			skip_blocks(r)
		case BLOCK_IMAGE:
			left, top, fw, fh := read_u16(r), read_u16(r), read_u16(r), read_u16(r)
			if r.failed { return }
			size = {max(d.screen.x, left + fw), max(d.screen.y, top + fh)}
			return size, size.x > 0 && size.y > 0
		case:
			return   // (the trailer before any frame, or a byte that starts no block)
		}
	}
	return
}

// How decode_frames reads an animation.
Frames_Options :: struct {
	max_bytes: int,    // the pixels of every frame together: past them, the frames so far (0: FRAMES_BYTES_DEFAULT)
	first:     bool,   // the first frame alone (a thumbnail: a long animation's every frame for one small picture is a waste)
}

// Every frame of a GIF file, each the whole canvas (straight RGBA8 in `allocator`, frames_destroy), with its delay.
// ok: at least one frame. Past `max_bytes`, the frames decoded so far.
decode_frames :: proc(data: []u8, o := Frames_Options{}, allocator := context.allocator) -> (frames: []Frame, width, height: int, ok: bool) {
	d: Decoder
	defer decoder_destroy(&d)
	if !decoder_init(&d, data, runtime.heap_allocator()) { return }
	most := o.max_bytes > 0 ? o.max_bytes : FRAMES_BYTES_DEFAULT
	list := make([dynamic]Frame, allocator)
	for {
		px, delay, next := next_frame(&d)
		if !next { break }
		if len(list) > 0 && (len(list) + 1) * len(px) > most { break }
		copied := make([]u8, len(px), allocator)
		copy(copied, px)
		append(&list, Frame{copied, delay})
		if o.first { break }
	}
	if len(list) == 0 { delete(list); return }
	shrink(&list)
	return list[:], d.width, d.height, true
}

frames_destroy :: proc(frames: []Frame, allocator := context.allocator) {
	for f in frames { delete(f.pixels, allocator) }
	delete(frames, allocator)
}

// The frame at the reader: what the last frame left is disposed of, the frame drawn over the canvas.
@(private = "file")
frame_read :: proc(d: ^Decoder, transparent: int, disposal: Disposal) -> bool {
	r := &d.r
	left, top, fw, fh := read_u16(r), read_u16(r), read_u16(r), read_u16(r)
	flags := read_byte(r)
	palette := d.global
	if flags & FLAG_TABLE != 0 { palette = take(r, 3 << uint(flags & 7 + 1)) }
	min_size := read_byte(r)
	if r.failed || palette == nil || min_size < 1 || min_size > 8 { return false }
	// (a frame's own sides are 16 bits each, apart from the screen's: 65535 by 65535 would ask 4 GB of indices for a
	// file of a hundred bytes)
	if fw * fh > MAX_DECODE_PIXELS { return false }

	if d.canvas == nil {
		w, h := max(d.screen.x, left + fw), max(d.screen.y, top + fh)
		if w == 0 || h == 0 || w * h > MAX_DECODE_PIXELS { return false }
		d.width, d.height = w, h
		d.canvas = make([]u8, w * h * 4, d.allocator)
	} else {
		dispose(d)
	}
	clear(&d.codes)
	gather_blocks(r, &d.codes)
	cut := r.failed

	// (a frame clipped by the canvas's bottom: its rows past it are not decoded, unless interlaced: those come out of order)
	interlaced := flags & FLAG_INTERLACED != 0
	rows := interlaced ? fh : clamp(d.height - top, 0, fh)
	resize(&d.indices, fw * rows)
	count, lzw_ok := lzw_decode(d.codes[:], min_size, d.indices[:])
	if !lzw_ok { return false }
	// (a file cut after its frame's last code still reads: the end code, the terminator and the trailer are not needed;
	// cut before, it is damage)
	if cut && count < len(d.indices) { return false }

	if disposal == .Previous {
		if d.before == nil { d.before = make([]u8, len(d.canvas), d.allocator) }
		copy(d.before, d.canvas)
	}
	d.pending = disposal
	d.rect = {left, top, fw, fh}
	for row in 0 ..< (fw > 0 ? (count + fw - 1) / fw : 0) {
		y := top + (interlaced ? interlaced_row(row, fh) : row)
		if y >= d.height { continue }
		line := d.indices[row * fw:][:min(fw, count - row * fw)]
		for index, x in line {
			cx := left + x
			if cx >= d.width { break }
			i := int(index)
			if i == transparent || i * 3 + 2 >= len(palette) { continue }
			o := (y * d.width + cx) * 4
			d.canvas[o], d.canvas[o + 1], d.canvas[o + 2], d.canvas[o + 3] = palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2], 255
		}
	}
	return true
}

// What the frame before left, as its disposal says, before the next is drawn.
@(private = "file")
dispose :: proc(d: ^Decoder) {
	switch d.pending {
	case .None, .Keep:
	case .Background:
		x0, y0 := d.rect[0], d.rect[1]
		x1, y1 := min(x0 + d.rect[2], d.width), min(y0 + d.rect[3], d.height)
		for y in y0 ..< y1 {
			for x in x0 ..< x1 {
				o := (y * d.width + x) * 4
				d.canvas[o], d.canvas[o + 1], d.canvas[o + 2], d.canvas[o + 3] = 0, 0, 0, 0
			}
		}
	case .Previous:
		if d.before != nil { copy(d.canvas, d.before) }
	}
	d.pending = .None
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

// The indices of a frame's code stream (its sub-blocks joined) into `out`; `count` is how many came (at most len(out):
// what is past the frame is dropped). A stream that ends before its end code keeps what came. False for a code that
// names no string. Each string is written from its last index to its first by its chain of prefixes: every prefix is a
// smaller code, so the walk ends.
@(private = "file")
lzw_decode :: proc(data: []u8, min_size: int, out: []u8) -> (count: int, ok: bool) {
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
	at := 0
	for count < len(out) {
		for held < width {
			if at >= len(data) { return count, true }   // (the terminator before the end code)
			bits |= u32(data[at]) << held
			at += 1
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

@(private)
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

// The sub-blocks up to their terminator, joined into `out`. A stream cut before its terminator fails the reader, with
// what came of it in `out`.
@(private = "file")
gather_blocks :: proc(r: ^Reader, out: ^[dynamic]u8) {
	for !r.failed {
		n := read_byte(r)
		if n == 0 { return }
		if n > len(r.data) - r.at { append(out, ..r.data[r.at:]); r.at = len(r.data); r.failed = true; return }
		append(out, ..take(r, n))
	}
}
