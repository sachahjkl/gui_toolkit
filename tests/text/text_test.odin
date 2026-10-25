// Tests of the DirectWrite text stack: faces, fallback, shaping, bidi, line breaks, color glyphs, the atlas.
//   odin test tests/text -vet
package text_test

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "../../font"

setup :: proc(t: ^testing.T, settings := font.DEFAULT_SETTINGS) -> ^font.State {
	s := new(font.State)
	font.init(s, settings)
	testing.expect(t, s.ok, "DirectWrite did not start")
	return s
}

teardown :: proc(s: ^font.State) {
	font.destroy(s)
	free(s)
}

sys :: proc(t: ^testing.T, s: ^font.State, family: string, weight := 400, style := font.Font_Style.Normal) -> font.Font_Id {
	id, ok := font.load_system(s, family, weight, style)
	testing.expectf(t, ok, "system font %q missing", family)
	return id
}

@(test)
system_faces_and_metrics :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	a := sys(t, s, "Segoe UI")
	b := sys(t, s, "segoe ui", 400)
	testing.expect_value(t, a, b)   // shared
	bold := sys(t, s, "Segoe UI", 700)
	testing.expect(t, bold != a)
	testing.expect(t, font.has_system_family(s, "Arial"))
	testing.expect(t, !font.has_system_family(s, "No Such Family 1234"))
	_, ok := font.load_system(s, "No Such Family 1234")
	testing.expect(t, !ok)
	m := font.metrics(s, a, 20)
	testing.expect(t, m.ascent > 15 && m.ascent < 25 && m.descent > 3 && m.x_height > 7 && m.x_height < 13)
	w := font.text_width(s, a, 20, "Hello")
	testing.expect(t, w > 30 && w < 70)
	testing.expect(t, font.text_width(s, bold, 20, "Hello") > w)
	// widths add up word by word, spaces included
	ww := font.text_width(s, a, 20, "Hello world")
	testing.expect(t, abs(ww - (w + font.text_width(s, a, 20, " ") + font.text_width(s, a, 20, "world"))) < 0.01)
}

@(test)
memory_faces :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	id, ok := font.load_embedded(s, font.FALLBACK_UI_DATA)
	testing.expect(t, ok)
	testing.expect(t, font.text_width(s, id, 16, "Roboto") > 20)
	data := make([]byte, len(font.FALLBACK_MONO_DATA))
	copy(data, font.FALLBACK_MONO_DATA)
	mono, ok2 := font.load_from_memory(s, data)
	testing.expect(t, ok2)
	// monospace: every letter has the same advance
	testing.expect(t, abs(font.text_width(s, mono, 16, "iiii") - font.text_width(s, mono, 16, "WWWW")) < 0.01)
	bold := font.with_simulations(s, mono, true, false)
	testing.expect(t, bold != mono)
	font.unload(s, mono)
	font.unload(s, bold)
	testing.expect(t, !font.valid(s, mono))
	// (malformed data is refused too, but DirectWrite throws and catches a C++ exception meanwhile, which the test
	// runner's exception handler takes for a crash)
	_, bad := font.load_from_memory(s, nil)
	testing.expect(t, !bad)
}

// U+2190 in a font without arrows comes from a system font.
@(test)
fallback_per_character :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	latin, ok := font.load_embedded(s, font.FALLBACK_MONO_DATA)
	testing.expect(t, ok)
	text := "\u2190 retour \u0915\u093f \U0001F600 \u4e2d\u6587"
	sh := font.shape(s, latin, 16, text, {}, context.temp_allocator)
	faces: map[font.Font_Id]bool
	defer delete(faces)
	for g in sh.glyphs {
		faces[g.face] = true
		testing.expectf(t, g.id != 0, "glyph %v (cluster %d) is .notdef", g, g.cluster)
	}
	testing.expect(t, len(faces) >= 3, "the arrow, Devanagari, emoji and CJK should come from other faces")
	// the arrow's glyph is not from the latin face
	for g in sh.glyphs {
		if g.cluster == 0 { testing.expect(t, g.face != latin) }
	}
	// a cascade: the first entry covers only its unicode-range
	ui := sys(t, s, "Segoe UI")
	c := font.cascade(s, {{font = latin, ranges = {{0x30, 0x39}}}, {font = ui}})
	sh2 := font.shape(s, c, 16, "a1", {}, context.temp_allocator)
	testing.expect_value(t, len(sh2.glyphs), 2)
	testing.expect_value(t, sh2.glyphs[0].face, ui)
	testing.expect_value(t, sh2.glyphs[1].face, latin)
}

