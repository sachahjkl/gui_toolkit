package tk_site

// Markdown to HTML: a CommonMark subset tuned to the documents projects ship. ATX headings (GitHub's ids, each with its "#"
// anchor), paragraphs, fenced code (``` or ~~~, coloured by highlight.odin), GFM tables (aligned, in a frame that scrolls),
// blockquotes, bullet and ordered lists (nested by indentation), thematic breaks, and HTML blocks that start a line with a known
// block tag (copied as they are). Inline: `code`, **strong**, *em* / _em_, [text](url "title"), ![alt](src), <autolinks>,
// hard breaks (two trailing spaces), backslash escapes and entities. It is a renderer, not a validator: malformed input gives
// plausible HTML, never a failure, so an author sees the mistake in the page.

import "core:strconv"
import "core:strings"
import "../ascii"

// A rendered document: its HTML, its headings (for a table of contents) and its plain text (for a search index).
Markdown :: struct {
	html:     string,
	headings: [dynamic]Heading,
	plain:    string,
}

Heading :: struct {
	level: int,      // 1..6
	text:  string,   // its plain text
	id:    string,   // its anchor, unique in the document
}

// How a document is rendered. Every field may stay zero.
Markdown_Context :: struct {
	link:      proc(href: string, user: rawptr) -> string,   // a link's or picture's address in the page; "": as written
	user:      rawptr,                                        // what `link` needs
	ids:       map[string]int,                                // the anchors given so far, to keep them unique (nil map: made)
	languages: []Code_Language,                               // the project's languages, looked at before highlight.odin's
}

// The plain text of the first "# " heading, as the page shows it without its marks ("" when there is none). It stops at a line
// that starts with "**": a release note leads with a bold line, and a heading further down is not the page's title.
markdown_title :: proc(md: string, allocator := context.allocator) -> string {
	in_fence := false
	for line in strings.split_lines(md, context.temp_allocator) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "```") || strings.has_prefix(t, "~~~") { in_fence = !in_fence; continue }
		if in_fence { continue }
		if strings.has_prefix(t, "# ") {
			context.allocator = context.temp_allocator
			ctx: Markdown_Context
			plain := strings.builder_make()
			render_inline(strings.trim_space(strings.trim_right(t[2:], "#")), &ctx, &plain)
			return strings.clone(strings.to_string(plain), allocator)
		}
		if strings.has_prefix(t, "**") { break }
	}
	return ""
}

// &, < and > as entities; with `quote` also " (a double-quoted attribute's value).
write_escaped :: proc(b: ^strings.Builder, s: string, quote := false) {
	start := 0
	for i in 0 ..< len(s) {
		rep := ""
		switch s[i] {
		case '&': rep = "&amp;"
		case '<': rep = "&lt;"
		case '>': rep = "&gt;"
		case '"': if quote { rep = "&quot;" }
		}
		if rep == "" { continue }
		strings.write_string(b, s[start:i])
		strings.write_string(b, rep)
		start = i + 1
	}
	strings.write_string(b, s[start:])
}

// The id of a heading, as GitHub makes it: lower case, "-" for a space, "-" or "_", letters and digits kept, the rest dropped,
// runs of "-" made one and trimmed ("section" when nothing is left).
heading_id :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for c in transmute([]byte)s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9': strings.write_byte(&b, c)
		case 'A' ..= 'Z': strings.write_byte(&b, ascii.lower_byte(c))
		case ' ', '-', '_':
			if strings.builder_len(b) > 0 && b.buf[len(b.buf) - 1] != '-' { strings.write_byte(&b, '-') }
		}
	}
	out := strings.trim_right(strings.to_string(b), "-")
	return out == "" ? "section" : out
}

render_markdown :: proc(source: string, ctx: ^Markdown_Context = nil, allocator := context.allocator) -> Markdown {
	context.allocator = allocator
	own: Markdown_Context
	c := ctx != nil ? ctx : &own
	if c.ids == nil { c.ids = make(map[string]int) }
	return markdown_blocks(source, c)
}

