package ui

// A list of items the user reorders by dragging, along X (a row of tabs) or Y (a column of rows), with the others
// sliding out of the way. The geometry is pure and independent of the axis (positions are along it):
//   * reorder_item_size: an equal share of the room between a minimum and a maximum (past the minimum the list scrolls);
//   * reorder_offset: the scroll kept in range, following the current item when it changes;
//   * reorder_slot: where a dragged item belongs (the slot its middle is over); list_move moves it there;
//   * reorder_edge_scroll: an item held past an edge of the view scrolls the list;
//   * reorder_visible: which items show (with a margin), so a long scrolling list builds only those.
// The drag is the press's (press_data), on the item's box: reorder_begin starts it past a threshold, reorder_item_pos
// gives each item its place (its slot's, animated when items move; the dragged one follows the pointer). An item is told
// by the key of its box, which is its list's too: lists whose items share ids drag apart. The drag ends with its press
// (the button went up, the item's box went, the user left the window): nothing to end, nothing kept by the app.

import "core:math"

// What the press of an item keeps while it drags it.
@(private = "file")
Reorder_Press :: struct {
	dragging: bool,
	grab:     f32,   // where the pointer holds it: pointer minus the item's leading edge, at the press
}

// The left button's press on box `item` (another button drags nothing); nil when it holds no such box.
@(private = "file")
reorder_press :: proc(item: Key) -> ^Reorder_Press {
	if item == 0 || active_key() != item { return nil }
	return press_data(Reorder_Press, item)
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
		o = view_reveal_offset(o, lead, lead + pitch, view)
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

// The slot of a dragged item among items of different sizes (a bar of bookmarks, of buttons). `sizes`: each item's size
// in the list's order, the dragged one at `current`; `origin`: the first item's leading edge; `gap`: the space between two
// items; `pos`: the dragged item's leading edge now. The item takes a neighbour's place as soon as its edge on that side
// goes `into` of the neighbour's size inside it, and `hysteresis` further: with the middles' rule of reorder_slot, a
// narrow item had to pass the whole of a wide one. Going back takes the same rule from the new order, so `into` >= 0.5,
// or a `hysteresis` > 0, leaves a band between the two where nothing moves (no swap back and forth on one pixel).
// One call moves the item as many places as the pointer went, in one direction.
reorder_slot_sized :: proc(pos, origin, gap: f32, sizes: []f32, current: int, into: f32 = 0.5, hysteresis: f32 = 0) -> int {
	n := len(sizes)
	if n <= 0 { return 0 }
	if current < 0 || current >= n { return clamp(current, 0, n - 1) }
	// the others in order, without the dragged item: the one after it when it is at slot t is other(t), before it other(t - 1)
	other :: proc(sizes: []f32, current, k: int) -> f32 { return sizes[k < current ? k : k + 1] }
	d := sizes[current]
	f := clamp(into, 0, 1)
	lead := origin
	for k in 0 ..< current { lead += sizes[k] + gap }
	t := current
	for t + 1 < n {
		o := other(sizes, current, t)
		next_at := lead + d + gap
		if pos + d <= next_at + o * f + hysteresis { break }
		lead += o + gap
		t += 1
	}
	if t != current { return t }
	for t > 0 {
		o := other(sizes, current, t - 1)
		prev_end := lead - gap
		if pos >= prev_end - o * f - hysteresis { break }
		lead -= o + gap
		t -= 1
	}
	return t
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

// Whether the item whose box is `item` is dragged.
reorder_dragging :: proc(item: Key) -> bool {
	p := reorder_press(item)
	return p != nil && p.dragging
}

// Starts dragging the item whose box is `item`, held by the left button, when the press moved more than `threshold`
// (`moved`: reorder_moved); `press` and `slot`: where the press and the item's leading edge were, in the coordinates
// reorder_item_pos is given. Once per press: false when it drags already.
reorder_begin :: proc(item: Key, moved, threshold, press, slot: f32) -> bool {
	p := reorder_press(item)
	if p == nil || p.dragging || moved <= threshold { return false }
	p^ = {dragging = true, grab = press - slot}
	return true
}

REORDER_ANIM_RATE :: 30

// The place along the axis of the item whose box is `item` (its key before the box is built: key_from_string of the
// list's box and the item's id): its `slot`, animated (`rate` as `anim`), or, while it is dragged, the pointer less the
// grab, within `lo` .. `hi` (the release then slides from there).
reorder_item_pos :: proc(item: Key, slot, pointer, lo, hi: f32, rate: f32 = REORDER_ANIM_RATE) -> (pos: f32, dragging: bool) {
	k := key_from_string(item, "###reorder_pos")   // (the item's own box may animate on its key)
	if p := reorder_press(item); p != nil && p.dragging {
		pos = clamp(pointer - p.grab, lo, hi)
		_ = anim(k, pos, rate, pos)
		return pos, true
	}
	return math.round(anim(k, slot, rate, slot)), false
}
