// Tests of the COLR interpreter: the color-fonts test glyphs against Direct2D, tables made hostile, Noto Color Emoji
// (tools\fetch_emoji.ps1 puts it in build\emoji; the tests that need it are skipped without it) shaped, drawn and
// reached through the built-in emoji fallback.
package colr_test

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../../font"

COLRV1 :: #load("../color_glyphs/data/test_glyphs-glyf_colr_1.ttf")

EMOJI_DIR :: #config(EMOJI_DIR, "build/emoji")

emoji_font :: proc() -> (data: []byte, ok: bool) {
	d, err := os.read_entire_file(fmt.tprintf("%s/NotoColorEmoji-COLRv1.ttf", EMOJI_DIR), context.temp_allocator)
	return d, err == nil
}

// The fully qualified sequences of emoji-test.txt, as UTF-8 (temp allocator).
emoji_sequences :: proc() -> (list: []string, ok: bool) {
	data, err := os.read_entire_file(fmt.tprintf("%s/emoji-test.txt", EMOJI_DIR), context.temp_allocator)
	if err != nil { return nil, false }
	out := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if len(line) == 0 || line[0] == '#' || !strings.contains(line, "; fully-qualified") { continue }
		sb := strings.builder_make(context.temp_allocator)
		for tok in strings.fields(line[:strings.index_byte(line, ';')], context.temp_allocator) {
			v, _ := strconv.parse_int(tok, 16)
			strings.write_rune(&sb, rune(v))
		}
		append(&out, strings.to_string(sb))
	}
	return out[:], true
}

// A glyph bitmap read back from its atlas page: straight-alpha RGBA.
Bitmap :: struct {
	w, h:   int,
	offset: [2]int,
	px:     [][4]u8,
}

bitmap_of :: proc(s: ^font.State, img: font.Glyph_Image) -> (b: Bitmap) {
	if img.page < 0 { return }
	Sync :: struct { stride: int, pixels: []u8 }
	sy: Sync
	font.atlas_sync_page(s, int(img.page), 0, &sy, proc(user: rawptr, page: int, kind: font.Page_Kind, x, y, w, h: int, pixels: []u8, stride: int) {
		(^Sync)(user)^ = Sync{stride, pixels}
	})
	b.w, b.h, b.offset = int(img.size.x), int(img.size.y), {int(img.offset.x), int(img.offset.y)}
	b.px = make([][4]u8, b.w * b.h, context.temp_allocator)
	for row in 0 ..< b.h {
		for col in 0 ..< b.w {
			o := (int(img.uv[1]) + row) * sy.stride + (int(img.uv[0]) + col) * 4
			b.px[row * b.w + col] = {sy.pixels[o], sy.pixels[o + 1], sy.pixels[o + 2], sy.pixels[o + 3]}
		}
	}
	return
}

// Mean absolute difference per channel (0 ..= 255) of two bitmaps on white, over the union of their boxes.
difference :: proc(a, b: Bitmap) -> f32 {
	x0, y0 := min(a.offset.x, b.offset.x), min(a.offset.y, b.offset.y)
	x1, y1 := max(a.offset.x + a.w, b.offset.x + b.w), max(a.offset.y + a.h, b.offset.y + b.h)
	w, h := x1 - x0, y1 - y0
	if w <= 0 || h <= 0 { return 0 }
	on_white :: proc(b: Bitmap, x, y: int) -> [3]f32 {
		lx, ly := x - b.offset.x, y - b.offset.y
		if lx < 0 || ly < 0 || lx >= b.w || ly >= b.h { return {255, 255, 255} }
		p := b.px[ly * b.w + lx]
		al := f32(p[3]) / 255
		return {f32(p[0]) * al + 255 * (1 - al), f32(p[1]) * al + 255 * (1 - al), f32(p[2]) * al + 255 * (1 - al)}
	}
	sum: f32
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			p, q := on_white(a, x, y), on_white(b, x, y)
			sum += abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)
		}
	}
	return sum / f32(w * h * 3)
}

utf8 :: proc(r: rune) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_rune(&sb, r)
	return strings.to_string(sb)
}