@(test)
ligatures_and_kerning :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	cal := sys(t, s, "Calibri")
	sh := font.shape(s, cal, 32, "fi", {}, context.temp_allocator)
	testing.expect_value(t, len(sh.glyphs), 1)   // the fi ligature
	testing.expect_value(t, len(sh.clusters), 1)
	// letter-spacing turns optional ligatures off
	sh_ls := font.shape(s, cal, 32, "fi", {letter_spacing = 2}, context.temp_allocator)
	testing.expect_value(t, len(sh_ls.glyphs), 2)
	// a feature off in the cascade
	noliga := font.cascade(s, {{font = cal}}, {{tag = {'l', 'i', 'g', 'a'}, value = 0}})
	testing.expect_value(t, len(font.shape(s, noliga, 32, "fi", {}, context.temp_allocator).glyphs), 2)
	// caret inside a ligature: shared out
	x1 := font.caret_x(sh, "fi", 1)
	testing.expect(t, x1 > 0 && x1 < sh.width)
	arial := sys(t, s, "Arial")
	av := font.text_width(s, arial, 40, "AV")
	apart := font.text_width(s, arial, 40, "A") + font.text_width(s, arial, 40, "V")
	testing.expectf(t, av < apart - 0.5, "AV is not kerned: %v vs %v", av, apart)
	nokern := font.cascade(s, {{font = arial}}, {{tag = {'k', 'e', 'r', 'n'}, value = 0}})
	testing.expect(t, abs(font.text_width(s, nokern, 40, "AV") - apart) < 0.01)
}

@(test)
complex_scripts :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	// Arabic: letters join (contextual forms differ from the isolated ones)
	word := "\u0633\u0644\u0627\u0645"   // سلام
	sh := font.shape(s, ui, 24, word, {}, context.temp_allocator)
	testing.expect(t, len(sh.glyphs) >= 3)
	testing.expect(t, sh.glyphs[0].rtl)
	iso := font.shape(s, ui, 24, "\u0633", {}, context.temp_allocator)
	// the first letter (rightmost glyph) in initial form, not isolated
	last := sh.glyphs[len(sh.glyphs) - 1]
	testing.expect(t, last.id != iso.glyphs[0].id, "Arabic letters are not joined")
	// visual order: the first character is at the right
	c0 := sh.clusters[0]
	testing.expect(t, c0.x1 > sh.width - 0.5)
	// Devanagari: the i matra goes before its consonant (reordering), "क्षि" is less glyphs than characters
	dev := "\u0915\u093f"
	shd := font.shape(s, ui, 24, dev, {}, context.temp_allocator)
	testing.expect(t, len(shd.glyphs) >= 1)
	if len(shd.glyphs) == 2 {
		testing.expect(t, shd.glyphs[0].x <= shd.glyphs[1].x)
	}
	testing.expect_value(t, len(shd.clusters), 1)   // one cluster: the caret never splits it
	kssa := font.shape(s, ui, 24, "\u0915\u094d\u0937", {}, context.temp_allocator)
	testing.expect(t, len(kssa.glyphs) < 3, "no conjunct")
}

