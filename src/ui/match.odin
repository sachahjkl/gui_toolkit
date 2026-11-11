package ui

// What a search found, shown: in a list filtered by what is typed (the palette, a menu that searches, a settings page, a
// program's own list), the parts of each line that match are drawn in the theme's "match" colour (the text's) on its
// "match_bg" (a tint of the accent).
//
//	ranges := ui.word_ranges(line, query)                   // each word (or "phrase") of a query, where it is in the line
//	_, ranges, _ = ui.fuzzy_words(query, line)              // or what a fuzzy search found
//	ui.next({width = ui.fill()})
//	ui.matched_label("###t", line, ranges)                  // one line, cut with "…" when it is too long

import "core:slice"
import "core:strings"

// Where each word of `query` is in `text`, in any case: every place, merged where they touch, in order. A phrase between
// double quotes is one word, spaces and all (as config.words_match reads a query).
word_ranges :: proc(text, query: string, allocator := context.temp_allocator) -> []Fuzzy_Range {
	out := make([dynamic]Fuzzy_Range, allocator)
	if text == "" || query == "" { return out[:] }
	low := fold_lower(text)
	q := fold_lower(query)
	words := make([dynamic]string, context.temp_allocator)
	rest := q
	for len(rest) > 0 {
		quote := strings.index_byte(rest, '"')
		plain := quote < 0 ? rest : rest[:quote]
		for w in strings.fields_iterator(&plain) { append(&words, w) }
		if quote < 0 { break }
		rest = rest[quote + 1:]
		end := strings.index_byte(rest, '"')
		phrase := end < 0 ? rest : rest[:end]
		if p := strings.trim_space(phrase); p != "" { append(&words, p) }
		rest = end < 0 ? "" : rest[end + 1:]
	}
	for w in words {
		at := 0
		for at < len(low) {
			i := strings.index(low[at:], w)
			if i < 0 { break }
			append(&out, Fuzzy_Range{at + i, at + i + len(w)})
			at += i + len(w)
		}
	}
	slice.sort_by(out[:], proc(a, b: Fuzzy_Range) -> bool { return a[0] < b[0] })
	// (merged where they overlap or touch: one highlight, not two)
	merged := make([dynamic]Fuzzy_Range, 0, len(out), allocator)
	for r in out {
		if n := len(merged); n > 0 && r[0] <= merged[n - 1][1] { merged[n - 1][1] = max(merged[n - 1][1], r[1]); continue }
		append(&merged, r)
	}
	return merged[:]
}

// `text` as runs of `style`, the ranges in the theme's "match" colour on its "match_bg" (the ranges in order, inside the
// text; the text's own bytes, no copy).
match_runs :: proc(text: string, ranges: []Fuzzy_Range, style: Rich_Style, runs: ^[dynamic]Rich_Run) {
	lit := style
	lit.color = color("match")
	lit.background = color("match_bg")
	at := 0
	for r in ranges {
		from, to := clamp(r[0], at, len(text)), clamp(r[1], at, len(text))
		if to <= from { continue }
		if from > at { append(runs, Rich_Run{text = text[at:from], style = style}) }
		append(runs, Rich_Run{text = text[from:to], style = lit})
		at = to
	}
	if at < len(text) { append(runs, Rich_Run{text = text[at:], style = style}) }
}

// A line of `text` with its ranges lit, cut with "…" when it is longer than its box (as wide as `next` says; else it
// fills). With no ranges, a plain label.
matched_label :: proc(id, text: string, ranges: []Fuzzy_Range) -> ^Box {
	if len(ranges) == 0 { return label(text_with_id(text, id)).box }
	runs := make([dynamic]Rich_Run, context.temp_allocator)
	match_runs(text, ranges, {}, &runs)
	return rich_paragraph(id, runs[:], max_lines = 1).box
}

// `text` shown, `id` its key ("###k"): the label's own id-string.
@(private = "file")
text_with_id :: proc(text, id: string) -> string {
	return strings.concatenate({text_shown(text), id}, frame_allocator())
}