@(private)
markdown_blocks :: proc(source: string, ctx: ^Markdown_Context) -> Markdown {
	r: Markdown
	r.headings = make([dynamic]Heading)
	b := strings.builder_make()
	plain := strings.builder_make()
	lines := md_lines(source)
	i := 0
	for i < len(lines) {
		line := lines[i]
		trimmed := strings.trim_left_space(line)

		if len(strings.trim_space(line)) == 0 { i += 1; continue }

		if fence, lang, ok := code_fence(trimmed); ok {
			i += 1
			code := strings.builder_make()
			for i < len(lines) {
				l := lines[i]
				if is_closing_fence(strings.trim_left_space(l), fence) { i += 1; break }
				strings.write_string(&code, l)
				strings.write_byte(&code, '\n')
				i += 1
			}
			write_code_block(&b, strings.to_string(code), lang, ctx.languages)
			strings.write_string(&plain, strings.to_string(code))
			strings.write_byte(&plain, ' ')
			continue
		}

		// an HTML block or a comment: copied up to the next blank line
		if len(trimmed) > 0 && trimmed[0] == '<' && is_html_block_start(trimmed) {
			for i < len(lines) {
				l := lines[i]
				if len(strings.trim_space(l)) == 0 { break }
				strings.write_string(&b, l)
				strings.write_byte(&b, '\n')
				i += 1
			}
			continue
		}

		if level, rest, ok := atx_heading(trimmed); ok {
			write_heading(&b, &r, ctx, level, rest, &plain)
			i += 1
			continue
		}

		if is_thematic_break(trimmed) {
			strings.write_string(&b, "<hr>\n")
			i += 1
			continue
		}

		if i + 1 < len(lines) && is_table_delimiter(strings.trim_space(lines[i + 1])) && strings.contains(line, "|") {
			i = write_table(&b, &plain, lines, i, ctx)
			continue
		}

		if strings.has_prefix(trimmed, ">") {
			block := make([dynamic]string)
			for i < len(lines) {
				t := strings.trim_left_space(lines[i])
				if !strings.has_prefix(t, ">") { break }
				inner := t[1:]
				if len(inner) > 0 && inner[0] == ' ' { inner = inner[1:] }
				append(&block, inner)
				i += 1
			}
			sub := markdown_blocks(strings.join(block[:], "\n"), ctx)
			strings.write_string(&b, "<blockquote>\n")
			strings.write_string(&b, sub.html)
			strings.write_string(&b, "</blockquote>\n")
			strings.write_string(&plain, sub.plain)
			strings.write_byte(&plain, ' ')
			continue
		}

		if _, _, ok := list_marker(line); ok {
			i = write_list(&b, &plain, lines, i, ctx)
			continue
		}

		// a paragraph: up to a blank line or the start of another block
		para := make([dynamic]string)
		for i < len(lines) {
			l := lines[i]
			t := strings.trim_left_space(l)
			if len(strings.trim_space(l)) == 0 { break }
			if _, _, ok := atx_heading(t); ok { break }
			if _, _, ok := code_fence(t); ok { break }
			if _, _, ok := list_marker(l); ok { break }
			if is_thematic_break(t) { break }
			if strings.has_prefix(t, ">") { break }
			if i + 1 < len(lines) && is_table_delimiter(strings.trim_space(lines[i + 1])) && strings.contains(l, "|") { break }
			kept := strings.trim_left_space(l)
			if !strings.has_suffix(kept, "  ") { kept = strings.trim_right_space(kept) }   // (two trailing spaces: a hard break)
			append(&para, kept)
			i += 1
		}
		text := strings.trim_right_space(strings.join(para[:], "\n"))
		strings.write_string(&b, "<p>")
		strings.write_string(&b, render_inline(text, ctx, &plain))
		strings.write_string(&b, "</p>\n")
		strings.write_byte(&plain, ' ')
	}
	r.html = strings.to_string(b)
	r.plain = strings.to_string(plain)
	return r
}

