// The GIF encoder, read back by a small GIF decoder of its own (below): the header, the loop extension and the trailer;
// frames of at most 256 colours come back pixel for pixel, whole or as changed rectangles; an unchanged frame costs
// nothing (its delay goes to the frame before) and a small change a few bytes; the changed rectangle is the exact
// bounding box wherever the change is in a row (the vector and the scalar parts of the search); odd sizes; strides;
// long inputs (clear codes); many colours (median cut, the fixed table, dithering) come back close; a writer gets the
// same bytes.
//   odin test tests/gif -vet
package gif_test

import "core:math/rand"
import "core:testing"
import "../../src/gif"

////////////////////////////////
// A GIF decoder: what a browser shows after each frame

@(private = "file")
Shown :: struct {
	rgb:         []u8,      // the canvas after the frame, width * height * 3
	delay:       int,
	x, y, w, h:  int,       // the frame's rectangle
	transparent: int,       // -1: none
	disposal:    int,
	local_table: bool,
}

@(private = "file")
Decoded :: struct {
	width, height: int,
	loop_count:    int,      // -1: no NETSCAPE2.0 extension
	global_table:  bool,
	frames:        [dynamic]Shown,
}

@(private = "file")
Reader :: struct { data: []u8, at: int, ok: bool }

@(private = "file")
byte_of :: proc(r: ^Reader) -> int {
	if r.at >= len(r.data) { r.ok = false; return 0 }
	r.at += 1
	return int(r.data[r.at - 1])
}

@(private = "file")
u16_of :: proc(r: ^Reader) -> int { return byte_of(r) | byte_of(r) << 8 }

@(private = "file")
sub_blocks :: proc(r: ^Reader) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	for r.ok {
		n := byte_of(r)
		if n == 0 { break }
		if r.at + n > len(r.data) { r.ok = false; break }
		append(&out, ..r.data[r.at:][:n])
		r.at += n
	}
	return out[:]
}

// GIF's LZW, the decoder's side: `count` indices exactly, then the end code.
@(private = "file")
lzw_decode :: proc(data: []u8, min_size, count: int) -> (out: []u8, ok: bool) {
	if min_size < 2 || min_size > 8 { return }
	clear := 1 << uint(min_size)
	end := clear + 1
	prefix: [4096]int
	suffix: [4096]u8
	first: [4096]u8
	for i in 0 ..< clear { prefix[i], suffix[i], first[i] = -1, u8(i), u8(i) }
	result := make([dynamic]u8, 0, count, context.temp_allocator)
	width, next, old := uint(min_size + 1), end + 1, -1
	bits: u64
	have: uint
	at := 0
	stack: [4096]u8
	emit :: proc(result: ^[dynamic]u8, stack: ^[4096]u8, prefix: ^[4096]int, suffix: ^[4096]u8, code: int) {
		n := 0
		for c := code; c >= 0; c = prefix[c] { stack[n] = suffix[c]; n += 1 }
		for i := n - 1; i >= 0; i -= 1 { append(result, stack[i]) }
	}
	for {
		for have < width {
			if at >= len(data) { return }
			bits |= u64(data[at]) << have
			at += 1
			have += 8
		}
		code := int(bits & (1 << width - 1))
		bits >>= width
		have -= width
		if code == clear {
			width, next, old = uint(min_size + 1), end + 1, -1
			continue
		}
		if code == end { break }
		if old < 0 {
			if code >= clear { return }
			emit(&result, &stack, &prefix, &suffix, code)
			old = code
			continue
		}
		f: u8
		switch {
		case code < next:
			f = first[code]
			emit(&result, &stack, &prefix, &suffix, code)
			if next < 4096 { prefix[next], suffix[next], first[next] = old, f, first[old] }
		case code == next && next < 4096:
			f = first[old]
			prefix[next], suffix[next], first[next] = old, f, first[old]
			emit(&result, &stack, &prefix, &suffix, code)
		case:
			return
		}
		if next < 4096 {
			next += 1
			if next == 1 << width && width < 12 { width += 1 }
		}
		old = code
	}
	if len(result) != count { return }
	if at != len(data) { return }   // (nothing but padding bits after the end code)
	return result[:], true
}

