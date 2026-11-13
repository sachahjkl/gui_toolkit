// An animated GIF encoder (GIF89a) for screen recordings: BGRA frames in, a GIF file out, in memory or through a writer
// procedure. Each frame after the first is only the rectangle that changed, its unchanged pixels transparent (disposal 1:
// the decoder keeps what is below), so a still screen costs nothing and a moving cursor a few bytes. Pure Odin, any
// target. See docs/gif.md.
package gif

import "base:intrinsics"
import "base:runtime"
import "core:simd"

// How a frame's colours become at most 256.
Quantizer :: enum u8 {
	Median_Cut,   // per frame: the exact colours when they fit (screen content), else Heckbert's median cut; a local table
	Fixed,        // one global table: 6 x 7 x 6 levels and 3 greys; no search of colours, the fastest
}

// The zero value is the defaults.
Encoder_Options :: struct {
	quantizer:   Quantizer,
	dither:      bool,   // ordered (Bayer 4 x 4) dithering of colours the palette lacks; off: text stays crisp
	full_frames: bool,   // every frame whole: no changed rectangle, no transparency, no merging of unchanged frames
}

// Where a streaming encoder sends its bytes; false stops the encoder (add_frame and end return false).
Write_Proc :: #type proc(user: rawptr, data: []u8) -> bool

// begin, add_frame for each frame, end. The fields are the encoder's own.
Encoder :: struct {
	width, height: int,
	options:       Encoder_Options,
	write:         Write_Proc,
	user:          rawptr,
	allocator:     runtime.Allocator,
	out:           [dynamic]u8,   // the file, or what the writer has not been given yet
	pending:       int,           // where the last frame starts in out (-1: none): an unchanged frame adds its delay there
	frames:        int,
	failed:        bool,
	previous:      []u8,          // the last frame's BGRA, width * 4 a row (not with full_frames)
	pixels:        []u32,         // the changed rectangle's colours (0x00RRGGBB) or UNCHANGED
	indices:       []u8,          // the rectangle's palette indices
	quantize:      Quantize_State,
	lzw:           Lzw_State,
}

// The largest side and delay a GIF holds (16-bit fields).
MAX_SIDE :: 65535
MAX_DELAY :: 65535

@(private) PIXEL :: 4   // bytes of a BGRA pixel
@(private = "file") EXTENSION :: 0x21
@(private = "file") GRAPHIC_CONTROL :: 0xF9
@(private = "file") APPLICATION :: 0xFF
@(private = "file") IMAGE :: 0x2C
@(private = "file") TRAILER :: 0x3B
@(private = "file") DISPOSAL_KEEP :: 1 << 2       // disposal method 1 in the graphic control's packed byte
@(private = "file") HAS_TRANSPARENT :: 1
@(private = "file") HAS_TABLE :: 0x80             // a global or local colour table follows
@(private = "file") COLOR_RESOLUTION :: 7 << 4    // 8 bits a primary
@(private = "file") GCE_DELAY :: 4                // the delay's offset in a graphic control extension
@(private) Rect :: struct { x, y, w, h: int }

// Starts a file of `width` x `height` pixels. `loop_count` is the NETSCAPE2.0 count: 0 loops forever, n plays n more
// times after the first (browsers' reading), -1 writes no loop extension (played once). With `write`, the bytes go to it
// as the frames come (a frame is held until the next one, which may add to its delay) and end returns nil; else end
// returns the file. False when a side is not in 1 ..= MAX_SIDE or the writer fails.
begin :: proc(e: ^Encoder, width, height: int, loop_count := 0, o := Encoder_Options{}, write: Write_Proc = nil, user: rawptr = nil,
	allocator := context.allocator) -> bool {
	e^ = {}
	if width < 1 || height < 1 || width > MAX_SIDE || height > MAX_SIDE { return false }
	e.width, e.height, e.options, e.write, e.user, e.allocator = width, height, o, write, user, allocator
	e.pending = -1
	n := width * height
	e.out = make([dynamic]u8, 0, 1024, allocator)
	if !o.full_frames { e.previous = make([]u8, n * PIXEL, allocator) }
	e.pixels = make([]u32, n, allocator)
	e.indices = make([]u8, n, allocator)
	quantize_init(&e.quantize, o.quantizer, allocator)
	lzw_init(&e.lzw, allocator)

	append(&e.out, "GIF89a")
	put_u16(&e.out, width)
	put_u16(&e.out, height)
	if o.quantizer == .Fixed {
		append(&e.out, HAS_TABLE | COLOR_RESOLUTION | 7, 0, 0)   // (7: 2^(7+1) entries)
		for c in e.quantize.fixed.rgb { append(&e.out, c[0], c[1], c[2]) }
	} else {
		append(&e.out, COLOR_RESOLUTION, 0, 0)
	}
	if loop_count >= 0 {
		append(&e.out, EXTENSION, APPLICATION, 11)
		append(&e.out, "NETSCAPE2.0")
		append(&e.out, 3, 1)
		put_u16(&e.out, min(loop_count, 65535))
		append(&e.out, 0)
	}
	return flush(e)
}

