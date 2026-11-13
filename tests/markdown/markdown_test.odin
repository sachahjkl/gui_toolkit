// Markdown in a window: the blocks of a text and their cache (read once, a text that grows read from its last block), the
// lists' marker column, a table as HTML; in a session a document read once across frames, a table's grid, a code block
// highlighted and a link that calls the program.
//   odin test tests/markdown -vet -define:ODIN_TEST_THREADS=1
package markdown_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "../../src/font"
import "../../src/markdown"
import "../../src/testkit/session"
import "../../src/ui"

// A list's numbers take the width of its widest ("10." is not cut); its levels are measured apart; another list is
// measured on its own; what is not a list has no marker.
@(test)
a_list_takes_the_width_of_its_widest_number :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	for i in 1 ..= 10 { fmt.sbprintf(&b, "%d. item\n", i) }
	strings.write_string(&b, "   - under ten\n\nA paragraph.\n\n1. alone\n2. two\n")
	doc := markdown.Doc{alloc = context.temp_allocator}
	markdown.read(&doc, strings.to_string(b))
	blocks := doc.blocks
	measure :: proc(face: font.Font_Id, s: string, size: f32) -> f32 { return f32(len(s)) * 8 }   // (8 px a character)
	w := markdown.list_marker_widths(blocks[:], measure, 0, 16, 20, 4)
	kinds := make([dynamic]string, context.temp_allocator)
	for bl in blocks { append(&kinds, fmt.tprintf("%v", bl.kind)) }
	if !testing.expectf(t, len(blocks) == 14, "the blocks: %v", kinds) { return }
	for i in 0 ..< 10 { testing.expectf(t, w[i] == 3 * 8 + 4, "item %d: as wide as \"10.\" and the gap: %v", i + 1, w[i]) }
	testing.expect_value(t, w[10], 20)   // (a bullet one level under: the least)
	testing.expect_value(t, w[11], 0)    // (a paragraph)
	testing.expect_value(t, w[12], 20)   // ("1." and "2.": the least is wider)
	testing.expect_value(t, w[13], 20)
}

