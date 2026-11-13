package tk_diff

// The lines of a diff on rows: its numbers in two gutters, its sign, its text; an added line on a tint of green, a removed one of red,
// what changed in a changed line on a stronger tint, the code in its colours when a language is given. Every row has one height:
// `view` builds only the rows in view, whatever the length of the patch.
//
// The colours are the theme's, under the tag "diff" (theme_default.odin): "diff_added background", "diff_removed background",
// "diff_added mark", "diff_removed mark" (what changed in a line), "diff_added text", "diff_removed text", "diff text" (a line in
// both), "diff_added sign", "diff_removed sign", "diff sign", "diff mark_text", "diff line_number", "diff gap", "diff divider" (between
// the sides of a split view). A program sets its own with ui.theme_add before the palette.

import "core:fmt"
import "core:math"
import "core:strings"
import tk_font "../font"
import syntax "../syntax"
import "../ui"

Layout :: enum u8 {
	Stacked,   // old and new lines one under the other, as the patch has them
	Split,     // old on the left, new on the right, a changed line facing itself
}

// Which of a line's numbers its row shows.
Numbers :: enum u8 { Both, Old, New, None }

// How rows look. Sizes are pixels; 0: the default said.
View_Options :: struct {
	font:         tk_font.Font_Id,           // of the lines (0: ui.mono_font())
	sign_font:    tk_font.Font_Id,           // of the signs (0: `font`)
	number_font:  tk_font.Font_Id,           // of the numbers (0: `font`)
	size:         f32,                    // of the lines' text (0: ui.font_size())
	number_size:  f32,                    // of the numbers (0: `size`)
	row_height:   f32,                    // (0: 1.5 × `size`)
	gap_height:   f32,                    // of the row between two hunks (0: `row_height`; `view` always uses `row_height`)
	gutter_width: f32,                    // of one column of numbers (0: 3.2 × `size`)
	sign_width:   f32,                    // (0: 1.2 × `size`)
	indent:       f32,                    // before the sign, and before a gap's mark (0: 0.5 × `size`)
	tab:          string,                 // what a tab shows ("": four spaces)
	max_bytes:    int,                    // of a line's text shown, cut at a character with "…" (0: all)
	language:     Maybe(syntax.Language), // the code's colours (tk_syntax)
	selectable:   bool,                   // the lines' text can be selected and copied
}

// The options with their defaults resolved, and the colours, read once for a build.
@(private)
Look :: struct {
	using o:    View_Options,
	background: [Kind]ui.Color,
	mark:       [Kind]ui.Color,
	text:       [Kind]ui.Color,
	sign:       [Kind]ui.Color,
	mark_text:  ui.Color,
	number:     ui.Color,
	gap:        ui.Color,
	divider:    ui.Color,
}

// (under the tag "diff": call it there)
@(private)
look_of :: proc(o: View_Options) -> (k: Look) {
	k.o = o
	if k.font == 0 { k.font = ui.mono_font() }
	if k.sign_font == 0 { k.sign_font = k.font }
	if k.number_font == 0 { k.number_font = k.font }
	if k.size <= 0 { k.size = ui.font_size() }
	if k.number_size <= 0 { k.number_size = k.size }
	if k.row_height <= 0 { k.row_height = math.round(k.size * 1.5) }
	if k.gap_height <= 0 { k.gap_height = k.row_height }
	if k.gutter_width <= 0 { k.gutter_width = math.round(k.size * 3.2) }
	if k.sign_width <= 0 { k.sign_width = math.round(k.size * 1.2) }
	if k.indent <= 0 { k.indent = math.round(k.size * 0.5) }
	if k.tab == "" { k.tab = "    " }
	k.background[.Added], k.background[.Removed] = ui.color("diff_added background"), ui.color("diff_removed background")
	k.mark[.Added], k.mark[.Removed] = ui.color("diff_added mark"), ui.color("diff_removed mark")
	k.text[.Same], k.text[.Added], k.text[.Removed] = ui.color("diff text"), ui.color("diff_added text"), ui.color("diff_removed text")
	k.sign[.Same], k.sign[.Added], k.sign[.Removed] = ui.color("diff sign"), ui.color("diff_added sign"), ui.color("diff_removed sign")
	k.mark_text = ui.color("diff mark_text")
	k.number = ui.color("diff line_number")
	k.gap = ui.color("diff gap")
	k.divider = ui.color("diff divider")
	return
}