// Adds a frame: `bgra` is width x height pixels, B, G, R, A bytes (straight alpha; alpha is not encoded: a GIF frame
// is opaque), `stride` bytes a row (0: width * 4). It shows for `delay_cs` hundredths of a second (clamped to 0 ..=
// MAX_DELAY; browsers show 0 and 1 as 10). A frame equal to the last one adds its delay to it and writes nothing.
add_frame :: proc(e: ^Encoder, bgra: []u8, stride := 0, delay_cs := 10) -> bool {
	if e.failed || e.pixels == nil { return false }
	stride := stride == 0 ? e.width * PIXEL : stride
	if stride < e.width * PIXEL || len(bgra) < (e.height - 1) * stride + e.width * PIXEL { return false }
	delay := clamp(delay_cs, 0, MAX_DELAY)
	differencing := !e.options.full_frames && e.frames > 0

	rect := Rect{0, 0, e.width, e.height}
	if differencing {
		changed: bool
		rect, changed = changed_rect(e, bgra, stride)
		if !changed {
			if e.pending >= 0 {
				at := e.pending + GCE_DELAY
				sum := (int(e.out[at]) | int(e.out[at + 1]) << 8) + delay
				if sum <= MAX_DELAY {
					e.out[at], e.out[at + 1] = u8(sum), u8(sum >> 8)
					return true
				}
			}
			rect = {0, 0, 1, 1}   // (the delay does not fit the last frame: one transparent pixel carries it)
		}
	}

	n := rect.w * rect.h
	px := e.pixels[:n]
	unchanged := gather(e, bgra, stride, rect, differencing, px)
	palette := &e.quantize.palette
	indices := e.indices[:n]
	map_colors(&e.quantize, px, rect, unchanged > 0, e.options.dither, palette, indices)

	e.pending = len(e.out)
	append(&e.out, EXTENSION, GRAPHIC_CONTROL, 4)
	append(&e.out, u8(DISPOSAL_KEEP) | (palette.transparent >= 0 ? u8(HAS_TRANSPARENT) : 0))
	put_u16(&e.out, delay)
	append(&e.out, u8(max(palette.transparent, 0)), 0)
	append(&e.out, IMAGE)
	put_u16(&e.out, rect.x)
	put_u16(&e.out, rect.y)
	put_u16(&e.out, rect.w)
	put_u16(&e.out, rect.h)
	bits := 8
	if e.options.quantizer == .Fixed {
		append(&e.out, 0)
	} else {
		bits = 1
		for 1 << uint(bits) < palette.count { bits += 1 }
		append(&e.out, HAS_TABLE | u8(bits - 1))
		for c in palette.rgb[:palette.count] { append(&e.out, c[0], c[1], c[2]) }
		for _ in palette.count ..< 1 << uint(bits) { append(&e.out, 0, 0, 0) }
	}
	lzw_encode(&e.lzw, &e.out, indices, max(2, bits))

	if !e.options.full_frames {
		for y in rect.y ..< rect.y + rect.h {
			copy(e.previous[(y * e.width + rect.x) * PIXEL:][:rect.w * PIXEL], bgra[y * stride + rect.x * PIXEL:][:rect.w * PIXEL])
		}
	}
	e.frames += 1
	return flush(e)
}

// Writes the trailer and frees the encoder. Without a writer, `data` is the file (the encoder's allocator); with one,
// nil. ok is false when a writer failed or no frame was added (a GIF needs one).
end :: proc(e: ^Encoder) -> (data: []u8, ok: bool) {
	ok = !e.failed && e.frames > 0
	if ok {
		append(&e.out, TRAILER)
		e.pending = -1
		ok = flush(e)
	}
	if ok && e.write == nil {
		data = e.out[:]
		e.out = nil
	}
	destroy(e)
	return
}

// Frees what the encoder holds (end does it; this is for an encoder given up before its end).
destroy :: proc(e: ^Encoder) {
	context.allocator = e.allocator
	delete(e.out)
	delete(e.previous)
	delete(e.pixels)
	delete(e.indices)
	quantize_destroy(&e.quantize)
	lzw_destroy(&e.lzw)
	e^ = {}
}

