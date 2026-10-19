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
			x: f32
			i := start
			last_space := -1
			for i < para_end {
				r, n := utf8.decode_rune_in_string(text[i:])
				adv := font.glyph(g.fonts, f, size, r).advance
				if x + adv > w && i > start { break }
				if r == ' ' { last_space = i }
				x += adv
				i += n
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
	inner := (b.rect.max.x - b.rect.min.x) - 2 * b.text_pad
	lines := wrap_lines(b.font, b.font_size, b.text, inner)
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