@(private = "file")
decode :: proc(data: []u8) -> (d: Decoded, ok: bool) {
	r := Reader{data = data, ok = true}
	if len(data) < 13 || string(data[:6]) != "GIF89a" { return }
	r.at = 6
	d.width, d.height = u16_of(&r), u16_of(&r)
	packed := byte_of(&r)
	byte_of(&r)
	byte_of(&r)
	d.loop_count = -1
	global: []u8
	if packed & 0x80 != 0 {
		d.global_table = true
		n := 3 << uint(packed & 7 + 1)
		if r.at + n > len(data) { return }
		global = data[r.at:][:n]
		r.at += n
	}
	d.frames = make([dynamic]Shown, context.temp_allocator)
	canvas := make([]u8, d.width * d.height * 3, context.temp_allocator)
	delay, transparent, disposal := 0, -1, 0
	for r.ok {
		switch byte_of(&r) {
		case 0x21:
			switch byte_of(&r) {
			case 0xF9:
				if byte_of(&r) != 4 { return }
				p := byte_of(&r)
				delay = u16_of(&r)
				t := byte_of(&r)
				transparent = p & 1 != 0 ? t : -1
				disposal = p >> 2 & 7
				if byte_of(&r) != 0 { return }
			case 0xFF:
				if byte_of(&r) != 11 || r.at + 11 > len(data) { return }
				id := string(data[r.at:][:11])
				r.at += 11
				blocks := sub_blocks(&r)
				if id == "NETSCAPE2.0" {
					if len(blocks) != 3 || blocks[0] != 1 { return }
					d.loop_count = int(blocks[1]) | int(blocks[2]) << 8
				}
			case:
				sub_blocks(&r)
			}
		case 0x2C:
			s := Shown{delay = delay, transparent = transparent, disposal = disposal}
			s.x, s.y, s.w, s.h = u16_of(&r), u16_of(&r), u16_of(&r), u16_of(&r)
			p := byte_of(&r)
			table := global
			if p & 0x80 != 0 {
				s.local_table = true
				n := 3 << uint(p & 7 + 1)
				if r.at + n > len(data) { return }
				table = data[r.at:][:n]
				r.at += n
			}
			if table == nil || s.x + s.w > d.width || s.y + s.h > d.height || s.w == 0 || s.h == 0 { return }
			min_size := byte_of(&r)
			indices, decoded := lzw_decode(sub_blocks(&r), min_size, s.w * s.h)
			if !decoded || !r.ok { return }
			for y in 0 ..< s.h {
				for x in 0 ..< s.w {
					i := int(indices[y * s.w + x])
					if i == transparent { continue }
					if i * 3 + 3 > len(table) { return }
					copy(canvas[((s.y + y) * d.width + s.x + x) * 3:][:3], table[i * 3:][:3])
				}
			}
			s.rgb = make([]u8, len(canvas), context.temp_allocator)
			copy(s.rgb, canvas)
			append(&d.frames, s)
			delay, transparent, disposal = 0, -1, 0
		case 0x3B:
			return d, r.ok && r.at == len(data)
		case:
			return
		}
	}
	return
}

////////////////////////////////
// Frames

@(private = "file")
Picture :: struct { w, h: int, bgra: []u8 }

@(private = "file")
picture :: proc(w, h: int) -> Picture {
	p := Picture{w, h, make([]u8, w * h * 4, context.temp_allocator)}
	for i in 0 ..< w * h { p.bgra[i * 4 + 3] = 255 }
	return p
}

@(private = "file")
clone :: proc(p: Picture) -> Picture {
	q := Picture{p.w, p.h, make([]u8, len(p.bgra), context.temp_allocator)}
	copy(q.bgra, p.bgra)
	return q
}

@(private = "file")
set :: proc(p: Picture, x, y: int, rgb: u32) {
	i := (y * p.w + x) * 4
	p.bgra[i], p.bgra[i + 1], p.bgra[i + 2], p.bgra[i + 3] = u8(rgb), u8(rgb >> 8), u8(rgb >> 16), 255
}

// Whether the canvas shows the picture exactly.
@(private = "file")
same :: proc(p: Picture, rgb: []u8) -> bool {
	for i in 0 ..< p.w * p.h {
		if rgb[i * 3] != p.bgra[i * 4 + 2] || rgb[i * 3 + 1] != p.bgra[i * 4 + 1] || rgb[i * 3 + 2] != p.bgra[i * 4] { return false }
	}
	return true
}