@(test)
bidi_mixed :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	text := "abc \u05e9\u05dc\u05d5\u05dd def"   // abc שלום def
	levels := font.bidi_levels(s, text, .Ltr, context.temp_allocator)
	testing.expect_value(t, levels[0], 0)
	testing.expect_value(t, levels[4], 1)
	testing.expect_value(t, levels[len(text) - 1], 0)
	sh := font.shape(s, ui, 20, text, {direction = .Ltr}, context.temp_allocator)
	// logical order of the Hebrew letters runs right to left on screen
	x_of :: proc(sh: font.Shaped, byte_index: i32) -> f32 {
		for c in sh.clusters { if c.start == byte_index { return c.x0 } }
		return -1
	}
	shin, mem := x_of(sh, 4), x_of(sh, 10)
	testing.expectf(t, shin > mem, "Hebrew not reversed: %v %v", shin, mem)
	testing.expect(t, x_of(sh, 0) < mem && x_of(sh, i32(len(text) - 1)) > shin)
	// an RTL paragraph: the Latin word comes first visually at the right
	sh2 := font.shape(s, ui, 20, "\u05e9\u05dc\u05d5\u05dd abc", {direction = .Rtl}, context.temp_allocator)
	testing.expect(t, x_of(sh2, 0) > x_of(sh2, 9))
	// one right-to-left run of several words (a layout fragment): clusters in logical order, the caret of the logical
	// end at the left edge, and hit testing finds every caret again
	rtl := "\u0633\u0644\u0627\u0645 \u0639\u0644\u064a\u0643\u0645"
	sh3 := font.shape(s, ui, 20, rtl, {one_run = true, direction = .Rtl}, context.temp_allocator)
	for i in 1 ..< len(sh3.clusters) { testing.expect(t, sh3.clusters[i].start > sh3.clusters[i - 1].start, "clusters in logical order") }
	testing.expect(t, abs(font.caret_x(sh3, rtl, len(rtl))) < 0.01 && abs(font.caret_x(sh3, rtl, 0) - sh3.width) < 0.01)
	for i in 0 ..= len(rtl) {
		if i < len(rtl) && rtl[i] & 0xC0 == 0x80 { continue }
		testing.expect_value(t, font.hit_index(sh3, rtl, font.caret_x(sh3, rtl, i)), i)
	}
	// L2 reordering of levels
	order := font.reorder({0, 1, 1, 2, 2, 1, 0}, context.temp_allocator)
	want := [?]int{0, 5, 3, 4, 2, 1, 6}
	for v, i in want { testing.expect_value(t, order[i], v) }
}

@(test)
line_break_opportunities :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	b := font.line_breaks(s, "hello world-wide", context.temp_allocator)
	at :: proc(b: []font.Break_Opportunity, i: int) -> bool {
		for x in b { if x.at == i { return true } }
		return false
	}
	testing.expect(t, at(b, 6))    // after the space
	testing.expect(t, at(b, 12))   // after the hyphen
	testing.expect(t, !at(b, 3))
	// Thai has no spaces between words: the dictionary finds breaks
	thai := "\u0e20\u0e32\u0e29\u0e32\u0e44\u0e17\u0e22\u0e07\u0e48\u0e32\u0e22"   // ภาษาไทยง่าย
	bt := font.line_breaks(s, thai, context.temp_allocator)
	testing.expect(t, len(bt) >= 1, "no break inside Thai")
	// CJK: between ideographs
	bc := font.line_breaks(s, "\u4e2d\u6587\u5b57", context.temp_allocator)
	testing.expect(t, len(bc) == 2)
}