@(private)
write_heading :: proc(b: ^strings.Builder, r: ^Markdown, ctx: ^Markdown_Context, level: int, rest: string, plain: ^strings.Builder) {
	// a trailing run of '#' closes an ATX heading
	text := strings.trim_space(strings.trim_right(rest, "#"))
	inline_text := strings.builder_make(context.temp_allocator)
	html := render_inline(text, ctx, &inline_text)
	bare := strings.to_string(inline_text)
	id := unique_id(ctx, heading_id(bare))
	strings.write_string(b, "<h")
	write_int(b, level)
	strings.write_string(b, " id=\"")
	strings.write_string(b, id)
	strings.write_string(b, "\"><a class=\"anchor\" href=\"#")
	strings.write_string(b, id)
	strings.write_string(b, "\" aria-hidden=\"true\">#</a>")
	strings.write_string(b, html)
	strings.write_string(b, "</h")
	write_int(b, level)
	strings.write_string(b, ">\n")
	append(&r.headings, Heading{level = level, text = strings.clone(bare), id = id})
	strings.write_string(plain, bare)
	strings.write_byte(plain, ' ')
}

// A list: the items at the first one's indentation. A blank line in an item makes it "loose" (its paragraphs in <p>); the
// lines of an item, nested lists included, are rendered as blocks of their own.
@(private)
write_list :: proc(b: ^strings.Builder, plain: ^strings.Builder, lines: []string, start: int, ctx: ^Markdown_Context) -> int {
	i := start
	_, ordered0, _ := list_marker(lines[start])
	tag := ordered0 ? "ol" : "ul"
	strings.write_string(b, "<")
	strings.write_string(b, tag)
	strings.write_string(b, ">\n")
	for i < len(lines) {
		line := lines[i]
		indent, ordered, ok := list_marker(line)
		if !ok || ordered != ordered0 { break }
		marker_end := list_content_start(line)
		item := make([dynamic]string)
		append(&item, line[marker_end:])
		i += 1
		for i < len(lines) {
			l := lines[i]
			if len(strings.trim_space(l)) == 0 {
				// a blank line stays in the item when what follows it is more indented
				j := i
				for j < len(lines) && len(strings.trim_space(lines[j])) == 0 { j += 1 }
				if j < len(lines) && leading_spaces(lines[j]) > indent {
					append(&item, "")
					i += 1
					continue
				}
				break
			}
			if _, _, is_item := list_marker(l); is_item && leading_spaces(l) <= indent { break }
			if leading_spaces(l) > indent {
				append(&item, l[min(marker_end, leading_spaces(l)):])
			} else {
				append(&item, strings.trim_left_space(l))
			}
			i += 1
		}
		sub := markdown_blocks(strings.join(item[:], "\n"), ctx)
		strings.write_string(b, "<li>")
		// an item of one paragraph is tight (no <p>)
		inner := strings.trim_space(sub.html)
		if strings.has_prefix(inner, "<p>") && strings.has_suffix(inner, "</p>") && strings.count(inner, "<p>") == 1 {
			inner = inner[3:len(inner) - 4]
		}
		strings.write_string(b, inner)
		strings.write_string(b, "</li>\n")
		strings.write_string(plain, sub.plain)
		strings.write_byte(plain, ' ')
	}
	strings.write_string(b, "</")
	strings.write_string(b, tag)
	strings.write_string(b, ">\n")
	return i
}

@(private)
write_table :: proc(b: ^strings.Builder, plain: ^strings.Builder, lines: []string, start: int, ctx: ^Markdown_Context) -> int {
	header := table_cells(lines[start])
	aligns := table_aligns(lines[start + 1])
	strings.write_string(b, "<div class=\"table-box\"><table>\n<thead><tr>")
	for cell, k in header {
		strings.write_string(b, "<th")
		write_align(b, aligns, k)
		strings.write_string(b, ">")
		strings.write_string(b, render_inline(cell, ctx, plain))
		strings.write_string(b, "</th>")
	}
	strings.write_string(b, "</tr></thead>\n<tbody>\n")
	i := start + 2
	for i < len(lines) {
		row := strings.trim_space(lines[i])
		if len(row) == 0 || !strings.contains(row, "|") { break }
		cells := table_cells(lines[i])
		strings.write_string(b, "<tr>")
		for k in 0 ..< len(header) {
			cell := k < len(cells) ? cells[k] : ""
			strings.write_string(b, "<td")
			write_align(b, aligns, k)
			strings.write_string(b, ">")
			strings.write_string(b, render_inline(cell, ctx, plain))
			strings.write_string(b, "</td>")
		}
		strings.write_string(b, "</tr>\n")
		i += 1
	}
	strings.write_string(b, "</tbody>\n</table></div>\n")
	strings.write_byte(plain, ' ')
	return i
}

