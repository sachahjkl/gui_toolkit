package ui

import "core:fmt"

// A lazy column: a long run of items of any height (messages, cards, paragraphs) inside a scroll box, where only those near
// the view are built; the others stand as a space of the height they had when last built (one space for a run of them),
// so the content keeps its height and the scroll stays where it is. What a long document cost at every frame (building
// every item) becomes the cost of a screen of it.
//
//   lz := ui.lazy_begin()                     // in the column the items go in, inside a scroll_y
//   for m, i in messages {
//       if ui.lazy_item(lz, fmt.tprintf("###m%s", m.id), always = i == len(messages) - 1) {
//           ... the item ...                  // built in a box of its own (full width, as tall as its content)
//       }
//   }
//
// Like row(), the item is the block of the `if`: `if !ui.lazy_item(...) { continue }` closes the item at once, its
// content lands in the column and nothing is ever skipped (a debug build says so: set_layout_warnings).
//
// An item never built stands as the mean height of those that were; one built at another width keeps its old height
// until it is built again. Either is corrected when the item comes near the view, and the view stays on the item it
// showed (the first one visible keeps its place on screen: lazy_settle, after the layout), so nothing jumps.
// `lazy_begin(all = true)` builds every item; `sweep`: these items too, by their order ([first, end): `sweep = find_sweep()`, a find in
// page reads a slice of them at each frame); `always`: build this item
// whatever (the item that grows while streaming; a focus in an item left behind waits for it). One lazy column to a
// parent: what a column keeps between frames goes by that parent's key.

Lazy :: struct {
	lo, hi:  f32,    // the content's band that is built (the view and a screen each side), in the scroll box's content
	tlo, thi: f32,   // the same around where the view is heading (a wheel's jump, a scroll to a match): built too
	y:       f32,    // where the next item starts in the content (from the heights known)
	on:      bool,   // items may be skipped
	column:  Key,
	scroll:  ^Box,   // the scroll box the column is in
	est:     f32,    // the height of an item never built
	skip:    f32,    // the height of the items skipped since the last one built (one space for all of them)
	last:    ^Box,   // the item built last (whether anything went in it)
	built, empty: int,
	known_h: f32,    // heights known this frame (their sum and count: the next frame's estimate)
	known_n: int,
	items:   [dynamic]^Box,   // the items built, in order (lazy_settle)
	pin:     Key,     // the item the view stays on, whatever moves around it (lazy_pin), 0: none
	pin_dy:  f32,
	sweep:   [2]int,  // the items built for a find's sweep, [first, end) by their order
	n:       int,     // items met so far
}

@(private)
Lazy_Height :: struct { h: f32, seen: u64, known: bool }   // (known: built once; an item that shows nothing has a height, 0)

// What a column keeps between frames: the estimate, and the item the view was on.
@(private)
Lazy_Column :: struct {
	est:        f32,
	anchor:     Key,   // the first item visible at the last frame
	anchor_top: f32,   // where it started in the content
	seen:       u64,
	pin_found:  bool,  // the pinned item was built and laid out at the last build
	pin_moved:  bool,  // ... and the view had to move to stay on it
}

LAZY_MARGIN :: 1.0   // screens built above and below the view
@(private = "file") LAZY_FIRST_ESTIMATE_EM :: 4   // an item's height before any was built
@(private = "file") LAZY_ANCHOR_MOVED_PX :: 0.5   // the view follows its anchor when it moved more than this
@(private = "file") LAZY_TRIM_INTERVAL_BUILDS :: 120
@(private = "file") LAZY_KEEP_BUILDS :: 600

