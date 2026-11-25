package ui

// The rubber band (src/md/features/view-modes.md): a press on the empty part of a view of items, then a drag, selects
// every item the rectangle touches; with Ctrl the items are added to the selection there was. Ctrl and a press on an
// item start it too (item_band_begin): from a selected item it takes the items it touches out of the selection, from
// another it adds them. A pointer press on the empty part of a full-width row (Item_Band_Press, item_band_row_press)
// stays pending until the pointer passes platform.drag_threshold (starts the band) or releases cleanly (selects the
// row as a normal click). Escape restores the prior selection (item_band_cancel). The rectangle is kept in the view's
// content (it scrolls with the items) and drawn inside `box` in a floating child box.
//
// Any view of items uses it: a Table in each of its views, or a program's own list or grid. It reads item geometry
// from Item_Band_Layout and updates Item_Selection over Item_Rows; each frame tests only the items the rectangle
// touches and those it touched on the previous frame. It leaves unselectable rows (Item_Rows.selectable) unchanged and
// notifies `changed` once per row that enters or leaves the selection.

import "core:math"
import "../draw"
import "../platform"

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

// A pointer press on the empty part of a row, held until the pointer either passes the drag threshold (starts a band)
// or releases cleanly (selects the row as a normal click).
Item_Band_Press :: struct {
	active:   bool,
	row:      int,
	key:      Key,
	mods:     platform.Modifiers,
	selected: bool,
}

Item_Band :: struct {
	// The program's callback: told each row the band changes (nil: none), for a running sum over the selection.
	changed:      Item_Band_Changed,
	user:         rawptr,
	active:       bool,
	pending:      bool,                // pointer held on the empty part of a row, waiting for drag threshold or release
	start:        Vec2,                // where the band started, in `box`'s content coordinates
	press_pos:    Vec2,                // window coordinates at the press (for drag threshold checks)
	base:         map[u64]struct{},    // the selection at the press, by identity (Ctrl adds/removes; Escape restores)
	removing:     bool,                // touched items leave the selection (Ctrl+drag from a selected item)
	keeping:      bool,                // base selection stays (Ctrl); else only touched items stay selected
	from_item:    bool,                // started by item_band_begin (Ctrl+press on an item): keeps anchor on click without drag
	dragged:      bool,                // pointer moved past drag_threshold since press
	// Items the band touched on the last frame [lo, hi): each frame visits the union of last and current ranges.
	lo, hi:       int,
	// Pending empty-part row press state.
	pending_row:      int,
	pending_id:       u64,
	pending_key:      Key,
	pending_mods:     platform.Modifiers,
	pending_selected: bool,
}

item_band_destroy :: proc(b: ^Item_Band) {
	delete(b.base)
	b^ = {}
}

// Builds an Item_Band_Press when `sig` is a left pointer press on the empty part of `row` (excluding double clicks).
// `selected`: whether `row` was selected before the press. `empty`: List_State.pressed_empty or !row_content_at.
item_band_row_press :: proc(row: int, sig: Signal, selected, empty: bool) -> Item_Band_Press {
	if !empty || !sig.pointer_pressed || sig.double_clicked || sig.box == nil { return {} }
	return {active = true, row = row, key = sig.box.key, mods = sig.mods, selected = selected}
}

// Whether window point `p` hits interactive or visible content inside `row` (icon, text, control, visual leaf) rather
// than empty space (right of text, cell padding, empty cells, spacers). Reads the rects and the text widths of the last
// layout, measures nothing. Walks only `row`'s children so the row's own pill or stripe never counts. Call it before the
// build makes `row` again (prev_box): a box made again has no children yet.
row_content_at :: proc(row: ^Box, p: Vec2) -> bool {
	if row == nil || !draw.rect_contains(row.rect, p) { return false }
	return row_content_walk(row, p, row.rect, row.last_build)
}

