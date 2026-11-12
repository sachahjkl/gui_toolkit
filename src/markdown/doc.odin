// Markdown as people and models write it in a chat or a note: headings, paragraphs, lists, quotes, rules, tables, fenced
// code, and inline **bold**, *italic*, `code`, ~~strike~~, [links](url) and bare web addresses. Each block is a
// ui.rich_paragraph (selectable); a table is a grid that scrolls sideways when it is wider than its place; fenced code is
// highlighted by the syntax package.
//
//   doc: Doc                                        // the program keeps it, one per text shown
//   markdown.view(&doc, "answer", text, cfg)        // at each build; the text is read again only when it changes
//
// Doc is the cache: the blocks of a text, read when the text changes (its place or its length), never at each frame. A text
// that grows in its buffer (an answer that streams) has only its last block read again.
package markdown

import "core:math"
import "core:mem"
import "core:strings"
import "../font"
import syntax "../syntax"
import "../ui"

// Odd 64-bit constants that spread the bits of what they multiply.
@(private) HASH_MIX_A :: 0x9e3779b97f4a7c15
@(private) HASH_MIX_B :: 0xc2b2ae3d27d4eb4f

HEADING_LEVEL_MAX :: 6

Block_Kind :: enum u8 { Para, Heading, Bullet, Number, Quote, Rule, Code, Table }

Block :: struct {
	kind:   Block_Kind,
	level:  int,      // heading level, list indent
	marker: string,   // "3." of a numbered item, "•" of a bullet
	lang:   string,   // a code block's language, as written after its fence
	at:     int,      // where its first line starts in the text
	first, count: int,   // its lines, in Doc.lines
	closed: bool,     // a code block whose closing fence came (one still being written is not)
	// what a build makes of it, made once (block_text, block_runs, code_runs, the table): in the doc's memory, or for the
	// last block in the doc's tail buffers
	text:     string,
	has_text: bool,
	runs:     []ui.Rich_Run,
	runs_key: u64,    // what the runs were made with (0: none yet)
	table:    ^Table,
}

// The blocks of a Markdown text, kept with the text they were read from (its place, its length): a build reads none of it
// again. The text grows (an answer streams): only its last block is read again, from where it starts. Every block before
// it is final: a line only ever goes to the last block, and a block that starts reads the same with or without what came
// before it.
// Memory: `alloc` (zero: context.allocator at the first read). What is read again is cleared and filled again, it does not
// grow past the text; a final block's text, runs and table are made in `alloc`, once each. The text itself is the
// program's: it must live (and stay where it is) as long as the doc shows it. A doc read once does not move (its last
// block's table is in it).
Doc :: struct {
	alloc:  mem.Allocator,
	parses: int,      // how many times a text was read into it, whole or from its last block (statistics, tests)
	read:   bool,     // a text was read into it
	src:    rawptr,   // the text read: where it lies, how long it was
	n:      int,
	blocks: [dynamic]Block,
	lines:  [dynamic]string,
	tail_text:  [dynamic]u8,             // the last block's text, runs and table (read again as the text grows)
	tail_runs:  [dynamic]ui.Rich_Run,
	tail_table: Table,
	tail_table_bufs: Table_Bufs,
	markers:     [dynamic]f32,           // marker_widths, for markers_key
	markers_key: [3]f32,                 // (the size, least and gap they were measured at; none once the text is read again)
}

// Frees what the doc holds (not the text it was read from). A doc in an arena needs none of it.
doc_destroy :: proc(d: ^Doc) {
	if !d.read { return }
	drop_owned(d)
	delete(d.blocks)
	delete(d.lines)
	delete(d.tail_text)
	delete(d.tail_runs)
	table_bufs_destroy(&d.tail_table_bufs)
	delete(d.markers)
	d^ = {alloc = d.alloc}
}

// The lines of block `n` (a heading: its text; a table: its rows as written; code: its lines without the fences).
block_lines :: proc(d: ^Doc, n: int) -> []string {
	bl := &d.blocks[n]
	return d.lines[bl.first:][:bl.count]
}

