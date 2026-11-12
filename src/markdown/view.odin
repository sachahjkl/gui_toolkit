package markdown

import "core:fmt"
import "core:math"
import "../draw"
import "../font"
import "../ui"

LIST_MARKER_EM     :: 1.3   // a list item's marker column, at least (its text, the gap and the padding on both sides)
LIST_MARKER_GAP_EM :: 0.3   // between a list's widest number and its text
CODE_PAD_X_EM      :: 0.9   // at the sides of a code block's text (code_block)
CODE_PAD_Y_EM      :: 0.6   // above and under it

// The colours Markdown is shown in. Alpha 0: the default said beside each.
Colors :: struct {
	text:         ui.Color,   // paragraphs, list items, table cells (the theme's "text")
	heading:      ui.Color,   // headings of level 1 and 2 (the text's; the others are in the text's)
	quote:        ui.Color,   // a quote's text (the theme's "weak text")
	marker:       ui.Color,   // a list item's marker (the theme's "accent")
	rail:         ui.Color,   // the rail along a quote (the marker's, a little faint)
	inline_code:  ui.Color,   // `code` in a paragraph (the text around it)
	code_text:    ui.Color,   // a code block's plain text (the text's)
	code_frame:   ui.Color,   // behind a code block, when Config.frame is nil (the theme's "code_bg")
	table_header: ui.Color,   // a table's header row (the heading's)
	table_frame:  ui.Color,   // behind a table, when Config.frame is nil (the theme's "well")
	table_stripe: ui.Color,   // every other row of a table (the text's, faint)
	table_rule:   ui.Color,   // under a table's header (the marker's, faint)
	scroll_bar:   ui.Color,   // the bar under a table that scrolls sideways, drawn faint (the text's)
}

// What a fenced code block gives Config.code.
Code :: struct {
	lang:    string,          // the word after its fence ("" for none)
	text:    string,          // its lines
	runs:    []ui.Rich_Run,   // its text highlighted (code_runs): kept by the doc, valid through the build
	closed:  bool,            // its closing fence came (one still being written is not)
	version: u64,             // for rich_paragraph's `version`: the same while its text is
}

// What Config.frame paints.
Frame_Kind :: enum u8 { Table, Code }

// How a program shows Markdown: its faces and sizes, its colours, and what it does with what is not text (a link
// clicked, a code block, the box around a table, a rule, the tools on a table). Every field may stay zero.
Config :: struct {
	prose:       font.Font_Id,   // the text's face (0: the current one)
	face:        font.Font_Id,   // the tables' face (0: prose)
	mono:        font.Font_Id,   // the code blocks' face (0: ui.mono_font)
	prose_scale: f32,            // the text's size, of the size view is given (0: 1)
	line_ratio:  f32,            // the height of the text's lines, of its size (0: the font's)
	cell_scale:  f32,            // the tables' text, of the size view is given (0: 1)
	colors:      Colors,
	user:        rawptr,         // what the procedures below are given
	// a link clicked or chosen with Enter; its target is as written (nil: links open nothing)
	link:  proc(user: rawptr, url: string),
	// a fenced block, built in its place, `id` its box's (nil: code_block)
	code:  proc(user: rawptr, id: string, c: Code),
	// paints `b`, the box a table or a code block sits in (b.custom...); nil: its colour (Colors), rounded
	frame: proc(user: rawptr, b: ^ui.Box, kind: Frame_Kind),
	// a rule ("---"), built in its place (nil: ui.hline)
	rule:  proc(user: rawptr, id: string),
	// what is built in a table's top right corner while the pointer is on the table (a copy button: table_html, `source`
	// its lines as written), in a row `size` square (nil: nothing)
	table_corner: proc(user: rawptr, t: ^Table, source: []string, size: f32),
}

