package ui

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "../ascii"
import "../draw"
import "../font"

Fuzzy_Range :: [2]int   // byte offsets [start, end) in the haystack

// `s` in lower case, rune by rune, with exactly the length of `s` in bytes (a rune whose lower case takes another number
// of bytes, such as the dotted capital I, stays as it is): positions found in it are positions in `s`.
@(private)
fold_lower :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := make([]u8, len(s), allocator)
	fold_lower_into(b, s)
	return string(b)
}

// fold_lower into `b` (as long as `s`). An ASCII run, most of what is typed and listed, goes a register at a time
// (ascii.lower_run: the same bytes as unicode.to_lower gives them); a rune past it, one at a time.
@(private)
fold_lower_into :: proc(b: []u8, s: string) {
	for i := 0; i < len(s); {
		if s[i] < 0x80 {
			i += ascii.lower_run(b[i:], s[i:])
			continue
		}
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
}

// A text as the fuzzy procedures read it: as it is (where its words begin: a capital after a small letter) and folded
// (fold_lower: as long, so a place in one is the same place in the other). Folded once, it is matched against every
// needle typed.
Fuzzy_Text :: struct { text, low: string }

fuzzy_text :: proc(s: string, allocator := context.temp_allocator) -> Fuzzy_Text { return {s, fold_lower(s, allocator)} }

// A needle as the fuzzy procedures read it, folded once for all the texts it is matched against.
Fuzzy_Needle :: struct {
	words:      []string,   // its space-separated parts, folded (fuzzy_find, fuzzy_typos)
	word_runes: [][]rune,   // ... as runes (fuzzy_typos)
	want:       string,     // folded, its spaces taken out (fuzzy_words)
	runes:      []rune,     // ... as runes (fuzzy_score)
}

fuzzy_needle :: proc(needle: string, allocator := context.temp_allocator) -> Fuzzy_Needle {
	low := fold_lower(needle, allocator)
	n: Fuzzy_Needle
	// (the parts of the folded needle are the folded parts: no rune folds to a space or from one)
	n.words = strings.fields(low, allocator)
	n.word_runes = make([][]rune, len(n.words), allocator)
	for w, i in n.words { n.word_runes[i] = utf8.string_to_runes(w, allocator) }
	runes := make([dynamic]rune, allocator)
	b := strings.builder_make(allocator)
	for r in low {
		if unicode.is_space(r) { continue }
		append(&runes, r)
		strings.write_rune(&b, r)
	}
	n.runes, n.want = runes[:], strings.to_string(b)
	return n
}

// What a list that searches keeps from one frame to the next: its needle, folded again only when the query changes, and
// its texts by slot (an item's place in the list), folded again only where a slot's text changed. A list that a program
// builds again each frame (in the frame's memory) is then folded once: a slot is compared with what it was, byte by byte,
// which costs much less than a fold.
Fuzzy_Cache :: struct {
	query:  string,               // what `needle` was made from (in `arena`)
	needle: Fuzzy_Needle,         // (in `arena`)
	ready:  bool,                 // `needle` was made
	arena:  virtual.Arena,
	texts:  [dynamic]Fuzzy_Text,  // by slot (each one's text and fold in one allocation of the heap)
}

// The needle of `query`, folded when the query is not the one of the last call.
fuzzy_cache_needle :: proc(c: ^Fuzzy_Cache, query: string) -> Fuzzy_Needle {
	if !c.ready || c.query != query {
		virtual.arena_free_all(&c.arena)
		a := virtual.arena_allocator(&c.arena)
		c.query = strings.clone(query, a)
		c.needle = fuzzy_needle(query, a)
		c.ready = true
	}
	return c.needle
}

// The text of `slot`: `parts` one after the other ("label", " ", "tag": no copy made to compare them), folded when they
// are not what the slot held.
fuzzy_cache_text :: proc(c: ^Fuzzy_Cache, slot: int, parts: ..string) -> Fuzzy_Text {
	// (the heap's, as the texts are: whatever allocator the frame that first used it had)
	if c.texts.allocator.procedure == nil { c.texts.allocator = runtime.heap_allocator() }
	if slot >= len(c.texts) { resize(&c.texts, slot + 1) }
	kept := &c.texts[slot]
	rest := kept.text
	same := true
	for part in parts {
		if !strings.has_prefix(rest, part) { same = false; break }
		rest = rest[len(part):]
	}
	if same && rest == "" { return kept^ }
	free(rawptr(raw_data(kept.text)), runtime.heap_allocator())
	n := 0
	for part in parts { n += len(part) }
	if n == 0 { kept^ = {}; return {} }
	// (the text, then its fold: one allocation)
	buf := make([]u8, 2 * n, runtime.heap_allocator())
	at := 0
	for part in parts { at += copy(buf[at:], part) }
	fold_lower_into(buf[n:], string(buf[:n]))
	kept^ = {string(buf[:n]), string(buf[n:])}
	return kept^
}

// Lets go of the slots from `slots` on (the list is shorter now).
fuzzy_cache_keep :: proc(c: ^Fuzzy_Cache, slots: int) {
	for i in slots ..< len(c.texts) { free(rawptr(raw_data(c.texts[i].text)), runtime.heap_allocator()) }
	if slots < len(c.texts) { resize(&c.texts, slots) }
}

fuzzy_cache_destroy :: proc(c: ^Fuzzy_Cache) {
	fuzzy_cache_keep(c, 0)
	delete(c.texts)
	virtual.arena_destroy(&c.arena)
	c^ = {}
}

// Every space-separated part of `needle` must occur (case-insensitively) in `hay`, outside the ranges already taken by
// earlier parts. Returns the matched ranges. An empty needle matches everything with no ranges. (The needle and the text
// folded already: fuzzy_needle, fuzzy_text.)
fuzzy_find :: proc{fuzzy_find_strings, fuzzy_find_folded}

fuzzy_find_strings :: proc(needle, hay: string, allocator := context.temp_allocator) -> (ranges: []Fuzzy_Range, ok: bool) {
	return fuzzy_find_folded(fuzzy_needle(needle), fuzzy_text(hay), allocator)
}

fuzzy_find_folded :: proc(needle: Fuzzy_Needle, hay: Fuzzy_Text, allocator := context.temp_allocator) -> (ranges: []Fuzzy_Range, ok: bool) {
	if len(needle.words) == 0 { return nil, true }
	low_hay := hay.low
	out := make([dynamic]Fuzzy_Range, allocator)
	for low in needle.words {
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
// matches everything with score 0 and no ranges. (The needle and the text folded already: fuzzy_needle, fuzzy_text.)
fuzzy_score :: proc{fuzzy_score_strings, fuzzy_score_folded}

fuzzy_score_strings :: proc(needle, hay: string, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	return fuzzy_score_folded(fuzzy_needle(needle), fuzzy_text(hay), allocator)
}

fuzzy_score_folded :: proc(needle: Fuzzy_Needle, h: Fuzzy_Text, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	want := needle.runes
	if len(want) == 0 { return 0, nil, true }
	hay, low := h.text, h.low
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
// word before elsewhere, fewer pieces and a shorter text first. An empty needle matches everything with score 0. (The needle
// and the text folded already: fuzzy_needle, fuzzy_text.)
fuzzy_words :: proc{fuzzy_words_strings, fuzzy_words_folded}

fuzzy_words_strings :: proc(needle, hay: string, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	return fuzzy_words_folded(fuzzy_needle(needle), fuzzy_text(hay), allocator)
}

fuzzy_words_folded :: proc(needle: Fuzzy_Needle, h: Fuzzy_Text, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	want := needle.want
	if want == "" { return 0, nil, true }
	hay, low := h.text, h.low
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
// `ranges` are the words found, as far as the needle's word goes. An empty needle matches everything with score 0. (The
// needle and the text folded already: fuzzy_needle, fuzzy_text.)
fuzzy_typos :: proc{fuzzy_typos_strings, fuzzy_typos_folded}

fuzzy_typos_strings :: proc(needle, hay: string, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	return fuzzy_typos_folded(fuzzy_needle(needle), fuzzy_text(hay), allocator)
}

fuzzy_typos_folded :: proc(needle: Fuzzy_Needle, h: Fuzzy_Text, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	if len(needle.words) == 0 { return 0, nil, true }
	hay, low := h.text, h.low
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
	for want in needle.word_runes {
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
