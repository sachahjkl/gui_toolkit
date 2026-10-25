package ui

import "core:math"
import "core:unicode/utf8"
import "../draw"
import "../font"

// Wrapped text: a box with .Text_Wrap breaks its text into lines at its width (greedy, at spaces; a word longer than
// the line is broken between characters; "\n" always breaks). With a .Text height it is as tall as its lines: the
// height is resolved in the Y pass, once the X pass gave the box its width.

// Byte ranges [start, end) of the lines of `text` laid out in `width` pixels (trailing spaces of a line excluded).
wrap_lines :: proc(f: font.Font_Id, size: f32, text: string, width: f32, allocator := context.temp_allocator) -> [][2]int {
	lines := make([dynamic][2]int, 0, 4, allocator)
	if text == "" { return lines[:] }
	w := max(width, 1)
	para_start := 0
	for para_start <= len(text) {
		para_end := para_start
		for para_end < len(text) && text[para_end] != '\n' { para_end += 1 }
		start := para_start
		for {
			for start < para_end && text[start] == ' ' && start > para_start { start += 1 }
			if start >= para_end { if start == para_start { append(&lines, [2]int{start, start}) }; break }
			// longest prefix that fits, ending at a space if there is one
			// (by grapheme cluster: an emoji sequence or a letter with its marks is measured whole and never cut)
			x: f32
			i := start
			last_space := -1
			it := utf8.decode_grapheme_iterator_make(text[start:para_end])
			for {
				cl, gr, more := utf8.decode_grapheme_iterate(&it)
				if !more { break }
				at := start + gr.byte_index
				adv: f32
				if len(cl) == 1 {
					r, _ := utf8.decode_rune_in_string(cl)
					adv = font.glyph(g.fonts, f, size, r).advance
				} else {
					adv = font.text_width(g.fonts, f, size, cl)
				}
				if x + adv > w && at > start { i = at; break }
				if cl == " " { last_space = at }
				x += adv
				i = at + len(cl)
			}
			if i >= para_end { append(&lines, [2]int{start, trim_end(text, start, para_end)}); break }
			cut := last_space > start ? last_space : i
			append(&lines, [2]int{start, trim_end(text, start, cut)})
			start = cut
		}
		if para_end >= len(text) { break }
		para_start = para_end + 1
	}
	return lines[:]
}

// Wrapped lines are kept between builds: a paragraph is wrapped once for a given text, font, size and width, then
// only looked up (layout and drawing both ask, every frame). Entries not used for WRAP_CACHE_KEEP builds go.
WRAP_CACHE_KEEP :: 120

Wrap_Key :: struct {
	text_hash: u64,
	text_len:  int,
	font:      font.Font_Id,
	size:      f32,
	width:     f32,
}

Wrap_Entry :: struct {
	lines:      [][2]int,   // heap (the state's allocator)
	last_build: u64,
}

// Lines of `text` at `width` from the cache (wrapped and remembered the first time).
wrap_lines_cached :: proc(f: font.Font_Id, size: f32, text: string, width: f32) -> [][2]int {
	s := g
	if text == "" { return nil }
	h: u64 = 0xcbf29ce484222325
	for c in transmute([]u8)text { h = (h ~ u64(c)) * 0x100000001b3 }
	k := Wrap_Key{text_hash = h, text_len = len(text), font = f, size = size, width = max(width, 1)}
	if e, ok := &s.wrap_cache[k]; ok {
		e.last_build = s.build_index
		return e.lines
	}
	lines := wrap_lines(f, size, text, width, context.allocator)
	s.wrap_cache[k] = {lines = lines, last_build = s.build_index}
	return lines
}

@(private)
wrap_cache_trim :: proc(s: ^State) {
	if s.build_index % 30 != 0 { return }
	dead := make([dynamic]Wrap_Key, context.temp_allocator)
	for k, e in s.wrap_cache { if e.last_build + WRAP_CACHE_KEEP < s.build_index { append(&dead, k) } }
	for k in dead {
		e := s.wrap_cache[k]
		delete(e.lines)
		delete_key(&s.wrap_cache, k)
	}
}

@(private)
wrap_cache_destroy :: proc(s: ^State) {
	for _, e in s.wrap_cache { delete(e.lines) }
	delete(s.wrap_cache)
}

// Number of wrapped paragraphs kept (tests, statistics).
wrap_cache_len :: proc(s: ^State) -> int { return len(s.wrap_cache) }

@(private)
trim_end :: proc(text: string, start, end: int) -> int {
	e := end
	for e > start && text[e - 1] == ' ' { e -= 1 }
	return e
}

@(private)
line_height_of :: proc(b: ^Box) -> f32 {
	m := font.metrics(g.fonts, b.font, b.font_size)
	return math.ceil(m.line_height)
}

@(private)
draw_wrapped_text :: proc(s: ^State, dc: ^draw.Context, b: ^Box) {
	m := font.metrics(s.fonts, b.font, b.font_size)
	lh := math.ceil(m.line_height)
	inner := b.size.x - 2 * b.text_pad   // the width layout wrapped at (the rect is rounded to pixels)
	lines := wrap_lines_cached(b.font, b.font_size, b.text, inner)
	total := f32(len(lines)) * lh
	y := (b.rect.min.y + b.rect.max.y) * 0.5 - total * 0.5   // the block of lines is centred like single-line text
	for l in lines {
		line := b.text[l[0]:l[1]]
		lw := font.text_width(s.fonts, b.font, b.font_size, line)
		x: f32
		switch b.text_align {
		case .Left:   x = b.rect.min.x + b.text_pad
		case .Center: x = (b.rect.min.x + b.rect.max.x - lw) * 0.5
		case .Right:  x = b.rect.max.x - b.text_pad - lw
		}
		baseline := y + (lh + m.ascent - m.descent) * 0.5
		draw.text(dc, b.font, b.font_size, {math.round(x), math.round(baseline)}, b.text_color, line)
		y += lh
	}
}

// Text that wraps at the width it is given (full width unless `next` says otherwise) and is as tall as its lines.
paragraph :: proc(id: string) -> Signal {
	m := g.has_next ? g.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = text_size() }
	g.next_mod = m
	g.has_next = true
	b := build_box({.Draw_Text, .Text_Wrap, .No_Text_Trunc}, id)
	return signal(b)
}