// Both engines on the test font's glyphs: they must agree (Direct2D is the other implementation of the same format on
// this machine). The cycle glyphs are refused by the interpreter, drawn as their outline.
@(test)
interpreter_agrees_with_direct2d :: proc(t: ^testing.T) {
	sd, sb: font.State
	font.init(&sd)
	font.init(&sb)
	defer font.destroy(&sd)
	defer font.destroy(&sb)
	st := sb.settings
	st.color_engine = .Builtin
	font.set_settings(&sb, st)
	fd, ok1 := font.load_embedded(&sd, COLRV1)
	fb, ok2 := font.load_embedded(&sb, COLRV1)
	testing.expect(t, ok1 && ok2)
	if !font.color_renderable(&sd, fd) || font.colr_of(&sd, fd) == nil { fmt.println("skipped: Direct2D cannot draw COLR v1 paint graphs here"); return }
	cd := font.cascade(&sd, {{font = fd}}, nil, true)
	cb := font.cascade(&sb, {{font = fb}}, nil, true)
	n, bad := 0, 0
	sum, worst: f32
	worst_cp: rune
	for r := rune(0xF0000); r < 0xF2000; r += 1 {
		if r >= 0xF1100 && r < 0xF1200 { continue }   // the PaintColrGlyph cycle: DirectWrite throws and catches a C++ exception, which the test runner's handler takes for a crash
		shd := font.shape(&sd, cd, 64, utf8(r), {}, context.temp_allocator)
		shb := font.shape(&sb, cb, 64, utf8(r), {}, context.temp_allocator)
		if len(shd.glyphs) != 1 || len(shb.glyphs) != 1 || shd.glyphs[0].id == 0 { continue }
		a := font.glyph_image(&sd, fd, shd.glyphs[0].id, 64, 0)
		b := font.glyph_image(&sb, fb, shb.glyphs[0].id, 64, 0)
		if !a.color { continue }
		if !b.color { bad += 1; continue }
		d := difference(bitmap_of(&sd, a), bitmap_of(&sb, b))
		sum += d
		n += 1
		if d > worst { worst, worst_cp = d, r }
	}
	drawn, refused := font.colr_counts(&sb)
	fmt.printf("%d glyphs: mean difference %.3f /255, worst U+%X %.2f; interpreter %d drawn, %d refused, %d without color\n", n, sum / f32(max(n, 1)), worst_cp, worst, drawn, refused, bad)
	testing.expect(t, n > 150)
	testing.expectf(t, sum / f32(n) < 1.5, "mean difference %.3f", sum / f32(n))
	testing.expectf(t, worst < 8, "worst glyph U+%X differs by %.2f", worst_cp, worst)
	testing.expectf(t, refused <= 3, "%d glyphs refused", refused)
}

// A glyph that is its own descendant (PaintColrGlyph) is refused, not drawn forever: the outline shows.
@(test)
cycle_is_refused :: proc(t: ^testing.T) {
	s: font.State
	font.init(&s)
	defer font.destroy(&s)
	st := s.settings
	st.color_engine = .Builtin
	font.set_settings(&s, st)
	id, ok := font.load_embedded(&s, COLRV1)
	testing.expect(t, ok)
	cas := font.cascade(&s, {{font = id}}, nil, true)
	sh := font.shape(&s, cas, 48, "\U000F1100", {}, context.temp_allocator)
	testing.expect_value(t, len(sh.glyphs), 1)
	img := font.glyph_image(&s, id, sh.glyphs[0].id, 48, 0)
	_, refused := font.colr_counts(&s)
	testing.expectf(t, refused >= 1 && !img.color, "refused %d, color %v", refused, img.color)
}

// The table's own bytes made hostile: the interpreter reads them as untrusted. No crash, no endless graph, no huge canvas.
@(test)
hostile_tables_are_survived :: proc(t: ^testing.T) {
	colr, ok := sfnt_table(COLRV1, "COLR")
	testing.expect(t, ok)
	cpal, _ := sfnt_table(COLRV1, "CPAL")
	box := font.Outline{}
	append(&box.quads, font.Quad{{{0, 0}, {1, 0}, {1, 0}}}, font.Quad{{{1, 0}, {1, 1}, {1, 1}}}, font.Quad{{{1, 1}, {0, 1}, {0, 1}}}, font.Quad{{{0, 1}, {0, 0}, {0, 0}}})
	defer delete(box.quads)
	outline := proc(user: rawptr, gid: u16) -> ^font.Outline { return (^font.Outline)(user) }
	rng := rand.create(12345)
	context.random_generator = rand.default_random_generator(&rng)
	mutated := make([]u8, len(colr), context.temp_allocator)
	rendered, opened := 0, 0
	for round in 0 ..< 400 {
		copy(mutated, colr)
		// a few bytes anywhere, and now and then a run of 0xFF or 0x00
		for _ in 0 ..< 1 + round % 24 { mutated[rand.int_max(len(mutated))] = u8(rand.int_max(256)) }
		if round % 5 == 0 { start := rand.int_max(len(mutated) - 64); for k in 0 ..< 32 { mutated[start + k] = round % 10 == 0 ? 0xFF : 0 } }
		c := font.colr_open(mutated, cpal)
		if c == nil { continue }
		opened += 1
		for gid in 0 ..< 400 {
			if !font.colr_has_glyph(c, u16(gid)) { continue }
			bm, drew := font.colr_render({colr = c, upem = 1000, outline = outline, user = &box}, u16(gid), {size = 40, fg = {10, 20, 30}, samples = 4}, context.temp_allocator)
			if drew { rendered += 1 }
			testing.expect(t, bm.w <= font.COLR_CANVAS_LIMIT && bm.h <= font.COLR_CANVAS_LIMIT)
		}
		font.colr_destroy(c)
	}
	fmt.printf("hostile tables: %d opened, %d glyphs drawn\n", opened, rendered)
	testing.expect(t, opened > 50 && rendered > 500)
}

