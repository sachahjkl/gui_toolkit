package ui

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "../draw"
import "../font"

Fuzzy_Range :: [2]int   // byte offsets [start, end) in the haystack

// `s` in lower case, rune by rune, with exactly the length of `s` in bytes (a rune whose lower case takes another number
// of bytes, such as the dotted capital I, stays as it is): positions found in it are positions in `s`.
@(private)
fold_lower :: proc(s: string) -> string {
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

// Every space-separated part of `needle` must occur (case-insensitively) in `hay`, outside the ranges already taken by
// earlier parts. Returns the matched ranges. An empty needle matches everything with no ranges.
fuzzy_find :: proc(needle, hay: string, allocator := context.temp_allocator) -> (ranges: []Fuzzy_Range, ok: bool) {
	parts := strings.fields(needle, context.temp_allocator)
	if len(parts) == 0 { return nil, true }
	low_hay := fold_lower(hay)
	out := make([dynamic]Fuzzy_Range, allocator)
	for part in parts {
		low := fold_lower(part)
		pos := 0
		found := false
		for pos <= len(low_hay) - len(low) {
			i := strings.index(low_hay[pos:], low)
			if i < 0 { break }
			start := pos + i
			overlap := false
			for r in out { if start < r[1] && start + len(low) > r[0] { overlap = true; pos = r[1]; break } }
			if overlap { continue }
			append(&out, Fuzzy_Range{start, start + len(low)})
			found = true
			break
		}
		if !found { return nil, false }
	}
	return out[:], true
}

Fuzzy_Draw :: struct { ranges: []Fuzzy_Range, text: string, color: Color }

@(private)
fuzzy_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Fuzzy_Draw)(user)
	s := gs()
	dim := Vec2{b.text_dim.x, b.text_dim.y}
	origin := text_origin(s, b, dim)
	m := font.metrics(s.fonts, b.font, b.font_size)
	for r in d.ranges {
		x0 := origin.x + font.text_width(s.fonts, b.font, b.font_size, d.text[:r[0]])
		x1 := origin.x + font.text_width(s.fonts, b.font, b.font_size, d.text[:r[1]])
		cy := (b.rect.min.y + b.rect.max.y) * 0.5
		draw.rect(dc, {{x0, cy - m.line_height * 0.5}, {x1, cy + m.line_height * 0.5}}, d.color, 2 * s.scale)
	}
}

// A label whose matched ranges (from `fuzzy_find`) are lit on the theme's "match_bg", as a list's matches are (match.odin): a
// heavier tint of the accent (30 %, blended in linear light) left the text on it hard to read.
label_fuzzy :: proc(text: string, ranges: []Fuzzy_Range) -> Signal {
	b := build_box({.Draw_Text}, text)
	if len(ranges) > 0 {
		d := frame_new(Fuzzy_Draw)
		d.ranges = make([]Fuzzy_Range, len(ranges), frame_allocator())
		copy(d.ranges, ranges)
		d.text = b.text
		d.color = color("match_bg")
		b.custom, b.custom_user = fuzzy_draw, d
	}
	return signal(b)
}

// fuzzy_score: what a matched character earns, by where it is; what a gap (capped) and the text's length cost.
@(private = "file") FUZZY_SCORE_CHAR :: 16
@(private = "file") FUZZY_SCORE_TEXT_START :: 20
@(private = "file") FUZZY_SCORE_WORD_START :: 18
@(private = "file") FUZZY_SCORE_CAMEL_START :: 14
@(private = "file") FUZZY_SCORE_ADJACENT :: 24
@(private = "file") FUZZY_GAP_PENALTY_MAX :: 12
@(private = "file") FUZZY_BYTES_PER_LENGTH_POINT :: 8

// The bytes the rune at `i` takes in the text (an invalid byte matches U+FFFD, which would take three).
@(private = "file")
rune_width_at :: proc(s: string, i: int) -> int {
	_, w := utf8.decode_rune_in_string(s[i:])
	return w
}

