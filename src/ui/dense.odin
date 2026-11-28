package ui

// The dense look of an instrument (src/md/features/debug-panel.md, "A dense look, only here"): the debug window, a
// program's own inspector. Small text, rows one line high, hairlines, a label and its field on one row. The theme's
// colours; not the person's density, which stays the person's screens'.
//
//   if ui.dense_scope() {
//       if ui.tree_header("###transform", "Transform", &app.open) {
//           if ui.dense_row("position") { ui.drag_vector("###position", &app.position) }
//       }
//   }

import "core:fmt"
import "core:math"
import lucide "../lucide"

// The text of a dense scope, a share of the size around it; a row's height, in that text's sizes.
DENSE_FONT_SCALE :: 0.85
DENSE_ROW_EM :: 1.55
// The share of a dense row's width its label takes when no Dense_Labels column is given, and the maximum share any
// label column may take so values are never crushed in a narrow panel.
DENSE_LABEL_SHARE :: 0.38
DENSE_LABEL_MAX_SHARE :: 0.45
// What a nested header's rows are moved in by, in the scope's text sizes.
DENSE_INDENT_EM :: 0.9
// A dense floating window's header (View_Options.dense), in the scope's text sizes: a row of tabs, a little taller
// than a row.
DENSE_HEADER_EM :: DENSE_ROW_EM * 1.25

// Whether a view's header is the dense strip: its kind asks it, and it is a floating window (a dialog keeps its
// corner cross, a window of its own its system's or the program's caption, a panel its stack's strip).
@(private)
view_header_dense :: proc(r: ^View_Record, p: View_Presentation) -> bool { return r.kind.o.dense && p == .Internal }

// `if ui.dense_scope() { ... }`: what is built inside wears the dense look: text at DENSE_FONT_SCALE of the size
// around it, rows of dense_row_height, tight insets, square corners (every box built inside but a shape's, Fixed_Radius;
// a check box's mark), the least density for the toolkit's own widgets. Nested scopes add nothing.
@(require_results, deferred_none = dense_scope_end)
dense_scope :: proc() -> bool {
	s := gs()
	st := top_style()^
	if s.dense_depth == 0 {
		s.dense_saved = s.density
		s.density = DENSITY_MIN
		st.font_size = math.round(st.font_size * DENSE_FONT_SCALE)
		st.text_pad = math.round(st.font_size * DENSE_PAD_EM)
		st.radius = 0
	}
	s.dense_depth += 1
	s.square_depth += 1
	append(&s.style_stack, st)
	return true
}

@(private)
dense_scope_end :: proc() {
	s := gs()
	pop(&s.style_stack)
	s.dense_depth -= 1
	s.square_depth -= 1
	if s.dense_depth == 0 { s.density = s.dense_saved }
}

// Whether a dense scope is open where this is built.
dense_shown :: proc() -> bool { return gs().dense_depth > 0 }

// A dense row's height: one line of the text in use and a few pixels.
dense_row_height :: proc() -> f32 { return math.round(font_size() * DENSE_ROW_EM) }

// The gap between two dense rows, and between a label and its field: a pixel or two.
dense_gap :: proc() -> f32 { return max(1, math.round(scale() * DENSE_GAP_PX)) }

// A dense scope's inset, in its text's sizes; its gap in logical pixels.
@(private = "file") DENSE_PAD_EM :: 0.35
@(private = "file") DENSE_GAP_PX :: 2

// `if ui.dense_row("speed") { ui.drag_number("###speed", &app.speed) }`: a label and its field on one row of
// dense_row_height: the label at the left in the weak ink, cut to its column; what is built inside after it takes the
// rest (give it width fill()). The column: `label_width` pixels, never less, so that rows at several depths line their
// fields up (0: DENSE_LABEL_SHARE of the row). `id`: the row's ("": from the label). `ranges`: the parts of the label a
// filter matched, lit as every filtered list lights them (match.odin). `height`: a taller row's (a graph's), 0: one row.
@(require_results, deferred_none = pop_parent)
dense_row :: proc(label: string, id := "", label_width: f32 = 0, ranges: []Fuzzy_Range = nil, height: f32 = 0) -> bool {
	dense_row_open(label, id, label_width, ranges, height)
	return true
}

// The width in pixels that `label` needs on one line in the current dense style (its text plus horizontal padding).
dense_label_width :: proc(label: string) -> f32 {
	st := top_style()
	return math.ceil(text_width(st.font, st.font_size, label) + 2 * st.text_pad)
}

