package ui

import "core:fmt"

// A lazy column: a long run of items of any height (messages, cards, paragraphs) inside a scroll box, where only those near
// the view are built; the others stand as a space of the height they had when last built, so the content keeps its height
// and the scroll stays where it is. A run of items skipped is one space. What a long document cost at every frame (building every item) becomes the cost of a
// screen of it.
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
// Every item is built when the column's width changed (the heights no longer hold), when `lazy_begin(all = true)` (a find
// in page reads the text of all of them), and before an item was ever built. `always`: build it whatever (the item that
// grows while streaming, one with the focus).

Lazy :: struct {
	lo, hi: f32,    // the content's band that is built (the view and a screen each side), in the scroll box's content
	y:      f32,    // where the next item starts in the content (from the heights known)
	on:     bool,   // items may be skipped
	column: Key,
	skip:   f32,    // the height of the items skipped since the last one built (one space for all of them)
	last:   ^Box,   // the item built last (whether anything went in it)
	built, empty: int,
}

@(private)
Lazy_Height :: struct { h: f32, seen: u64 }

LAZY_MARGIN :: 1.0   // screens built above and below the view

// In the column the items go in. `all`: build every item this frame. (The space of the last items skipped is put in
// when the block lazy_begin was called in ends: before the column closes.)
@(deferred_out = lazy_end)
lazy_begin :: proc(all := false) -> (lz: ^Lazy) {
	s := g
	lz = new(Lazy, frame_allocator())
	col := parent_box()
	lz.column = col.key
	sb := col.parent
	for sb != nil && (Box_Flag.View_Scroll_Y not_in sb.flags) { sb = sb.parent }
	width := col.rect.max.x - col.rect.min.x   // (the last layout's)
	prev_w := s.lazy_widths[col.key] or_else -1
	s.lazy_widths[col.key] = width
	if sb == nil || all || prev_w != width || width <= 0 { return }
	lz.on = true
	lz.lo = sb.view_off.y - sb.size.y * LAZY_MARGIN
	lz.hi = sb.view_off.y + sb.size.y * (1 + LAZY_MARGIN)
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
	top := lz.y
	lz.y += e.h
	if lz.on && !always && e.h > 0 && (top + e.h < lz.lo || top > lz.hi) {
		lz.skip += e.h
		return false
	}
	lazy_flush(lz)
	lazy_count(lz)
	next({width = fill(), height = children_sum(), axis = .Y})
	lz.last = build_box({}, id)
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
	// every item built and nothing in any: their content was built after each item closed
	s := g
	if lz.built >= 2 && lz.empty == lz.built && s.layout_warnings && !(lz.column in s.layout_warned) {
		col := box_from_key(lz.column)
		s.layout_warned[lz.column] = fmt.aprintf("%s: its lazy items are empty, their content is built next to them: `if !lazy_item(...) { continue }` ends the item with the if's block; write `if lazy_item(...) { ... }`", col != nil && col.name != "" ? col.name : "a lazy column")
		fmt.eprintfln("ui: layout: %s", s.layout_warned[lz.column])
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
	for k, _ in s.lazy_widths { if s.boxes[k] == nil { append(&dead, k) } }
	for k in dead { delete_key(&s.lazy_widths, k) }
}