@(private = "file")
row_content_walk :: proc(parent: ^Box, p: Vec2, clip: Rect, build: u64) -> bool {
	for c := parent.first; c != nil; c = c.next {
		if c.last_build != build || .Gap in c.flags { continue }
		if c.rect.max.x <= c.rect.min.x || c.rect.max.y <= c.rect.min.y { continue }
		cc := clip
		if .Clip in c.flags {
			cc = {{max(clip.min.x, c.rect.min.x), max(clip.min.y, c.rect.min.y)}, {min(clip.max.x, c.rect.max.x), min(clip.max.y, c.rect.max.y)}}
			if !draw.rect_contains(cc, p) { continue }
		}
		if .Clickable in c.flags {
			if box_contains(c, p) && draw.rect_contains(clip, p) { return true }
			continue
		}
		if c.custom == rich_draw {
			// Single-line cells inside a horizontal parent span the parent's full row height vertically.
			y_rect := parent.layout_axis == .X ? parent.rect : c.rect
			if text_span_contains(c, p, cc, y_rect) { return true }
			continue
		}
		if .Draw_Text in c.flags {
			// Fixed-width non-truncating glyph cells (ui.icon) count as content across their full cell rect.
			if .No_Text_Trunc in c.flags && c.pref[.X].kind == .Pixels {
				if box_contains(c, p) && draw.rect_contains(cc, p) { return true }
			} else if text_span_contains(c, p, cc, c.rect) {
				return true
			}
			if c.first != nil && row_content_walk(c, p, cc, build) { return true }
			continue
		}
		if c.first == nil {
			if (c.custom != nil || .Draw_Background in c.flags) && box_contains(c, p) && draw.rect_contains(cc, p) { return true }
			continue
		}
		if row_content_walk(c, p, cc, build) { return true }
	}
	return false
}

// Whether `p` lies within `c`'s rendered horizontal text span (aligned inside text_pad), clipped to `clip` and
// vertically within `y_rect`.
@(private = "file")
text_span_contains :: proc(c: ^Box, p: Vec2, clip, y_rect: Rect) -> bool {
	text_w := c.custom == rich_draw ? c.rich_width : c.text_dim.x
	if text_w <= 0 || p.y < max(y_rect.min.y, clip.min.y) || p.y >= min(y_rect.max.y, clip.max.y) { return false }
	avail := max(0, (c.rect.max.x - c.rect.min.x) - 2 * c.text_pad)
	w := min(text_w, avail)
	if w <= 0 { return false }
	x0: f32
	switch c.text_align {
	case .Left:   x0 = c.rect.min.x + c.text_pad
	case .Center: x0 = (c.rect.min.x + c.rect.max.x) * 0.5 - w * 0.5
	case .Right:  x0 = c.rect.max.x - c.text_pad - w
	}
	lo := max(x0, clip.min.x)
	hi := min(x0 + w, clip.max.x)
	return p.x >= lo && p.x < hi
}

// Scroll offset subtracted by layout_positions from children of `box` (only along scrolling axes).
@(private = "file")
item_band_scroll_off :: proc(box: ^Box) -> Vec2 {
	return {box_scrolls(box, .X) ? box.view_off.x : 0, box_scrolls(box, .Y) ? box.view_off.y : 0}
}

// Visible content area inside `box` (inside its border and clear of its scroll bars) and its content origin.
@(private = "file")
item_band_view_rect :: proc(box: ^Box) -> (view: Rect, origin: Vec2) {
	inset := border_inset(box)
	sx0, sx1 := bar_room_ends(box, .X)
	sy0, sy1 := bar_room_ends(box, .Y)
	lead := Vec2{inset + sx0, inset + sy0}
	trail := Vec2{inset + sx1, inset + sy1}
	origin = box.rect.min + lead
	view = {origin, {max(origin.x, box.rect.max.x - trail.x), max(origin.y, box.rect.max.y - trail.y)}}
	return
}

// Whether `key` received a normal left release this frame (not a lost release from focus loss or touch cancel).
@(private = "file")
item_band_release_clean :: proc(s: ^State, key: Key) -> bool {
	if s.released_key[.Left] != key { return false }
	for e in s.mouse_events {
		if e.kind == .Mouse_Release && e.button == .Left && !e.lost { return true }
	}
	return false
}

// Row `i` in the selection or not, the program told when it changed.
@(private = "file")
item_band_set :: proc(b: ^Item_Band, sel: ^Item_Selection, rows: Item_Rows, i: int, on: bool) {
	if item_selection_has(sel, rows, i) == on { return }
	item_selection_set(sel, rows, i, on)
	if b.changed != nil { b.changed(b.user, i, on) }
}

// Clears `sel` before a fresh band, notifying `b.changed` per row when set.
@(private = "file")
item_band_clear :: proc(b: ^Item_Band, sel: ^Item_Selection, rows: Item_Rows) {
	if b.changed != nil && len(sel.selected) > 0 {
		// Row by row so the caller's running total stays exact (once per gesture).
		for i in 0 ..< rows.count { item_band_set(b, sel, rows, i, false) }
	}
	item_selection_clear(sel)
}