// Gives the writer all but the frame held (the whole of it when nothing is held).
@(private = "file")
flush :: proc(e: ^Encoder) -> bool {
	if e.write == nil { return true }
	n := e.pending >= 0 ? e.pending : len(e.out)
	if n == 0 { return true }
	if !e.write(e.user, e.out[:n]) {
		e.failed = true
		return false
	}
	rest := len(e.out) - n
	copy(e.out[:rest], e.out[n:])
	resize(&e.out, rest)
	if e.pending >= 0 { e.pending = 0 }
	return true
}

@(private = "file")
put_u16 :: #force_inline proc(out: ^[dynamic]u8, v: int) { append(out, u8(v), u8(v >> 8)) }

////////////////////////////////
// Frame differencing

@(private) LANES :: 16
@(private) Bytes :: #simd[LANES]u8

// The bounding box of the pixels that differ from the last frame; false when none does.
@(private = "file")
changed_rect :: proc(e: ^Encoder, bgra: []u8, stride: int) -> (r: Rect, changed: bool) {
	left, right, top, bottom := e.width, -1, -1, -1
	row_bytes := e.width * PIXEL
	for y in 0 ..< e.height {
		first, last := row_changes(bgra[y * stride:][:row_bytes], e.previous[y * row_bytes:][:row_bytes], right)
		if first < 0 { continue }
		if top < 0 { top = y }
		bottom = y
		left = min(left, first)
		right = max(right, last)
	}
	if top < 0 { return {}, false }
	return {left, top, right - left + 1, bottom - top + 1}, true
}

// The first pixel of a row that differs between `a` and `b` (-1: none), and the last one when it is right of `right`
// (the box's right side so far; else `last` is `first`, which the box spans already): the search from the right stops
// there. A register at a time, then pixel by pixel; the result is the same either way.
@(private)
row_changes :: proc "contextless" (a, b: []u8, right: int) -> (first, last: int) #no_bounds_check {
	n := len(a)
	pa, pb := raw_data(a), raw_data(b)
	first = -1
	i := 0
	for ; i + LANES <= n; i += LANES {
		m := transmute(u16)simd.extract_msbs(simd.lanes_ne(intrinsics.unaligned_load((^Bytes)(&pa[i])), intrinsics.unaligned_load((^Bytes)(&pb[i]))))
		if m != 0 {
			first = (i + int(intrinsics.count_trailing_zeros(m))) / PIXEL
			break
		}
	}
	if first < 0 {
		for ; i < n; i += PIXEL {
			if pixel_at(pa, i) != pixel_at(pb, i) { first = i / PIXEL; break }
		}
		if first < 0 { return -1, -1 }
	}
	last = first
	low := max(right + 1, first + 1) * PIXEL
	j := n
	for ; j - LANES >= low; j -= LANES {
		m := transmute(u16)simd.extract_msbs(simd.lanes_ne(intrinsics.unaligned_load((^Bytes)(&pa[j - LANES])), intrinsics.unaligned_load((^Bytes)(&pb[j - LANES]))))
		if m != 0 { return first, (j - 1 - int(intrinsics.count_leading_zeros(m))) / PIXEL }
	}
	for ; j > low; j -= PIXEL {
		if pixel_at(pa, j - PIXEL) != pixel_at(pb, j - PIXEL) { return first, j / PIXEL - 1 }
	}
	return
}

@(private = "file")
pixel_at :: #force_inline proc "contextless" (p: [^]u8, i: int) -> u32 { return intrinsics.unaligned_load((^u32)(&p[i])) }

// The rectangle's colours into `px`, UNCHANGED where `differencing` and the pixel equals the last frame's; returns how
// many are UNCHANGED.
@(private = "file")
gather :: proc(e: ^Encoder, bgra: []u8, stride: int, r: Rect, differencing: bool, px: []u32) -> (unchanged: int) #no_bounds_check {
	k := 0
	for y in r.y ..< r.y + r.h {
		row := raw_data(bgra[y * stride + r.x * PIXEL:])
		if differencing {
			prev := raw_data(e.previous[(y * e.width + r.x) * PIXEL:])
			for x in 0 ..< r.w {
				i := x * PIXEL
				if pixel_at(row, i) == pixel_at(prev, i) {
					px[k] = UNCHANGED
					unchanged += 1
				} else {
					px[k] = u32(row[i + 2]) << 16 | u32(row[i + 1]) << 8 | u32(row[i])
				}
				k += 1
			}
		} else {
			for x in 0 ..< r.w {
				i := x * PIXEL
				px[k] = u32(row[i + 2]) << 16 | u32(row[i + 1]) << 8 | u32(row[i])
				k += 1
			}
		}
	}
	return
}