// Table `tag` of a font file (the bytes inside it).
sfnt_table :: proc(data: []u8, tag: string) -> ([]u8, bool) {
	n := int(data[4]) << 8 | int(data[5])
	for i in 0 ..< n {
		o := 12 + 16 * i
		if string(data[o:][:4]) != tag { continue }
		off := int(data[o + 8]) << 24 | int(data[o + 9]) << 16 | int(data[o + 10]) << 8 | int(data[o + 11])
		length := int(data[o + 12]) << 24 | int(data[o + 13]) << 16 | int(data[o + 14]) << 8 | int(data[o + 15])
		return data[off:][:length], true
	}
	return nil, false
}

// Every emoji of Unicode's list shaped with the font alone: one glyph each (a ligature for sequences), not .notdef.
@(test)
emoji_sequences_shape_to_one_glyph :: proc(t: ^testing.T) {
	data, ok := emoji_font()
	if !ok { fmt.println("skipped: build/emoji/NotoColorEmoji-COLRv1.ttf is missing (tools\\fetch_emoji.ps1)"); return }
	seqs, ok2 := emoji_sequences()
	if !ok2 { fmt.println("skipped: emoji-test.txt is missing (tools\\fetch_emoji.ps1 -Unicode)"); return }
	s: font.State
	font.init(&s)
	defer font.destroy(&s)
	id, loaded := font.load_embedded(&s, data)
	testing.expect(t, loaded)
	cas := font.cascade(&s, {{font = id}}, nil, true)
	bad := 0
	for q in seqs {
		sh := font.shape(&s, cas, 32, q, {}, context.temp_allocator)
		one := len(sh.glyphs) == 1 && sh.glyphs[0].id != 0 && sh.glyphs[0].face == id
		if !one {
			bad += 1
			if bad <= 12 {
				cps := make([dynamic]string, context.temp_allocator)
				for r in q { append(&cps, fmt.tprintf("%X", u32(r))) }
				fmt.printf("not one glyph: %s -> %d glyphs\n", strings.join(cps[:], " ", context.temp_allocator), len(sh.glyphs))
			}
		}
	}
	fmt.printf("%d sequences, %d not shaped to one glyph\n", len(seqs), bad)
	testing.expectf(t, bad == 0, "%d of %d emoji sequences are not one glyph", bad, len(seqs))
}

