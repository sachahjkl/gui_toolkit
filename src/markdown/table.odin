package markdown

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "../draw"
import "../ui"

TABLE_COL_MAX_EM    :: 28    // a table's column is no wider (its words wrap past it); a table wider than its place scrolls sideways
TABLE_FADE_EM       :: 2     // the fade at a side of a table that scrolls, where it hides more
TABLE_STRIPE_ALPHA  :: 0.045 // every other row: the text's colour, this faint
TABLE_RULE_ALPHA    :: 0.35  // the rule under the header: the marker colour, this faint
TABLE_MEASURE_W     :: 1e6   // a cell is laid out this wide to measure it: on one line
TABLE_CELL_PAD_Y_EM :: 0.4   // above and under a cell's words
TABLE_CELL_PAD_X_EM :: 0.7   // at the sides of a cell's words
TABLE_CODE_SLACK_EM :: 0.5   // a code word in a cell: the room of its chip around it
TABLE_RADIUS_PX     :: 6

// A table block as it is shown, made once from its lines (table_of): its cells' runs, each column's alignment as its
// separator row says (":--", ":-:", "--:"), and each column's widths as last measured. The first row is the header.
Table :: struct {
	key:    u64,                // what the runs were made with (0: none yet)
	rows, cols: int,
	aligns: []ui.Text_Align,    // per column
	texts:  []string,           // per cell (row by row, `cols` a row): its text as written
	spans:  [][2]int,           // per cell: its runs in `runs` (first, count)
	runs:   []ui.Rich_Run,
	measure_key:   u64,         // what the widths were measured with (0: none yet)
	widths, least: []f32,       // per column: its widest cell on one line, its longest word (padding in)
}

// The tail buffers a last block's table is made in (made again as the text grows).
@(private)
Table_Bufs :: struct {
	aligns: [dynamic]ui.Text_Align,
	texts:  [dynamic]string,
	spans:  [dynamic][2]int,
	runs:   [dynamic]ui.Rich_Run,
	widths, least: [dynamic]f32,
}

@(private)
table_bufs_init :: proc(b: ^Table_Bufs, a: mem.Allocator) {
	b.aligns.allocator, b.texts.allocator, b.spans.allocator, b.runs.allocator, b.widths.allocator, b.least.allocator = a, a, a, a, a, a
}

@(private)
table_bufs_destroy :: proc(b: ^Table_Bufs) {
	delete(b.aligns); delete(b.texts); delete(b.spans); delete(b.runs); delete(b.widths); delete(b.least)
}

@(private)
table_cache_free :: proc(t: ^Table, a: mem.Allocator) {
	delete(t.aligns, a); delete(t.texts, a); delete(t.spans, a); delete(t.runs, a); delete(t.widths, a); delete(t.least, a)
	free(t, a)
}

// The runs of the cell at `row`, `col`.
table_cell :: proc(t: ^Table, row, col: int) -> []ui.Rich_Run {
	sp := t.spans[row * t.cols + col]
	return t.runs[sp[0]:][:sp[1]]
}