@(private = "file")
encode :: proc(t: ^testing.T, frames: []Picture, delays: []int = nil, o := gif.Encoder_Options{}, loop_count := 0) -> []u8 {
	e: gif.Encoder
	testing.expect(t, gif.begin(&e, frames[0].w, frames[0].h, loop_count, o, allocator = context.temp_allocator))
	for f, i in frames {
		testing.expect(t, gif.add_frame(&e, f.bgra, 0, delays == nil ? 10 : delays[i]))
	}
	data, ok := gif.end(&e)
	testing.expect(t, ok)
	return data
}

// A sequence of frames that each change a few rectangles, with colours from a set of `colors`.
@(private = "file")
sequence :: proc(w, h, count, colors: int, seed: u64) -> []Picture {
	gen := rand.create(seed)
	context.random_generator = rand.default_random_generator(&gen)
	set_of := make([]u32, colors, context.temp_allocator)
	for &c in set_of { c = rand.uint32() & 0xFFFFFF }
	frames := make([]Picture, count, context.temp_allocator)
	frames[0] = picture(w, h)
	for y in 0 ..< h {
		for x in 0 ..< w { set(frames[0], x, y, set_of[(x / 3 + y / 2) % colors]) }
	}
	for k in 1 ..< count {
		frames[k] = clone(frames[k - 1])
		for _ in 0 ..< 1 + rand.int_max(3) {
			rx, ry := rand.int_max(w), rand.int_max(h)
			rw, rh := 1 + rand.int_max(w - rx), 1 + rand.int_max(h - ry)
			for y in ry ..< ry + rh {
				for x in rx ..< rx + rw {
					if rand.int_max(4) != 0 { set(frames[k], x, y, set_of[rand.int_max(colors)]) }
				}
			}
		}
	}
	return frames
}

@(private = "file")
expect_round_trip :: proc(t: ^testing.T, frames: []Picture, o := gif.Encoder_Options{}, label := "") {
	data := encode(t, frames, nil, o)
	d, ok := decode(data)
	if !testing.expectf(t, ok, "%s: the file does not decode", label) { return }
	testing.expectf(t, d.width == frames[0].w && d.height == frames[0].h, "%s: %d x %d", label, d.width, d.height)
	// (an unchanged frame is merged into the one before: compare each shown frame with the last input it stands for)
	k := 0
	for f, i in frames {
		if i > 0 && string(f.bgra) == string(frames[i - 1].bgra) && !o.full_frames { continue }
		if !testing.expectf(t, k < len(d.frames), "%s: frame %d is missing", label, i) { return }
		testing.expectf(t, same(f, d.frames[k].rgb), "%s: frame %d differs", label, i)
		testing.expectf(t, d.frames[k].disposal == 1, "%s: frame %d: disposal %d", label, i, d.frames[k].disposal)
		k += 1
	}
	testing.expectf(t, k == len(d.frames), "%s: %d frames shown, want %d", label, len(d.frames), k)
}

////////////////////////////////
// Tests

@(test)
header_loop_and_trailer :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	p := picture(4, 3)
	for loop in ([3]int{0, 3, -1}) {
		data := encode(t, []Picture{p}, nil, {}, loop)
		testing.expect(t, string(data[:6]) == "GIF89a")
		testing.expect(t, data[6] == 4 && data[7] == 0 && data[8] == 3 && data[9] == 0)
		testing.expect(t, data[len(data) - 1] == 0x3B)
		d, ok := decode(data)
		testing.expectf(t, ok && d.loop_count == loop && len(d.frames) == 1, "loop %d: %v, loop %d", loop, ok, d.loop_count)
		testing.expect(t, !d.global_table && d.frames[0].local_table)
	}
	fixed := encode(t, []Picture{p}, nil, {quantizer = .Fixed})
	d, ok := decode(fixed)
	testing.expect(t, ok && d.global_table && !d.frames[0].local_table)
}

