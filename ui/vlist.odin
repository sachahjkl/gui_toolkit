package ui

import "core:fmt"
import "core:math"

// A virtualized keyboard list: only the rows in view (and a margin around it) are built, whatever the row count.
//
//   ids := ...                                                 // one stable identity per row (see below)
//   if rows, ok := ui.vlist("###prefs", &view.vl, ids, labels, selectable); ok {
//       for i in rows.first ..< rows.last {
//           row := ui.list_row(&view.vl, i, labels[i], selectable[i])   // as in a `list`
//           if ui.parent(row.box) { ... }
//       }
//   }
//
// Rows may have any height (wrapped descriptions...). The height of each row is measured when it is laid out and kept,
// by row identity, for the width, scale and font size it was measured at; rows never seen count with the average
// height of those measured. The identity (`ids[i]`) says when a row is the same: the app folds into it whatever changes
// the row's height (its content, an error shown under it...), so a changed row is measured again. When heights change
// above the view (a row measured for the first time, a width change), the view stays on the row it was showing.
//
// Keyboard and mouse as in `list` (Up / Down, Page Up / Down, Home / End, Enter, Escape, type-ahead on `labels`), over
// all the rows, built or not; the active row is scrolled into view at once. `labels` / `selectable` may be nil (no
// type-ahead / every row selectable).

Virtual_List :: struct {
	using list:  List_State,
	measured:    map[u64]f32,      // row identity -> height, at `layout_key`
	layout_key:  u64,
	ids:         [dynamic]u64,     // this build's rows (a copy of the app's)
	offsets:     [dynamic]f32,     // top of each row in the content, and the total at the end (estimates included)
	est:         f32,              // height of a row never measured
	overscan:    f32,              // px built beyond each edge of the view (0: half a view)
	first, last: int,              // rows built this build
	prev_ids:    [dynamic]u64,     // identities of the rows built last build [prev_first, ...), to measure them
	prev_first:  int,
	anchor_id:   u64,              // the row at the top of the view last build, and where it was in the content then
	anchor_top:  f32,
	has_anchor:  bool,
}

Vlist_Rows :: struct { first, last: int }

vlist_destroy :: proc(st: ^Virtual_List) {
	list_state_destroy(&st.list)
	delete(st.measured)
	delete(st.ids)
	delete(st.offsets)
	delete(st.prev_ids)
}

// Forgets every measured height (the content of all rows changed in a way their identities do not tell).
vlist_invalidate :: proc(st: ^Virtual_List) { clear(&st.measured) }

// Puts the view at content position `y` at once (e.g. back to the top when the rows are filtered anew).
vlist_scroll_to :: proc(st: ^Virtual_List, y: f32) {
	st.has_anchor = false
	if b := box_from_key(st.key); b != nil {
		b.view_off.y, b.view_target.y = y, y
		b.view_anim[1].active = false
	}
}

// Top of row `i` in the content and its height (estimated if never laid out) as of this build.
vlist_row_extent :: proc(st: ^Virtual_List, i: int) -> (top, height: f32) {
	if i < 0 || i + 1 >= len(st.offsets) { return }
	return st.offsets[i], st.offsets[i + 1] - st.offsets[i]
}

@(private)
vlist_row_key :: proc(list_key: Key, i: int) -> Key {
	buf: [32]u8
	return key_from_string(list_key, fmt.bprintf(buf[:], "###lrow_%d", i))
}

// Row index at content position `y` (the last row whose top is <= y).
@(private)
vlist_row_at :: proc(offsets: []f32, y: f32) -> int {
	n := len(offsets) - 1
	if n <= 0 { return 0 }
	lo, hi := 0, n - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if offsets[mid] <= y { lo = mid } else { hi = mid - 1 }
	}
	return lo
}