// The table of block `n` (a .Table), its header's runs in `header`, the others' in `body`: made again only when they changed.
table_of :: proc(d: ^Doc, n: int, header, body: ui.Rich_Style, o: Inline = {}) -> ^Table {
	key := (runs_key(header, o) * HASH_MIX_A ~ runs_key(body, o)) | 1
	bl := &d.blocks[n]
	if bl.table != nil && bl.table.key == key { return bl.table }
	lines := block_lines(d, n)
	rows := make([dynamic][]string, context.temp_allocator)
	aligns: []ui.Text_Align
	for l in lines {
		cells := table_cells(l)
		sep := len(cells) > 0
		for c in cells { if strings.trim(c, ":- ") != "" || c == "" { sep = false } }
		if sep && len(rows) == 1 {
			aligns = make([]ui.Text_Align, len(cells), context.temp_allocator)
			for c, i in cells {
				switch {
				case strings.has_prefix(c, ":") && strings.has_suffix(c, ":"): aligns[i] = .Center
				case strings.has_suffix(c, ":"):                               aligns[i] = .Right
				}
			}
			continue
		}
		append(&rows, cells)
	}
	cols := 0
	for r in rows { cols = max(cols, len(r)) }
	al := make([]ui.Text_Align, cols, context.temp_allocator)
	copy(al, aligns)
	texts := make([dynamic]string, context.temp_allocator)
	spans := make([dynamic][2]int, context.temp_allocator)
	runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
	for r, ri in rows {
		for ci in 0 ..< cols {
			c := ci < len(r) ? r[ci] : ""
			first := len(runs)
			inline_runs(c, ri == 0 ? header : body, &runs, o)
			append(&texts, c)
			append(&spans, [2]int{first, len(runs) - first})
		}
	}
	t: ^Table
	if n == len(d.blocks) - 1 {
		b := &d.tail_table_bufs
		clear(&b.aligns); append(&b.aligns, ..al)
		clear(&b.texts);  append(&b.texts, ..texts[:])
		clear(&b.spans);  append(&b.spans, ..spans[:])
		clear(&b.runs);   append(&b.runs, ..runs[:])
		resize(&b.widths, cols); resize(&b.least, cols)
		t = &d.tail_table
		t^ = {aligns = b.aligns[:], texts = b.texts[:], spans = b.spans[:], runs = b.runs[:], widths = b.widths[:], least = b.least[:]}
	} else {
		if bl.table != nil { table_cache_free(bl.table, d.alloc) }
		t = new(Table, d.alloc)
		t.aligns, _ = slice.clone(al, d.alloc)
		t.texts, _ = slice.clone(texts[:], d.alloc)
		t.spans, _ = slice.clone(spans[:], d.alloc)
		t.runs, _ = slice.clone(runs[:], d.alloc)
		t.widths = make([]f32, cols, d.alloc)
		t.least = make([]f32, cols, d.alloc)
	}
	t.rows, t.cols, t.key = len(rows), cols, key
	bl.table = t
	return t
}

// Measures each column of `t` in the faces and size of `rc` (its widest cell on one line, its longest word, `pad` on both
// sides of each): only when they changed.
table_measure :: proc(t: ^Table, rc: ui.Rich_Context, em, pad: f32) {
	key := hash_floats(u64(rc.base_font) * HASH_MIX_A ~ u64(uintptr(rc.fonts)), []f32{rc.base_size, em, pad})
	if t.measure_key == key { return }
	for ci in 0 ..< t.cols { t.widths[ci], t.least[ci] = 0, 0 }
	for ri in 0 ..< t.rows {
		for ci in 0 ..< t.cols {
			runs := table_cell(t, ri, ci)
			l := ui.rich_layout(runs, rc, TABLE_MEASURE_W, allocator = context.temp_allocator)
			t.widths[ci] = max(t.widths[ci], math.ceil(l.size.x) + 2 * pad)
			for run in runs {
				face, size := ui.rich_face(rc, run.style)
				for word in strings.split(run.text, " ", context.temp_allocator) {
					t.least[ci] = max(t.least[ci], math.ceil(ui.text_width(face, size, word) + (run.style.code ? em * TABLE_CODE_SLACK_EM : 0)) + 2 * pad)
				}
			}
		}
	}
	t.measure_key = key
}

// The cells of a table row: `| a | b |` -> {"a", "b"}.
@(private = "file")
table_cells :: proc(line: string) -> []string {
	t := strings.trim_space(line)
	t = strings.trim_prefix(t, "|")
	t = strings.trim_suffix(t, "|")
	cells := strings.split(t, "|", context.temp_allocator)
	for &c in cells { c = strings.trim_space(c) }
	return cells
}

