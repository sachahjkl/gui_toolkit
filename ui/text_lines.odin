package ui

import "core:unicode/utf8"
import "../font"

// Visual lines of edited text: each paragraph ("\n"-separated) is one line, or, with a width, as many as it takes to
// fit: lines break at the font backend's line break opportunities (UAX #14 on the whole paragraph: spaces, hyphens,
// between CJK characters, Thai / Lao / Khmer / Myanmar words), and a run without one that is wider than the line
// breaks between grapheme clusters. Trailing spaces stay on their line (they hang past the width, as in browsers).

Visual_Line :: struct {
	start, end: int,    // bytes shown on the line (end: before the "\n", or at the wrap with its trailing spaces)
	next:       int,    // where the next line starts (end + 1 after a "\n"; end at a wrap; len(text) + 1 for the last)
	soft:       bool,   // the line ends at a wrap: index `end` is also the next line's start (the caret's affinity says which)
	para:       int,    // paragraph (logical line) number
	first:      bool,   // first visual line of its paragraph
}

// The visual lines of `text` in font `f` at `size`, wrapped at `width` pixels (<= 0: no wrapping).
text_visual_lines :: proc(fonts: ^font.State, f: font.Font_Id, size: f32, text: string, width: f32, allocator := context.temp_allocator) -> []Visual_Line {
	lines := make([dynamic]Visual_Line, 0, 8, allocator)
	ps := 0
	para := 0
	for {
		pe := ps
		for pe < len(text) && text[pe] != '\n' { pe += 1 }
		last := pe >= len(text)
		after := last ? len(text) + 1 : pe + 1
		if width <= 0 || pe - ps == 0 || font.measure(fonts, f, size, text[ps:pe]) <= width {
			append(&lines, Visual_Line{start = ps, end = pe, next = after, para = para, first = true})
		} else {
			wrap_paragraph(fonts, f, size, text, ps, pe, width, para, &lines)
			lines[len(lines) - 1].next = after
		}
		if last { break }
		ps = pe + 1
		para += 1
	}
	return lines[:]
}

@(private)
wrap_paragraph :: proc(fonts: ^font.State, f: font.Font_Id, size: f32, text: string, ps, pe: int, width: f32, para: int, lines: ^[dynamic]Visual_Line) {
	p := text[ps:pe]
	breaks := font.line_breaks(fonts, p, context.temp_allocator)
	ls := 0   // line start, relative to the paragraph
	bi := 0
	first := true
	for ls < len(p) {
		for bi < len(breaks) && breaks[bi].at <= ls { bi += 1 }
		// the rest fits: the paragraph's last line
		if font.measure(fonts, f, size, p[ls:trim_end(p, ls, len(p))]) <= width {
			append(lines, Visual_Line{start = ps + ls, end = ps + len(p), para = para, first = first})
			return
		}
		// the farthest opportunity whose line, without its trailing spaces, fits
		cut := -1
		for k := bi; k < len(breaks); k += 1 {
			at := breaks[k].at
			if font.measure(fonts, f, size, p[ls:trim_end(p, ls, at)]) > width { break }
			cut = at
		}
		// none: the first word alone is too wide, it is cut between grapheme clusters
		if cut < 0 {
			limit := bi < len(breaks) ? breaks[bi].at : len(p)
			cut = grapheme_cut(fonts, f, size, p, ls, limit, width)
		}
		append(lines, Visual_Line{start = ps + ls, end = ps + cut, next = ps + cut, soft = true, para = para, first = first})
		first = false
		ls = cut
	}
}

// The largest grapheme boundary b in (ls, limit] with p[ls:b] no wider than `width` (at least one grapheme).
@(private)
grapheme_cut :: proc(fonts: ^font.State, f: font.Font_Id, size: f32, p: string, ls, limit: int, width: f32) -> int {
	best := -1
	it := utf8.decode_grapheme_iterator_make(p[ls:limit])
	for {
		cl, gr, more := utf8.decode_grapheme_iterate(&it)
		if !more { break }
		b := ls + gr.byte_index + len(cl)
		if best >= 0 && font.measure(fonts, f, size, p[ls:b]) > width { break }
		best = b
	}
	return best < 0 ? limit : best
}

// The visual line of byte `index`. At the end of a wrapped line (`index` == its end == the next line's start),
// `upstream` picks the line that ends there (the caret after a click past a line's end, or after End).
visual_line_of :: proc(lines: []Visual_Line, index: int, upstream := false) -> int {
	if len(lines) == 0 { return 0 }
	lo, hi := 0, len(lines) - 1
	for lo < hi {   // the last line starting at or before index
		mid := (lo + hi + 1) / 2
		if lines[mid].start <= index { lo = mid } else { hi = mid - 1 }
	}
	if upstream && lo > 0 && lines[lo - 1].soft && lines[lo - 1].end == index { return lo - 1 }
	return lo
}
