package gif_test

// gif.decode, the first frame of a file: files made by hand here (a code stream of single indices, each after a clear
// code, so the decoder is checked against no LZW of its own): one pixel, global and local tables, an index past its
// table, transparency, interlace at every small height, a frame off the screen's corner or past its edge, a stream
// that stops early; the encoder's files (long strings, full tables, clear codes) pixel for pixel; and what is refused
// without a panic or a read past the data: every cut of a file, every byte of it changed, codes that name no string,
// no colour table, bad code sizes, a screen past MAX_DECODE_PIXELS.

import "core:testing"
import "../../src/gif"

@(private = "file")
Hand :: struct {
	screen_w, screen_h: int,
	left, top, w, h:    int,
	palette:            []u8,    // RGB triples, padded to a power of two
	local:              bool,    // the table is the frame's, not the screen's
	transparent:        int,     // -1: no graphic control
	interlaced:         bool,
	indices:            []u8,    // in the stream's order
	codes:              []int,   // when set, the stream's codes as they are, at min_size + 1 bits each
	no_end:             bool,    // the stream's terminator comes with no end code
}

@(private = "file")
put16 :: proc(out: ^[dynamic]u8, v: int) { append(out, u8(v), u8(v >> 8)) }

// Codes of `width` bits, least significant first.
@(private = "file")
pack_codes :: proc(codes: []int, width: uint) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	bits: u64
	held: uint
	for c in codes {
		bits |= u64(c) << held
		held += width
		for held >= 8 { append(&out, u8(bits)); bits >>= 8; held -= 8 }
	}
	if held > 0 { append(&out, u8(bits)) }
	return out[:]
}

@(private = "file")
hand_file :: proc(h: Hand) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, "GIF89a")
	put16(&out, h.screen_w)
	put16(&out, h.screen_h)
	bits := 1
	for 1 << uint(bits) < len(h.palette) / 3 { bits += 1 }
	table := make([]u8, 3 << uint(bits), context.temp_allocator)
	copy(table, h.palette)
	if h.local {
		append(&out, 0, 0, 0)
	} else {
		append(&out, 0x80 | u8(bits - 1), 0, 0)
		append(&out, ..table)
	}
	if h.transparent >= 0 { append(&out, 0x21, 0xF9, 4, 1, 0, 0, u8(h.transparent), 0) }
	append(&out, 0x2C)
	put16(&out, h.left)
	put16(&out, h.top)
	put16(&out, h.w)
	put16(&out, h.h)
	flags: u8 = h.interlaced ? 0x40 : 0
	if h.local { flags |= 0x80 | u8(bits - 1) }
	append(&out, flags)
	if h.local { append(&out, ..table) }
	min_size := max(2, bits)
	clear_code := 1 << uint(min_size)
	codes := h.codes
	if codes == nil {
		list := make([dynamic]int, context.temp_allocator)
		for i in h.indices { append(&list, clear_code, int(i)) }
		if !h.no_end { append(&list, clear_code + 1) }
		codes = list[:]
	}
	append(&out, u8(min_size))
	stream := pack_codes(codes, uint(min_size + 1))
	for len(stream) > 0 {
		n := min(len(stream), 255)
		append(&out, u8(n))
		append(&out, ..stream[:n])
		stream = stream[n:]
	}
	append(&out, 0, 0x3B)
	return out[:]
}

@(private = "file")
pixel_of :: proc(rgba: []u8, width, x, y: int) -> [4]u8 {
	i := (y * width + x) * 4
	return {rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]}
}

@(private = "file")
random_next :: proc(state: ^u64) -> u64 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 7
	state^ ~= state^ << 17
	return state^
}

// The encoder's file of one frame, and the RGBA a decoder must give back: `colors` colours (at most 256: kept exactly)
// in runs of 1 to `run` pixels.
@(private = "file")
encoded_file :: proc(t: ^testing.T, w, h, colors, run: int, seed: u64) -> (file: []u8, rgba: []u8) {
	state := seed
	set_of := make([][3]u8, colors, context.temp_allocator)
	for &c in set_of { v := random_next(&state); c = {u8(v), u8(v >> 8), u8(v >> 16)} }
	bgra := make([]u8, w * h * 4, context.temp_allocator)
	rgba = make([]u8, w * h * 4, context.temp_allocator)
	for i := 0; i < w * h; {
		c := set_of[random_next(&state) % u64(colors)]
		for _ in 0 ..< 1 + int(random_next(&state) % u64(run)) {
			if i >= w * h { break }
			bgra[i * 4], bgra[i * 4 + 1], bgra[i * 4 + 2], bgra[i * 4 + 3] = c[2], c[1], c[0], 255
			rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = c[0], c[1], c[2], 255
			i += 1
		}
	}
	e: gif.Encoder
	testing.expect(t, gif.begin(&e, w, h, allocator = context.temp_allocator))
	testing.expect(t, gif.add_frame(&e, bgra))
	ok: bool
	file, ok = gif.end(&e)
	testing.expect(t, ok)
	return
}