@(deferred_out = vlist_end)
vlist :: proc(id: string, st: ^Virtual_List, ids: []u64, labels: []string = nil, selectable: []bool = nil) -> (rows: Vlist_Rows, ok: bool) {
	s := g
	set_next_axis(.Y)
	b := build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Focusable, .Clickable, .Text_Input}, id)
	b.cursor = .Arrow
	_ = signal(b)   // the wheel (against last build's bounds)
	st.virtual = true
	st.key = b.key
	st.activated, st.cancelled, st.changed = false, false, false
	st.focused = s.focus_key == b.key
	n := len(ids)

	// 1. heights of the rows laid out last build, for the size they were laid out at
	// (the box's size is last layout's: the size those rows were laid out at)
	key := u64(key_from_u64(key_from_u64(key_from_u64(0, u64(math.round(b.size.x))), u64(transmute(u32)s.scale)), u64(transmute(u32)(b.font_size * s.density))))
	if key != st.layout_key { clear(&st.measured); st.layout_key = key }
	for pid, k in st.prev_ids {
		r := box_from_key(vlist_row_key(b.key, st.prev_first + k))
		if r != nil && r.last_build + 1 == s.build_index && r.size.y > 0 { st.measured[pid] = r.size.y }
	}
	if len(st.measured) > 0 {
		sum: f32
		for _, h in st.measured { sum += h }
		st.est = sum / f32(len(st.measured))
	} else if st.est <= 0 {
		st.est = math.round(b.font_size * 2.4)
	}

	// 2. this build's rows and where they are
	resize(&st.ids, n)
	copy(st.ids[:], ids)
	resize(&st.offsets, n + 1)
	y: f32
	for i in 0 ..< n {
		st.offsets[i] = y
		h, found := st.measured[ids[i]]
		y += found ? h : st.est
	}
	st.offsets[n] = y
	total := y

	// 3. the view stays on the row it showed, wherever that row is now
	dragging := s.active_key[.Left] == scrollbar_key(b)
	if st.has_anchor && !dragging && n > 0 {
		at := -1
		guess := vlist_row_at(st.offsets[:], b.view_off.y)
		for k in max(guess - 64, 0) ..< min(guess + 64, n) { if ids[k] == st.anchor_id { at = k; break } }
		if at < 0 { for k in 0 ..< n { if ids[k] == st.anchor_id { at = k; break } } }
		if at >= 0 {
			moved := st.offsets[at] - st.anchor_top   // what the rows above it grew or shrank by
			if abs(moved) > 0.01 && b.view_off.y > 0 {
				b.view_off.y += moved
				b.view_target.y += moved
			}
		}
	}
	view_h := b.size.y > 0 ? b.size.y : s.window_size.y
	limit := max(0, total - view_h)
	b.view_target.y = clamp(b.view_target.y, 0, limit)
	b.view_off.y = clamp(b.view_off.y, 0, max(limit, b.view_off.y))

	// 4. keyboard, over all the rows
	resize(&st.selectable, n)
	if selectable != nil && len(selectable) == n { copy(st.selectable[:], selectable) } else { for &v in st.selectable { v = true } }
	st.count = n
	if st.sel >= n { st.sel = n - 1 }
	old := st.sel
	st.seek = false
	st.page_rows = max(int(view_h / max(st.est, 1)), 1)
	if st.focused { list_keys(s, st) }
	if st.seek {
		if labels != nil && len(labels) == n {
			for i in 0 ..< n { if st.selectable[i] { list_seek_row(st, i, labels[i]) } }
		}
		pick := st.seek_after >= 0 ? st.seek_after : st.seek_first
		if pick >= 0 { st.sel = pick; st.reveal = 3 }
		st.seek = false
	}
	if st.sel != old { st.changed = true }
	// the active row in view, at once (its place is known even when it is not built), and again for a few builds while
	// the rows around it get measured
	if st.reveal > 0 && st.sel >= 0 && st.sel < n {
		st.reveal -= 1
		top, bottom := st.offsets[st.sel], st.offsets[st.sel + 1]
		if top < b.view_target.y { b.view_target.y = top }
		if bottom > b.view_target.y + view_h { b.view_target.y = min(bottom - view_h, top) }
		s.anim_busy = true
	}

	// 5. the rows to build: the view, a margin, and the active row's neighbours are not needed (its place is known)
	over := st.overscan > 0 ? st.overscan : max(view_h * 0.5, st.est * 2)
	lo := min(b.view_off.y, b.view_target.y) - over
	hi := max(b.view_off.y, b.view_target.y) + view_h + over
	// a long animated jump only builds what the view shows now
	if hi - lo > view_h * 3 + over * 2 { lo, hi = b.view_off.y - over, b.view_off.y + view_h + over }
	st.first = n > 0 ? vlist_row_at(st.offsets[:], max(lo, 0)) : 0
	st.last = st.first
	for st.last < n && st.offsets[st.last] < hi { st.last += 1 }

	// the anchor for the next build: the row at the top of the view
	if n > 0 {
		a := vlist_row_at(st.offsets[:], b.view_off.y)
		st.anchor_id, st.anchor_top, st.has_anchor = ids[a], st.offsets[a], true
	} else {
		st.has_anchor = false
	}

	append(&s.list_stack, &st.list)
	push_parent(b)
	spacer(px(st.offsets[st.first]), exact = true)
	return {st.first, st.last}, true
}

@(private)
vlist_end :: proc(rows: Vlist_Rows, ok: bool) {
	s := g
	st := (^Virtual_List)(pop(&s.list_stack))
	n := len(st.ids)
	spacer(px(st.offsets[n] - st.offsets[st.last]), exact = true)
	pop_parent()
	// the rows built, measured at the start of the next build
	resize(&st.prev_ids, st.last - st.first)
	copy(st.prev_ids[:], st.ids[st.first:st.last])
	st.prev_first = st.first
}