// Shows `src` as Markdown in the current column (full width), its blocks read into `d` (read again only as `src`
// changes: read). `id` keys its boxes. `size`: the text's size (0: the current one; Config scales it).
view :: proc(d: ^Doc, id: string, src: string, cfg: Config, size: f32 = 0) {
	cfg := cfg
	em := ui.font_size()
	fs := size > 0 ? size : em
	prose := cfg.prose != 0 ? cfg.prose : ui.top_style().font
	c := colors_of(cfg.colors)
	// every line the same height, inline code or not; tables stay in their own face
	prose_fs := math.round(fs * (cfg.prose_scale > 0 ? cfg.prose_scale : 1))
	line_h := cfg.line_ratio > 0 ? math.round(prose_fs * cfg.line_ratio) : 0
	read(d, src)
	measure :: proc(face: font.Font_Id, s: string, size: f32) -> f32 { return ui.text_width(face, size, s) }
	// (a marker's column holds its text, the gap and the padding on both sides of a box: LIST_MARKER_EM in all at least)
	pad := ui.parent_box().text_pad
	marker_w := marker_widths(d, measure, prose, prose_fs, math.round(em * LIST_MARKER_EM) - 2 * pad, math.round(em * LIST_MARKER_GAP_EM))
	for &bl, n in d.blocks {
		bid := fmt.tprintf("###%s_b%d", id, n)
		lines := block_lines(d, n)
		lines_version := len(lines) > 0 ? source_version(lines[0], lines[len(lines) - 1], fs) : 0
		if n > 0 { ui.spacer(ui.px(math.round(em * (bl.kind == .Bullet || bl.kind == .Number ? 0.25 : 0.6)))) }
		switch bl.kind {
		case .Rule:
			if cfg.rule != nil { cfg.rule(cfg.user, bid) } else { ui.hline(ui.fill()) }
		case .Code:
			mono := cfg.mono != 0 ? cfg.mono : ui.mono_font()
			code := Code{lang = bl.lang, text = block_text(d, n), runs = code_runs(d, n, {font = mono, color = c.code_text}), closed = bl.closed,
				version = len(lines) > 0 ? source_version(lines[0], lines[len(lines) - 1], em) : 0}
			if cfg.code != nil { cfg.code(cfg.user, bid, code) } else { code_block(bid, code, cfg) }
		case .Table:
			table_block(bid, d, n, &cfg, c, fs)
		case .Heading:
			k := [HEADING_LEVEL_MAX + 1]f32{1, 1.45, 1.25, 1.1, 1, 1, 1}
			runs := block_runs(d, n, {bold = true, color = bl.level <= 2 ? c.heading : c.text}, {code_color = c.inline_code})
			if bl.level >= 2 { ui.spacer(ui.px(em * 0.3)) }
			ui.next({width = ui.fill(), font = prose, font_size = math.round(prose_fs * k[bl.level]), flags = {.Selectable}})
			link_clicked(&cfg, ui.rich_paragraph(bid, runs, version = source_version(lines[0], lines[0], fs)))
		case .Para, .Quote:
			runs := block_runs(d, n, {color = bl.kind == .Quote ? c.quote : c.text}, {code_size = fs, code_color = c.inline_code})
			if bl.kind == .Quote {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if rail_row(fmt.tprintf("%s_q", bid), c.rail) {
					ui.spacer(ui.px(em * 0.9))
					ui.next({width = ui.fill(), font = prose, font_size = prose_fs, flags = {.Selectable}})
					link_clicked(&cfg, ui.rich_paragraph(bid, runs, version = lines_version, line_height = line_h))
				}
			} else {
				ui.next({width = ui.fill(), font = prose, font_size = prose_fs, flags = {.Selectable}})
				link_clicked(&cfg, ui.rich_paragraph(bid, runs, version = lines_version, line_height = line_h))
			}
		case .Bullet, .Number:
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = fmt.tprintf("%s_li", bid)) {
				ui.spacer(ui.px(em * (0.3 + 1.2 * f32(bl.level))))
				mk := bl.marker
				if bl.kind == .Bullet { mk = bl.level == 0 ? "•" : "◦" }
				// (a paragraph of the item's face, size, line height and padding: its baseline is the text's; the column is
				// as wide as the widest marker of the list, its padding on both sides with it)
				mark := [1]ui.Rich_Run{{text = mk, style = {color = c.marker}}}
				ui.next({width = ui.px(marker_w[n] + 2 * pad), font = prose, font_size = prose_fs})
				ui.rich_paragraph(fmt.tprintf("%s_mk", bid), mark[:], line_height = line_h)
				runs := block_runs(d, n, {color = c.text}, {code_size = fs, code_color = c.inline_code})
				ui.next({width = ui.fill(), font = prose, font_size = prose_fs, flags = {.Selectable}})
				link_clicked(&cfg, ui.rich_paragraph(bid, runs, version = lines_version, line_height = line_h))
			}
		}
	}
}