// Noto Color Emoji drawn by both engines at a few sizes: the same pictures (the tools\colrboard board holds the
// interpreter to Chrome's, to 0.8 / 255).
@(test)
noto_emoji_agree_with_direct2d :: proc(t: ^testing.T) {
	data, ok := emoji_font()
	if !ok { fmt.println("skipped: build/emoji/NotoColorEmoji-COLRv1.ttf is missing"); return }
	sd, sb: font.State
	font.init(&sd)
	font.init(&sb)
	defer font.destroy(&sd)
	defer font.destroy(&sb)
	st := sb.settings
	st.color_engine = .Builtin
	font.set_settings(&sb, st)
	fd, _ := font.load_embedded(&sd, data)
	fb, _ := font.load_embedded(&sb, data)
	if !font.color_renderable(&sd, fd) { fmt.println("skipped: Direct2D cannot draw COLR v1 here"); return }
	cd := font.cascade(&sd, {{font = fd}}, nil, true)
	cb := font.cascade(&sb, {{font = fb}}, nil, true)
	n: int
	sum, worst: f32
	for r := rune(0x1F300); r < 0x1F650; r += 7 {
		for size in ([?]f32{24, 64}) {
			shd := font.shape(&sd, cd, size, utf8(r), {}, context.temp_allocator)
			shb := font.shape(&sb, cb, size, utf8(r), {}, context.temp_allocator)
			if len(shd.glyphs) != 1 || len(shb.glyphs) != 1 || shd.glyphs[0].id == 0 { continue }
			a := font.glyph_image(&sd, fd, shd.glyphs[0].id, size, 0)
			b := font.glyph_image(&sb, fb, shb.glyphs[0].id, size, 0)
			if !a.color || !b.color { continue }
			d := difference(bitmap_of(&sd, a), bitmap_of(&sb, b))
			sum += d
			worst = max(worst, d)
			n += 1
		}
	}
	_, refused := font.colr_counts(&sb)
	fmt.printf("%d emoji pictures: mean difference %.3f /255, worst %.2f, %d refused\n", n, sum / f32(max(n, 1)), worst, refused)
	testing.expect(t, n > 100)
	testing.expectf(t, sum / f32(n) < 3, "mean difference %.3f", sum / f32(n))
	testing.expectf(t, worst < 25, "worst difference %.2f", worst)
	testing.expect_value(t, refused, 0)
}

// The emoji font as the fallback of a text face: emoji characters, sequences, keycaps and VS16 come from it, one glyph
// per emoji, and the text around them from the text face.
@(test)
emoji_fallback_in_a_cascade :: proc(t: ^testing.T) {
	data, ok := emoji_font()
	if !ok { fmt.println("skipped: build/emoji/NotoColorEmoji-COLRv1.ttf is missing"); return }
	s: font.State
	font.init(&s)
	defer font.destroy(&s)
	text, tok := font.load_embedded(&s, font.FALLBACK_UI_DATA)
	testing.expect(t, tok)
	// no emoji source: a face without the character shows .notdef (system fallback off keeps the test off the machine's fonts)
	cas := font.cascade(&s, {{font = text}}, nil, true)
	before := font.shape(&s, cas, 20, "a\U0001F600", {}, context.temp_allocator)
	for g in before.glyphs { testing.expect_value(t, g.face, text) }
	testing.expect(t, !font.has_emoji_source(&s))
	font.set_emoji_source(&s, data = data)
	testing.expect(t, font.has_emoji_source(&s))
	Case :: struct { text: string, glyphs: int, emoji: int }   // emoji: the index of the one glyph from the emoji font (-1: none)
	cases := [?]Case{
		{"x\U0001F600y", 3, 1},                                              // an emoji between letters
		{"\U0001F468\u200D\U0001F469\u200D\U0001F467", 1, 0},                // a ZWJ family
		{"\U0001F44B\U0001F3FD", 1, 0},                                      // a hand with a skin tone
		{"\U0001F1EB\U0001F1F7", 1, 0},                                      // a flag (two regional indicators)
		{"1\uFE0F\u20E3", 1, 0},                                             // a keycap
		{"\u2764\uFE0F", 1, 0},                                              // a text-default emoji with VS16
		{"\U0001F3F4\U000E0067\U000E0062\U000E0065\U000E006E\U000E0067\U000E007F", 1, 0},   // England: a tag sequence
		{"7 1", 3, -1},                                                      // digits stay in the text face
	}
	for c in cases {
		sh := font.shape(&s, cas, 20, c.text, {}, context.temp_allocator)
		testing.expectf(t, len(sh.glyphs) == c.glyphs, "%q: %d glyphs, want %d", c.text, len(sh.glyphs), c.glyphs)
		ef := font.emoji_face(&s)
		testing.expect(t, ef != 0)
		for g, i in sh.glyphs {
			want_emoji := i == c.emoji
			testing.expectf(t, (g.face == ef) == want_emoji, "%q glyph %d from face %d (emoji face %d)", c.text, i, g.face, ef)
		}
	}
	// a character with a text glyph in the text face stays there even with the emoji font set
	plain := font.shape(&s, cas, 20, "\u00A9", {}, context.temp_allocator)
	for g in plain.glyphs { testing.expect_value(t, g.face, text) }
	// taking the source away
	font.set_emoji_source(&s)
	after := font.shape(&s, cas, 20, "\U0001F600", {}, context.temp_allocator)
	for g in after.glyphs { testing.expect_value(t, g.face, text) }
}