// A Markdown table as a grid: the header row in its style, under a rule, each column aligned as written, alternate rows
// shaded. Its columns: each as wide as its widest cell on one line, no wider than TABLE_COL_MAX_EM (past that its words
// wrap in it), never under its longest word: a table wider than its place scrolls sideways in its frame.
@(private)
table_block :: proc(id: string, d: ^Doc, n: int, cfg: ^Config, c: Colors, fs: f32) {
	em := ui.font_size()
	header := c.table_header.a > 0 ? c.table_header : c.heading
	t := table_of(d, n, {bold = true, color = header}, {color = c.text}, {code_color = c.inline_code})
	if t.rows == 0 { return }
	pad := math.round(em * TABLE_CELL_PAD_X_EM)
	cell_size := math.round(fs * (cfg.cell_scale > 0 ? cfg.cell_scale : 1))
	face := cfg.face != 0 ? cfg.face : cfg.prose
	st := ui.current_state()
	if face == 0 { face = ui.top_style().font }
	rc := ui.Rich_Context{fonts = st.fonts, base_font = face, base_size = cell_size, mono = st.mono_font, faces = &st.families}
	table_measure(t, rc, em, pad)
	widths := make([]f32, t.cols, context.temp_allocator)
	col_max := math.round(em * TABLE_COL_MAX_EM)
	total: f32
	for ci in 0 ..< t.cols {
		widths[ci] = min(t.widths[ci], max(col_max, t.least[ci] < col_max ? t.least[ci] : col_max))
		total += widths[ci]
	}
	room := ui.parent_box().rect.max.x - ui.parent_box().rect.min.x   // (the place it had in the last layout: none yet, it fits)
	// (every other row tinted with the text's colour, faintly: light on a dark theme, dark on a light one; the header is told by
	// its words and its rule. The rows stand off the frame's edge, rounded a little: their tint does not cover its rim.)
	stripe := c.table_stripe.a > 0 ? c.table_stripe : with_alpha(c.text, TABLE_STRIPE_ALPHA)
	rule := c.table_rule.a > 0 ? c.table_rule : with_alpha(c.marker, TABLE_RULE_ALPHA)
	edge := 2 * max(1, math.round(ui.scale()))
	overflow := room > 0 && total > room - 2 * edge
	frame_open(id, cfg, .Table, c.table_frame)
	ui.spacer(ui.px(em * 0.3))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###in") {
		ui.spacer(ui.px(edge))
		// (sideways: the rows in a box that scrolls; a fade on the side that hides more, and the box's own scroll bar
		// under them, say so: the toolkit's, as every box that scrolls has; a second bar of the table's drew two)
		_ = table_scroller(overflow, total, em)
		ui.next({width = overflow ? ui.px(total, 1) : ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###rows") {
			for ri in 0 ..< t.rows {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, bg = ri > 0 && ri % 2 == 0 ? stripe : {}, radius = math.round(em * 0.25)})
				if ui.row(flags = {.Draw_Background}, id = fmt.tprintf("###tr%d", ri)) {
					for ci in 0 ..< t.cols {
						text := t.texts[ri * t.cols + ci]
						ui.next({width = ui.px(widths[ci], 1), height = ui.children_sum(), axis = .X})
						if ui.row(id = fmt.tprintf("###tc%d", ci)) {
							ui.spacer(ui.px(pad))
							ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
							if ui.column(id = "###v") {   // (the room around the words is the spacers': measured so)
								ui.spacer(ui.px(math.round(em * TABLE_CELL_PAD_Y_EM)))
								ui.next({width = ui.fill(), font = face, font_size = cell_size, flags = {.Selectable}, text_align = t.aligns[ci], text_pad = 0})
								link_clicked(cfg, ui.rich_paragraph("###p", table_cell(t, ri, ci), version = source_version(text, text, cell_size)))
								ui.spacer(ui.px(math.round(em * TABLE_CELL_PAD_Y_EM)))
							}
							ui.spacer(ui.px(pad))
						}
					}
				}
				if ri == 0 { ui.next({width = ui.fill(), height = ui.px(2), bg = rule}); ui.build_box({.Draw_Background}, "###hl") }
			}
			// (the room of the scroll bar under the rows: it is drawn over the box's bottom edge, not over a row)
			if overflow { ui.spacer(ui.px(ui.scrollbar_gutter())) }
		}
		ui.pop_parent()   // (table_scroller's box)
		ui.spacer(ui.px(edge))
	}
	ui.spacer(ui.px(em * 0.3))
	if cfg.table_corner != nil { table_corner(cfg, t, block_lines(d, n), em) }
	ui.pop_parent()   // (the frame)
}