// Red, green, blue, white.
@(private = "file")
four_colours :: proc() -> []u8 {
	p := make([]u8, 12, context.temp_allocator)
	copy(p, []u8{255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255})
	return p
}

@(test)
one_pixel :: proc(t: ^testing.T) {
	// (the smallest GIF there is: a two-colour table, the stream clear, 0, end in two bytes)
	file := []u8{'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0x80, 0, 0, 255, 0, 0, 0, 0, 0,
		0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3B}
	rgba, w, h, ok := gif.decode(file, context.temp_allocator)
	if !testing.expect(t, ok, "it reads") { return }
	testing.expect(t, w == 1 && h == 1, "one pixel")
	testing.expect_value(t, pixel_of(rgba, w, 0, 0), [4]u8{255, 0, 0, 255})
}

@(test)
global_and_local_tables :: proc(t: ^testing.T) {
	for local in ([]bool{false, true}) {
		file := hand_file({screen_w = 3, screen_h = 2, w = 3, h = 2, palette = four_colours(), local = local, transparent = -1, indices = {0, 1, 2, 3, 2, 1}})
		rgba, w, h, ok := gif.decode(file, context.temp_allocator)
		if !testing.expectf(t, ok && w == 3 && h == 2, "a %v table reads", local ? "local" : "global") { continue }
		want := [][4]u8{{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 255}, {0, 0, 255, 255}, {0, 255, 0, 255}}
		for c, i in want { testing.expectf(t, pixel_of(rgba, w, i % 3, i / 3) == c, "pixel %d", i) }
	}
	// (two colours, a code size of 2: index 3 is past the table)
	file := hand_file({screen_w = 2, screen_h = 1, w = 2, h = 1, palette = four_colours()[:6], transparent = -1, indices = {1, 3}})
	rgba, w, _, ok := gif.decode(file, context.temp_allocator)
	if !testing.expect(t, ok, "an index past the table reads") { return }
	testing.expect_value(t, pixel_of(rgba, w, 0, 0), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, pixel_of(rgba, w, 1, 0), [4]u8{})
}

@(test)
the_transparent_index :: proc(t: ^testing.T) {
	file := hand_file({screen_w = 2, screen_h = 2, w = 2, h = 2, palette = four_colours(), transparent = 1, indices = {0, 1, 1, 2}})
	rgba, w, _, ok := gif.decode(file, context.temp_allocator)
	if !testing.expect(t, ok, "it reads") { return }
	testing.expect_value(t, pixel_of(rgba, w, 0, 0), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel_of(rgba, w, 1, 0), [4]u8{})
	testing.expect_value(t, pixel_of(rgba, w, 0, 1), [4]u8{})
	testing.expect_value(t, pixel_of(rgba, w, 1, 1), [4]u8{0, 0, 255, 255})
}

@(test)
interlaced_rows_find_their_place :: proc(t: ^testing.T) {
	palette := make([]u8, 16 * 3, context.temp_allocator)
	for i in 0 ..< 16 { palette[i * 3] = u8(i * 16) }
	for height in 1 ..= 16 {
		// (each row's index is its own y, stored in the four passes' order)
		order := make([dynamic]u8, context.temp_allocator)
		for pass in ([][2]int{{0, 8}, {4, 8}, {2, 4}, {1, 2}}) {
			for y := pass[0]; y < height; y += pass[1] { append(&order, u8(y)) }
		}
		file := hand_file({screen_w = 1, screen_h = height, w = 1, h = height, palette = palette, transparent = -1, interlaced = true, indices = order[:]})
		rgba, w, h, ok := gif.decode(file, context.temp_allocator)
		if !testing.expectf(t, ok && h == height, "%d rows read", height) { continue }
		for y in 0 ..< height { testing.expectf(t, pixel_of(rgba, w, 0, y)[0] == u8(y * 16), "%d rows: row %d in its place", height, y) }
	}
}

@(test)
a_frame_on_the_screen :: proc(t: ^testing.T) {
	file := hand_file({screen_w = 4, screen_h = 3, left = 1, top = 1, w = 2, h = 1, palette = four_colours(), transparent = -1, indices = {0, 2}})
	rgba, w, h, ok := gif.decode(file, context.temp_allocator)
	if !testing.expect(t, ok && w == 4 && h == 3, "the screen's size") { return }
	for y in 0 ..< 3 {
		for x in 0 ..< 4 {
			want: [4]u8
			if y == 1 && x == 1 { want = {255, 0, 0, 255} }
			if y == 1 && x == 2 { want = {0, 0, 255, 255} }
			testing.expectf(t, pixel_of(rgba, w, x, y) == want, "(%d, %d): the frame, else transparent", x, y)
		}
	}
	// (a frame past the screen's edge grows the picture, as browsers do)
	file = hand_file({screen_w = 2, screen_h = 2, left = 1, top = 1, w = 2, h = 2, palette = four_colours(), transparent = -1, indices = {3, 3, 3, 3}})
	rgba, w, h, ok = gif.decode(file, context.temp_allocator)
	if !testing.expect(t, ok && w == 3 && h == 3, "grown to the frame") { return }
	testing.expect_value(t, pixel_of(rgba, w, 2, 2), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, pixel_of(rgba, w, 0, 0), [4]u8{})
}