// In the column the items go in. `all`: build every item this frame; `sweep`: these ones too (find_sweep). (The space of the last
// items skipped is put in when the block lazy_begin was called in ends: before the column closes.)
@(deferred_out = lazy_end)
lazy_begin :: proc(all := false, sweep := [2]int{}) -> (lz: ^Lazy) {
	s := gs()
	lz = new(Lazy, frame_allocator())
	lz.items.allocator = frame_allocator()
	lz.sweep = sweep
	col := parent_box()
	lz.column = col.key
	if sweep[1] > sweep[0] { s.find.column = col.key }
	c := s.lazy_columns[col.key] or_else {}
	c.seen = s.build_index
	s.lazy_columns[col.key] = c
	lz.est = c.est > 0 ? c.est : font_size() * LAZY_FIRST_ESTIMATE_EM
	sb := col.parent
	for sb != nil && (Box_Flag.View_Scroll_Y not_in sb.flags) { sb = sb.parent }
	lz.scroll = sb
	if sb == nil || all { return }
	lz.on = true
	s.virtual_depth += 1
	view := sb.size.y > 0 ? sb.size.y : s.window_size.y   // (the first frame: no layout yet)
	lz.lo = sb.view_off.y - view * LAZY_MARGIN
	lz.hi = sb.view_off.y + view * (1 + LAZY_MARGIN)
	lz.tlo = sb.view_target.y - view * LAZY_MARGIN
	lz.thi = sb.view_target.y + view * (1 + LAZY_MARGIN)
	// the column's top in the content, from the last layout
	lz.y = col.rect.min.y - sb.rect.min.y + sb.view_off.y
	return
}

// The view stays on this item, `dy` into it (from the item's top to the view's top: what was on screen at that place), placed after each
// layout: what grows or shrinks around it, items built for the first time above it above all, moves nothing. Said at each build for as long
// as it holds (the item must be built: `always` in its lazy_item). The column's own anchor waits meanwhile.
lazy_pin :: proc(lz: ^Lazy, id: string, dy: f32) {
	lz.pin = key_from_string(lz.column, id)
	lz.pin_dy = dy
}

// What the last layout found of the pin: whether the item was there, and whether the view had to move to be on it. (Found and not moved
// a few builds in a row: the heights around it have settled.)
lazy_pinned :: proc(lz: ^Lazy) -> (found, moved: bool) {
	c := gs().lazy_columns[lz.column] or_else {}
	return c.pin_found, c.pin_moved
}

// One item: true when it is built now (its box is the parent until the block ends); false when a space stands for it.
@(deferred_out = lazy_item_end)
lazy_item :: proc(lz: ^Lazy, id: string, always := false) -> bool {
	s := gs()
	key := key_from_string(parent_box().key, id)
	// (One look in one map: a column of thousands pays this for each of them, at every build. What was built last has its height from lazy_settle.)
	e, kept := &s.lazy_heights[key]
	if !kept {
		s.lazy_heights[key] = {}
		e = &s.lazy_heights[key]
	}
	e.seen = s.build_index
	h := e.h
	if !e.known { h = lz.est } else if h > 0 { lz.known_h += h; lz.known_n += 1 }
	top := lz.y
	lz.y += h
	swept := lz.n >= lz.sweep[0] && lz.n < lz.sweep[1]
	lz.n += 1
	if lz.on && !always && !swept && (top + h < lz.lo || top > lz.hi) && (top + h < lz.tlo || top > lz.thi) {
		lz.skip += h
		next_drop(s)
		return false
	}
	lazy_flush(lz)
	lazy_count(lz)
	next({width = fill(), height = children_sum(), axis = .Y})
	lz.last = build_box({}, id)
	append(&lz.items, lz.last)
	if lz.sweep[1] > lz.sweep[0] { append(&s.find.built, lz.last.key) }
	if swept { append(&s.find.chunk, lz.last.key) }
	push_parent(lz.last)
	return true
}

@(private)
lazy_item_end :: proc(built: bool) { if built { pop_parent() } }

@(private)
lazy_flush :: proc(lz: ^Lazy) {
	if lz.skip > 0 { spacer(px(lz.skip), exact = true) }
	lz.skip = 0
}

@(private)
lazy_count :: proc(lz: ^Lazy) {
	if lz.last == nil { return }
	lz.built += 1
	if lz.last.first == nil { lz.empty += 1 }
	lz.last = nil
}

