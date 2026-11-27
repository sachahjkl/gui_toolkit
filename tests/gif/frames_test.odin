package gif_test

// gif.Decoder and gif.decode_frames (moved from galerie with its tests): every frame drawn over what the one before left
// (disposal 1 keeps, 2 clears to transparent, 3 puts back), short delays shown as browsers show them, the first frame
// alone for a thumbnail, a frame that asks for 65535 by 65535 refused, a frame past the screen clipped, and a fuzz test
// with a fixed seed: never a read outside the file, never a frame list past its budget.

import "core:math/rand"
import "core:testing"
import "gt:gif"

// A GIF written by hand: a screen of `w` by `h`, four colours (black, red, green, blue), its frames with their
// disposal and delay. The codes are written with a clear before each: every pixel one code, the table never grows.
@(private = "file")
Gif_Frame :: struct { left, top, w, h: int, pixels: []u8, disposal, delay_cs: int, transparent: int }

@(private = "file")
gif_by_hand :: proc(w, h: int, frames: []Gif_Frame) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	u16le :: proc(b: ^[dynamic]u8, v: int) { append(b, u8(v), u8(v >> 8)) }
	append(&b, ..transmute([]u8)string("GIF89a"))
	u16le(&b, w); u16le(&b, h)
	append(&b, 0x81, 0, 0)   // (a global table of 4 colours)
	append(&b, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255)
	for f in frames {
		packed := u8(f.disposal << 2) | (f.transparent >= 0 ? 1 : 0)
		append(&b, 0x21, 0xF9, 4, packed, u8(f.delay_cs), u8(f.delay_cs >> 8), u8(max(f.transparent, 0)), 0)
		append(&b, 0x2C)
		u16le(&b, f.left); u16le(&b, f.top); u16le(&b, f.w); u16le(&b, f.h)
		append(&b, 0, 2)   // (no local table; codes of 2 bits, 3 bits on the wire)
		codes := make([dynamic]u8, context.temp_allocator)
		bits, held := u32(0), 0
		put :: proc(codes: ^[dynamic]u8, bits: ^u32, held: ^int, c: u32) {
			bits^ |= c << uint(held^)
			held^ += 3
			for held^ >= 8 { append(codes, u8(bits^)); bits^ >>= 8; held^ -= 8 }
		}
		for p in f.pixels { put(&codes, &bits, &held, 4); put(&codes, &bits, &held, u32(p)) }
		put(&codes, &bits, &held, 5)
		if held > 0 { append(&codes, u8(bits)) }
		for i := 0; i < len(codes); i += 255 {
			n := min(255, len(codes) - i)
			append(&b, u8(n))
			append(&b, ..codes[i:][:n])
		}
		append(&b, 0)
	}
	append(&b, 0x3B)
	return b[:]
}

@(private = "file")
pixel :: proc(frames: []gif.Frame, w, x, y, frame: int) -> [4]u8 {
	p := frames[frame].pixels[(y * w + x) * 4:][:4]
	return {p[0], p[1], p[2], p[3]}
}

@(test)
every_frame_with_its_disposal_and_delay :: proc(t: ^testing.T) {
	red := [?]u8{1, 1, 1, 1}
	green := [?]u8{2}
	blue := [?]u8{3}
	hand := [?]Gif_Frame{
		{0, 0, 2, 2, red[:], 1, 0, -1},     // the whole screen red, kept
		{0, 0, 1, 1, green[:], 3, 5, -1},   // the top left green, then put back
		{1, 1, 1, 1, blue[:], 2, 2, -1},    // the bottom right blue, then cleared
		{1, 0, 1, 1, green[:], 1, 7, 2},    // a transparent pixel: what was there shows through
	}
	data := gif_by_hand(2, 2, hand[:])
	frames, w, h, ok := gif.decode_frames(data, allocator = context.temp_allocator)
	if !testing.expect(t, ok) { return }
	testing.expect_value(t, w, 2)
	testing.expect_value(t, h, 2)
	testing.expect_value(t, len(frames), 4)
	R, G, B, CLEAR := [4]u8{255, 0, 0, 255}, [4]u8{0, 255, 0, 255}, [4]u8{0, 0, 255, 255}, [4]u8{0, 0, 0, 0}
	testing.expect_value(t, pixel(frames, w, 0, 0, 0), R)
	testing.expect_value(t, pixel(frames, w, 0, 0, 1), G)
	// (frame 1 put back: frame 2 has red there again, and its blue)
	testing.expect_value(t, pixel(frames, w, 0, 0, 2), R)
	testing.expect_value(t, pixel(frames, w, 1, 1, 2), B)
	// (frame 2 cleared: transparent there in frame 3; frame 3's pixel is transparent, the red shows)
	testing.expect_value(t, pixel(frames, w, 1, 1, 3), CLEAR)
	testing.expect_value(t, pixel(frames, w, 1, 0, 3), R)
	testing.expect_value(t, frames[0].delay_ms, gif.SLOW_DELAY_MS)   // (none said)
	testing.expect_value(t, frames[1].delay_ms, 50)
	testing.expect_value(t, frames[2].delay_ms, 20)
	testing.expect_value(t, frames[3].delay_ms, 70)

	// a thumbnail reads the first frame alone; decode gives the same picture
	still, _, _, ok2 := gif.decode_frames(data, {first = true}, context.temp_allocator)
	testing.expect(t, ok2)
	testing.expect_value(t, len(still), 1)
	first, fw, fh, ok3 := gif.decode(data, context.temp_allocator)
	testing.expect(t, ok3 && fw == 2 && fh == 2)
	testing.expect(t, string(first) == string(frames[0].pixels), "decode is the first frame")

	// a budget of two frames' bytes: the first two
	two, _, _, ok4 := gif.decode_frames(data, {max_bytes = 2 * 2 * 2 * 4}, context.temp_allocator)
	testing.expect(t, ok4)
	testing.expect_value(t, len(two), 2)

	// the decoder gives the same frames one by one, then says no more
	d: gif.Decoder
	testing.expect(t, gif.decoder_init(&d, data))
	defer gif.decoder_destroy(&d)
	n := 0
	for {
		px, delay, next := gif.next_frame(&d)
		if !next { break }
		testing.expect(t, string(px) == string(frames[n].pixels))
		testing.expect_value(t, delay, frames[n].delay_ms)
		n += 1
	}
	testing.expect_value(t, n, 4)
}

