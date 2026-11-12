package markdown

import "core:strings"
import "../ui"

// How inline code is shown in a block's runs.
Inline :: struct {
	code_size:  f32,        // not 0: inline code at that size, when the text around it is at another
	code_color: ui.Color,   // alpha 0: the colour of the text around it
}

// The inline Markdown of one block's text as runs of `base`, appended to `out` (the text's own bytes: no copy):
// **bold** and __bold__, *italic* and _italic_, ~~strike~~, `code`, [text](target), and bare web addresses as links.
inline_runs :: proc(text: string, base: ui.Rich_Style, out: ^[dynamic]ui.Rich_Run, o: Inline = {}) {
	st := base
	i, start := 0, 0
	flush :: proc(out: ^[dynamic]ui.Rich_Run, s: string, st: ui.Rich_Style) { if s != "" { append(out, ui.Rich_Run{text = s, style = st}) } }
	for i < len(text) {
		c := text[i]
		switch {
		case ui.web_address_len(text, i) > 0:   // a bare web address: a link (before the emphasis marks: "_" is common in them)
			n := ui.web_address_len(text, i)
			flush(out, text[start:i], st)
			l := st
			l.link, l.underline, l.color = text[i:i + n], true, {}
			flush(out, text[i:i + n], l)
			i += n; start = i
		case strings.has_prefix(text[i:], "**") || strings.has_prefix(text[i:], "__"):
			flush(out, text[start:i], st); st.bold = !st.bold; i += 2; start = i
		case strings.has_prefix(text[i:], "~~"):
			flush(out, text[start:i], st); st.strike = !st.strike; i += 2; start = i
		case c == '*' || (c == '_' && (i == 0 || !is_word(text[i - 1]) || st.italic) && (st.italic || (i + 1 < len(text) && text[i + 1] != ' '))):
			// (a lone '*' between spaces is a multiplication, not emphasis; a '_' inside a word is part of it)
			if c == '*' && i + 1 < len(text) && text[i + 1] == ' ' && !st.italic { i += 1; continue }
			flush(out, text[start:i], st); st.italic = !st.italic; i += 1; start = i
		case c == '`':
			e := strings.index_byte(text[i + 1:], '`')
			if e < 0 { i += 1; continue }
			flush(out, text[start:i], st)
			cs := st
			cs.code = true
			if o.code_size > 0 { cs.size = o.code_size }
			if o.code_color.a > 0 { cs.color = o.code_color }
			if inner := text[i + 1:i + 1 + e]; ui.web_address_len(inner, 0) == len(inner) {   // `https://...`: a link still
				cs.link, cs.underline, cs.color = inner, true, {}
			}
			flush(out, text[i + 1:i + 1 + e], cs)
			i += e + 2; start = i
		case c == '[':
			close_b := strings.index(text[i:], "](")
			close_p := close_b >= 0 ? strings.index_byte(text[i + close_b:], ')') : -1
			if close_b < 0 || close_p < 0 { i += 1; continue }
			flush(out, text[start:i], st)
			l := st
			l.link = text[i + close_b + 2:i + close_b + close_p]
			l.underline, l.color = true, {}   // (the theme's link colour)
			flush(out, text[i + 1:i + close_b], l)
			i += close_b + close_p + 1; start = i
		case:
			i += 1
		}
	}
	flush(out, text[start:], st)
}

@(private = "file")
is_word :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') }