// Applies a deferred click on row `i` and notifies `b.changed` for every row whose membership changed.
@(private = "file")
item_band_click_apply :: proc(b: ^Item_Band, sel: ^Item_Selection, rows: Item_Rows, i: int, mods: platform.Modifiers) {
	if !item_rows_selectable(rows, i) { return }
	if b.changed == nil {
		item_selection_click(sel, rows, i, mods)
		return
	}
	item_band_keep_base(b, sel)
	item_selection_click(sel, rows, i, mods)
	for k in 0 ..< rows.count {
		id := item_rows_id(rows, k)
		was := id in b.base
		now := id in sel.selected
		if was != now { b.changed(b.user, k, now) }
	}
}

// Ctrl and a press on an item of `box`: starts a band from there, taking touched items out when that item was in the
// selection (`removing`). Call before the press toggles the item so the base records the prior selection.
item_band_begin :: proc(b: ^Item_Band, box: ^Box, sel: ^Item_Selection, removing: bool) {
	if box == nil { return }
	s := gs()
	off := item_band_scroll_off(box)
	_, origin := item_band_view_rect(box)
	pos := active_key() != 0 ? s.press_pos[.Left] : mouse_pos()
	b.pending = false
	b.active, b.removing, b.keeping, b.from_item, b.dragged, b.lo, b.hi = true, removing, true, true, false, 0, 0
	b.press_pos = pos
	b.start = pos - origin + off
	item_band_keep_base(b, sel)
	// Transfer press ownership to `box` so boxes_gone does not cancel the band when the pressed item scrolls out.
	_ = press_hand(active_key(), box.key)
}

@(private = "file")
item_band_keep_base :: proc(b: ^Item_Band, sel: ^Item_Selection) {
	clear(&b.base)
	for id in sel.selected { b.base[id] = {} }
}

