package ui

// A list of items the user reorders by dragging, along X (a row of tabs) or Y (a column of rows), with the others
// sliding out of the way. The geometry is pure and independent of the axis (positions are along it):
//   * reorder_item_size: an equal share of the room between a minimum and a maximum (past the minimum the list scrolls);
//   * reorder_offset: the scroll kept in range, following the current item when it changes;
//   * reorder_slot: where a dragged item belongs (the slot its middle is over); list_move moves it there;
//   * reorder_edge_scroll: an item held past an edge of the view scrolls the list;
//   * reorder_visible: which items show (with a margin), so a long scrolling list builds only those.
// Reorder is the drag's state (one per list or per family of lists that never drag at once): reorder_frame ends a
// drag when the button went up, reorder_begin starts one past a threshold, reorder_item_pos gives each item its place
// (its slot's, animated when items move; the dragged one follows the pointer).

import "core:math"

Reorder :: struct {
	id:     u64,    // the item under a drag (0: none)
	active: bool,   // ... and it moved past the threshold
	grab:   f32,    // where the pointer holds it: pointer minus the item's leading edge, at the press
}

// The size of each of `n` items sharing `avail`: an equal share between `min_size` and `max_size` (the maximum wins
// when they cross).
reorder_item_size :: proc(avail: f32, n: int, min_size, max_size: f32) -> f32 {
	if n <= 0 { return max_size }
	return clamp(avail / f32(n), min(min_size, max_size), max_size)
}

// The scroll of a list of `n` items `pitch` apart shown in `view`: kept in range and, when `follow` (the current item
// changed), moved just enough to show item `current` whole.
reorder_offset :: proc(offset: f32, n: int, pitch, view: f32, current: int, follow: bool) -> f32 {
	limit := max(f32(n) * pitch - view, 0)
	o := offset
	if follow && current >= 0 && current < n {
		lead := f32(current) * pitch
		if lead < o { o = lead }
		if lead + pitch > o + view { o = lead + pitch - view }
	}
	return clamp(o, 0, limit)
}

// The items of a list scrolled by `offset` that show in `view` (`pitch` apart, `n` of them), and `margin` more on
// either side: the half-open range [first, last). A list that scrolls (more items than fit) builds only these, not all
// `n`, so a frame's cost stays flat whatever the list's length.
reorder_visible :: proc(offset, view, pitch: f32, n, margin: int) -> (first, last: int) {
	if n <= 0 || pitch <= 0 { return 0, 0 }
	first = clamp(int(math.floor(offset / pitch)) - margin, 0, n)
	last = clamp(int(math.ceil((offset + view) / pitch)) + margin, first, n)
	return
}

// The slot of an item whose leading edge is at `pos` (list coordinates, scroll included): the one its middle is over.
reorder_slot :: proc(pos, pitch: f32, n: int) -> int {
	if n <= 0 || pitch <= 0 { return 0 }
	return clamp(int(math.floor((pos + pitch * 0.5) / pitch)), 0, n - 1)
}

// Moves the element at `from` to `to`, shifting those between; returns where the element at `current` went.
list_move :: proc(list: []$T, from, to, current: int) -> int {
	if from == to || from < 0 || to < 0 || from >= len(list) || to >= len(list) { return current }
	v := list[from]
	if from < to { copy(list[from:to], list[from + 1:to + 1]) } else { copy(list[to + 1:from + 1], list[to:from]) }
	list[to] = v
	switch {
	case current == from: return to
	case from < current && current <= to: return current - 1
	case to <= current && current < from: return current + 1
	}
	return current
}

// The scroll target that shows an item held at `pos` (`size` long) when it is past an edge of the view (`view_off`,
// `view`); `target` otherwise. `limit`: the largest scroll.
reorder_edge_scroll :: proc(pos, size, view_off, view, limit, target: f32) -> f32 {
	if pos < view_off { return clamp(pos, 0, limit) }
	if pos + size > view_off + view { return clamp(pos + size - view, 0, limit) }
	return target
}

// How far a press has moved for the threshold: along the axis, and across it too when `across` (a gesture of its own
// starts that way, such as dragging an item out of its list).
reorder_moved :: proc(delta: Vec2, axis: Axis, across: bool) -> f32 {
	along, other := axis == .X ? abs(delta.x) : abs(delta.y), axis == .X ? abs(delta.y) : abs(delta.x)
	return max(along, across ? other : 0)
}

// Ends the drag once the left button is up (wherever it went up). Once per frame, before the items.
reorder_frame :: proc(r: ^Reorder) {
	if active_key() == 0 { r.id, r.active = 0, false }
}

reorder_dragging :: proc(r: ^Reorder, id: u64) -> bool { return r.active && r.id == id }

// Starts dragging item `id` when the press moved more than `threshold` (`moved`: reorder_moved); `press` and `slot`:
// where the press and the item's leading edge were, in the coordinates reorder_item_pos is given.
reorder_begin :: proc(r: ^Reorder, id: u64, moved, threshold, press, slot: f32) -> bool {
	if r.active || moved <= threshold { return false }
	r.active, r.id = true, id
	r.grab = press - slot
	return true
}

// The place of item `id` along the axis: its `slot`, animated (`key` keeps the animation; `rate` as `anim`), or, while
// it is dragged, the pointer less the grab, within `lo` .. `hi` (the release then slides from there).
reorder_item_pos :: proc(r: ^Reorder, key: Key, id: u64, slot, pointer, lo, hi: f32, rate: f32 = 30) -> (pos: f32, dragging: bool) {
	if r.active && r.id == id {
		pos = clamp(pointer - r.grab, lo, hi)
		_ = anim(key, pos, rate, pos)
		return pos, true
	}
	return math.round(anim(key, slot, rate, slot)), false
}