// `lines` on rows, each built: an excerpt (a program shows the first lines of a patch and a way to the whole). `numbered`: with
// the gutters of their numbers (Parsed.numbered: a patch without hunks has none).
lines_view :: proc(id: string, lines: []Line, numbered: bool, o: View_Options = {}) {
	if len(lines) == 0 { return }
	if ui.tags("diff") {
		k := look_of(o)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = id) {
			for l, i in lines {
				if l.kind == .Gap {
					gap_row(fmt.tprintf("###g%d", i), &k, k.gap_height)
				} else {
					line_row(fmt.tprintf("###l%d", i), l, numbered ? .Both : .None, &k)
				}
			}
		}
	}
}

// `d`'s rows in a box that fills its parent and scrolls, stacked or split. Only the rows in view, and VIEW_MARGIN_ROWS beyond, are
// built. The box is returned (its scroll: view_off, view_target).
view :: proc(id: string, d: ^Doc, layout: Layout, o: View_Options = {}) -> ^ui.Box {
	box: ^ui.Box
	if ui.tags("diff") {
		k := look_of(o)
		k.gap_height = k.row_height   // (one height for every row: what shows is a sum)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		box = ui.build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, id)
		_ = ui.signal(box)
		if ui.parent(box) {
			h := k.row_height
			count := layout == .Stacked ? len(d.lines) : len(d.rows)
			first, last := visible_rows(box.view_off.y, box.view_target.y, box.size.y, h, count)
			ui.spacer(ui.px(f32(first) * h))
			for i in first ..< last {
				switch layout {
				case .Stacked:
					l := d.lines[i]
					if l.kind == .Gap { gap_row(fmt.tprintf("###g%d", i), &k, h) } else { line_row(fmt.tprintf("###l%d", i), l, .Both, &k) }
				case .Split:
					r := d.rows[i]
					if r.left >= 0 && d.lines[r.left].kind == .Gap { gap_row(fmt.tprintf("###g%d", i), &k, h); continue }
					ui.next({width = ui.fill(), height = ui.px(h), axis = .X})
					if ui.row(id = fmt.tprintf("###r%d", i)) {
						line_row("###a", r.left >= 0 ? d.lines[r.left] : nil, .Old, &k)
						ui.next({width = ui.px(max(1, ui.scale())), height = ui.px(h), bg = k.divider})
						ui.build_box({.Draw_Background}, "###bar")
						line_row("###b", r.right >= 0 ? d.lines[r.right] : nil, .New, &k)
					}
				}
			}
			ui.spacer(ui.px(f32(count - last) * h))
		}
	}
	return box
}

// The mark between two hunks.
@(private)
gap_row :: proc(id: string, k: ^Look, h: f32) {
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		ui.spacer(ui.px(k.indent))
		ui.next({width = ui.text_size(), height = ui.px(h), font = k.font, font_size = k.size, fg = k.gap, text_pad = 0})
		ui.build_box({.Draw_Text}, "⋯###m")
	}
}

// A line on one row (nil: nothing on that side of a split row, its tint left blank).
@(private)
line_row :: proc(id: string, line: Maybe(Line), numbers: Numbers, k: ^Look) {
	l, there := line.?
	bg := there && l.kind != .Same ? k.background[l.kind] : ui.Color{}
	ui.next({width = ui.fill(), height = ui.px(k.row_height), axis = .X, cross = .Center, bg = bg, radius = 0})
	b := ui.build_box({.Draw_Background, .Clip}, id)
	if !there { return }
	if ui.parent(b) { line_cells(l, numbers, k) }
}