@(test)
frames_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for colors in ([?]int{1, 2, 5, 16, 100, 255}) {
		frames := sequence(61, 37, 12, colors, u64(colors))
		expect_round_trip(t, frames, {}, "differences")
		expect_round_trip(t, frames, {full_frames = true}, "full frames")
	}
	// 256 colours in a first frame (no transparency there), with clear codes on the way: 300 x 300 indices at random
	frames := []Picture{picture(300, 300)}
	gen := rand.create(7)
	context.random_generator = rand.default_random_generator(&gen)
	for y in 0 ..< 300 {
		for x in 0 ..< 300 { set(frames[0], x, y, u32(rand.int_max(256)) * 0x010101) }
	}
	expect_round_trip(t, frames, {}, "256 colours")
	runs := []Picture{picture(1000, 400)}   // (long strings: the codes reach 12 bits and the table fills)
	for y in 0 ..< 400 {
		for x in 0 ..< 1000 { set(runs[0], x, y, u32((x / 7 + y) % 9) * 0x1F0F07) }
	}
	expect_round_trip(t, runs, {}, "runs")
}

@(test)
odd_sizes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for size in ([?][2]int{{1, 1}, {7, 3}, {3, 7}, {2000, 2}, {2, 600}, {17, 1}}) {
		frames := sequence(size.x, size.y, 6, 9, u64(size.x * 1000 + size.y))
		expect_round_trip(t, frames, {}, "odd size")
		expect_round_trip(t, frames, {full_frames = true}, "odd size, whole")
	}
}

@(test)
unchanged_frame_costs_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	frames := sequence(320, 200, 1, 40, 3)
	one := encode(t, []Picture{frames[0]}, []int{7})
	two := encode(t, []Picture{frames[0], frames[0], frames[0]}, []int{7, 20, 30})
	testing.expectf(t, len(two) == len(one), "%d bytes, then %d with two unchanged frames", len(one), len(two))
	d, ok := decode(two)
	testing.expect(t, ok && len(d.frames) == 1 && d.frames[0].delay == 57)
	// a delay past what a frame holds: one transparent pixel carries the rest
	long := encode(t, []Picture{frames[0], frames[0]}, []int{60000, 60000})
	testing.expectf(t, len(long) - len(one) <= 32, "%d bytes for an unchanged frame", len(long) - len(one))
	d, ok = decode(long)
	testing.expect(t, ok && len(d.frames) == 2 && d.frames[1].w == 1 && d.frames[1].h == 1 && d.frames[1].delay == 60000)
	testing.expect(t, same(frames[0], d.frames[1].rgb))
}

@(test)
small_change_small_frame :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := sequence(640, 480, 1, 200, 5)[0]
	b := clone(a)
	for y in 100 ..< 103 { for x in 200 ..< 203 { set(b, x, y, 0xFFFFFF) } }
	one := encode(t, []Picture{a})
	two := encode(t, []Picture{a, b})
	testing.expectf(t, len(two) - len(one) < 64, "a 3 x 3 change costs %d bytes", len(two) - len(one))
	d, ok := decode(two)
	testing.expect(t, ok && len(d.frames) == 2)
	f := d.frames[1]
	testing.expectf(t, f.x == 200 && f.y == 100 && f.w == 3 && f.h == 3, "rectangle %d %d %d %d", f.x, f.y, f.w, f.h)
	testing.expect(t, same(b, f.rgb))
}

// A change at each column of rows of several widths (a register of 4 pixels, its tail) gives exactly that rectangle.
@(test)
changed_rectangle_is_exact :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for w in ([?]int{1, 3, 4, 5, 8, 13, 37}) {
		base := picture(w, 5)
		for x in 0 ..< w {
			for x2 in x ..< w {
				b := clone(base)
				set(b, x, 1, 0xFF0000)
				set(b, x2, 3, 0x00FF00)
				d, ok := decode(encode(t, []Picture{base, b}))
				if !testing.expectf(t, ok && len(d.frames) == 2, "width %d, %d..%d", w, x, x2) { continue }
				f := d.frames[1]
				testing.expectf(t, f.x == x && f.w == x2 - x + 1 && f.y == 1 && f.h == 3, "width %d, %d..%d: %d %d %d %d", w, x, x2, f.x, f.y, f.w, f.h)
				testing.expect(t, same(b, f.rgb))
			}
		}
	}
}

