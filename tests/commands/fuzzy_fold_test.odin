package commands_test

import "core:strings"
import "core:testing"
import "core:unicode"
import "core:unicode/utf8"
import "../../src/ui"

// The fold as it was, a rune at a time (the reference of its ASCII vector path): the lower case of each rune, a rune whose
// lower case takes another number of bytes, or a byte that is no rune, left as it is.
@(private = "file")
fold_reference :: proc(s: string) -> string {
	b := make([]u8, len(s), context.temp_allocator)
	for i := 0; i < len(s); {
		r, w := utf8.decode_rune_in_string(s[i:])
		l := unicode.to_lower(r)
		if (r == utf8.RUNE_ERROR && w == 1) || utf8.rune_size(l) != w {
			copy(b[i:i + w], s[i:i + w])
		} else {
			e, n := utf8.encode_rune(l)
			copy(b[i:i + n], e[:n])
		}
		i += w
	}
	return string(b)
}

@(private = "file")
expect_fold :: proc(t: ^testing.T, s: string, loc := #caller_location) {
	got, want := ui.fuzzy_text(s).low, fold_reference(s)
	testing.expectf(t, got == want, "the fold of % x: % x, not % x", transmute([]u8)s, transmute([]u8)got, transmute([]u8)want, loc = loc)
}

// Every length up to 64, a rune that is not ASCII (two, three, four bytes; one that keeps its case; a byte that is no
// rune; a rune cut short) at every place, every byte value: the fold is the one of a rune at a time.
@(test)
fuzzy_fold_is_the_rune_one :: proc(t: ^testing.T) {
	alphabet := "aZ09 -_.QrStUvWxYz@[`{"
	INSERTS :: [?]string{"É", "Σ", "İ", "K", "\U0001F600", "\xff", "\xc3", "\xe2\x82", "étÉ"}
	inserts := INSERTS
	state := u32(7)
	for n in 0 ..= 64 {
		buf := make([]u8, n, context.temp_allocator)
		for &c in buf {
			state = state * 1664525 + 1013904223
			c = alphabet[int(state >> 24) % len(alphabet)]
		}
		expect_fold(t, string(buf))
		for at in 0 ..= n {
			for ins in inserts {
				s := strings.concatenate({string(buf[:at]), ins, string(buf[at:])}, context.temp_allocator)
				expect_fold(t, s)
			}
		}
	}
	all: [256]u8
	for &c, i in all { c = u8(i) }
	expect_fold(t, string(all[:]))
	for c in 0 ..< 256 {
		line: [40]u8
		for &x in line { x = 'K' }
		line[20] = u8(c)
		expect_fold(t, string(line[:]))
	}
	testing.expect_value(t, ui.fuzzy_text("Hello, WÖRLD: İstanbul").low, "hello, wörld: İstanbul")
}

// A needle and entries folded once give what the strings give; a slot whose text changed is folded again, and a query
// that changed makes another needle.
@(test)
fuzzy_folded_once_is_the_same :: proc(t: ^testing.T) {
	Case :: struct { query, label, group: string, tags: []string }
	cases := [?]Case{
		{"quit", "Quit", "General", {"exit", "close"}},
		{"exit", "Quit", "General", {"exit", "close"}},
		{"gen", "Quit", "General", nil},
		{"Qestart pencode", "Restart opencode native", "General", nil},
		{"ks", "Keyboard shortcuts", "", nil},
		{"ÉTÉ", "L'été indien", "Saisons", {"été"}},
		{"zebra", "Quit", "General", {""}},
		{"x", "Quit", "", {"", ""}},
	}
	cache: ui.Fuzzy_Cache
	defer ui.fuzzy_cache_destroy(&cache)
	for c, i in cases {
		s1, r1, ok1 := ui.palette_match(c.query, c.label, c.group, c.tags)
		s2, r2, ok2 := ui.palette_match(ui.fuzzy_cache_needle(&cache, c.query), ui.palette_entry_cached(&cache, i, c.label, c.group, c.tags))
		testing.expectf(t, s1 == s2 && ok1 == ok2 && ranges_equal(r1, r2), "case %d: %v %v %v, not %v %v %v", i, s2, r2, ok2, s1, r1, ok1)
		w1, wr1, wok1 := ui.fuzzy_words(c.query, c.label)
		w2, wr2, wok2 := ui.fuzzy_words(ui.fuzzy_needle(c.query), ui.fuzzy_text(c.label))
		testing.expectf(t, w1 == w2 && wok1 == wok2 && ranges_equal(wr1, wr2), "case %d, fuzzy_words", i)
		f1, fr1, fok1 := ui.fuzzy_score(c.query, c.label)
		f2, fr2, fok2 := ui.fuzzy_score(ui.fuzzy_needle(c.query), ui.fuzzy_text(c.label))
		testing.expectf(t, f1 == f2 && fok1 == fok2 && ranges_equal(fr1, fr2), "case %d, fuzzy_score", i)
		g1, gok1 := ui.fuzzy_find(c.query, c.label)
		g2, gok2 := ui.fuzzy_find(ui.fuzzy_needle(c.query), ui.fuzzy_text(c.label))
		testing.expectf(t, gok1 == gok2 && ranges_equal(g1, g2), "case %d, fuzzy_find", i)
	}
	// (the slot of the first case takes another label, the tags go: what it finds follows)
	_, _, before := ui.palette_match(ui.fuzzy_cache_needle(&cache, "exit"), ui.palette_entry_cached(&cache, 0, "Quit", "General", {"exit"}))
	_, _, after := ui.palette_match(ui.fuzzy_cache_needle(&cache, "exit"), ui.palette_entry_cached(&cache, 0, "Quit", "General", nil))
	testing.expect(t, before && !after, "the tags gone, \"exit\" no longer finds Quit")
	_, _, renamed := ui.palette_match(ui.fuzzy_cache_needle(&cache, "open"), ui.palette_entry_cached(&cache, 0, "Open", "General", nil))
	testing.expect(t, renamed, "the label changed in place: folded again")
	testing.expect_value(t, ui.fuzzy_cache_needle(&cache, "Op En").want, "open")
	ui.fuzzy_cache_keep(&cache, 0)
	testing.expect_value(t, ui.fuzzy_cache_text(&cache, 5, "A", "B").low, "ab")
}

@(private = "file")
ranges_equal :: proc(a, b: []ui.Fuzzy_Range) -> bool {
	if len(a) != len(b) { return false }
	for r, i in a { if r != b[i] { return false } }
	return true
}
