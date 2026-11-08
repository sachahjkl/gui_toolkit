package tk_site

// What the steps of a site share: files read and written, HTML escaped, pieces of HTML found, and what JavaScript's strings do.
// These pages were first made by JavaScript, and were compared with this byte for byte: the matchers each say which regular
// expression they are, with what JS gives its "whitespace", ".", UTF-16 lengths and "$" in a replacement.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// The text of a file, which must be UTF-8: JS would have turned the rest into U+FFFD without a word.
read_utf8 :: proc(path: string) -> (text: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { fmt.eprintfln("site: %s: %v", path, err); return "", false }
	if !utf8.valid_string(string(data)) { fmt.eprintfln("site: %s is not UTF-8", path); return "", false }
	return string(data), true
}

write_text :: proc(path, text: string) -> bool {
	err := os.write_entire_file(path, text)
	if err != nil { fmt.eprintfln("site: %s: %v", path, err) }
	return err == nil
}

// <out> gets what <site> has; what it had besides stays.
copy_site :: proc(site, out: string) -> bool {
	// (first: on Linux a folder that does not exist has no absolute path)
	if err := os.make_directory_all(out); err != nil && err != .Exist { fmt.eprintfln("site: %s: %v", out, err); return false }
	from, from_err := os.get_absolute_path(site, context.temp_allocator)
	to, to_err := os.get_absolute_path(out, context.temp_allocator)
	if from_err != nil || to_err != nil { fmt.eprintfln("site: no path for %s or %s", site, out); return false }
	if from == to || strings.has_prefix(to, cat(from, "/")) || strings.has_prefix(to, cat(from, "\\")) {
		fmt.eprintfln("site: cannot copy %s into itself", site)
		return false
	}
	if err := os.copy_directory_all(out, site); err != nil { fmt.eprintfln("site: copy to %s: %v", out, err); return false }
	return true
}

cat :: proc(parts: ..string) -> string { return strings.concatenate(parts, context.temp_allocator) }

put :: proc(b: ^strings.Builder, parts: ..string) {
	for p in parts { strings.write_string(b, p) }
}

esc :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&': strings.write_string(&b, "&amp;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case '"': strings.write_string(&b, "&quot;")
		case:     strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// \s in JS, and what its trim() removes.
is_js_space :: proc(r: rune) -> bool {
	switch r {
	case '\t', '\n', 0x0B, 0x0C, '\r', ' ', 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		return true
	}
	return false
}

js_trim :: proc(s: string) -> string { return strings.trim_right_proc(strings.trim_left_proc(s, is_js_space), is_js_space) }

// What "." does not match.
has_line_end :: proc(s: string) -> bool {
	return strings.contains_any(s, "\r\n") || strings.contains(s, "\u2028") || strings.contains(s, "\u2029")
}

is_word_byte :: proc(c: byte) -> bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// toLowerCase(), but for one thing: a Greek sigma ending a word stays σ, where JS says ς. Headings and menu labels have none.
js_lower :: proc(s: string) -> string {
	dotted, _ := strings.replace_all(s, "\u0130", "i\u0307", context.temp_allocator)   // (the one letter that gets longer)
	return strings.to_lower(dotted, context.temp_allocator)
}

// How long a JS string says this is.
utf16_length :: proc(s: string) -> int {
	n := 0
	for r in s { n += r >= 0x10000 ? 2 : 1 }
	return n
}

// slice(0, n). Half of a pair is what JS keeps, and a file cannot hold it: U+FFFD is what it writes.
utf16_prefix :: proc(s: string, n: int) -> string {
	units := 0
	for r, i in s {
		width := r >= 0x10000 ? 2 : 1
		if units + width > n { return units < n ? cat(s[:i], "\ufffd") : s[:i] }
		units += width
	}
	return s
}

// /\r?\n/ as split(): a lone \r is not a line's end.
split_lines :: proc(text: string) -> []string {
	lines := strings.split(text, "\n", context.temp_allocator)
	for i in 0 ..< len(lines) - 1 { lines[i] = strings.trim_suffix(lines[i], "\r") }
	return lines
}

// The replacement text of String.replace, when it is not a function: a changelog entry saying "$&" gets what JS gives it.
// (No expression here has a group in those cases: "$1" stays as it is.)
expand_replacement :: proc(with, s: string, start, end: int) -> string {
	if strings.index_byte(with, '$') < 0 { return with }
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(with); i += 1 {
		if with[i] == '$' && i + 1 < len(with) {
			switch with[i + 1] {
			case '$':  strings.write_byte(&b, '$'); i += 1; continue
			case '&':  strings.write_string(&b, s[start:end]); i += 1; continue
			case '`':  strings.write_string(&b, s[:start]); i += 1; continue
			case '\'': strings.write_string(&b, s[end:]); i += 1; continue
			}
		}
		strings.write_byte(&b, with[i])
	}
	return strings.to_string(b)
}