@(test)
stride_and_bad_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	frames := sequence(9, 4, 3, 7, 11)
	// (each frame differs from the one before: an unchanged frame is folded into the last one's delay, as it should)
	for k in 1 ..< len(frames) { set(frames[k], k, 0, 0x101010 * u32(k + 1)) }
	e: gif.Encoder
	testing.expect(t, gif.begin(&e, 9, 4, allocator = context.temp_allocator))
	stride := 9 * 4 + 12
	for f in frames {
		padded := make([]u8, stride * 4, context.temp_allocator)
		for &b in padded { b = 0xA5 }
		for y in 0 ..< 4 { copy(padded[y * stride:][:9 * 4], f.bgra[y * 9 * 4:][:9 * 4]) }
		testing.expect(t, gif.add_frame(&e, padded[:stride * 3 + 9 * 4], stride, 5))
	}
	testing.expect(t, !gif.add_frame(&e, frames[0].bgra[:9 * 4 * 4 - 1]))   // (one byte short)
	data, ok := gif.end(&e)
	d, decoded := decode(data)
	testing.expectf(t, ok && decoded && len(d.frames) == 3, "ok %v decoded %v frames %d", ok, decoded, len(d.frames))
	for f, i in frames { testing.expect(t, same(f, d.frames[i].rgb)) }

	testing.expect(t, !gif.begin(&e, 0, 4))
	testing.expect(t, !gif.begin(&e, 70000, 4))
	testing.expect(t, gif.begin(&e, 2, 2, allocator = context.temp_allocator))
	_, ok = gif.end(&e)
	testing.expect(t, !ok)   // (no frame)
}

@(test)
many_colours_come_close :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	p := picture(256, 64)
	for y in 0 ..< 64 {
		for x in 0 ..< 256 { set(p, x, y, u32(x) << 16 | u32(y * 4) << 8 | u32(255 - x)) }
	}
	for options in ([?]gif.Encoder_Options{{}, {quantizer = .Fixed}, {dither = true}, {quantizer = .Fixed, dither = true}}) {
		d, ok := decode(encode(t, []Picture{p}, nil, options))
		if !testing.expectf(t, ok && len(d.frames) == 1, "%v", options) { continue }
		total, worst := 0, 0
		for i in 0 ..< p.w * p.h {
			for c in 0 ..< 3 {
				e := abs(int(d.frames[0].rgb[i * 3 + c]) - int(p.bgra[i * 4 + 2 - c]))
				total += e
				worst = max(worst, e)
			}
		}
		mean := f64(total) / f64(p.w * p.h * 3)
		// (the fixed table's steps are 42 to 51; dithering adds its pattern to every pixel)
		limit := options.quantizer == .Fixed ? 16.0 : 6.0
		if options.dither { limit += 6 }
		testing.expectf(t, mean < limit, "%v: mean error %.2f", options, mean)
		if !options.dither { testing.expectf(t, worst <= (options.quantizer == .Fixed ? 56 : 40), "%v: worst error %d", options, worst) }
	}
}

@(private = "file")
Sink :: struct { bytes: [dynamic]u8, calls: int, fail_at: int }

@(test)
writer_gets_the_same_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	frames := sequence(50, 30, 8, 20, 13)
	frames[4] = frames[3]   // (an unchanged frame: held and merged before the writer sees it)
	whole := encode(t, frames)
	sink := Sink{bytes = make([dynamic]u8, context.temp_allocator)}
	write :: proc(user: rawptr, data: []u8) -> bool {
		s := (^Sink)(user)
		s.calls += 1
		if s.calls == s.fail_at { return false }
		append(&s.bytes, ..data)
		return true
	}
	e: gif.Encoder
	testing.expect(t, gif.begin(&e, 50, 30, 0, {}, write, &sink, context.temp_allocator))
	for f in frames { testing.expect(t, gif.add_frame(&e, f.bgra, 0, 10)) }
	data, ok := gif.end(&e)
	testing.expect(t, ok && data == nil)
	testing.expectf(t, string(sink.bytes[:]) == string(whole), "%d bytes streamed, %d in memory", len(sink.bytes), len(whole))
	testing.expect(t, sink.calls > 2)

	failing := Sink{bytes = make([dynamic]u8, context.temp_allocator), fail_at = 3}
	testing.expect(t, gif.begin(&e, 50, 30, 0, {}, write, &failing, context.temp_allocator))
	refused := false
	for f in frames { if !gif.add_frame(&e, f.bgra, 0, 10) { refused = true } }
	_, ok = gif.end(&e)
	testing.expect(t, refused && !ok)
}