@(private)
write_align :: proc(b: ^strings.Builder, aligns: []string, k: int) {
	if k < len(aligns) && aligns[k] != "" {
		strings.write_string(b, " style=\"text-align:")
		strings.write_string(b, aligns[k])
		strings.write_string(b, "\"")
	}
}

// An inline text as HTML; its plain text goes to `plain`.
@(private)
render_inline :: proc(s: string, ctx: ^Markdown_Context, plain: ^strings.Builder) -> string {
	b := strings.builder_make()
	n := len(s)
	i := 0
	for i < n {
		c := s[i]
		switch c {
		case '\\':
			if i + 1 < n && is_escapable(s[i + 1]) {
				write_escaped(&b, s[i + 1:i + 2])
				strings.write_byte(plain, s[i + 1])
				i += 2
				continue
			}
			strings.write_byte(&b, '\\')
			i += 1
		case '`':
			// a run of backticks opens code up to the same run
			run := backtick_run(s, i)
			end := find_backtick_close(s, i + run, run)
			if end >= 0 {
				code := strings.trim_space(s[i + run:end])
				strings.write_string(&b, "<code>")
				write_escaped(&b, code)
				strings.write_string(&b, "</code>")
				strings.write_string(plain, code)
				i = end + run
				continue
			}
			strings.write_byte(&b, '`')
			i += 1
		case '*', '_':
			// **strong** / __strong__, then *em* / _em_. A '_' inside a word (gui_toolkit, api_generated) is a letter:
			// CommonMark opens no '_' emphasis there.
			intra := c == '_' && i > 0 && is_alnum(s[i - 1]) && i + 1 < n && is_alnum(s[i + 1])
			if !intra {
				if i + 1 < n && s[i + 1] == c {
					if end := find_delim(s, i + 2, c, 2); end >= 0 {
						strings.write_string(&b, "<strong>")
						strings.write_string(&b, render_inline(s[i + 2:end], ctx, plain))
						strings.write_string(&b, "</strong>")
						i = end + 2
						continue
					}
				}
				if end := find_delim(s, i + 1, c, 1); end >= 0 && end > i + 1 {
					strings.write_string(&b, "<em>")
					strings.write_string(&b, render_inline(s[i + 1:end], ctx, plain))
					strings.write_string(&b, "</em>")
					i = end + 1
					continue
				}
			}
			write_escaped(&b, s[i:i + 1])
			strings.write_byte(plain, c)
			i += 1
		case '!':
			if i + 1 < n && s[i + 1] == '[' {
				if alt, dest, _, next, ok := parse_link(s, i + 1); ok {
					strings.write_string(&b, "<img src=\"")
					write_escaped(&b, resolve_href(ctx, dest), true)
					strings.write_string(&b, "\" alt=\"")
					write_escaped(&b, alt, true)
					strings.write_string(&b, "\" loading=\"lazy\">")
					strings.write_string(plain, alt)
					i = next
					continue
				}
			}
			strings.write_byte(&b, '!')
			i += 1
		case '[':
			if text, dest, title, next, ok := parse_link(s, i); ok {
				strings.write_string(&b, "<a href=\"")
				write_escaped(&b, resolve_href(ctx, dest), true)
				strings.write_string(&b, "\"")
				if title != "" {
					strings.write_string(&b, " title=\"")
					write_escaped(&b, title, true)
					strings.write_string(&b, "\"")
				}
				if is_external(dest) { strings.write_string(&b, " rel=\"noopener\"") }
				strings.write_string(&b, ">")
				strings.write_string(&b, render_inline(text, ctx, plain))
				strings.write_string(&b, "</a>")
				i = next
				continue
			}
			strings.write_byte(&b, '[')
			i += 1
		case '<':
			// an autolink: <http://...> or <a@b>
			if end := strings.index_byte(s[i:], '>'); end > 0 {
				inside := s[i + 1:i + end]
				if is_autolink(inside) {
					href := inside
					if strings.contains(inside, "@") && !strings.contains(inside, ":") { href = strings.concatenate({"mailto:", inside}, context.temp_allocator) }
					strings.write_string(&b, "<a href=\"")
					write_escaped(&b, href, true)
					strings.write_string(&b, "\" rel=\"noopener\">")
					write_escaped(&b, inside)
					strings.write_string(&b, "</a>")
					strings.write_string(plain, inside)
					i = i + end + 1
					continue
				}
			}
			strings.write_string(&b, "&lt;")
			i += 1
		case '&':
			// an entity stays, a bare ampersand is escaped
			strings.write_string(&b, is_entity(s, i) ? "&" : "&amp;")
			i += 1
		case '>':
			strings.write_string(&b, "&gt;")
			i += 1
		case '\n':
			// two trailing spaces: a hard break
			strings.write_string(&b, i >= 2 && s[i - 1] == ' ' && s[i - 2] == ' ' ? "<br>\n" : "\n")
			strings.write_byte(plain, ' ')
			i += 1
		case:
			strings.write_byte(&b, c)
			strings.write_byte(plain, c)
			i += 1
		}
	}
	return strings.to_string(b)
}