// After the items of `box` are built: handles a pending empty-part row press (`row_press`), starts a band on empty
// space (`box` itself or `pressed_empty`), tracks the drag, draws the rectangle inside `box`, or ends on release.
// `pressed_item`: an item took the press (no empty-space band). `id`: the rectangle's box id. Returns whether a band
// is active.
item_band_update :: proc(
	b: ^Item_Band,
	sel: ^Item_Selection,
	rows: Item_Rows,
	box: ^Box,
	layout: Item_Band_Layout,
	pressed_item: bool,
	pressed_empty := false,
	id := "###item_band",
	row_press := Item_Band_Press{},
) -> (running: bool) {
	if box == nil || !sel.multi {
		b.pending, b.active = false, false
		return
	}
	s := gs()
	ver_before := sel.version
	// Rows were built before item_band_update: request another frame whenever selection changes so they repaint.
	defer if sel.version != ver_before { s.anim_busy = true }

	sig := signal(box)
	m := mouse_pos()
	off := item_band_scroll_off(box)
	view, origin := item_band_view_rect(box)
	content := m - origin + off
	th := platform.drag_threshold(s.window)

	if row_press.active && !b.active {
		b.pending = true
		b.pending_row = row_press.row
		b.pending_id = item_rows_id(rows, row_press.row)
		b.pending_key = row_press.key
		b.pending_mods = row_press.mods
		b.pending_selected = row_press.selected
		b.press_pos = s.press_pos[.Left]
		b.start = b.press_pos - origin + off
	} else if b.pending && (pressed_item || sig.pointer_pressed || pressed_empty) {
		b.pending = false
	}

	if b.pending {
		if active_key() == b.pending_key {
			if abs(m.x - b.press_pos.x) >= th.x || abs(m.y - b.press_pos.y) >= th.y {
				b.pending = false
				b.active = true
				b.from_item = false
				b.dragged = true
				b.keeping = .Ctrl in b.pending_mods
				b.removing = .Ctrl in b.pending_mods && .Shift not_in b.pending_mods && b.pending_selected
				b.lo, b.hi = 0, 0
				item_band_keep_base(b, sel)
				if !b.keeping { item_band_clear(b, sel, rows) }
				// A press that turned into a band drag is not the first click of a double click.
				s.last_click_key = 0
				_ = press_hand(b.pending_key, box.key)
			} else {
				return false
			}
		} else {
			key := b.pending_key
			row, row_id, mods := b.pending_row, b.pending_id, b.pending_mods
			b.pending = false
			if item_band_release_clean(s, key) {
				if row < 0 || row >= rows.count || item_rows_id(rows, row) != row_id { row = item_rows_find(rows, row_id) }
				if row >= 0 && item_rows_selectable(rows, row) {
					item_band_click_apply(b, sel, rows, row, mods)
				}
			}
			return false
		}
	}

	if (sig.pointer_pressed || pressed_empty) && !pressed_item && !b.active {
		b.active, b.start, b.removing, b.keeping, b.from_item, b.dragged, b.lo, b.hi = true, content, false, .Ctrl in s.mods, false, false, 0, 0
		b.press_pos = active_key() != 0 ? s.press_pos[.Left] : m
		item_band_keep_base(b, sel)
		if !b.keeping { item_band_clear(b, sel, rows) }
		_ = press_hand(active_key(), box.key)
	}
	if !b.active { return }
	// Release ends the band; a subsequent Shift range starts from the cursor unless this was an unmoved Ctrl+click.
	// (every start hands the press to `box`: a press held by another box is a later one, of a band whose view was hidden
	// when its own was let go)
	if active_key() != box.key {
		b.active = false
		if !b.from_item || b.dragged { sel.anchored = false }
		b.from_item, b.dragged = false, false
		return
	}
	if !b.dragged && (abs(m.x - b.press_pos.x) >= th.x || abs(m.y - b.press_pos.y) >= th.y) {
		b.dragged = true
		s.last_click_key = 0
	}

	drag_autoscroll(box.key)
	x0, x1 := min(b.start.x, content.x), max(b.start.x, content.x)
	y0, y1 := min(b.start.y, content.y), max(b.start.y, content.y)
	lo, hi := item_band_items(layout, rows.count, x0, x1, y0, y1)
	from, to := min(lo, b.lo), max(hi, b.hi)
	if b.lo == b.hi { from, to = lo, hi }
	b.lo, b.hi = lo, hi
	for i in from ..< to {
		// Unselectable rows (for example, folded group headers) are not items: leave them unchanged.
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

	// Draw the rectangle inside `box` (last visual child: above items, clipped by `box`, under scroll bars and border).
	if !b.from_item || b.dragged {
		a := b.start - off + origin
		rx0, rx1 := min(a.x, m.x), max(a.x, m.x)
		ry0, ry1 := min(a.y, m.y), max(a.y, m.y)
		if rx1 > view.min.x && rx0 < view.max.x && ry1 > view.min.y && ry0 < view.max.y {
			r := Rect{{max(rx0, view.min.x), max(ry0, view.min.y)}, {min(rx1, view.max.x), min(ry1, view.max.y)}}
			pushed := parent_box() != box
			if pushed { push_parent(box) }
			defer if pushed { pop_parent() }
			accent := color("accent")
			next({width = px(max(r.max.x - r.min.x, 1)), height = px(max(r.max.y - r.min.y, 1)), bg = tuned(accent * {1, 1, 1, 0.18}), border = accent, radius = 0})
			rect_box := build_box({.Floating_X, .Floating_Y, .Draw_Background, .Draw_Border}, id)
			// layout_positions subtracts `off` from floating children: add `off` so rect_box lands at viewport `r.min`.
			rect_box.fixed_pos = r.min - box.rect.min + off
		}
	}
	return true
}

// Escape during a band or pending row press: restores the prior selection (one pass over items, once per gesture).
// Returns false when no band is active or pending so Escape stays available to other handlers.
item_band_cancel :: proc(b: ^Item_Band, sel: ^Item_Selection, rows: Item_Rows) -> bool {
	if b.pending {
		b.pending = false
		return true
	}
	if !b.active { return false }
	b.active, b.from_item, b.dragged = false, false, false
	ver := sel.version
	// Restore by identity so items touched on any frame return to their pre-band membership.
	for i in 0 ..< rows.count { item_band_set(b, sel, rows, i, item_rows_id(rows, i) in b.base) }
	if sel.version != ver { gs().anim_busy = true }
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
		// A card spans its column and its row minus the surrounding gap.
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

// The items [lo, hi) a rectangle can touch: rows found by binary search in the list's tops (O(log n)), or columns by
// their step width.
@(private = "file")
item_band_items :: proc(g: Item_Band_Layout, n: int, x0, x1, y0, y1: f32) -> (lo, hi: int) {
	// First row whose bottom is below y, or whose top is past y.
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
