package ui

// The rubber band (src/md/features/view-modes.md): a press on the empty part of a view of items, then a drag, selects
// every item the rectangle touches; with Ctrl the items are added to the selection there was. Ctrl and a press on an
// item start it too (item_band_begin): from a selected item it takes the items it touches out of the selection, from
// another it adds them. Escape gives the selection there was back (item_band_cancel). The rectangle is kept in the
// view's content (it scrolls with the items) and drawn over them in a floating box.
//
// Any view of items uses it: a Table in each of its views, a program's own grid. It reads where the items are from an
// Item_Band_Layout and changes an Item_Selection over Item_Rows; it tests only the items the rectangle may touch. It
// leaves the rows that cannot be selected (Item_Rows.selectable) as they are, and tells `changed` each row it changes.

import "core:math"

// How the items are laid out in the content of the box the band is drawn over.
Item_Band_Kind :: enum u8 {
	Rows,      // one item a row of `vl` (a list)
	Grid,      // `count` items a row of `vl`, each `item_w` wide, `gap` between them and before the first
	Columns,   // `count` items a column, columns `step` wide, each item `item_w` wide and `row_h` high
}

Item_Band_Layout :: struct {
	kind:   Item_Band_Kind,
	vl:     ^Virtual_List,   // Rows, Grid: the list whose rows hold the items (their tops: vlist_row_top)
	count:  int,
	item_w: f32,
	gap:    f32,
	step:   f32,
	row_h:  f32,
}

// A row went in (`now_selected`) or out of the selection by the band: called once per change, as it happens.
Item_Band_Changed :: #type proc(user: rawptr, row: int, now_selected: bool)

Item_Band :: struct {
	// the program's: told each row the band changes (nil: none), for a sum it keeps over the selection
	changed:  Item_Band_Changed,
	user:     rawptr,
	active:   bool,
	start:    Vec2,                // where it started, in the box's content
	base:     map[u64]struct{},    // the selection at the press, by identity (Ctrl adds to it; Escape gives it back)
	removing: bool,                // the items it touches leave the selection (Ctrl and a press on a selected item)
	keeping:  bool,                // the selection at the press stays (Ctrl); else the items it touches alone are selected
	// the items it could touch at the last frame [lo, hi): a frame visits those and the ones it may touch now, not
	// every item
	lo, hi:   int,
}

item_band_destroy :: proc(b: ^Item_Band) {
	delete(b.base)
	b^ = {}
}

// Row `i` in the selection or not, the program told when it changed.
@(private = "file")
item_band_set :: proc(b: ^Item_Band, sel: ^Item_Selection, rows: Item_Rows, i: int, on: bool) {
	if item_selection_has(sel, rows, i) == on { return }
	item_selection_set(sel, rows, i, on)
	if b.changed != nil { b.changed(b.user, i, on) }
}

// Ctrl and a press on an item of `box`: a band from there, its items taken out of the selection when that item was in
// it (`removing`). Call it before the press toggles the item: the base is the selection there was.
item_band_begin :: proc(b: ^Item_Band, box: ^Box, sel: ^Item_Selection, removing: bool) {
	if box == nil { return }
	b.active, b.removing, b.keeping, b.lo, b.hi = true, removing, true, 0, 0
	b.start = mouse_pos() - box.rect.min + box.view_off
	item_band_keep_base(b, sel)
}

@(private = "file")
item_band_keep_base :: proc(b: ^Item_Band, sel: ^Item_Selection) {
	clear(&b.base)
	for id in sel.selected { b.base[id] = {} }
}