// A code block as the package shows it when Config.code is nil: its highlighted text in its frame, in the current size.
// A program's Config.code may build it too, for the languages it has nothing of its own for.
code_block :: proc(id: string, c: Code, cfg: Config) {
	cfg := cfg
	em := ui.font_size()
	frame_open(id, &cfg, .Code, colors_of(cfg.colors).code_frame)
	ui.spacer(ui.px(math.round(em * CODE_PAD_Y_EM)))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###body") {
		ui.spacer(ui.px(math.round(em * CODE_PAD_X_EM)))
		ui.next({width = ui.fill(), flags = {.Selectable}})
		ui.rich_paragraph("###code", c.runs, version = c.version)
		ui.spacer(ui.px(math.round(em * CODE_PAD_X_EM)))
	}
	ui.spacer(ui.px(math.round(em * CODE_PAD_Y_EM)))
	ui.pop_parent()   // (the frame)
}

// The colours, each default in place.
@(private)
colors_of :: proc(in_c: Colors) -> Colors {
	c := in_c
	if c.text.a == 0 { c.text = ui.color("text") }
	if c.heading.a == 0 { c.heading = c.text }
	if c.quote.a == 0 { c.quote = ui.color("weak text") }
	if c.marker.a == 0 { c.marker = ui.color("accent") }
	if c.rail.a == 0 { c.rail = with_alpha(c.marker, 0.6) }
	if c.code_text.a == 0 { c.code_text = c.text }
	if c.code_frame.a == 0 { c.code_frame = ui.color("code_bg") }
	if c.table_frame.a == 0 { c.table_frame = ui.color("well") }
	return c
}

// Builds the box a table or a code block sits in, full width and as tall as what it holds, and makes it the parent (the
// caller pops it).
@(private)
frame_open :: proc(id: string, cfg: ^Config, kind: Frame_Kind, bg: ui.Color) {
	m := ui.Style_Mod{width = ui.fill(), height = ui.children_sum(), axis = .Y}
	flags := ui.Box_Flags{}
	if cfg.frame == nil {
		m.bg, m.radius = bg, math.round(TABLE_RADIUS_PX * ui.scale())
		flags = {.Draw_Background}
	}
	ui.next(m)
	b := ui.build_box(flags, id)
	if cfg.frame != nil { cfg.frame(cfg.user, b, kind) }
	ui.push_parent(b)
}

@(private)
link_clicked :: proc(cfg: ^Config, res: ui.Rich_Result) {
	if res.link_clicked >= 0 && cfg.link != nil { cfg.link(cfg.user, res.link) }
}

@(private)
with_alpha :: proc(c: ui.Color, a: f32) -> ui.Color { return {c.r, c.g, c.b, c.a * a} }

@(private = "file")
rail_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	c := (^ui.Color)(user)^
	s := ui.scale()
	r := b.rect
	draw.rect(dc, {r.min, {r.min.x + 2.5 * s, r.max.y}}, c, 1.25 * s)
}

// `if rail_row(id, color) { ... }`: a row as tall as what it holds, with a rail of `color` along its left edge (a quote).
@(private = "file", deferred_none = ui.pop_parent)
rail_row :: proc(id: string, color: ui.Color) -> bool {
	b := ui.build_box({}, id)
	b.layout_axis = .X
	c := ui.frame_new(ui.Color)
	c^ = color
	b.custom, b.custom_user = rail_draw, c
	ui.push_parent(b)
	return true
}