replace_span :: proc(s, with: string, start, end: int) -> string {
	return cat(s[:start], expand_replacement(with, s, start, end), s[end:])
}

// s.replace("what", with).
replace_text :: proc(s, what, with: string) -> string {
	at := strings.index(s, what)
	return at < 0 ? s : replace_span(s, with, at, at + len(what))
}

// /open[\s\S]*?close/, what it matched. "": nothing, as take() said.
between :: proc(s, open, close: string) -> string {
	start := strings.index(s, open)
	if start < 0 { return "" }
	body := start + len(open)
	end := strings.index(s[body:], close)
	return end < 0 ? "" : s[start:body + end + len(close)]
}

// /<title>[^<]*<\/title>/
title_span :: proc(s: string) -> (start, end: int, ok: bool) {
	OPEN :: "<title>"
	CLOSE :: "</title>"
	from := 0
	for {
		at := strings.index(s[from:], OPEN)
		if at < 0 { return }
		start = from + at
		body := start + len(OPEN)
		stop := strings.index_byte(s[body:], '<')
		if stop >= 0 && strings.has_prefix(s[body + stop:], CLOSE) { return start, body + stop + len(CLOSE), true }
		from = body
	}
}

// /open[^>]*>/
tag_span :: proc(s, open: string) -> (start, end: int, ok: bool) {
	start = strings.index(s, open)
	if start < 0 { return }
	stop := strings.index_byte(s[start + len(open):], '>')
	if stop < 0 { return }
	return start, start + len(open) + stop + 1, true
}

// /prefix([^"]*)"after/: the value.
quoted_value :: proc(s, prefix, after: string) -> (value: string, ok: bool) {
	from := 0
	for {
		at := strings.index(s[from:], prefix)
		if at < 0 { return "", false }
		body := from + at + len(prefix)
		stop := strings.index_byte(s[body:], '"')
		if stop < 0 { return "", false }
		if strings.has_prefix(s[body + stop + 1:], after) { return s[body:body + stop], true }
		from = body
	}
}

// /<section id="\w+" class="download">[\s\S]*?<\/section>/
download_section :: proc(s: string) -> string {
	OPEN :: `<section id="`
	CLASS :: `" class="download">`
	from := 0
	for {
		at := strings.index(s[from:], OPEN)
		if at < 0 { return "" }
		start := from + at
		word := start + len(OPEN)
		end := word
		for end < len(s) && is_word_byte(s[end]) { end += 1 }
		if end > word && strings.has_prefix(s[end:], CLASS) {
			stop := strings.index(s[end:], "</section>")
			return stop < 0 ? "" : s[start:end + stop + len("</section>")]
		}
		from = word
	}
}

// /<script src="[^"]*"[^>]*><\/script>/
script_with_src :: proc(s: string) -> string {
	OPEN :: `<script src="`
	CLOSE :: "</script>"
	from := 0
	for {
		at := strings.index(s[from:], OPEN)
		if at < 0 { return "" }
		start := from + at
		body := start + len(OPEN)
		quote := strings.index_byte(s[body:], '"')
		if quote < 0 { return "" }
		stop := strings.index_byte(s[body + quote:], '>')
		if stop < 0 { return "" }
		end := body + quote + stop + 1
		if strings.has_prefix(s[end:], CLOSE) { return s[start:end + len(CLOSE)] }
		from = body
	}
}

// The tag around a piece of HTML taken away, and the blanks around that.
inner :: proc(html: string) -> string {
	s := js_trim(html)
	if strings.has_prefix(s, "<") {
		if end := strings.index_byte(s, '>'); end >= 0 { s = s[end + 1:] }
	}
	if strings.has_suffix(s, ">") {
		last := len(s) - 1
		from := strings.last_index_byte(s[:last], '>') + 1
		if close := strings.index(s[from:last], "</"); close >= 0 { s = s[:from + close] }
	}
	return js_trim(s)
}