// A frame that says it is 65535 by 65535 on a screen of 2 by 2: refused at once, never 4 GB asked; the frames before it
// stay. A frame past the screen's side is clipped.
@(test)
a_frame_cannot_ask_for_the_moon :: proc(t: ^testing.T) {
	red := [?]u8{1, 1, 1, 1}
	data := gif_by_hand(2, 2, {{0, 0, 2, 2, red[:], 1, 0, -1}, {0, 0, 2, 2, red[:], 1, 0, -1}})
	at_desc := -1
	seen := 0
	for i in 0 ..< len(data) - 9 {
		if data[i] == 0x2C && data[i + 1] == 0 && data[i + 3] == 0 && data[i + 5] == 2 {
			seen += 1
			if seen == 2 { at_desc = i }
		}
	}
	testing.expect(t, at_desc > 0)
	data[at_desc + 5], data[at_desc + 6], data[at_desc + 7], data[at_desc + 8] = 0xFF, 0xFF, 0xFF, 0xFF
	frames, _, _, ok := gif.decode_frames(data, allocator = context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(frames), 1)
	// (the canvas is the first frame's: what a caller checks its limits against, nothing decoded)
	size, sized := gif.canvas_size(data)
	testing.expect(t, sized && size == {2, 2})
	first := data[:at_desc]
	_, cut := gif.canvas_size(first[:13])
	testing.expect(t, !cut, "cut before its first frame: no size")

	// (a second frame wider than the screen: its row 1 is red, green and a blue past the side, clipped)
	wide := [?]u8{1, 2, 3, 1, 2, 3}
	two := gif_by_hand(2, 2, {{0, 0, 2, 2, red[:], 1, 0, -1}, {0, 0, 3, 2, wide[:], 1, 0, -1}})
	q, w, _, ok2 := gif.decode_frames(two, allocator = context.temp_allocator)
	testing.expect(t, ok2 && len(q) == 2 && w == 2)
	testing.expect_value(t, pixel(q, w, 1, 1, 1), [4]u8{0, 255, 0, 255})
}

// The rounds of the fuzz test (more with -define:GIF_FUZZ_ROUNDS=n, a fixed seed: a failure reproduces).
FUZZ_ROUNDS :: #config(GIF_FUZZ_ROUNDS, 4000)
FUZZ_SEED :: 0x91f

// Damaged and crafted GIFs decode to frames or to a refusal: never a read outside the file (the tests check bounds),
// never a frame list past its budget.
@(test)
frames_fuzz :: proc(t: ^testing.T) {
	r := rand.create(FUZZ_SEED)
	gen := rand.default_random_generator(&r)
	for round in 0 ..< FUZZ_ROUNDS {
		free_all(context.temp_allocator)
		red := [?]u8{1, 2, 3, 0, 1, 2}
		seeds := [?][]u8{
			gif_by_hand(3, 2, {{0, 0, 3, 2, red[:], 1, 0, -1}, {1, 0, 2, 1, red[:2], 2, 3, 0}, {0, 1, 1, 1, red[:1], 3, 9, -1}}),
			gif_by_hand(1, 1, {{0, 0, 1, 1, red[:1], 0, 0, -1}}),
		}
		base := seeds[round % len(seeds)]
		data := make([dynamic]u8, context.temp_allocator)
		append(&data, ..base)
		for _ in 0 ..< 1 + rand.int_max(6, gen) {
			if len(data) == 0 { break }
			i := rand.int_max(len(data), gen)
			switch rand.int_max(5, gen) {
			case 0: data[i] ~= u8(1) << uint(rand.int_max(8, gen))
			case 1:
				edges := [?]u8{0, 1, 2, 0x7F, 0x80, 0xFF}
				data[i] = edges[rand.int_max(len(edges), gen)]
			case 2: data[i] = u8(rand.uint32(gen))
			case 3: resize(&data, i)
			case 4: inject_at(&data, i, u8(rand.uint32(gen)))
			}
		}
		budget := 1 << 20
		frames, w, h, ok := gif.decode_frames(data[:], {max_bytes = budget}, context.temp_allocator)
		if ok {
			testing.expect(t, len(frames) > 0 && w > 0 && h > 0)
			testing.expect(t, len(frames) == 1 || len(frames) * w * h * 4 <= budget)
			for f in frames { testing.expect_value(t, len(f.pixels), w * h * 4) }
		}
	}
}