@(test)
a_stream_that_stops_early_keeps_what_came :: proc(t: ^testing.T) {
	file := hand_file({screen_w = 3, screen_h = 1, w = 3, h = 1, palette = four_colours(), transparent = -1, indices = {1}, no_end = true})
	rgba, w, _, ok := gif.decode(file, context.temp_allocator)
	if !testing.expect(t, ok, "it reads") { return }
	testing.expect_value(t, pixel_of(rgba, w, 0, 0), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, pixel_of(rgba, w, 1, 0), [4]u8{})
	testing.expect_value(t, pixel_of(rgba, w, 2, 0), [4]u8{})
}

@(test)
the_encoders_files_read_back :: proc(t: ^testing.T) {
	Case :: struct { w, h, colors, run: int, label: string }
	cases := []Case{
		{1, 1, 1, 1, "one pixel"},
		{13, 7, 5, 3, "odd sides"},
		{300, 200, 1, 1, "one colour: the longest strings, a code that is the string being defined"},
		{256, 128, 200, 1, "noise: the table full many times, clear codes, 12-bit codes"},
		{320, 240, 256, 40, "runs of 256 colours"},
	}
	for c, i in cases {
		file, want := encoded_file(t, c.w, c.h, c.colors, c.run, u64(i) * 7919 + 1)
		rgba, w, h, ok := gif.decode(file, context.temp_allocator)
		if !testing.expectf(t, ok && w == c.w && h == c.h, "%s: it reads", c.label) { continue }
		testing.expectf(t, string(rgba) == string(want), "%s: pixel for pixel", c.label)
	}
}

@(private = "file")
refused :: proc(t: ^testing.T, file: []u8, why: string) {
	_, _, _, ok := gif.decode(file, context.temp_allocator)
	testing.expectf(t, !ok, "refused: %s", why)
}

@(test)
damage_is_refused_never_read_past :: proc(t: ^testing.T) {
	file, _ := encoded_file(t, 64, 48, 60, 4, 42)
	// (the last pixel's code is within the last 3 bytes of data, which the terminator and the trailer follow)
	for cut in 0 ..< len(file) {
		_, _, _, ok := gif.decode(file[:cut], context.temp_allocator)
		if cut < len(file) - 6 { testing.expectf(t, !ok, "cut at %d of %d: refused", cut, len(file)) }
	}
	changed := make([]u8, len(file), context.temp_allocator)
	for at in 0 ..< len(file) {
		for v in ([]u8{0, 1, 0x7F, 0xFF, file[at] ~ 0x10}) {
			copy(changed, file)
			changed[at] = v
			// (a panic or a read past the data fails the test; the heap, freed at once: a changed side makes a canvas of MBs)
			rgba, _, _, ok := gif.decode(changed)
			if ok { delete(rgba) }
		}
	}

	// (two pixels: the decoder stops reading once its frame is full)
	refused(t, hand_file({screen_w = 2, screen_h = 1, w = 2, h = 1, palette = four_colours(), transparent = -1, codes = {4, 0, 7}}), "a code past the next one")
	refused(t, hand_file({screen_w = 1, screen_h = 1, w = 1, h = 1, palette = four_colours(), transparent = -1, codes = {4, 6}}), "a string's code right after a clear")
	refused(t, hand_file({screen_w = 1, screen_h = 1, w = 1, h = 1, palette = four_colours(), transparent = -1, codes = {6}}), "a string's code first")
	no_table := []u8{'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0, 0, 0, 0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3B}
	refused(t, no_table, "no colour table")
	one := []u8{'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0x80, 0, 0, 255, 0, 0, 0, 0, 0,
		0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3B}
	for size in ([]u8{0, 9, 12, 255}) {
		bad := make([]u8, len(one), context.temp_allocator)
		copy(bad, one)
		bad[29] = size
		refused(t, bad, "a code size out of 1 ..= 8")
	}
	refused(t, []u8{'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0, 0, 0, 0x3B}, "the trailer before any frame")
	refused(t, []u8{'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0, 0, 0, 0x99}, "a byte that starts no block")
	refused(t, hand_file({screen_w = 65535, screen_h = 65535, w = 1, h = 1, palette = four_colours(), transparent = -1, indices = {0}}), "a screen past MAX_DECODE_PIXELS")
	refused(t, hand_file({screen_w = 1, screen_h = 1, left = 65534, top = 65534, w = 1, h = 1, palette = four_colours(), transparent = -1, indices = {0}}), "a frame that grows the screen past MAX_DECODE_PIXELS")
	refused(t, hand_file({screen_w = 1, screen_h = 1, w = 65535, h = 65535, palette = four_colours(), transparent = -1, indices = {0}}), "a frame past MAX_DECODE_PIXELS")
	_, _, _, ok := gif.decode(hand_file({screen_w = 2048, screen_h = 2048, w = 1, h = 1, palette = four_colours(), transparent = -1, indices = {0}}), context.temp_allocator)
	testing.expect(t, ok, "a large screen within the limit reads")
}
