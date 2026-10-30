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
// `lazy_begin(all = true)` builds every item (a find in page reads the text of all of them); `always`: build this item
// whatever (the item that grows while streaming, one with the focus).

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
}

@(private)
Lazy_Height :: struct { h: f32, seen: u64 }

// What a column keeps between frames: the estimate, and the item the view was on.
@(private)
Lazy_Column :: struct {
	est:        f32,
	anchor:     Key,   // the first item visible at the last frame
	anchor_top: f32,   // where it started in the content
	seen:       u64,
}

LAZY_MARGIN :: 1.0   // screens built above and below the view

// In the column the items go in. `all`: build every item this frame. (The space of the last items skipped is put in
// when the block lazy_begin was called in ends: before the column closes.)
@(deferred_out = lazy_end)
lazy_begin :: proc(all := false) -> (lz: ^Lazy) {
	s := g
	lz = new(Lazy, frame_allocator())
	lz.items.allocator = frame_allocator()
	col := parent_box()
	lz.column = col.key
	c := s.lazy_columns[col.key] or_else {}
	c.seen = s.build_index
	s.lazy_columns[col.key] = c
	lz.est = c.est > 0 ? c.est : font_size() * 4
	sb := col.parent
	for sb != nil && (Box_Flag.View_Scroll_Y not_in sb.flags) { sb = sb.parent }
	lz.scroll = sb
	if sb == nil || all { return }
	lz.on = true
	view := sb.size.y > 0 ? sb.size.y : s.window_size.y   // (the first frame: no layout yet)
	lz.lo = sb.view_off.y - view * LAZY_MARGIN
	lz.hi = sb.view_off.y + view * (1 + LAZY_MARGIN)
	lz.tlo = sb.view_target.y - view * LAZY_MARGIN
	lz.thi = sb.view_target.y + view * (1 + LAZY_MARGIN)
	// the column's top in the content, from the last layout
	lz.y = col.rect.min.y - sb.rect.min.y + sb.view_off.y
	return
}

// One item: true when it is built now (its box is the parent until the block ends); false when a space stands for it.
@(deferred_out = lazy_item_end)
lazy_item :: proc(lz: ^Lazy, id: string, always := false) -> bool {
	s := g
	key := key_from_string(parent_box().key, id)
	e := s.lazy_heights[key] or_else {}
	if b := s.boxes[key]; b != nil && b.last_build + 1 == s.build_index {
		e.h = b.size.y   // built at the last build: its height then
	}
	e.seen = s.build_index
	s.lazy_heights[key] = e
	h := e.h
	if h > 0 { lz.known_h += h; lz.known_n += 1 } else { h = lz.est }
	top := lz.y
	lz.y += h
	if lz.on && !always && (top + h < lz.lo || top > lz.hi) && (top + h < lz.tlo || top > lz.thi) {
		lz.skip += h
		return false
	}
	lazy_flush(lz)
	lazy_count(lz)
	next({width = fill(), height = children_sum(), axis = .Y})
	lz.last = build_box({}, id)
	append(&lz.items, lz.last)
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
	s := g
	if c, ok := &s.lazy_columns[lz.column]; ok && lz.known_n > 0 { c.est = lz.known_h / f32(lz.known_n) }
	if lz.scroll != nil { append(&s.lazy_frame, lz) }
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
		sb := lz.scroll
		c, ok := &s.lazy_columns[lz.column]
		if !ok || sb == nil || sb.last_build != s.build_index { continue }
		dragging := s.active_key[.Left] == scrollbar_key(sb)
		if c.anchor != 0 && !dragging && sb.view_off.y > 0 {
			for b in lz.items {
				if b.key != c.anchor { continue }
				moved := content_top(sb, b) - c.anchor_top
				if abs(moved) > 0.5 {
					limit := max(0, sb.view_bounds.y - sb.size.y)
					sb.view_off.y = clamp(sb.view_off.y + moved, 0, limit)
					sb.view_target.y = clamp(sb.view_target.y + moved, 0, limit)
					if a := &sb.view_anim[1]; a.active { a.from += f64(moved); a.to += f64(moved) }
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
	if s.build_index % 120 != 0 { return }
	dead := make([dynamic]Key, context.temp_allocator)
	for k, e in s.lazy_heights { if s.build_index - e.seen > 600 { append(&dead, k) } }
	for k in dead { delete_key(&s.lazy_heights, k) }
	clear(&dead)
	for k, c in s.lazy_columns { if s.build_index - c.seen > 600 { append(&dead, k) } }
	for k in dead { delete_key(&s.lazy_columns, k) }
}
