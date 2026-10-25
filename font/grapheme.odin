package font

import "core:unicode/utf8"

// Grapheme clusters (extended grapheme clusters of UAX #29): what a reader calls one character. An emoji family
// (man ZWJ woman ZWJ girl), a flag (two regional indicators), a letter with its combining marks, a Hangul syllable or an
// Indic conjunct is one cluster of several code points. A caret, the arrow keys, Backspace and Delete, and a click work
// on these, never inside one. The rules (and their data) are `core:unicode/utf8`'s; these procedures give them the shape
// an editor needs: a boundary after or before any byte index, without segmenting the whole text first.
//
// Every index is a byte index into `s`, and an index that is inside a code point or a cluster is allowed (the answer is
// the boundary after, or before, it). Invalid UTF-8 counts one byte per cluster, as `utf8.decode_rune` does.

// The index to start segmenting from for a boundary near `i`: a line feed always ends a cluster (GB4), so the text
// after the last one before `i` is segmented the same alone.
@(private)
grapheme_anchor :: proc "contextless" (s: string, i: int) -> int {
	for k := min(i, len(s)) - 1; k >= 0; k -= 1 {
		if s[k] == '\n' { return k + 1 }
	}
	return 0
}

// The first cluster boundary after byte `i` (`len(s)` at the end).
grapheme_next :: proc(s: string, from: int) -> int {
	if from >= len(s) { return len(s) }
	i := max(from, 0)
	start := grapheme_anchor(s, i)
	it := utf8.decode_grapheme_iterator_make(s[start:])
	for {
		text, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok { break }
		if end := start + g.byte_index + len(text); end > i { return end }
	}
	return len(s)
}

// The last cluster boundary before byte `i` (0 at the start).
grapheme_prev :: proc(s: string, from: int) -> int {
	if from <= 0 { return 0 }
	i := min(from, len(s))
	start := grapheme_anchor(s, i - 1)   // the cluster of the byte before `i`: a line feed at i - 1 belongs to it
	it := utf8.decode_grapheme_iterator_make(s[start:])
	for {
		text, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok { break }
		a := start + g.byte_index
		if a < i && i <= a + len(text) { return a }
	}
	return start
}

// Whether a cluster starts at byte `i` (`0` and `len(s)` are boundaries).
is_grapheme_boundary :: proc(s: string, i: int) -> bool {
	if i <= 0 || i >= len(s) { return true }
	return grapheme_next(s, grapheme_prev(s, i)) == i
}

// The number of clusters of `s`.
grapheme_count :: proc(s: string) -> int {
	n, _, _ := utf8.grapheme_count(s)
	return n
}

// A mark for every byte index 0 ..= len(s): true where a cluster boundary is (temp allocator or `allocator`).
@(private)
grapheme_marks :: proc(s: string, allocator := context.temp_allocator) -> []bool {
	marks := make([]bool, len(s) + 1, allocator)
	it := utf8.decode_grapheme_iterator_make(s)
	for {
		_, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok { break }
		marks[g.byte_index] = true
	}
	marks[len(s)] = true
	return marks
}