@(test)
color_emoji :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	sh := font.shape(s, ui, 32, "\U0001F600", {}, context.temp_allocator)
	testing.expect_value(t, len(sh.glyphs), 1)
	g := sh.glyphs[0]
	img := font.glyph_image(s, g.face, g.id, 32, 0)
	testing.expect(t, img.page >= 0 && img.color, "the emoji is not a color glyph")
	// the bitmap has colored pixels (not only grays)
	Probe :: struct { colored: int, page: int, img: font.Glyph_Image }
	pr := Probe{page = int(img.page), img = img}
	font.atlas_sync_page(s, int(img.page), 0, &pr, proc(user: rawptr, page: int, kind: font.Page_Kind, x, y, w, h: int, pixels: []u8, stride: int) {
		p := (^Probe)(user)
		testing_kind := kind
		_ = testing_kind
		for row in int(p.img.uv[1]) ..< int(p.img.uv[3]) {
			if row - y >= h { break }
			for col in int(p.img.uv[0]) ..< int(p.img.uv[2]) {
				px := pixels[(row - y) * stride + (col - x) * 4:][:4]
				if px[3] > 128 && (abs(int(px[0]) - int(px[1])) > 40 || abs(int(px[1]) - int(px[2])) > 40) { p.colored += 1 }
			}
		}
	})
	testing.expectf(t, pr.colored > 20, "only %d colored pixels", pr.colored)
	// with color glyphs off, the same glyph is coverage
	st := font.DEFAULT_SETTINGS
	st.color_glyphs = false
	font.set_settings(s, st)
	font.clear_atlas(s)
	img2 := font.glyph_image(s, g.face, g.id, 32, 0)
	testing.expect(t, !img2.color)
}

// Many sizes and faces through a tiny atlas: pages are reused, never while a frame still draws from them, and every
// glyph a frame got stays where it was until the frame ends.
@(test)
atlas_stress :: proc(t: ^testing.T) {
	st := font.DEFAULT_SETTINGS
	st.page_size = 256
	st.max_gray_pages = 2
	s := setup(t, st)
	defer teardown(s)
	faces := [?]font.Font_Id{sys(t, s, "Segoe UI"), sys(t, s, "Arial"), sys(t, s, "Times New Roman"), sys(t, s, "Consolas")}
	text := "The quick brown fox jumps over the lazy dog 0123456789 \u00e0\u00e9\u00e8"
	user := rawptr(uintptr(1))
	for frame in 0 ..< 30 {
		font.atlas_begin_frame(s, user)
		got := make([dynamic]font.Glyph_Image, context.temp_allocator)
		keys := make([dynamic][4]f32, context.temp_allocator)
		for f, fi in faces {
			size := f32(10 + (frame * 3 + fi * 7) % 40)
			sh := font.shape(s, f, size, text, {}, context.temp_allocator)
			for g in sh.glyphs {
				img := font.glyph_image(s, g.face, g.id, size, frame % 4)
				if img.page < 0 { continue }
				append(&got, img)
				append(&keys, [4]f32{f32(g.face), f32(g.id), size, f32(frame % 4)})
			}
		}
		// still the same placement at the end of the frame (no page was reused under it)
		for img, i in got {
			k := keys[i]
			again := font.glyph_image(s, font.Font_Id(k[0]), u16(k[1]), k[2], int(k[3]))
			testing.expect(t, again == img, "a glyph moved during the frame")
		}
	}
	testing.expect(t, font.atlas_evictions(s) > 0, "the atlas never filled")
	fmt.printfln("atlas: %d pages, %d evictions", font.atlas_page_count(s), font.atlas_evictions(s))
}

// A glyph that cannot fit a page is not kept, and asking for it does not make a page (nor evict a valid one) each time.
@(test)
glyphs_bigger_than_a_page_make_no_page :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	sh := font.shape(s, ui, 20, "W", {}, context.temp_allocator)
	small := font.glyph_image(s, ui, sh.glyphs[0].id, 20, 0)
	testing.expect(t, small.page >= 0)
	pages, evictions := font.atlas_page_count(s), font.atlas_evictions(s)
	// "I" is about 0.7 em tall: over 2047 px from 3000 px on
	sh = font.shape(s, ui, 20, "I", {}, context.temp_allocator)
	for size in ([?]f32{3000, 3200, 3500, 4000}) {
		for sub in 0 ..< 4 {
			img := font.glyph_image(s, ui, sh.glyphs[0].id, size, sub)
			testing.expect(t, img.page < 0)
		}
	}
	testing.expect_value(t, font.atlas_page_count(s), pages)
	testing.expect_value(t, font.atlas_evictions(s), evictions)
}