@(private)
line_cells :: proc(l: Line, numbers: Numbers, k: ^Look) {
	switch numbers {
	case .Both:
		number("###o", l.old_no, k)
		number("###n", l.new_no, k)
	case .Old:  number("###o", l.old_no, k)
	case .New:  number("###n", l.new_no, k)
	case .None:
	}
	ui.spacer(ui.px(k.indent))
	glyph := l.kind == .Added ? "+" : l.kind == .Removed ? "−" : " "
	ui.next({width = ui.px(k.sign_width), height = ui.px(k.row_height), font = k.sign_font, font_size = k.size, fg = k.sign[l.kind], text_pad = 0})
	ui.build_box({.Draw_Text}, fmt.tprintf("%s###s", glyph))
	runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
	line_runs(l, k, &runs)
	// (one line: the two sides of a split row face each other; a copy has the whole of what is shown)
	ui.next({width = ui.fill(), font_size = k.size, flags = k.selectable ? ui.Box_Flags{.Selectable} : ui.Box_Flags{}})
	ui.rich_paragraph("###t", runs[:], 1)
}

@(private)
number :: proc(id: string, n: int, k: ^Look) {
	s := n > 0 ? fmt.tprintf("%d%s", n, id) : id
	ui.next({width = ui.px(k.gutter_width), height = ui.px(k.row_height), font = k.number_font, font_size = k.number_size, fg = k.number, text_align = .Right, text_pad = 0})
	ui.build_box({.Draw_Text}, s)
}

// A line's text as runs: the code's colours when a language is given, what changed on its tint, tabs opened, cut at max_bytes.
// (Only the rows built are lexed: a sum, as they are.)
@(private)
line_runs :: proc(l: Line, k: ^Look, runs: ^[dynamic]ui.Rich_Run) {
	text := l.text
	cut := false
	if k.max_bytes > 0 && len(text) > k.max_bytes {
		end := k.max_bytes
		for end > 0 && text[end] & 0xC0 == 0x80 { end -= 1 }
		text, cut = text[:end], true
	}
	base := ui.Rich_Style{font = k.font, color = k.text[l.kind]}
	if text == "" {
		append(runs, ui.Rich_Run{text = " ", style = base})
		return
	}
	// pieces of one class, each cut again at the mark's ends
	Piece :: struct { start, end: int, class: syntax.Class }
	pieces := make([dynamic]Piece, context.temp_allocator)
	if lang, ok := k.language.?; ok {
		spans := make([dynamic]syntax.Span, context.temp_allocator)
		syntax.spans(text, lang, &spans)
		at := 0
		for sp in spans {
			if sp.start > at { append(&pieces, Piece{at, sp.start, .Plain}) }
			append(&pieces, Piece{sp.start, sp.end, sp.class})
			at = sp.end
		}
		if at < len(text) { append(&pieces, Piece{at, len(text), .Plain}) }
	} else {
		append(&pieces, Piece{0, len(text), .Plain})
	}
	lo, hi := min(l.lo, len(text)), min(l.hi, len(text))
	for p in pieces {
		cuts := [4]int{p.start, clamp(lo, p.start, p.end), clamp(hi, p.start, p.end), p.end}
		for c in 0 ..< 3 {
			a, b := cuts[c], cuts[c + 1]
			if a >= b { continue }
			st := base
			if p.class != .Plain {
				st.color = ui.code_color(p.class)
				st.italic = p.class == .Comment
			}
			if c == 1 && hi > lo {
				st.background = k.mark[l.kind]
				if p.class == .Plain { st.color = k.mark_text }
			}
			append(runs, ui.Rich_Run{text = opened(text[a:b], k.tab), style = st})
		}
	}
	if cut { append(runs, ui.Rich_Run{text = "…", style = base}) }
}

@(private)
opened :: proc(s, tab: string) -> string {
	if strings.index_byte(s, '\t') < 0 { return s }
	out, _ := strings.replace_all(s, "\t", tab, context.temp_allocator)
	return out
}
