package ui

// A row of equal cells of which only those in view are built (docs/cell-row.md; its reasons:
// src/md/features/cell-row.md): a folder's pictures under a viewer, a film's frames, a long row of swatches. A row of
// ten thousand cells builds the same few as a row of ten: each is placed at its own x (fixed_x), and the cells before and
// after the view are not built at all. The chosen cell stays in the middle while the person does not scroll; the wheel
// moves the row and it stays where the person put it until another cell is chosen.
//
//   if cells, ok := ui.cell_row("###strip", &app.strip, len(pictures), {cell = side, gap = gap, chosen = app.index}); ok {
//       for i in cells.first ..< cells.last {
//           ui.cell_row_next(&app.strip, i)
//           cell := ui.build_box({.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###cell%d", pictures[i].id))
//           if ui.signal(cell).clicked { go_to(app, i) }
//       }
//   }
//
// The implicit state machine: Following (the view goes to the chosen cell, eased) -> a wheel -> Free (the view stays
// where the wheel put it) -> another chosen cell -> Following. A count that shrinks clamps the view.

import "core:math"

// How fast the view follows (halvings of the distance a second), and the cells a wheel notch moves.
CELL_ROW_RATE :: 18.0
CELL_ROW_WHEEL_CELLS :: 2.0

// The program's: where the row is, kept between builds.
Cell_Row :: struct {
	scroll:   f32,    // the view's start in the row, logical pixels from its left edge: where it goes
	followed: int,    // the chosen cell the view last went to (+1: 0 is none yet)
	free:     bool,   // the wheel moved it: it stays there until another cell is chosen
	// (this build's: what cell_row_next places by)
	shown:    f32,    // where the view is drawn this build (eased toward scroll)
	pitch:    f32,    // a cell and its gap
	cell:     f32,
	gap:      f32,
	height:   f32,
}

Cell_Row_Options :: struct {
	cell:        f32,   // a cell's width, logical pixels; its height is the row's less a gap above and below
	gap:         f32,   // between cells, and around them
	chosen:      int,   // the cell kept in the middle (-1: none)
	rate:        f32,   // how fast the view follows (0: CELL_ROW_RATE)
	wheel_cells: f32,   // cells a notch of the wheel moves (0: CELL_ROW_WHEEL_CELLS)
}

// The cells to build this build: first ..< last. (count and chosen: what cell_row_end tells a screen reader)
Cell_Range :: struct { first, last, count, chosen: int }

// `if cells, ok := cell_row(id, st, count, o); ok { ... }`: the row's box (width: fill, height: a cell and two gaps,
// unless next says otherwise) and the cells in view. Build one box per cell, each after cell_row_next, nothing else in
// the row: a screen reader is told each box's place in the whole row by its order. ok is false while the row has never
// been laid out (its first build: a next build comes at once) or has no cell.
@(deferred_out = cell_row_end)
cell_row :: proc(id: string, st: ^Cell_Row, count: int, o: Cell_Row_Options) -> (cells: Cell_Range, ok: bool) {
	s := gs()
	st.cell, st.gap = max(o.cell, 1), max(o.gap, 0)
	st.pitch = st.cell + st.gap
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = px(st.cell + 2 * st.gap) }
	s.next_mod, s.has_next = m, true
	b := build_box({.Clip, .Clickable, .Scroll_Self}, id)
	// (the last layout's size: the first build has none, and builds no cell)
	width := b.rect.max.x - b.rect.min.x
	st.height = b.rect.max.y - b.rect.min.y
	total := f32(count) * st.pitch + st.gap
	most := max(0, total - width)
	chosen := o.chosen
	if chosen >= count { chosen = -1 }
	// (Following -> Free by the wheel; Free -> Following when another cell is chosen)
	if st.followed != chosen + 1 { st.free, st.followed = false, chosen + 1 }
	if !st.free && chosen >= 0 { st.scroll = f32(chosen) * st.pitch + st.gap + st.cell / 2 - width / 2 }
	sig := signal(b)
	if sig.scrolled != {} {
		d := sig.scrolled.y != 0 ? sig.scrolled.y : sig.scrolled.x
		notch := o.wheel_cells > 0 ? o.wheel_cells : CELL_ROW_WHEEL_CELLS
		st.scroll += d * st.pitch * notch
		st.free = true
	}
	st.scroll = clamp(st.scroll, 0, most)
	rate := o.rate > 0 ? o.rate : CELL_ROW_RATE
	st.shown = clamp(anim(key_from_string(b.key, "cell_row_view"), st.scroll, rate), 0, most)
	if width <= 0 {
		// (laid out after this build: the next one builds the cells)
		if count > 0 { wake_within(s, 1) }
		return
	}
	if count == 0 { return }
	cells.first = clamp(int(math.floor((st.shown - st.gap) / st.pitch)), 0, count)
	cells.last = clamp(int(math.floor((st.shown + width) / st.pitch)) + 1, cells.first, count)
	cells.count, cells.chosen = count, chosen
	a11y_default(b, {role = .List_Box, orientation = Axis.X})
	// (a cell out of view is not built: a focused one keeps the focus there, as in a virtual list)
	s.virtual_depth += 1
	push_parent(b)
	return cells, true
}

@(private)
cell_row_end :: proc(cells: Cell_Range, ok: bool) {
	if !ok { return }
	s := gs()
	s.virtual_depth -= 1
	// (only the cells in view are built: each says its place in the whole row and the row's count, "5001 of 10000")
	i := cells.first
	for c := parent_box().first; c != nil; c = c.next {
		a11y_default(c, {role = .List_Box_Option, position = i + 1, set_size = cells.count, selected = i == cells.chosen})
		i += 1
	}
	pop_parent()
}

// The next box built is cell `i` of the row, at its place.
cell_row_next :: proc(st: ^Cell_Row, i: int) {
	x := f32(i) * st.pitch + st.gap - st.shown
	next({fixed_x = x, fixed_y = st.gap, fixed_w = st.cell, fixed_h = max(st.height - 2 * st.gap, 1)})
}

// Where cell `i` starts in the row, logical pixels (a test, a program that draws over the row).
cell_row_left :: proc(st: ^Cell_Row, i: int) -> f32 { return f32(i) * st.pitch + st.gap }

