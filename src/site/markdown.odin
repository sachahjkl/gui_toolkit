package tk_site

// Markdown to HTML: the subset a project's documents use. Headings (with GitHub's ids), paragraphs, *emphasis*, **strong**, `code`,
// fenced code, nested lists, tables, links and images. Nothing else is read, so a construct that is missing here shows up as plain
// text in the page.

import "core:fmt"
import "core:strings"

// What a link's address becomes in the page (a document's .md its page, another file its place in the repository...). nil: as is.
Link_Rule :: proc(url: string) -> string


// The text of the first "# " heading, without its code marks ("" when there is none).
markdown_title :: proc(md: string) -> string {
	in_fence := false
	for line in strings.split_lines(md, context.temp_allocator) {
		if strings.has_prefix(strings.trim_left_space(line), "```") { in_fence = !in_fence }
		if !in_fence && strings.has_prefix(line, "# ") {
			text, _ := strings.remove_all(line[2:], "`", context.temp_allocator)
			return strings.trim_space(text)
		}
	}
	return ""
}

markdown_html :: proc(md: string, link: Link_Rule = nil) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	text, _ := strings.remove_all(md, "\r", context.temp_allocator)
	markdown_blocks(&b, strings.split_lines(text, context.temp_allocator), false, link)
	return strings.to_string(b)
}

// The id of a heading, as GitHub makes it: lower case, a hyphen for a space, letters, digits, "-" and "_" kept, the rest dropped.
heading_id :: proc(text: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for c in transmute([]byte)text {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '-', '_': strings.write_byte(&b, c)
		case 'A' ..= 'Z': strings.write_byte(&b, c + 32)
		case ' ': strings.write_byte(&b, '-')
		}
	}
	return strings.to_string(b)
}

write_escaped :: proc(b: ^strings.Builder, s: string) {
	for c in transmute([]byte)s {
		switch c {
		case '&': strings.write_string(b, "&amp;")
		case '<': strings.write_string(b, "&lt;")
		case '>': strings.write_string(b, "&gt;")
		case '"': strings.write_string(b, "&quot;")
		case: strings.write_byte(b, c)
		}
	}
}

blank_line :: proc(l: string) -> bool { return strings.trim_space(l) == "" }

leading_spaces :: proc(l: string) -> int {
	n := 0
	for n < len(l) && l[n] == ' ' { n += 1 }
	return n
}

is_fence :: proc(l: string) -> bool { return strings.has_prefix(strings.trim_left(l, " "), "```") }

heading_level :: proc(l: string) -> int {
	n := 0
	for n < len(l) && l[n] == '#' { n += 1 }
	return n >= 1 && n <= 6 && n < len(l) && l[n] == ' ' ? n : 0
}

List_Marker :: struct {
	indent, width: int, // spaces before the marker; the marker and its space
	ordered:       bool,
}

list_marker :: proc(l: string) -> (m: List_Marker, ok: bool) {
	m.indent = leading_spaces(l)
	rest := l[m.indent:]
	if strings.has_prefix(rest, "- ") || strings.has_prefix(rest, "* ") { m.width = 2; return m, true }
	digits := 0
	for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' { digits += 1 }
	if digits > 0 && strings.has_prefix(rest[digits:], ". ") { m.width, m.ordered = digits + 2, true; return m, true }
	return m, false
}

is_table_separator :: proc(l: string) -> bool {
	t := strings.trim_space(l)
	if !strings.has_prefix(t, "|") || !strings.contains(t, "-") { return false }
	for c in transmute([]byte)t { if c != '|' && c != '-' && c != ':' && c != ' ' { return false } }
	return true
}

// A line that ends a paragraph. A numbered line does so only as "1.", so a wrapped line that starts with a number stays in it.
ends_paragraph :: proc(lines: []string, i: int) -> bool {
	l := lines[i]
	if blank_line(l) || is_fence(l) || heading_level(l) > 0 { return true }
	if strings.has_prefix(l, "|") && i + 1 < len(lines) && is_table_separator(lines[i + 1]) { return true }
	m, ok := list_marker(l)
	return ok && (!m.ordered || strings.has_prefix(l[m.indent:], "1. "))
}