// Under the pointer, the program's tools for the table (a copy button, say) in its top right corner. Built last, over the
// rows (built before them, the rows hid it and took its clicks).
@(private = "file")
table_corner :: proc(cfg: ^Config, t: ^Table, lines: []string, em: f32) {
	table_box := ui.parent_box()
	over := draw.rect_contains(table_box.rect, ui.mouse_pos())   // (its cells are no buttons: the pointer anywhere on it)
	tw := table_box.rect.max.x - table_box.rect.min.x
	if tw <= 1 || !over { return }
	sz := math.round(em * 1.6)
	m := math.round(em * 0.25)
	ui.next({fixed_x = tw - sz - m, fixed_y = m, width = ui.px(sz), height = ui.px(sz), axis = .X})
	if ui.row(id = "###tcorner") { cfg.table_corner(cfg.user, t, lines, sz) }
}

// The box a table's rows scroll sideways in (its parent until the caller pops it): the width it has, its content `total`
// wide when `overflow`. Its edge fades where it hides columns (by the last frame's offset).
@(private = "file")
table_scroller :: proc(overflow: bool, total, em: f32) -> ^ui.Box {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	hs := ui.build_box(overflow ? {.View_Scroll_X, .Clip} : {}, "###hs")
	if overflow {
		ui.scroll_fades(hs, .X, math.round(em * TABLE_FADE_EM))
		_ = ui.signal(hs)   // (the wheel sideways, or Shift+wheel, scrolls it in its signal)
	} else {
		hs.view_off, hs.view_target = {}, {}
	}
	ui.push_parent(hs)
	return hs
}

// A table as HTML for the clipboard: a plain grid that takes the style of the program it is pasted in (its fonts, its
// colours), with a thin grey rule around each cell, a little room in them, the header row as th, each column aligned as
// written; what is bold, italic or code in a cell stays so; what is HTML in a cell is escaped. In temp memory.
table_html :: proc(t: ^Table) -> string {
	esc :: proc(b: ^strings.Builder, s: string) {
		for r in s {
			switch r {
			case '&': strings.write_string(b, "&amp;")
			case '<': strings.write_string(b, "&lt;")
			case '>': strings.write_string(b, "&gt;")
			case '"': strings.write_string(b, "&quot;")
			case:     strings.write_rune(b, r)
			}
		}
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `<table style="border-collapse:collapse">`)
	for ri in 0 ..< t.rows {
		if ri == 0 { strings.write_string(&b, "<thead>") }
		if ri == 1 { strings.write_string(&b, "<tbody>") }
		strings.write_string(&b, "<tr>")
		tag := ri == 0 ? "th" : "td"
		for ci in 0 ..< t.cols {
			al := t.aligns[ci]
			side := al == .Center ? "center" : al == .Right ? "right" : "left"
			fmt.sbprintf(&b, `<%s style="border:1px solid #bbb;padding:4px 8px;text-align:%s">`, tag, side)
			for run in table_cell(t, ri, ci) {
				if run.style.code { strings.write_string(&b, "<code>") }
				if run.style.bold && ri > 0 { strings.write_string(&b, "<b>") }
				if run.style.italic { strings.write_string(&b, "<i>") }
				esc(&b, run.text)
				if run.style.italic { strings.write_string(&b, "</i>") }
				if run.style.bold && ri > 0 { strings.write_string(&b, "</b>") }
				if run.style.code { strings.write_string(&b, "</code>") }
			}
			fmt.sbprintf(&b, "</%s>", tag)
		}
		strings.write_string(&b, "</tr>")
		if ri == 0 { strings.write_string(&b, "</thead>") }
	}
	if t.rows > 1 { strings.write_string(&b, "</tbody>") }
	strings.write_string(&b, "</table>")
	return strings.to_string(b)
}