@(private)
resolve_href :: proc(ctx: ^Markdown_Context, dest: string) -> string {
	if ctx.link != nil {
		if out := ctx.link(dest, ctx.user); out != "" { return out }
	}
	return dest
}

@(private)
unique_id :: proc(ctx: ^Markdown_Context, id: string) -> string {
	n := ctx.ids[id]
	ctx.ids[id] = n + 1
	if n == 0 { return id }
	buf: [20]u8
	return strings.concatenate({id, "-", strconv.write_int(buf[:], i64(n), 10)})
}

// --- the block grammar ------------------------------------------------------

// The lines of `s`, each without its '\r' (documents mix CRLF and LF).
@(private)
md_lines :: proc(s: string) -> []string {
	out := make([dynamic]string)
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' {
			append(&out, strings.trim_right(s[start:i], "\r"))
			start = i + 1
		}
	}
	append(&out, strings.trim_right(s[start:], "\r"))
	return out[:]
}

// The indentation of a line, a tab counting 4.
@(private)
leading_spaces :: proc(s: string) -> int {
	n, i := 0, 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		n += s[i] == '\t' ? 4 : 1
		i += 1
	}
	return n
}

@(private)
atx_heading :: proc(s: string) -> (level: int, rest: string, ok: bool) {
	i := 0
	for i < len(s) && s[i] == '#' { i += 1 }
	if i == 0 || i > 6 { return 0, "", false }
	if i < len(s) && s[i] != ' ' { return 0, "", false }
	return i, strings.trim_space(s[i:]), true
}

// Three or more '`' or '~', then an optional info string whose first word is the language (folded to lower case).
@(private)
code_fence :: proc(s: string) -> (fence: string, lang: string, ok: bool) {
	if len(s) < 3 { return "", "", false }
	c := s[0]
	if c != '`' && c != '~' { return "", "", false }
	n := 0
	for n < len(s) && s[n] == c { n += 1 }
	if n < 3 { return "", "", false }
	info := strings.trim_space(s[n:])
	if sp := strings.index_any(info, " \t"); sp >= 0 { info = info[:sp] }
	return s[:n], ascii.lower(info), true
}

@(private)
is_closing_fence :: proc(s: string, fence: string) -> bool {
	t := strings.trim_right_space(s)
	if len(t) < len(fence) { return false }
	for i in 0 ..< len(t) { if t[i] != fence[0] { return false } }
	return true
}