// `tight`: a list item without blank lines, whose paragraphs are not wrapped in <p>.
markdown_blocks :: proc(b: ^strings.Builder, lines: []string, tight: bool, link: Link_Rule) {
	i := 0
	for i < len(lines) {
		l := lines[i]
		switch {
		case blank_line(l):
			i += 1
		case is_fence(l):
			indent := leading_spaces(l)
			lang := strings.trim_space(strings.trim_left(l, " ")[3:])
			if lang == "" { strings.write_string(b, "<pre><code>") } else { fmt.sbprintf(b, "<pre><code class=\"language-%s\">", esc(lang)) }
			i += 1
			first := true
			for i < len(lines) && !is_fence(lines[i]) {
				if !first { strings.write_byte(b, '\n') }
				first = false
				write_escaped(b, lines[i][min(indent, leading_spaces(lines[i])):])
				i += 1
			}
			i += 1 // the closing fence
			strings.write_string(b, "</code></pre>\n")
		case heading_level(l) > 0:
			level := heading_level(l)
			text := strings.trim_space(l[level:])
			plain, _ := strings.remove_all(text, "`", context.temp_allocator)
			fmt.sbprintf(b, "<h%d id=\"%s\">", level, heading_id(plain))
			markdown_inline(b, text, link)
			fmt.sbprintf(b, "</h%d>\n", level)
			i += 1
		case strings.has_prefix(l, "|") && i + 1 < len(lines) && is_table_separator(lines[i + 1]):
			i = markdown_table(b, lines, i, link)
		case:
			if _, ok := list_marker(l); ok {
				i = markdown_list(b, lines, i, link)
				continue
			}
			start := i
			i += 1
			for i < len(lines) && !ends_paragraph(lines, i) { i += 1 }
			if !tight { strings.write_string(b, "<p>") }
			// one text for the whole paragraph: emphasis and code may span its lines
			text, _ := strings.join(lines[start:i], "\n", context.temp_allocator)
			markdown_inline(b, strings.trim_space(text), link)
			strings.write_string(b, tight ? "\n" : "</p>\n")
		}
	}
}

// The cells of a table row: split at "|" outside code spans and not after a backslash.
table_cells :: proc(l: string) -> []string {
	t := strings.trim_space(l)
	t = strings.trim_prefix(t, "|")
	t = strings.trim_suffix(t, "|")
	cells := make([dynamic]string, context.temp_allocator)
	start, i := 0, 0
	for i < len(t) {
		switch t[i] {
		case '\\': i += 2; continue
		case '`':
			n := run_length(t, i, '`')
			close := find_run(t, i + n, '`', n)
			i = close < 0 ? i + n : close + n
			continue
		case '|':
			append(&cells, strings.trim_space(t[start:i]))
			start = i + 1
		}
		i += 1
	}
	append(&cells, strings.trim_space(t[start:min(i, len(t))]))
	return cells[:]
}

markdown_table :: proc(b: ^strings.Builder, lines: []string, at: int, link: Link_Rule) -> int {
	strings.write_string(b, "<div class=\"table\"><table>\n<thead><tr>")
	for c in table_cells(lines[at]) {
		strings.write_string(b, "<th>")
		markdown_inline(b, c, link)
		strings.write_string(b, "</th>")
	}
	strings.write_string(b, "</tr></thead>\n<tbody>\n")
	i := at + 2
	for i < len(lines) && strings.has_prefix(strings.trim_space(lines[i]), "|") {
		strings.write_string(b, "<tr>")
		for c in table_cells(lines[i]) {
			strings.write_string(b, "<td>")
			markdown_inline(b, c, link)
			strings.write_string(b, "</td>")
		}
		strings.write_string(b, "</tr>\n")
		i += 1
	}
	strings.write_string(b, "</tbody>\n</table></div>\n")
	return i
}

// A list that starts at lines[at]: its items, each with the lines that belong to it (more indented, or a continuation of
// its text), rendered as blocks of their own. Returns the line after the list.
markdown_list :: proc(b: ^strings.Builder, lines: []string, at: int, link: Link_Rule) -> int {
	first, _ := list_marker(lines[at])
	tag := first.ordered ? "ol" : "ul"
	fmt.sbprintf(b, "<%s>\n", tag)
	i := at
	for i < len(lines) {
		m, ok := list_marker(lines[i])
		if !ok || m.indent != first.indent || m.ordered != first.ordered { break }
		item := make([dynamic]string, context.temp_allocator)
		append(&item, lines[i][m.indent + m.width:])
		tight := true
		j := i + 1
		for j < len(lines) {
			l := lines[j]
			if blank_line(l) {
				k := j
				for k < len(lines) && blank_line(lines[k]) { k += 1 }
				if k >= len(lines) || leading_spaces(lines[k]) <= m.indent { break }
				append(&item, "")
				tight = false
				j += 1
			} else if leading_spaces(l) > m.indent {
				append(&item, l[min(m.indent + m.width, leading_spaces(l)):])
				j += 1
			} else if _, is_item := list_marker(l); !is_item && !is_fence(l) && heading_level(l) == 0 && !blank_line(lines[j - 1]) {
				append(&item, l) // a wrapped line that is not indented
				j += 1
			} else {
				break
			}
		}
		strings.write_string(b, "<li>")
		markdown_blocks(b, item[:], tight, link)
		strings.write_string(b, "</li>\n")
		i = j
		// a blank line between two items does not end the list
		k := i
		for k < len(lines) && blank_line(lines[k]) { k += 1 }
		if k < len(lines) && k > i {
			if next, next_ok := list_marker(lines[k]); next_ok && next.indent == first.indent && next.ordered == first.ordered { i = k }
		}
	}
	fmt.sbprintf(b, "</%s>\n", tag)
	return i
}