// Subsequence matching, as in a picker or a command palette: the characters of `needle` (spaces ignored) occur in `hay`
// in that order, case-insensitively, not necessarily side by side ("cs5" finds "claude-sonnet-5"). The match is the
// tightest window ending where the leftmost one ends (fzf's first algorithm). `score` ranks matches, higher first:
// characters side by side, at the start of the text or of a word (after a separator, or a capital after a small letter)
// count more, gaps and a long text less. `ranges` are the matched runs, to highlight (label_fuzzy). An empty needle
// matches everything with score 0 and no ranges.
fuzzy_score :: proc(needle, hay: string, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	want := make([dynamic]rune, context.temp_allocator)
	for r in fold_lower(needle) { if !unicode.is_space(r) { append(&want, r) } }
	if len(want) == 0 { return 0, nil, true }
	low := fold_lower(hay)
	pos := make([]int, len(want), context.temp_allocator)
	// forward: where the leftmost match ends
	k := 0
	end := -1
	for r, i in low {
		if r == want[k] {
			k += 1
			if k == len(want) { end = i; break }
		}
	}
	if end < 0 { return 0, nil, false }
	// backward from there: the latest start, so the window is the tightest
	k = len(want) - 1
	for i := end + rune_width_at(low, end); i > 0 && k >= 0; {
		r, w := utf8.decode_last_rune_in_string(low[:i])
		i -= w
		if r == want[k] { pos[k] = i; k -= 1 }
	}
	out := make([dynamic]Fuzzy_Range, allocator)
	for p, j in pos {
		w := rune_width_at(low, p)
		score += FUZZY_SCORE_CHAR
		if p == 0 {
			score += FUZZY_SCORE_TEXT_START
		} else {
			prev, _ := utf8.decode_last_rune_in_string(hay[:p])
			cur, _ := utf8.decode_rune_in_string(hay[p:])
			if !unicode.is_letter(prev) && !unicode.is_digit(prev) {
				score += FUZZY_SCORE_WORD_START
			} else if unicode.is_lower(prev) && unicode.is_upper(cur) {
				score += FUZZY_SCORE_CAMEL_START
			}
		}
		if j > 0 {
			gap := p - (pos[j - 1] + rune_width_at(low, pos[j - 1]))
			if gap == 0 { score += FUZZY_SCORE_ADJACENT } else { score -= min(gap, FUZZY_GAP_PENALTY_MAX) }
		}
		if n := len(out); n > 0 && out[n - 1][1] == p { out[n - 1][1] = p + w } else { append(&out, Fuzzy_Range{p, p + w}) }
	}
	score -= len(hay) / FUZZY_BYTES_PER_LENGTH_POINT
	return score, out[:], true
}

// fuzzy_words: what a match earns. A run of the needle whole in the text beats pieces at words' starts; the start of the
// text or of a word adds; each piece past the first, and the text's length, cost.
@(private = "file") WORDS_SCORE_WHOLE :: 1000
@(private = "file") WORDS_SCORE_PIECES :: 600
@(private = "file") WORDS_SCORE_TEXT_START :: 200
@(private = "file") WORDS_SCORE_WORD_START :: 100
@(private = "file") WORDS_PIECE_COST :: 60
// The needle's characters a search by pieces tries at most (a longer one is matched whole or not at all).
@(private = "file") WORDS_MAX_NEEDLE :: 64

// Matching for a command palette, stricter than fuzzy_score: the needle (spaces ignored, case-insensitively) is in `hay`
// whole ("prio" in "Raise the priority"), or is made of pieces that each begin a word of `hay`, the words in order ("ks"
// in "Keyboard shortcuts", "endt" in "End task"). Letters scattered in a word do not match: "prio" does not find
// "Previous section". A word begins the text, follows a character that is not a letter or a digit, or is a capital after
// a small letter. `score` ranks matches, higher first: the needle whole before pieces, at the start of the text or of a
// word before elsewhere, fewer pieces and a shorter text first. An empty needle matches everything with score 0.
fuzzy_words :: proc(needle, hay: string, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	for r in fold_lower(needle) { if !unicode.is_space(r) { strings.write_rune(&b, r) } }
	want := strings.to_string(b)
	if want == "" { return 0, nil, true }
	low := fold_lower(hay)
	out := make([dynamic]Fuzzy_Range, allocator)
	if at := strings.index(low, want); at >= 0 {
		// (the first place it starts a word, else the first place it is)
		for i := at; i >= 0 && i < len(low); {
			if word_start(hay, i) { at = i; break }
			next := strings.index(low[i + 1:], want)
			if next < 0 { break }
			i += 1 + next
		}
		score = WORDS_SCORE_WHOLE
		if at == 0 { score += WORDS_SCORE_TEXT_START } else if word_start(hay, at) { score += WORDS_SCORE_WORD_START }
		append(&out, Fuzzy_Range{at, at + len(want)})
		return score - len(hay) / FUZZY_BYTES_PER_LENGTH_POINT, out[:], true
	}
	if len(want) > WORDS_MAX_NEEDLE { return 0, nil, false }
	if !word_pieces(hay, low, want, 0, &out) { return 0, nil, false }
	score = WORDS_SCORE_PIECES - WORDS_PIECE_COST * (len(out) - 1)
	if out[0][0] == 0 { score += WORDS_SCORE_TEXT_START }
	return score - len(hay) / FUZZY_BYTES_PER_LENGTH_POINT, out[:], true
}

// Whether a word of `hay` begins at byte `i`.
@(private = "file")
word_start :: proc(hay: string, i: int) -> bool {
	if i == 0 { return true }
	prev, _ := utf8.decode_last_rune_in_string(hay[:i])
	cur, _ := utf8.decode_rune_in_string(hay[i:])
	if !unicode.is_letter(prev) && !unicode.is_digit(prev) { return true }
	return unicode.is_lower(prev) && unicode.is_upper(cur)
}

