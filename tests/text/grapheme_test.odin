package text_test

import "core:testing"
import "../../font"

FAMILY :: "\U0001F468\u200D\U0001F469\u200D\U0001F467"
FLAG_FR :: "\U0001F1EB\U0001F1F7"
FLAG_DE :: "\U0001F1E9\U0001F1EA"
ENGLAND :: "\U0001F3F4\U000E0067\U000E0062\U000E0065\U000E006E\U000E0067\U000E007F"

// The clusters of a few strings of every kind: combining marks, ZWJ sequences, flags, modifiers, keycaps, tags, Hangul,
// Indic conjuncts, CR LF.
@(test)
grapheme_clusters :: proc(t: ^testing.T) {
	Case :: struct { s: string, n: int }
	cases := [?]Case{
		{"", 0}, {"abc", 3}, {"e\u0301", 1}, {"e\u0301\u0302x", 2}, {FAMILY, 1}, {"x" + FAMILY + "y", 3},
		{FLAG_FR, 1}, {FLAG_FR + FLAG_DE, 2}, {FLAG_FR + "\U0001F1E9", 2}, {"\U0001F1EB", 1},
		{"\U0001F44D\U0001F3FD", 1}, {"1\uFE0F\u20E3", 1}, {ENGLAND, 1}, {ENGLAND + ENGLAND, 2},
		{"\u1100\u1161\u11A8", 1}, {"\uAC00\u11A8", 1}, {"\u0915\u094D\u0937", 1}, {"\u0915\u094D\u0937\u093F", 1},
		{"\r\n", 1}, {"a\r\nb", 3}, {"a\n\nb", 4}, {"\U0001F600\U0001F600", 2}, {"\u0645\u0631\u062D\u0628\u0627", 5},
		{"\xff\xfe", 2},
	}
	for c in cases {
		testing.expectf(t, font.grapheme_count(c.s) == c.n, "%q: %d clusters, want %d", c.s, font.grapheme_count(c.s), c.n)
	}
}

// next / prev from every byte index, for strings with clusters: they walk exactly the clusters, never stop inside one.
@(test)
grapheme_walk :: proc(t: ^testing.T) {
	strs := [?]string{
		"a" + FAMILY + "b" + FLAG_FR + FLAG_DE + "e\u0301c", ENGLAND + "x\nab\u0915\u094D\u0937" + FAMILY,
		"\U0001F1EB" + FLAG_FR + FLAG_DE, "\r\nx\r\n",
	}
	for s in strs {
		// the boundaries, walked forward
		bounds := make([dynamic]int, context.temp_allocator)
		pos := 0
		for {
			append(&bounds, pos)
			if pos >= len(s) { break }
			j := font.grapheme_next(s, pos)
			testing.expect(t, j > pos)
			pos = j
		}
		testing.expect_value(t, bounds[len(bounds) - 1], len(s))
		// from any byte index: the next boundary above it, and the previous one below it
		for i in 0 ..= len(s) {
			want_next, want_prev := len(s), 0
			for b in bounds { if b > i { want_next = b; break } }
			for b in bounds { if b < i { want_prev = b } }
			if i < len(s) { testing.expectf(t, font.grapheme_next(s, i) == want_next, "next of %d in %q: %d, want %d", i, s, font.grapheme_next(s, i), want_next) }
			if i > 0 { testing.expectf(t, font.grapheme_prev(s, i) == want_prev, "prev of %d in %q: %d, want %d", i, s, font.grapheme_prev(s, i), want_prev) }
			is_bound := false
			for b in bounds { if b == i { is_bound = true } }
			testing.expectf(t, font.is_grapheme_boundary(s, i) == is_bound, "boundary %d in %q", i, s)
		}
	}
}

// The caret and a click work on whole clusters: a click on an emoji family lands before or after it, and the caret
// positions of a cluster of several code points are its two edges.
@(test)
caret_and_hit_follow_clusters :: proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	text := "a" + FAMILY + "e\u0301b"
	sh := font.shape(s, ui, 32, text, {}, context.temp_allocator)
	for x := f32(-5); x < sh.width + 5; x += 1.5 {
		i := font.hit_index(sh, text, x)
		testing.expectf(t, font.is_grapheme_boundary(text, i), "a click at x=%.1f lands at byte %d, inside a cluster", x, i)
	}
	// carets inside the family have no place of their own: asking for one gives a point of the cluster
	end_a := 1
	end_family := 1 + len(FAMILY)
	xa, xb := font.caret_x(sh, text, end_a), font.caret_x(sh, text, end_family)
	testing.expect(t, xb > xa)
}