// Reads `src` into `d`: nothing when it is the text read last, its last block and what follows when it grew in its place,
// else all of it.
read :: proc(d: ^Doc, src: string) {
	if d.read && d.src == raw_data(src) && d.n == len(src) { return }
	if !d.read {
		if d.alloc.procedure == nil { d.alloc = context.allocator }
		d.blocks.allocator, d.lines.allocator, d.tail_text.allocator, d.tail_runs.allocator, d.markers.allocator = d.alloc, d.alloc, d.alloc, d.alloc, d.alloc
		table_bufs_init(&d.tail_table_bufs, d.alloc)
	}
	from := 0
	if d.read && d.src == raw_data(src) && d.n < len(src) && len(d.blocks) > 0 {
		// (the last block's text, runs and table are in the tail buffers: nothing of it to free)
		last := d.blocks[len(d.blocks) - 1]
		from = last.at
		resize(&d.blocks, len(d.blocks) - 1)
		resize(&d.lines, last.first)
	} else {
		drop_owned(d)
		clear(&d.blocks)
		clear(&d.lines)
	}
	d.src, d.n, d.read = raw_data(src), len(src), true
	d.parses += 1
	d.markers_key = {}
	parse_blocks(d, src, from)
}

// Frees what the final blocks made in the doc's memory (the last block's is in the tail buffers).
@(private)
drop_owned :: proc(d: ^Doc) {
	for &bl, i in d.blocks {
		if i == len(d.blocks) - 1 { break }
		if bl.has_text && bl.kind != .Heading { delete(bl.text, d.alloc) }
		if bl.runs_key != 0 { delete(bl.runs, d.alloc) }
		if bl.table != nil { table_cache_free(bl.table, d.alloc) }
	}
}

@(private)
parse_blocks :: proc(d: ^Doc, src: string, from: int) {
	cur := -1   // the block lines go to (always the last one: a line only ever goes there)
	add :: proc(d: ^Doc, b: Block) -> int {
		b := b
		b.first = len(d.lines)
		append(&d.blocks, b)
		return len(d.blocks) - 1
	}
	line_to :: proc(d: ^Doc, cur: int, l: string) {
		append(&d.lines, l)
		d.blocks[cur].count += 1
	}
	text := src[from:]
	in_code := false
	fence := ""
	for len(text) > 0 {
		at := len(src) - len(text)
		raw, _ := strings.split_lines_iterator(&text)
		line := strings.trim_right(raw, "\r")
		t := strings.trim_space(line)
		if in_code {
			if strings.has_prefix(t, fence) && strings.trim_left(t, "`~") == "" { d.blocks[cur].closed = true; in_code = false; cur = -1; continue }
			line_to(d, cur, line)
			continue
		}
		if strings.has_prefix(t, "```") || strings.has_prefix(t, "~~~") {
			n := 0
			for n < len(t) && t[n] == t[0] { n += 1 }
			fence = t[:n]
			cur = add(d, {kind = .Code, lang = strings.trim_space(t[n:]), at = at})
			in_code = true
			continue
		}
		if t == "" { cur = -1; continue }
		if t == "---" || t == "***" || t == "___" {
			add(d, {kind = .Rule, at = at})
			cur = -1
			continue
		}
		if t[0] == '#' {
			lvl := 0
			for lvl < len(t) && t[lvl] == '#' { lvl += 1 }
			if lvl <= HEADING_LEVEL_MAX && lvl < len(t) && t[lvl] == ' ' {
				h := add(d, {kind = .Heading, level = lvl, at = at})
				line_to(d, h, strings.trim_space(t[lvl:]))
				cur = -1
				continue
			}
		}
		if t[0] == '|' {
			if cur < 0 || d.blocks[cur].kind != .Table { cur = add(d, {kind = .Table, at = at}) }
			line_to(d, cur, t)
			continue
		}
		if t[0] == '>' {
			q := strings.trim_left(t[1:], " ")
			if cur < 0 || d.blocks[cur].kind != .Quote { cur = add(d, {kind = .Quote, at = at}) }
			line_to(d, cur, q)
			continue
		}
		if indent, marker, rest, ok := list_item(line); ok {
			cur = add(d, {kind = marker == "•" ? .Bullet : .Number, level = indent, marker = marker, at = at})
			line_to(d, cur, rest)
			continue
		}
		// continuation of a paragraph or a list item, or a new paragraph
		if cur >= 0 && (d.blocks[cur].kind == .Para || d.blocks[cur].kind == .Bullet || d.blocks[cur].kind == .Number || d.blocks[cur].kind == .Quote) {
			line_to(d, cur, t)
			continue
		}
		cur = add(d, {kind = .Para, at = at})
		line_to(d, cur, t)
	}
}