// The words of a piece of HTML.
plain_text :: proc(html: string) -> string {
	tags := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(html); {
		if html[i] == '<' {
			if end := strings.index_byte(html[i + 1:], '>'); end > 0 { i += end + 2; continue }
		}
		strings.write_byte(&tags, html[i])
		i += 1
	}
	b := strings.builder_make(context.temp_allocator)
	blank := false
	for r in strings.to_string(tags) {
		if is_js_space(r) {
			if !blank { strings.write_byte(&b, ' ') }
		} else {
			strings.write_rune(&b, r)
		}
		blank = is_js_space(r)
	}
	return js_trim(strings.to_string(b))
}

slug :: proc(s: string) -> string {
	lower := js_lower(s)
	b := strings.builder_make(context.temp_allocator)
	gap := false
	for i in 0 ..< len(lower) {
		c := lower[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			if gap && strings.builder_len(b) > 0 { strings.write_byte(&b, '-') }
			strings.write_byte(&b, c)
			gap = false
		} else {
			gap = true
		}
	}
	return strings.to_string(b)
}

// split(/(?<=[.:;])\s/)[0]
first_sentence :: proc(text: string) -> string {
	for r, i in text {
		if i > 0 && is_js_space(r) && strings.index_byte(".:;", text[i - 1]) >= 0 { return text[:i] }
	}
	return text
}

// /\*\*(.+?)\*\*/ at `at`.
match_bold :: proc(s: string, at: int) -> (bold: string, end: int, ok: bool) {
	if !strings.has_prefix(s[at:], "**") || at + len("**") >= len(s) { return }
	body := at + len("**")
	close := strings.index(s[body + 1:], "**")
	if close < 0 { return }
	stop := body + 1 + close
	if has_line_end(s[body:stop]) { return }
	return s[body:stop], stop + len("**"), true
}

// /^\[([^\]]+)\]/: the text in brackets, and what follows.
bracket :: proc(s: string) -> (name, rest: string, ok: bool) {
	if !strings.has_prefix(s, "[") { return }
	close := strings.index_byte(s[1:], ']')
	if close <= 0 { return }
	return s[1:1 + close], s[close + 2:], true
}

// /\[([^\]]+)\]\((https?:[^)\s]+)\)/ at `at`.
match_link :: proc(s: string, at: int) -> (label, url: string, end: int, ok: bool) {
	name, rest, found := bracket(s[at:])
	if !found || !strings.has_prefix(rest, "(") { return }
	address := rest[1:]
	scheme := 0
	if strings.has_prefix(address, "http:") {
		scheme = len("http:")
	} else if strings.has_prefix(address, "https:") {
		scheme = len("https:")
	} else {
		return
	}
	for r, i in address[scheme:] {
		if r == ')' {
			if i == 0 { return }
			url = address[:scheme + i]
			return name, url, len(s) - len(address) + scheme + i + 1, true
		}
		if is_js_space(r) { return }
	}
	return
}

CODE_OPEN  :: 0x01
CODE_CLOSE :: 0x02

// **bold**, `code`, [text](url). Code first: what is in it is not markup.
inline :: proc(text: string) -> string {
	code := make([dynamic]string, context.temp_allocator)
	marked := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(text); {
		if text[i] == '`' {
			close := strings.index_byte(text[i + 1:], '`')
			if close > 0 {
				append(&code, cat("<code>", esc(text[i + 1:i + 1 + close]), "</code>"))
				fmt.sbprintf(&marked, "%c%d%c", CODE_OPEN, len(code) - 1, CODE_CLOSE)
				i += close + 2
				continue
			}
		}
		strings.write_byte(&marked, text[i])
		i += 1
	}
	s := esc(strings.to_string(marked))

	bold := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if strong, end, ok := match_bold(s, i); ok {
			put(&bold, "<strong>", strong, "</strong>")
			i = end
		} else {
			strings.write_byte(&bold, s[i])
			i += 1
		}
	}
	s = strings.to_string(bold)

	links := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if label, url, end, ok := match_link(s, i); ok {
			put(&links, `<a href="`, url, `">`, label, "</a>")
			i = end
		} else {
			strings.write_byte(&links, s[i])
			i += 1
		}
	}
	s = strings.to_string(links)

	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if s[i] == CODE_OPEN {
			digits := i + 1
			n := 0
			for digits < len(s) && s[digits] >= '0' && s[digits] <= '9' {
				n = min(n * 10 + int(s[digits] - '0'), len(code))   // (past the end is all that counts)
				digits += 1
			}
			if digits > i + 1 && digits < len(s) && s[digits] == CODE_CLOSE {
				// (a mark that was in the text itself, with no code behind it: what JS prints for it)
				strings.write_string(&b, n < len(code) ? code[n] : "undefined")
				i = digits + 1
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