// `want` as pieces that each begin a word of `hay` at or after `from`, the longest piece tried first; the pieces are
// appended to `out` (taken back when the rest does not match).
@(private = "file")
word_pieces :: proc(hay, low, want: string, from: int, out: ^[dynamic]Fuzzy_Range) -> bool {
	if want == "" { return true }
	for w := from; w < len(low); w += rune_width_at(low, w) {
		if !word_start(hay, w) { continue }
		common := 0
		for common < len(want) && w + common < len(low) && low[w + common] == want[common] { common += 1 }
		for l := common; l > 0; l -= 1 {
			// (whole runes only: a piece never ends inside one)
			if l < len(want) && !utf8.rune_start(want[l]) { continue }
			append(out, Fuzzy_Range{w, w + l})
			if word_pieces(hay, low, want[l:], w + l, out) { return true }
			pop(out)
		}
	}
	return false
}

// fuzzy_typos: a word typed with a slip still finds its word. How many slips a word may have, by its length in letters (a
// letter missing, one too many, one for another, two side by side swapped: one each), and what a match earns (below any of
// fuzzy_words', what it is tried after), less for each slip.
@(private = "file") TYPO_FREE_LEN :: 3      // up to this long: none
@(private = "file") TYPO_ONE_LEN :: 6       // up to this long: one; longer: two
@(private = "file") TYPOS_SCORE :: 300
@(private = "file") TYPO_COST :: 60

// Matching that forgives slips, for what a person types in a palette after fuzzy_words found nothing: each word of `needle`
// is a word of `hay`, whole or its beginning, with a few slips at most ("Qestart pencode" finds "Restart opencode native";
// "prio" does not find "Previous section": two slips in four letters). Two words of the needle are two words of `hay`.
// `ranges` are the words found, as far as the needle's word goes. An empty needle matches everything with score 0.
fuzzy_typos :: proc(needle, hay: string, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	wanted := strings.fields(fold_lower(needle), context.temp_allocator)
	if len(wanted) == 0 { return 0, nil, true }
	low := fold_lower(hay)
	// the words of `hay`: runs of letters and digits
	Word :: struct { from, to: int, runes: []rune }
	words := make([dynamic]Word, context.temp_allocator)
	start := -1
	for r, i in low {
		inside := unicode.is_letter(r) || unicode.is_digit(r)
		if inside && start < 0 { start = i }
		if !inside && start >= 0 { append(&words, Word{start, i, utf8.string_to_runes(low[start:i], context.temp_allocator)}); start = -1 }
	}
	if start >= 0 { append(&words, Word{start, len(low), utf8.string_to_runes(low[start:], context.temp_allocator)}) }
	used := make([]bool, len(words), context.temp_allocator)
	out := make([dynamic]Fuzzy_Range, allocator)
	slips := 0
	for w in wanted {
		want := utf8.string_to_runes(w, context.temp_allocator)
		allowed := len(want) <= TYPO_FREE_LEN ? 0 : len(want) <= TYPO_ONE_LEN ? 1 : 2
		best, best_d, best_n := -1, allowed + 1, 0
		for word, k in words {
			if used[k] { continue }
			// the whole word, or its beginning as long as what was typed (one letter more or less: a slip in it)
			d, n := typo_distance(want, word.runes), len(word.runes)
			for l in max(len(want) - 1, 1) ..= min(len(want) + 1, len(word.runes)) {
				if pd := typo_distance(want, word.runes[:l]); pd < d { d, n = pd, l }
			}
			if d < best_d { best, best_d, best_n = k, d, n }
		}
		if best < 0 { return 0, nil, false }
		used[best] = true
		slips += best_d
		word := words[best]
		end := word.from + len(utf8.runes_to_string(word.runes[:best_n], context.temp_allocator))
		append(&out, Fuzzy_Range{word.from, end})
	}
	// (in the order they are in the text: a highlight is drawn from left to right)
	for i in 1 ..< len(out) {
		for j := i; j > 0 && out[j][0] < out[j - 1][0]; j -= 1 { out[j], out[j - 1] = out[j - 1], out[j] }
	}
	return TYPOS_SCORE - TYPO_COST * slips - len(hay) / FUZZY_BYTES_PER_LENGTH_POINT, out[:], true
}

// The slips that make `a` into `b`: a letter missing, one too many, one for another, two side by side swapped (the optimal
// string alignment distance).
@(private = "file")
typo_distance :: proc(a, b: []rune) -> int {
	n, m := len(a), len(b)
	row := make([][]int, n + 1, context.temp_allocator)
	for i in 0 ..= n {
		row[i] = make([]int, m + 1, context.temp_allocator)
		row[i][0] = i
	}
	for j in 0 ..= m { row[0][j] = j }
	for i in 1 ..= n {
		for j in 1 ..= m {
			cost := a[i - 1] == b[j - 1] ? 0 : 1
			row[i][j] = min(row[i - 1][j] + 1, row[i][j - 1] + 1, row[i - 1][j - 1] + cost)
			if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] { row[i][j] = min(row[i][j], row[i - 2][j - 2] + 1) }
		}
	}
	return row[n][m]
}