// What block `n` shows as one text: its lines joined (code: as lines; a heading: its line). Made once for a final block,
// in the doc's memory; the last one's in the tail buffer, made again when the text grew.
block_text :: proc(d: ^Doc, n: int) -> string {
	bl := &d.blocks[n]
	if bl.has_text { return bl.text }
	lines := block_lines(d, n)
	s: string
	#partial switch bl.kind {
	case .Heading:                        s = len(lines) > 0 ? lines[0] : ""
	case .Code:                           s = strings.join(lines, "\n", context.temp_allocator)
	case .Para, .Quote, .Bullet, .Number: s = joined(lines)
	}
	if bl.kind != .Heading {
		if n == len(d.blocks) - 1 {
			clear(&d.tail_text)
			append(&d.tail_text, s)
			s = string(d.tail_text[:])
		} else {
			s = strings.clone(s, d.alloc)
		}
	}
	bl.text, bl.has_text = s, true
	return s
}

@(private)
hash_floats :: proc(h: u64, fs: []f32) -> u64 {
	h := h
	for f in fs { h = (h ~ u64(transmute(u32)f)) * HASH_MIX_B }
	return h | 1
}

// What inline runs are made with: the base style and the inline options.
@(private)
runs_key :: proc(base: ui.Rich_Style, o: Inline) -> u64 {
	c, k := base.color, o.code_color
	return hash_floats(HASH_MIX_A ~ u64(base.font) * HASH_MIX_B, []f32{c[0], c[1], c[2], c[3], k[0], k[1], k[2], k[3], o.code_size, base.size, base.bold ? 1 : 0, base.italic ? 1 : 0})
}

// Keeps runs made in temp memory as block `n`'s: in the tail buffer for the last block, else in the doc's memory.
@(private)
keep_runs :: proc(d: ^Doc, n: int, list: []ui.Rich_Run, key: u64) -> []ui.Rich_Run {
	bl := &d.blocks[n]
	if n == len(d.blocks) - 1 {
		clear(&d.tail_runs)
		append(&d.tail_runs, ..list)
		bl.runs = d.tail_runs[:]
	} else {
		if bl.runs_key != 0 { delete(bl.runs, d.alloc) }
		bl.runs = make([]ui.Rich_Run, len(list), d.alloc)
		copy(bl.runs, list)
	}
	bl.runs_key = key
	return bl.runs
}

// The inline runs of block `n` (inline_runs of block_text), made again only when what they are made with changed.
block_runs :: proc(d: ^Doc, n: int, base: ui.Rich_Style, o: Inline = {}) -> []ui.Rich_Run {
	key := runs_key(base, o)
	if d.blocks[n].runs_key == key { return d.blocks[n].runs }
	list := make([dynamic]ui.Rich_Run, context.temp_allocator)
	inline_runs(block_text(d, n), base, &list, o)
	return keep_runs(d, n, list[:], key)
}

// The runs of code block `n`, each class of its language (syntax.language of its fence's word) in the theme's colour
// (ui.code_runs); one run of `base` when the language is not known. Made again only when the base or the theme's code
// colours changed.
code_runs :: proc(d: ^Doc, n: int, base: ui.Rich_Style) -> []ui.Rich_Run {
	cols: [5]ui.Color
	for c, i in ([5]syntax.Class{.Keyword, .Str, .Comment, .Func, .Type}) { cols[i] = ui.code_color(c) }
	b := base.color
	key := hash_floats(HASH_MIX_B ~ u64(base.font) * HASH_MIX_A, []f32{b[0], b[1], b[2], b[3], base.size,
		cols[0][0], cols[0][1], cols[0][2], cols[1][0], cols[1][1], cols[1][2], cols[2][0], cols[2][1], cols[2][2],
		cols[3][0], cols[3][1], cols[3][2], cols[4][0], cols[4][1], cols[4][2]})
	if d.blocks[n].runs_key == key { return d.blocks[n].runs }
	text := block_text(d, n)
	list := make([dynamic]ui.Rich_Run, context.temp_allocator)
	if l, ok := syntax.language(d.blocks[n].lang); ok && d.blocks[n].lang != "" {
		ui.code_runs(text, l, base, &list)
	} else if text != "" {
		append(&list, ui.Rich_Run{text = text, style = base})
	}
	return keep_runs(d, n, list[:], key)
}

