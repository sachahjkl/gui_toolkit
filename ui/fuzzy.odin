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
	s := g
	dim := Vec2{b.text_dim.x, b.text_dim.y}
	origin := text_origin(s, b, dim)
	m := font.metrics(s.fonts, b.font, b.font_size)
	for r in d.ranges {
		x0 := origin.x + font.text_width(s.fonts, b.font, b.font_size, d.text[:r[0]])
		x1 := origin.x + font.text_width(s.fonts, b.font, b.font_size, d.text[:r[1]])
		cy := (b.rect.min.y + b.rect.max.y) * 0.5
		draw.rect(dc, {{x0, cy - m.line_height * 0.5}, {x1, cy + m.line_height * 0.5}}, d.color, 2)
	}
}

// A label whose matched ranges (from `fuzzy_find`) are highlighted with the accent color.
label_fuzzy :: proc(text: string, ranges: []Fuzzy_Range) -> Signal {
	b := build_box({.Draw_Text}, text)
	if len(ranges) > 0 {
		d := frame_new(Fuzzy_Draw)
		d.ranges = make([]Fuzzy_Range, len(ranges), frame_allocator())
		copy(d.ranges, ranges)
		d.text = b.text
		d.color = color("accent")
		d.color.a *= 0.30
		d.color = tuned(d.color)
		b.custom, b.custom_user = fuzzy_draw, d
	}
	return signal(b)
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
	for i := end + utf8.rune_size(want[k]); i > 0 && k >= 0; {
		r, w := utf8.decode_last_rune_in_string(low[:i])
		i -= w
		if r == want[k] { pos[k] = i; k -= 1 }
	}
	out := make([dynamic]Fuzzy_Range, allocator)
	for p, j in pos {
		w := utf8.rune_size(want[j])
		score += 16
		if p == 0 {
			score += 20
		} else {
			prev, _ := utf8.decode_last_rune_in_string(hay[:p])
			cur, _ := utf8.decode_rune_in_string(hay[p:])
			if !unicode.is_letter(prev) && !unicode.is_digit(prev) {
				score += 18
			} else if unicode.is_lower(prev) && unicode.is_upper(cur) {
				score += 14
			}
		}
		if j > 0 {
			gap := p - (pos[j - 1] + utf8.rune_size(want[j - 1]))
			if gap == 0 { score += 24 } else { score -= min(gap, 12) }
		}
		if n := len(out); n > 0 && out[n - 1][1] == p { out[n - 1][1] = p + w } else { append(&out, Fuzzy_Range{p, p + w}) }
	}
	score -= len(hay) / 8
	return score, out[:], true
}
