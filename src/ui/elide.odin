package ui

// A text cut to a width with an ellipsis (src/md/features/elide.md): at its end, or in its middle so that both its start
// and its end show. One cutter for the boxes' text (draw_box_text), a mark's card, and a program's own drawing.

import "core:strings"
import "core:unicode/utf8"
import "../font"

// Where `elide` cuts a text that does not fit.
Elide_At :: enum u8 {
	End,      // "A long tit…": a title, a line of a list
	Middle,   // "report-20…final.pdf": a name whose end says what it is (an extension, a number)
}

// What `elide` puts where it cut.
ELLIPSIS :: "…"

// `text` in `width` pixels at font `f` and `size`: whole when it fits (the same string: no allocation), else cut between
// two characters at `at` with ELLIPSIS, "" when not even the ellipsis fits. The spaces beside the cut go. The cut is
// found by halves (a few measures, whatever the length) and kept in a cache by text, font, size and width, so a list
// that asks at every frame measures each text once.
elide :: proc(f: font.Font_Id, size: f32, text: string, width: f32, at := Elide_At.End, allocator := context.temp_allocator) -> string {
	return elide_text(text, elide_cut(gs(), f, size, text, width, at, ELLIPSIS), ELLIPSIS, allocator)
}

// Where a text is cut for a width: the cut costs a few shapings of the text, and a list of titles asks at every frame.
// Entries not used for WRAP_CACHE_KEEP builds go (elide_cache_trim).
@(private)
Elide_Key :: struct {
	text_hash: u64,
	text_len:  int,
	font:      font.Font_Id,
	size:      f32,
	width:     f32,
	at:        Elide_At,
	ellipsis:  u64,   // (its hash: a box's text ends in TRUNC_ELLIPSIS, elide's in ELLIPSIS)
}

@(private)
Elide_Entry :: struct {
	head:       int,   // bytes kept at the start (-1: not even the ellipsis fits; len(text): whole)
	tail:       int,   // where the kept end starts (len(text): no end kept)
	width:      f32,   // of what is shown, the ellipsis included
	last_build: u64,
}

// The cut of `text` for `width`, from the cache or measured.
@(private)
elide_cut :: proc(s: ^State, f: font.Font_Id, size: f32, text: string, width: f32, at: Elide_At, ellipsis: string) -> Elide_Entry {
	k := Elide_Key{text_hash = hash_bytes(transmute([]u8)text), text_len = len(text), font = f, size = size, width = width, at = at, ellipsis = hash_bytes(transmute([]u8)ellipsis)}
	e, known := &s.elide_cache[k]
	if !known {
		s.elide_cache[k] = elide_measure(s, f, size, text, width, at, ellipsis)
		e = &s.elide_cache[k]
	}
	e.last_build = s.build_index
	return e^
}

// The text a cut shows.
@(private)
elide_text :: proc(text: string, e: Elide_Entry, ellipsis: string, allocator := context.temp_allocator) -> string {
	if e.head < 0 { return "" }
	if e.head >= len(text) { return text }
	return strings.concatenate({text[:e.head], ellipsis, text[e.tail:]}, allocator)
}

@(private = "file")
elide_measure :: proc(s: ^State, f: font.Font_Id, size: f32, text: string, width: f32, at: Elide_At, ellipsis: string) -> Elide_Entry {
	if whole := font.text_width(s.fonts, f, size, text); whole <= width { return {head = len(text), tail = len(text), width = whole} }
	ell_w := font.text_width(s.fonts, f, size, ellipsis)
	if width < ell_w { return {head = -1} }
	// (the starts of its clusters, and its end: it is cut between clusters, never inside an accent or an emoji)
	starts := make([dynamic]int, 0, len(text) + 1, context.temp_allocator)
	it := utf8.decode_grapheme_iterator_make(text)
	for {
		_, g, more := utf8.decode_grapheme_iterate(&it)
		if !more { break }
		append(&starts, g.byte_index)
	}
	append(&starts, len(text))
	n := len(starts) - 1
	// the most clusters kept that fit (by halves: the width grows with what is kept); none kept is the ellipsis alone
	best := Elide_Entry{head = 0, tail = len(text), width = ell_w}
	lo, hi := 1, n - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		c := elide_try(s, f, size, text, starts[:], mid, at, ellipsis)
		if c.width <= width { best, lo = c, mid + 1 } else { hi = mid - 1 }
	}
	return best
}

// `kept` clusters of `text` with the ellipsis: all at its start (.End), or half at its start and half at its end
// (.Middle, the start's half the larger), the spaces beside the cut trimmed, and its width.
@(private = "file")
elide_try :: proc(s: ^State, f: font.Font_Id, size: f32, text: string, starts: []int, kept: int, at: Elide_At, ellipsis: string) -> Elide_Entry {
	n := len(starts) - 1
	head, tail := starts[kept], len(text)
	if at == .Middle { head, tail = starts[(kept + 1) / 2], starts[n - kept / 2] }
	head = len(strings.trim_right_space(text[:head]))
	tail = len(text) - len(strings.trim_left_space(text[tail:]))
	shown := strings.concatenate({text[:head], ellipsis, text[tail:]}, context.temp_allocator)
	return {head = head, tail = tail, width = font.text_width(s.fonts, f, size, shown)}
}

@(private)
elide_cache_trim :: proc(s: ^State) {
	if s.build_index % CACHE_TRIM_INTERVAL_BUILDS != 0 { return }
	dead := make([dynamic]Elide_Key, context.temp_allocator)
	for k, e in s.elide_cache { if e.last_build + WRAP_CACHE_KEEP < s.build_index { append(&dead, k) } }
	for k in dead { delete_key(&s.elide_cache, k) }
}