// How a list item's marker is measured: `s` in `face` at `size`.
Measure :: proc(face: font.Font_Id, s: string, size: f32) -> f32

// The width of each block's marker column (list_marker_widths), measured again when the text (read) or the sizes changed.
marker_widths :: proc(d: ^Doc, measure: Measure, face: font.Font_Id, size, least, gap: f32) -> []f32 {
	key := [3]f32{size, least, gap}
	if d.markers_key == key && len(d.markers) == len(d.blocks) { return d.markers[:] }
	w := list_marker_widths(d.blocks[:], measure, face, size, least, gap)
	clear(&d.markers)
	append(&d.markers, ..w)
	d.markers_key = key
	return d.markers[:]
}

// The width of each block's marker column (0 for what is not a list item), in temp memory: `least` at least; a list's
// numbers all take the width of its widest and `gap` ("10." is not cut, and the text of its items stays in one column).
// A list is a run of list items one after the other; each of its levels is measured on its own.
list_marker_widths :: proc(blocks: []Block, measure: Measure, face: font.Font_Id, size, least, gap: f32) -> []f32 {
	out := make([]f32, len(blocks), context.temp_allocator)
	is_item :: proc(b: Block) -> bool { return b.kind == .Bullet || b.kind == .Number }
	for start := 0; start < len(blocks); {
		if !is_item(blocks[start]) { start += 1; continue }
		end := start
		for end < len(blocks) && is_item(blocks[end]) { end += 1 }
		widest := make(map[int]f32, allocator = context.temp_allocator)
		for b in blocks[start:end] {
			w := least
			if b.kind == .Number { w = max(w, math.ceil(measure(face, b.marker, size) + gap)) }
			widest[b.level] = max(widest[b.level] or_else 0, w)
		}
		for b, i in blocks[start:end] { out[start + i] = widest[b.level] }
		start = end
	}
	return out
}

@(private = "file")
list_item :: proc(l: string) -> (indent: int, marker: string, rest: string, ok: bool) {
	t := strings.trim_left(l, " \t")
	indent = (len(l) - len(t)) / 2
	if len(t) >= 2 && (t[0] == '-' || t[0] == '*' || t[0] == '+') && t[1] == ' ' { return indent, "•", t[2:], true }
	j := 0
	for j < len(t) && t[j] >= '0' && t[j] <= '9' { j += 1 }
	if j > 0 && j + 1 < len(t) && (t[j] == '.' || t[j] == ')') && t[j + 1] == ' ' { return indent, t[:j + 1], t[j + 2:], true }
	return
}

// The lines of a block joined as one paragraph (a line break where the source ends a line with two spaces or "\").
@(private = "file")
joined :: proc(lines: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for l, i in lines {
		if i > 0 {
			prev := lines[i - 1]
			if strings.has_suffix(prev, "  ") || strings.has_suffix(prev, "\\") { strings.write_byte(&b, '\n') } else { strings.write_byte(&b, ' ') }
		}
		strings.write_string(&b, strings.trim_right(strings.trim_suffix(l, "\\"), " "))
	}
	return strings.to_string(b)
}

// A name for a piece of the source (where its bytes lie, how far, at which size): the rich layout cache finds the block by
// it instead of hashing its text at every frame. A text only grows: a block keeps its bytes until they move, and then it
// is a new name (rich_paragraph mixes in the paragraph's box, so two texts never share one).
@(private)
source_version :: proc(first, last: string, size: f32) -> u64 {
	if len(first) == 0 && len(last) == 0 { return 0 }
	a := u64(uintptr(raw_data(first)))
	b := u64(uintptr(raw_data(last))) + u64(len(last))
	return ((a * HASH_MIX_A) ~ (b * HASH_MIX_B) ~ u64(transmute(u32)size)) | 1
}