@(private)
is_thematic_break :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if len(t) < 3 { return false }
	c := t[0]
	if c != '-' && c != '*' && c != '_' { return false }
	count := 0
	for i in 0 ..< len(t) {
		if t[i] == c { count += 1 } else if t[i] != ' ' { return false }
	}
	return count >= 3
}

// "- ", "* ", "+ ", "N. " or "N) ": the marker's indentation and whether the list is ordered.
@(private)
list_marker :: proc(line: string) -> (indent: int, ordered: bool, ok: bool) {
	indent = leading_spaces(line)
	t := strings.trim_left_space(line)
	if len(t) == 0 { return 0, false, false }
	if (t[0] == '-' || t[0] == '*' || t[0] == '+') && len(t) > 1 && t[1] == ' ' { return indent, false, true }
	i := 0
	for i < len(t) && t[i] >= '0' && t[i] <= '9' { i += 1 }
	if i > 0 && i < len(t) && (t[i] == '.' || t[i] == ')') && i + 1 < len(t) && t[i + 1] == ' ' { return indent, true, true }
	return 0, false, false
}

// Where a list item's text begins in its line: after the marker and its space.
@(private)
list_content_start :: proc(line: string) -> int {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') { i += 1 }
	if i < len(line) && (line[i] == '-' || line[i] == '*' || line[i] == '+') {
		i += 1
	} else {
		for i < len(line) && line[i] >= '0' && line[i] <= '9' { i += 1 }
		if i < len(line) && (line[i] == '.' || line[i] == ')') { i += 1 }
	}
	if i < len(line) && line[i] == ' ' { i += 1 }
	return i
}

// A table's delimiter row: cells of '-', ':' and spaces between '|'.
@(private)
is_table_delimiter :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if !strings.contains(t, "-") { return false }
	has_cell := false
	for cell in strings.split(strings.trim(t, "|"), "|", context.temp_allocator) {
		cc := strings.trim_space(cell)
		if len(cc) == 0 { continue }
		for i in 0 ..< len(cc) {
			if cc[i] != '-' && cc[i] != ':' && cc[i] != ' ' { return false }
		}
		if strings.contains(cc, "-") { has_cell = true }
	}
	return has_cell
}

// The cells of a table row: split at a '|' that is not escaped and not in a code span. "\|" is a '|', in code too (GFM).
@(private)
table_cells :: proc(line: string) -> []string {
	t := strings.trim(strings.trim_space(line), "|")
	out := make([dynamic]string)
	cur := strings.builder_make()
	for i := 0; i < len(t); i += 1 {
		switch {
		case t[i] == '\\' && i + 1 < len(t) && t[i + 1] == '|':
			strings.write_byte(&cur, '|')
			i += 1
		case t[i] == '`':
			run := backtick_run(t, i)
			close := find_backtick_close(t, i + run, run)
			if close < 0 {
				strings.write_string(&cur, t[i:i + run])
			} else {
				code, _ := strings.replace_all(t[i:close + run], "\\|", "|", context.temp_allocator)
				strings.write_string(&cur, code)
				run = close + run - i
			}
			i += run - 1
		case t[i] == '|':
			append(&out, strings.trim_space(strings.to_string(cur)))
			cur = strings.builder_make()
		case:
			strings.write_byte(&cur, t[i])
		}
	}
	append(&out, strings.trim_space(strings.to_string(cur)))
	return out[:]
}

@(private)
table_aligns :: proc(delim: string) -> []string {
	cells := table_cells(delim)
	out := make([]string, len(cells))
	for cell, i in cells {
		c := strings.trim_space(cell)
		left, right := strings.has_prefix(c, ":"), strings.has_suffix(c, ":")
		switch {
		case left && right: out[i] = "center"
		case right:         out[i] = "right"
		case left:          out[i] = "left"
		}
	}
	return out
}

// A line that starts an HTML block: a comment or one of these tags.
@(private)
is_html_block_start :: proc(s: string) -> bool {
	if strings.has_prefix(s, "<!--") { return true }
	tags := [?]string{"<div", "<table", "<p", "<pre", "<ul", "<ol", "<section", "<nav", "<figure", "<details", "<sub", "<sup", "<br", "<hr", "<a ", "<a>", "<img", "<span"}
	for t in tags {
		if ascii.has_prefix_fold(s, t) { return true }
	}
	return false
}