// After the items of `box` are built: a band starts (a press on `box` itself, or `pressed_empty`: on an empty part that
// is a box of its own, between a grid's cards), follows the pointer, or ends with the press. `pressed_item`: an item
// took the press (no band). `id`: the rectangle's box. Whether a band is running.
item_band_update :: proc(b: ^Item_Band, sel: ^Item_Selection, rows: Item_Rows, box: ^Box, layout: Item_Band_Layout, pressed_item: bool, pressed_empty := false, id := "###item_band") -> (running: bool) {
	if box == nil || !sel.multi { return }
	sig := signal(box)
	m := mouse_pos()
	content := m - box.rect.min + box.view_off
	if (sig.pressed || pressed_empty) && !pressed_item && !b.active {
		b.active, b.start, b.removing, b.keeping, b.lo, b.hi = true, content, false, .Ctrl in gs().mods, 0, 0
		item_band_keep_base(b, sel)
		if !b.keeping {
			if b.changed != nil && len(sel.selected) > 0 {
				// (row by row, so the program is told each: one pass over the rows, once per gesture)
				for i in 0 ..< rows.count { item_band_set(b, sel, rows, i, false) }
			}
			item_selection_clear(sel)
		}
	}
	if !b.active { return }
	// (the press let go: the band ends; a Shift range after it starts from the cursor, over what the band selected)
	if active_key() == 0 {
		b.active = false
		sel.anchored = false
		return
	}
	drag_autoscroll(box.key)
	x0, x1 := min(b.start.x, content.x), max(b.start.x, content.x)
	y0, y1 := min(b.start.y, content.y), max(b.start.y, content.y)
	lo, hi := item_band_items(layout, rows.count, x0, x1, y0, y1)
	from, to := min(lo, b.lo), max(hi, b.hi)
	if b.lo == b.hi { from, to = lo, hi }
	b.lo, b.hi = lo, hi
	for i in from ..< to {
		// (a row that cannot be selected is not an item, a folded group's title: the band leaves it as it is)
		if !item_rows_selectable(rows, i) { continue }
		touched := item_band_touches(layout, i, x0, x1, y0, y1)
		was := b.keeping && item_rows_id(rows, i) in b.base
		on := b.removing ? was && !touched : was || touched
		item_band_set(b, sel, rows, i, on)
		if touched && sel.sel != i {
			sel.sel = i
			sel.version += 1
		}
	}
	// the rectangle, on screen, within the box
	a := b.start - box.view_off + box.rect.min
	r := Rect{{max(min(a.x, m.x), box.rect.min.x), max(min(a.y, m.y), box.rect.min.y)}, {min(max(a.x, m.x), box.rect.max.x), min(max(a.y, m.y), box.rect.max.y)}}
	parent := parent_box()
	accent := color("accent")
	next({width = px(max(r.max.x - r.min.x, 1)), height = px(max(r.max.y - r.min.y, 1)), bg = accent * {1, 1, 1, 0.18}, border = accent, radius = 0})
	rect_box := build_box({.Floating_X, .Floating_Y, .Draw_Background, .Draw_Border}, id)
	rect_box.fixed_pos = r.min - parent.rect.min
	return true
}

// Escape during a band: the selection there was before it (a pass over the items: a gesture, not a frame). False when
// no band runs: the Escape is someone else's.
item_band_cancel :: proc(b: ^Item_Band, sel: ^Item_Selection, rows: Item_Rows) -> bool {
	if !b.active { return false }
	b.active = false
	// (by identity: the items the band's frames touched or not stay right)
	for i in 0 ..< rows.count { item_band_set(b, sel, rows, i, item_rows_id(rows, i) in b.base) }
	return true
}

// Whether item `i` is in the rectangle (x0, y0)-(x1, y1) of the content.
@(private = "file")
item_band_touches :: proc(g: Item_Band_Layout, i: int, x0, x1, y0, y1: f32) -> bool {
	switch g.kind {
	case .Rows:
		if g.vl == nil || i >= len(g.vl.ids) { return false }
		return vlist_row_top(g.vl, i + 1) > y0 && vlist_row_top(g.vl, i) < y1
	case .Grid:
		// (a card: its column's span, its row's less the gap around it)
		per := max(g.count, 1)
		r, c := i / per, i % per
		if g.vl == nil || r >= len(g.vl.ids) { return false }
		ix0 := g.gap + f32(c) * (g.item_w + g.gap)
		iy0, iy1 := vlist_row_top(g.vl, r) + g.gap * 0.5, vlist_row_top(g.vl, r + 1) - g.gap * 0.5
		return ix0 + g.item_w > x0 && ix0 < x1 && iy1 > y0 && iy0 < y1
	case .Columns:
		per := max(g.count, 1)
		c, r := i / per, i % per
		ix0, iy0 := f32(c) * g.step, f32(r) * g.row_h
		return ix0 + g.item_w > x0 && ix0 < x1 && iy0 + g.row_h > y0 && iy0 < y1
	}
	return false
}

// The items [lo, hi) a rectangle may touch: the rows found by halves in the list's tops (each O(log n)), or the columns
// by their width.
@(private = "file")
item_band_items :: proc(g: Item_Band_Layout, n: int, x0, x1, y0, y1: f32) -> (lo, hi: int) {
	// the first row whose bottom is under y, or whose top is past it
	first_after :: proc(vl: ^Virtual_List, lines: int, y: f32, top: bool) -> int {
		a, z := 0, lines
		for a < z {
			m := (a + z) / 2
			v := vlist_row_top(vl, top ? m : m + 1)
			if (top && v < y) || (!top && v <= y) { a = m + 1 } else { z = m }
		}
		return a
	}
	switch g.kind {
	case .Rows:
		if g.vl == nil { return }
		lines := min(n, len(g.vl.ids))
		if lines <= 0 { return }
		return first_after(g.vl, lines, y0, false), first_after(g.vl, lines, y1, true)
	case .Grid:
		if g.vl == nil { return }
		per := max(g.count, 1)
		lines := min((n + per - 1) / per, len(g.vl.ids))
		if lines <= 0 { return }
		a, z := first_after(g.vl, lines, y0, false), first_after(g.vl, lines, y1, true)
		return min(a * per, n), min(z * per, n)
	case .Columns:
		if g.step <= 0 { return 0, n }
		per := max(g.count, 1)
		a := max(int(math.floor(x0 / g.step)), 0)
		z := int(x1 / g.step) + 1
		return min(a * per, n), min(z * per, n)
	}
	return 0, n
}