// Unloading a font frees its slot: loading and unloading more fonts than the table has slots (65 536 when slots were never
// reused) goes on working, and the id of an unloaded font does not reach the font that took its slot.
@(test)
font_slots_are_reused :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	a, ok := font.load_embedded(s, font.FALLBACK_UI_DATA)
	testing.expect(t, ok)
	sh := font.shape(s, a, 20, "Hg", {}, context.temp_allocator)
	img_a := font.glyph_image(s, a, sh.glyphs[0].id, 20, 0)
	testing.expect(t, img_a.page >= 0)
	font.unload(s, a)
	testing.expect(t, !font.valid(s, a))
	// the slot of `a` goes to the next font
	b, ok_b := font.load_embedded(s, font.FALLBACK_MONO_DATA)
	testing.expect(t, ok_b && b != a && font.valid(s, b))
	testing.expect(t, !font.valid(s, a))
	testing.expect_value(t, font.text_width(s, a, 20, "Hg"), 0)
	testing.expect(t, font.text_width(s, b, 20, "Hg") > 0)
	// ... and the glyph cache of that slot is not reached with the old id, nor does the old id leave anything in it
	stale := font.glyph_image(s, a, sh.glyphs[0].id, 20, 0)
	testing.expect(t, stale.page < 0)
	img_b := font.glyph_image(s, b, sh.glyphs[0].id, 20, 0)
	testing.expect(t, img_b.page >= 0)
	testing.expect_value(t, font.glyph_image(s, b, sh.glyphs[0].id, 20, 0), img_b)
	testing.expect(t, font.glyph_image(s, a, sh.glyphs[0].id, 20, 0).page < 0)
	// more cascades made and unloaded than the table has slots: every one is made
	failed := 0
	last: font.Font_Id
	for i in 0 ..< 70000 {
		id := font.cascade(s, {{font = b}}, {{tag = {'s', 's', '0', '1'}, value = u32(i)}}, true)
		if id == 0 { failed += 1; continue }
		if last != 0 { font.unload(s, last) }
		last = id
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, failed, 0)
	testing.expect(t, font.valid(s, last) && last != a && last != b)
	testing.expect(t, font.text_width(s, last, 20, "Hg") > 0)
}

// Measuring from many threads at once gives what one thread gets.
@(test)
concurrent_measure :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	TEXTS :: [?]string{"Hello world", "caf\u00e9 cr\u00e8me", "\u0633\u0644\u0627\u0645 abc", "\u2190 back", "\U0001F600 smile", "fi fl ffi", "\u4e2d\u6587"}
	want: [len(TEXTS)]f32
	for txt, i in TEXTS { want[i] = font.text_width(s, ui, 15, txt) }
	font.clear_word_cache(s)
	Job :: struct { s: ^font.State, ui: font.Font_Id, want: ^[len(TEXTS)]f32, bad: ^int }
	bad := 0
	job := Job{s, ui, &want, &bad}
	threads: [8]^thread.Thread
	for &th in threads {
		th = thread.create_and_start_with_data(&job, proc(data: rawptr) {
			j := (^Job)(data)
			texts := TEXTS
			for round in 0 ..< 200 {
				for txt, i in texts {
					size := f32(15)
					if round % 7 == 3 { size = f32(15) }
					if font.text_width(j.s, j.ui, size, txt) != j.want[i] { sync.atomic_add(j.bad, 1) }
				}
			}
		})
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	testing.expect_value(t, bad, 0)
}