@(private)
lazy_end :: proc(lz: ^Lazy) {
	lazy_flush(lz)
	lazy_count(lz)
	s := gs()
	if lz.on { s.virtual_depth -= 1 }
	if lz.sweep[1] > lz.sweep[0] { s.find.total = lz.n }   // (where the sweep ends)
	if c, ok := &s.lazy_columns[lz.column]; ok && lz.known_n > 0 { c.est = lz.known_h / f32(lz.known_n) }
	append(&s.lazy_frame, lz)   // (a column in no scroll box too: its items' heights are noted there)
	// every item built and nothing in any: their content was built after each item closed
	if lz.built >= 2 && lz.empty == lz.built && s.layout_warnings && !(lz.column in s.layout_warned) {
		col := box_from_key(lz.column)
		s.layout_warned[lz.column] = fmt.aprintf("%s: its lazy items are empty, their content is built next to them: `if !lazy_item(...) { continue }` ends the item with the if's block; write `if lazy_item(...) { ... }`", col != nil && col.name != "" ? col.name : "a lazy column")
		fmt.eprintfln("ui: layout: %s", s.layout_warned[lz.column])
	}
}

// After the layout (end_build): the item the view was on keeps its place on screen. An item built for the first time,
// or again at a new width, may not be as tall as the space that stood for it: what changed above the view would move
// what the reader sees. The view follows by as much, the rects are placed again, and the first item visible becomes the
// anchor of the next frame.
@(private)
lazy_settle :: proc(s: ^State) {
	defer clear(&s.lazy_frame)
	s.lazy_more = false
	content_top :: proc(sb, b: ^Box) -> f32 { return b.rect.min.y - sb.rect.min.y + sb.view_off.y }
	for lz in s.lazy_frame {
		s.metrics.lazy_built += len(lz.items)
		for b in lz.items {
			if e, kept := &s.lazy_heights[b.key]; kept { e.h, e.known = b.size.y, true }
		}
		sb := lz.scroll
		c, ok := &s.lazy_columns[lz.column]
		if !ok || sb == nil || sb.last_build != s.build_index { continue }
		dragging := s.active_key[.Left] == scrollbar_key(sb)
		c.pin_found, c.pin_moved = false, false
		if lz.pin != 0 {
			for b in lz.items {
				if b.key != lz.pin { continue }
				c.pin_found = true
				want := clamp(content_top(sb, b) + lz.pin_dy, 0, view_limit(sb))
				if abs(want - sb.view_off.y) > LAZY_ANCHOR_MOVED_PX {
					view_jump(sb, want)   // (no glide toward where it was)
					layout_positions(sb, .Y)
					c.pin_moved = true
				}
				break
			}
		} else if c.anchor != 0 && !dragging && sb.view_off.y > 0 {
			for b in lz.items {
				if b.key != c.anchor { continue }
				moved := content_top(sb, b) - c.anchor_top
				if abs(moved) > LAZY_ANCHOR_MOVED_PX {
					view_shift(sb, moved, view_limit(sb))
					layout_positions(sb, .Y)
				}
				break
			}
		}
		// what is shown now beyond what was built (the view went further than its target said: a scroll bar dragged, a
		// clamp): the spaces show this frame, the next one builds what stands there
		if lz.on {
			top, bottom := sb.view_off.y, sb.view_off.y + sb.size.y
			covered := (top >= lz.lo && bottom <= lz.hi) || (top >= lz.tlo && bottom <= lz.thi)
			if !covered { s.lazy_more = true }
		}
		// the next anchor: the first item whose bottom is below the view's top
		c.anchor = 0
		for b in lz.items {
			if b.rect.max.y > sb.rect.min.y + 0.5 {
				c.anchor = b.key
				c.anchor_top = content_top(sb, b)
				break
			}
		}
	}
}

// The heights of items not seen for a while are forgotten (end_build).
@(private)
lazy_trim :: proc(s: ^State) {
	if s.build_index % LAZY_TRIM_INTERVAL_BUILDS != 0 { return }
	dead := make([dynamic]Key, context.temp_allocator)
	for k, e in s.lazy_heights { if s.build_index - e.seen > LAZY_KEEP_BUILDS { append(&dead, k) } }
	for k in dead { delete_key(&s.lazy_heights, k) }
	clear(&dead)
	for k, c in s.lazy_columns { if s.build_index - c.seen > LAZY_KEEP_BUILDS { append(&dead, k) } }
	for k in dead { delete_key(&s.lazy_columns, k) }
}
