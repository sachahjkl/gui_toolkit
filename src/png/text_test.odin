package tk_png

import "core:testing"

// Keywords and texts put after IHDR read back in order, the pixels untouched; a keyword given again replaces the old
// chunk; a file cut short or a keyword the format refuses gives nothing.
@(test)
texts_round_trip :: proc(t: ^testing.T) {
	px := []u8{255, 0, 0, 255, 0, 255, 0, 128}
	file := encode(px, 2, 1, .Fast, context.temp_allocator)
	none, ok := texts(file)
	testing.expect(t, ok && len(none) == 0, "a file with no text")

	add := []Text{{"Thumb::URI", "file:///home/a%20b/x.pdf"}, {"Thumb::MTime", "1700000000"}, {"Software", ""}}
	tagged := with_texts(file, add, context.temp_allocator)
	got, tok := texts(tagged)
	testing.expect(t, tok, "reads back")
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0], add[0])
		testing.expect_value(t, got[1], add[1])
		testing.expect_value(t, got[2], add[2])
	}
	rgba, w, h, dok := decode(tagged, context.temp_allocator)
	testing.expect(t, dok && w == 2 && h == 1 && string(rgba) == string(px), "the pixels are untouched")

	// a new date: one chunk of that keyword, the others kept
	again := with_texts(tagged, []Text{{"Thumb::MTime", "1800000000"}}, context.temp_allocator)
	got, tok = texts(again)
	testing.expect(t, tok && len(got) == 3, "three chunks")
	mtimes := 0
	for x in got { if x.keyword == "Thumb::MTime" { mtimes += 1; testing.expect_value(t, x.text, "1800000000") } }
	testing.expect_value(t, mtimes, 1)

	// refused
	_, cut := texts(tagged[:len(tagged) - 4])
	testing.expect(t, !cut, "a file cut short")
	broken := make([]u8, len(tagged), context.temp_allocator)
	copy(broken, tagged)
	broken[40] ~= 0xFF   // (inside the first tEXt: its CRC no longer matches)
	_, bad := texts(broken)
	testing.expect(t, !bad, "a wrong CRC")
	testing.expect(t, with_texts(file, []Text{{"", "x"}}) == nil, "an empty keyword")
	testing.expect(t, with_texts(file, []Text{{"k", "a\x00b"}}) == nil, "a NUL in the text")
	long := make([]u8, 80, context.temp_allocator)
	for &c in long { c = 'k' }
	testing.expect(t, with_texts(file, []Text{{string(long), "x"}}) == nil, "a keyword of 80 bytes")
	testing.expect(t, with_texts([]u8{1, 2, 3}, add) == nil, "not a PNG file")
}