@(private)
backtick_run :: proc(s: string, i: int) -> int {
	n := 0
	for i + n < len(s) && s[i + n] == '`' { n += 1 }
	return n
}

@(private)
find_backtick_close :: proc(s: string, from: int, run: int) -> int {
	i := from
	for i < len(s) {
		if s[i] == '`' {
			r := backtick_run(s, i)
			if r == run { return i }
			i += r
			continue
		}
		i += 1
	}
	return -1
}

// The closing run of `n` times `c` from `from`, not right after a space and not in code; -1 when there is none.
@(private)
find_delim :: proc(s: string, from: int, c: byte, n: int) -> int {
	i := from
	for i < len(s) {
		if s[i] == '`' {
			r := backtick_run(s, i)
			end := find_backtick_close(s, i + r, r)
			if end >= 0 { i = end + r; continue }
		}
		if s[i] == c {
			run := 0
			for i + run < len(s) && s[i + run] == c { run += 1 }
			// a '_' with letters on both sides is inside a word
			intra := c == '_' && i > 0 && is_alnum(s[i - 1]) && i + run < len(s) && is_alnum(s[i + run])
			if run >= n && i > from && s[i - 1] != ' ' && !intra { return i }
			i += run
			continue
		}
		i += 1
	}
	return -1
}

// A link at s[start] == '[': its text, address, title and the index after its ')'.
@(private)
parse_link :: proc(s: string, start: int) -> (text, dest, title: string, next: int, ok: bool) {
	depth := 0
	i := start
	for i < len(s) {
		if s[i] == '\\' { i += 2; continue }
		if s[i] == '[' { depth += 1 }
		if s[i] == ']' { depth -= 1; if depth == 0 { break } }
		i += 1
	}
	if i >= len(s) || s[i] != ']' { return "", "", "", 0, false }
	text = s[start + 1:i]
	i += 1
	if i >= len(s) || s[i] != '(' { return "", "", "", 0, false }
	i += 1
	ds := i
	for i < len(s) && s[i] != ')' && s[i] != ' ' && s[i] != '\t' { i += 1 }
	dest = s[ds:i]
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') { i += 1 }
	if i < len(s) && (s[i] == '"' || s[i] == '\'') {
		q := s[i]
		i += 1
		ts := i
		for i < len(s) && s[i] != q { i += 1 }
		title = s[ts:i]
		if i < len(s) { i += 1 }
		for i < len(s) && (s[i] == ' ' || s[i] == '\t') { i += 1 }
	}
	if i >= len(s) || s[i] != ')' { return "", "", "", 0, false }
	return text, dest, title, i + 1, true
}

// An address on another site (or a mail address): a page's link rules leave it alone.
is_external :: proc(href: string) -> bool {
	return strings.has_prefix(href, "http://") || strings.has_prefix(href, "https://") || strings.has_prefix(href, "//") || strings.has_prefix(href, "mailto:")
}

@(private)
is_autolink :: proc(s: string) -> bool {
	if strings.has_prefix(s, "http://") || strings.has_prefix(s, "https://") { return true }
	at := strings.index_byte(s, '@')
	return at > 0 && at < len(s) - 1 && !strings.contains(s, " ")
}

// &name; &#123; &#xAB; at s[i].
@(private)
is_entity :: proc(s: string, i: int) -> bool {
	j := i + 1
	if j < len(s) && s[j] == '#' { j += 1 }
	k := j
	for k < len(s) && k < i + 12 && s[k] != ';' && s[k] != ' ' && s[k] != '&' { k += 1 }
	return k < len(s) && s[k] == ';' && k > j
}

@(private)
is_escapable :: proc(c: byte) -> bool {
	switch c {
	case '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '<', '>', '|', '"', '\'', '~': return true
	}
	return false
}

@(private)
is_alnum :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

@(private)
write_int :: proc(b: ^strings.Builder, n: int) {
	buf: [20]u8
	strings.write_string(b, strconv.write_int(buf[:], i64(n), 10))
}