// dense_row's row without its scope: the caller pops it (pop_parent). For a wrapper whose own scope holds it.
dense_row_open :: proc(label: string, id := "", label_width: f32 = 0, ranges: []Fuzzy_Range = nil, height: f32 = 0) {
	set_next_axis(.X, .Center)
	s := gs()
	em := max(font_size(), 1)
	s.next_mod.width = fill()
	s.next_mod.height = px(height > 0 ? height : dense_row_height())
	row := build_box({}, id != "" ? id : fmt.tprintf("###row_%s", label))
	push_parent(row)
	row_w := row.rect.max.x - row.rect.min.x
	w: Size
	if label_width > 0 {
		lw := label_width
		if row_w > 0 {
			cap := max(math.floor(row_w * DENSE_LABEL_MAX_SHARE), math.ceil(DENSE_LABEL_MIN_EM * em))
			lw = min(lw, cap)
		}
		w = px(lw)
	} else if row_w > 0 {
		w = px(min(math.floor(row_w * DENSE_LABEL_SHARE), math.ceil(DENSE_LABEL_MAX_EM * em)))
	} else {
		w = pct(DENSE_LABEL_SHARE, 1)
	}
	// (lit, the label is a paragraph as tall as its line: centred in the row as the plain one's text is)
	next({width = w, height = len(ranges) > 0 ? text_size() : pct(1)})
	if tags("weak") {
		lb := len(ranges) > 0 ? matched_label("###label", label, ranges) : build_box({.Draw_Text}, fmt.tprintf("%s###label", label))
		dense_readable(lb)
	}
	spacer(px(dense_gap()))
}

// The labels' column of a dense panel (debug-panel.md, "A dense look"): as wide as its longest label shown, its indent
// counted, so that the fields of every depth line up on one edge and no label leaves a gap before its field. A label's
// width is measured once (by its text, in its text's ems: a zoom keeps it) and kept; a build takes the widest of the
// last build's labels (one map lookup a row: the row is built anyway), so a label that comes or goes moves the column
// at the next build. DENSE_LABEL_MIN_EM at least; DENSE_LABEL_MAX_EM at most: a longer label is cut, its whole text one
// click away (text-reveal.md).
//
//   ui.dense_labels_begin(&panel.labels)
//   if ui.dense_row("speed", label_width = ui.dense_label_column(&panel.labels, "speed", indent)) { ... }
//   ui.dense_labels_end(&panel.labels)
Dense_Labels :: struct {
	widths: map[u64]f32,   // a label's width with its inset, in its text's ems, by its text's hash
	column: f32,           // the last build's column, ems (0: no build yet)
	next:   f32,           // this build's so far
}

DENSE_LABEL_MIN_EM :: 2.5
DENSE_LABEL_MAX_EM :: 11
// The column before a build has measured one.
@(private = "file") DENSE_LABEL_FIRST_EM :: 6

dense_labels_begin :: proc(l: ^Dense_Labels) { l.next = 0 }

// (a column that moved asks for the next build: an idle window kept the first build's guess, its labels cut)
dense_labels_end :: proc(l: ^Dense_Labels) {
	if l.next > 0 && l.next != l.column {
		l.column = l.next
		keep_animating()
	}
}

dense_labels_destroy :: proc(l: ^Dense_Labels) { delete(l.widths); l^ = {} }

// The width of the labels' column for a row of `label` moved in by `indent` pixels (its sections'): the column less the
// indent, so that every depth's fields start on one edge. Counts the label toward the next build's column.
dense_label_column :: proc(l: ^Dense_Labels, label: string, indent: f32 = 0) -> f32 {
	st := top_style()
	em := max(st.font_size, 1)
	h := hash_bytes(transmute([]u8)label)
	w, ok := l.widths[h]
	if !ok {
		w = (text_width(st.font, st.font_size, label) + 2 * st.text_pad) / em
		l.widths[h] = w
	}
	l.next = max(l.next, min(w + indent / em, DENSE_LABEL_MAX_EM))
	col := l.column > 0 ? l.column : DENSE_LABEL_FIRST_EM
	return max(math.ceil(max(col, DENSE_LABEL_MIN_EM) * em - indent), math.ceil(em))
}

// A theme's weak ink is made for text at the theme's size: at a dense size, it still reads on the ground it lies on
// (WCAG AA, 4.5), moved away from that ground as far as it must.
@(private = "file")
dense_readable :: proc(b: ^Box) {
	for g := b.parent; g != nil; g = g.parent {
		if .Draw_Background in g.flags { b.target_text = readable(b.target_text, g.target_bg, 4.5); return }
	}
}

// A collapsible header: a chevron and `label` on a row of dense_row_height (under a dense scope; a control's height
// otherwise), its open state the caller's `open^`. A click, Enter or Space opens or closes it; Right opens it, Left
// closes it. True while it is open: build what it holds then. A screen reader sees a button, expanded or not.
tree_header :: proc(id, label: string, open: ^bool) -> bool {
	em := font_size()
	set_next_axis(.X, .Center)
	s := gs()
	s.next_mod.width = fill()
	s.next_mod.height = px(dense_shown() ? dense_row_height() : control_height())
	// (a ground of the well's colour: the header reads as the head of what it holds, in every theme)
	s.next_mod.bg = color("well")
	b := build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Draw_Focus_Ring, .Draw_Side_Bottom}, id)
	b.cursor = .Arrow
	if parent(b) {
		icon(open^ ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, math.round(em * 1.3), icon_font = lucide_icons())
		next({width = fill(), height = pct(1)})
		build_box({.Draw_Text}, fmt.tprintf("%s###title", label))
	}
	sig := signal(b)
	if sig.clicked { open^ = !open^ }
	if sig.focused {
		if open^ && key_press(.Left) { open^ = false }
		if !open^ && key_press(.Right) { open^ = true }
	}
	a11y_default(b, {role = .Button, name = label, expanded = open^})
	return open^
}