run_length :: proc(s: string, at: int, c: byte) -> int {
	n := 0
	for at + n < len(s) && s[at + n] == c { n += 1 }
	return n
}

// The start of the next run of exactly `n` times `c` from `from`, or -1.
find_run :: proc(s: string, from: int, c: byte, n: int) -> int {
	i := from
	for i < len(s) {
		if s[i] != c { i += 1; continue }
		r := run_length(s, i, c)
		if r == n { return i }
		i += r
	}
	return -1
}

// The start of the next `delim` from `from` that is not in a code span and not escaped, or -1. A closing "*" does not follow a
// space and is not the start of "**".
find_close :: proc(s: string, from: int, delim: string) -> int {
	i := from
	for i < len(s) {
		switch s[i] {
		case '\\': i += 2; continue
		case '`':
			n := run_length(s, i, '`')
			close := find_run(s, i + n, '`', n)
			i = close < 0 ? i + n : close + n
			continue
		}
		if strings.has_prefix(s[i:], delim) {
			if delim == "**" { return i }
			if s[i - 1] != ' ' && s[i - 1] != '*' && !(i + 1 < len(s) && s[i + 1] == '*') { return i }
			i += run_length(s, i, '*')
			continue
		}
		i += 1
	}
	return -1
}

// [label](url) at s[at] == '[': the label, the address (up to a space: a title is not read), the index after ")".
markdown_link :: proc(s: string, at: int) -> (label, url: string, end: int, ok: bool) {
	depth, i := 0, at
	for i < len(s) {
		switch s[i] {
		case '\\': i += 2; continue
		case '`':
			n := run_length(s, i, '`')
			close := find_run(s, i + n, '`', n)
			i = close < 0 ? i + n : close + n
			continue
		case '[': depth += 1
		case ']':
			depth -= 1
			if depth == 0 {
				if i + 1 >= len(s) || s[i + 1] != '(' { return }
				close := strings.index_byte(s[i + 2:], ')')
				if close < 0 { return }
				target := s[i + 2:][:close]
				if space := strings.index_byte(target, ' '); space >= 0 { target = target[:space] }
				return s[at + 1:i], target, i + 2 + close + 1, true
			}
		}
		i += 1
	}
	return
}

markdown_inline :: proc(b: ^strings.Builder, s: string, link: Link_Rule) {
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '`':
			n := run_length(s, i, '`')
			close := find_run(s, i + n, '`', n)
			if close < 0 {
				strings.write_string(b, s[i:i + n])
				i += n
				continue
			}
			code := s[i + n:close]
			if len(code) >= 2 && code[0] == ' ' && code[len(code) - 1] == ' ' { code = code[1:len(code) - 1] }
			strings.write_string(b, "<code>")
			write_escaped(b, code)
			strings.write_string(b, "</code>")
			i = close + n
		case c == '\\' && i + 1 < len(s) && strings.contains_rune("\\`*[]()#|!<>_{}-.+", rune(s[i + 1])):
			write_escaped(b, s[i + 1:i + 2])
			i += 2
		case c == '!' && i + 1 < len(s) && s[i + 1] == '[':
			if label, url, end, ok := markdown_link(s, i + 1); ok {
				// a picture keeps its address: the pictures are copied beside the pages
				fmt.sbprintf(b, "<img src=\"%s\" alt=\"%s\" loading=\"lazy\">", esc(url), esc(label))
				i = end
			} else {
				strings.write_byte(b, '!')
				i += 1
			}
		case c == '[':
			if label, url, end, ok := markdown_link(s, i); ok {
				fmt.sbprintf(b, "<a href=\"%s\">", esc(link != nil ? link(url) : url))
				markdown_inline(b, label, link)
				strings.write_string(b, "</a>")
				i = end
			} else {
				strings.write_byte(b, '[')
				i += 1
			}
		case c == '*' && strings.has_prefix(s[i:], "**"):
			close := find_close(s, i + 2, "**")
			if close > i + 2 {
				strings.write_string(b, "<strong>")
				markdown_inline(b, s[i + 2:close], link)
				strings.write_string(b, "</strong>")
				i = close + 2
			} else {
				strings.write_string(b, "**")
				i += 2
			}
		case c == '*' && i + 1 < len(s) && s[i + 1] != ' ' && s[i + 1] != '*':
			close := find_close(s, i + 1, "*")
			if close > i + 1 {
				strings.write_string(b, "<em>")
				markdown_inline(b, s[i + 1:close], link)
				strings.write_string(b, "</em>")
				i = close + 1
			} else {
				strings.write_byte(b, '*')
				i += 1
			}
		case:
			write_escaped(b, s[i:i + 1])
			i += 1
		}
	}
}