// The blocks as a line each: what they are and their lines (a doc read whole and one read as its text grew must say the same).
@(private = "file")
shape :: proc(d: ^markdown.Doc) -> string {
	b := strings.builder_make(context.temp_allocator)
	for bl, n in d.blocks {
		fmt.sbprintf(&b, "%v %d %q %q %v |", bl.kind, bl.level, bl.marker, bl.lang, bl.closed)
		for l in markdown.block_lines(d, n) { fmt.sbprintf(&b, " %q", l) }
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// An answer streams into its buffer: at every length, the blocks kept and read again from the last one are those of the
// whole text read anew, and the last block's text is the new one. A text in another buffer is read whole.
@(test)
a_growing_text_reads_as_the_whole_text :: proc(t: ^testing.T) {
	SRC :: "# Title\nA first line\nand its second.\n\n- one\n- two\n  1. under\n\n> a quote\n> goes on\n\n```odin\nx := 1\n\n```\n| a | b |\n|---|:-:|\n| 1 | 2 |\n\n---\nThe end, at https://example.com."
	text := make([dynamic]u8, 0, len(SRC) + 1, context.temp_allocator)   // (room for all of it: the buffer does not move)
	kept := markdown.Doc{alloc = context.temp_allocator}
	src_all := SRC   // (a constant string is not indexed by a variable)
	for i in 0 ..< len(src_all) {
		append(&text, src_all[i])
		src := string(text[:])
		markdown.read(&kept, src)
		whole := markdown.Doc{alloc = context.temp_allocator}
		markdown.read(&whole, strings.clone(src, context.temp_allocator))
		if !testing.expectf(t, shape(&kept) == shape(&whole), "at %d bytes:\n%s\nread whole:\n%s", i + 1, shape(&kept), shape(&whole)) { return }
		if n := len(kept.blocks); n > 0 && kept.blocks[n - 1].kind != .Rule && kept.blocks[n - 1].kind != .Table {
			testing.expect_value(t, markdown.block_text(&kept, n - 1), markdown.block_text(&whole, n - 1))
		}
	}
	testing.expect_value(t, kept.parses, len(SRC))   // (one read a length: never two)
	// the same length, another buffer: read again whole
	other := strings.clone(SRC, context.temp_allocator)
	other_b := transmute([]u8)other
	other_b[2] = 'X'
	markdown.read(&kept, other)
	testing.expect_value(t, markdown.block_lines(&kept, 0)[0], "Xitle")
}

// A table copied: a plain HTML grid (no colour, no font), the header row as th, each column aligned as written, bold and
// code kept, what is HTML in a cell escaped.
@(test)
a_table_copies_as_a_plain_grid :: proc(t: ^testing.T) {
	doc := markdown.Doc{alloc = context.temp_allocator}
	markdown.read(&doc, "| Name | Size |\n|---|--:|\n| a<b & c | `12` |\n| **big** | 3 |\n")
	if !testing.expect_value(t, len(doc.blocks), 1) { return }
	tb := markdown.table_of(&doc, 0, {bold = true}, {})
	testing.expect_value(t, tb.rows, 3)
	testing.expect_value(t, tb.cols, 2)
	testing.expect_value(t, tb.aligns[1], ui.Text_Align.Right)
	html := markdown.table_html(tb)
	testing.expect(t, strings.has_prefix(html, `<table style="border-collapse:collapse"><thead><tr><th style="border:1px solid #bbb;padding:4px 8px;text-align:left">Name</th>`), html)
	testing.expect(t, strings.contains(html, `text-align:right">Size</th>`), html)
	testing.expect(t, strings.contains(html, `>a&lt;b &amp; c</td>`), html)
	testing.expect(t, strings.contains(html, `<code>12</code>`), html)
	testing.expect(t, strings.contains(html, `<b>big</b>`), html)
	testing.expect(t, !strings.contains(html, "color") && !strings.contains(html, "font"), "no colour, no font: the program it is pasted in gives them")
	testing.expect(t, strings.has_suffix(html, "</tbody></table>"), html)
	testing.expect(t, markdown.table_of(&doc, 0, {bold = true}, {}) == tb, "made once for the same styles")
}

////////////////////////////////
// In a window

@(private = "file")
Run :: struct {
	doc:     markdown.Doc,
	text:    [dynamic]u8,     // the text shown (it grows in place: room for it is made first)
	clicked: string,          // what the link callback was given
	clicks:  int,
	code:    markdown.Code,   // what the code callback was given last
	codes:   int,
	keyword: ui.Color,        // the theme's colour of a keyword
	hook:    bool,            // the code goes to the callback
}

@(private = "file")
start :: proc(t: ^testing.T, r: ^Run, text: string) -> ^session.Session {
	r.doc.alloc = context.allocator
	r.text = make([dynamic]u8, 0, 4096)
	append(&r.text, text)
	return session.start(t, {size = {700, 500}, user = r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		r.keyword = ui.code_color(.Keyword)
		cfg := markdown.View_Options{user = r, link = proc(user: rawptr, url: string) {
			r := (^Run)(user)
			r.clicked = url
			r.clicks += 1
		}}
		if r.hook {
			cfg.code = proc(user: rawptr, id: string, c: markdown.Code) {
				r := (^Run)(user)
				r.code = c
				r.codes += 1
			}
		}
		ui.next({width = ui.px(600), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") { markdown.view(&r.doc, "md", string(r.text[:]), cfg) }
	}})
}

@(private = "file")
finish :: proc(r: ^Run) {
	markdown.doc_destroy(&r.doc)
	delete(r.text)
}

// The text is read once, whatever the frames; its blocks' runs are made once. When it grows in place, only its last
// block is read again: the blocks before keep their runs.
@(test)
a_document_is_read_once_across_frames :: proc(t: ^testing.T) {
	r: Run
	defer finish(&r)
	s := start(t, &r, "# A title\n\nA paragraph with **bold** in it.\n\nThe last one")
	session.frames(s, 5)
	testing.expect_value(t, r.doc.parses, 1)
	if !testing.expect_value(t, len(r.doc.blocks), 3) { return }
	first := raw_data(r.doc.blocks[1].runs)
	session.frames(s, 3)
	testing.expect_value(t, r.doc.parses, 1)
	testing.expect(t, raw_data(r.doc.blocks[1].runs) == first, "the runs kept")
	append(&r.text, ", grown.")   // (in place: there was room)
	session.frames(s, 3)
	testing.expect_value(t, r.doc.parses, 2)
	testing.expect(t, raw_data(r.doc.blocks[1].runs) == first, "a block before the last one keeps its runs")
	testing.expect_value(t, markdown.block_text(&r.doc, 2), "The last one, grown.")
	testing.expect(t, session.find_text(s, "grown") != nil, "shown")
}

// A table: its header and rows as a grid, each column aligned as its separator says, measured once.
@(test)
a_table_is_a_grid :: proc(t: ^testing.T) {
	r: Run
	defer finish(&r)
	s := start(t, &r, "| Name | Size |\n|------|-----:|\n| one | 1 |\n| two | 22 |\n")
	session.frames(s, 3)
	for name in ([]string{"tr0", "tr1", "tr2", "tc0", "tc1", "hl"}) { testing.expectf(t, session.find(s, name) != nil, "the box %s", name) }
	testing.expect(t, session.find(s, "tr3") == nil, "the separator is no row")
	one, size := session.find_text(s, "one"), session.find_text(s, "Size")
	if !testing.expect(t, one != nil && size != nil, "its cells") { return }
	testing.expect(t, one.rect.min.y > size.rect.max.y - 1, "a row under the header")
	cell := session.find(s, "p", 3)   // (the second column of the second row: row by row, two a row)
	if testing.expect(t, cell != nil) { testing.expect_value(t, cell.text_align, ui.Text_Align.Right) }
	tb := r.doc.blocks[0].table
	if !testing.expect(t, tb != nil) { return }
	measured := tb.measure_key
	testing.expect(t, measured != 0 && tb.widths[0] > 0, "measured")
	session.frames(s, 2)
	testing.expect_value(t, tb.measure_key, measured)
}

// A table wider than its place scrolls sideways in one box, with the toolkit's one scroll bar: no bar of its own under
// it (two bars showed), and room under its rows for that bar.
@(test)
a_wide_table_has_one_scroll_bar :: proc(t: ^testing.T) {
	r: Run
	defer finish(&r)
	wide := strings.repeat("word ", 30, context.temp_allocator)
	s := start(t, &r, strings.concatenate({"| A | B | C |\n|---|---|---|\n| ", wide, " | ", wide, " | ", wide, " |\n"}, context.temp_allocator))
	session.frames(s, 4)
	hs := session.find(s, "hs")
	if !testing.expect(t, hs != nil, "the box the rows scroll in") { return }
	testing.expect(t, .View_Scroll_X in hs.flags, "it scrolls sideways")
	testing.expect(t, session.find(s, "hbar") == nil, "no bar of the table's own")
	last := session.find(s, "tr1")
	if testing.expect(t, last != nil, "the last row") {
		testing.expectf(t, hs.rect.max.y - last.rect.max.y >= ui.scrollbar_gutter() - 1, "room for the bar under the rows: %v", hs.rect.max.y - last.rect.max.y)
	}
}

// A fenced block of a known language: its keywords in the theme's colour; the callback is given its runs, made once.
@(test)
a_code_block_is_highlighted :: proc(t: ^testing.T) {
	r: Run
	r.hook = true
	defer finish(&r)
	s := start(t, &r, "Before.\n\n```odin\nmain :: proc() {\n\treturn\n}\n```\n")
	session.frames(s, 3)
	testing.expect(t, r.codes > 0, "the callback built it")
	testing.expect_value(t, r.code.lang, "odin")
	testing.expect(t, r.code.closed, "its fence closed")
	keyword := false
	for run in r.code.runs { if run.text == "proc" || run.text == "return" { keyword = keyword || run.color == r.keyword } }
	testing.expect(t, keyword, "a keyword in the theme's colour")
	runs := raw_data(r.code.runs)
	session.frames(s, 2)
	testing.expect(t, raw_data(r.code.runs) == runs, "highlighted once")
	// without the callback: the package's own block shows it
	r.hook = false
	session.frames(s, 2)
	testing.expect(t, session.find(s, "code") != nil, "code_block")
}

// A click on a link calls the program with its target.
@(test)
a_link_click_calls_the_program :: proc(t: ^testing.T) {
	r: Run
	defer finish(&r)
	s := start(t, &r, "[open it](https://example.com/x) and more words.")
	session.frames(s, 2)
	p := session.find(s, "md_b0")
	if !testing.expect(t, p != nil, "the paragraph") { return }
	session.click_at(s, {p.rect.min.x + p.text_pad + 8, (p.rect.min.y + p.rect.max.y) * 0.5})
	testing.expect_value(t, r.clicks, 1)
	testing.expect_value(t, r.clicked, "https://example.com/x")
	// the words that are no link call nothing
	r.clicked = ""
	session.click_at(s, {p.rect.max.x - p.text_pad - 4, (p.rect.min.y + p.rect.max.y) * 0.5})
	testing.expect_value(t, r.clicks, 1)
}
