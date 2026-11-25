package ui

import "core:fmt"
import "core:math"
import "core:slice"

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
// all the rows, built or not; the active row is scrolled into view at once. With `multi`, the selection of several rows
// (List_State's Item_Selection: src/md/features/selection.md) is by `ids`: a row selected stays selected through a sort,
// and leaves the selection when it is no longer in `ids`. `labels` / `selectable` may be nil (no type-ahead / every row
// selectable).
//
// No build does work in proportion to the rows unless the ids change. The rows' heights are in a Fenwick tree
// (fenwick.odin): a row measured is a point update, the top of a row, the total and the row at a place are each
// O(log n). Every row is placed again (a pass over them, counted in `offsets_made`) only when the ids change, when
// the heights are forgotten (vlist_invalidate, a new width, scale or font size). `ids_version` says when the ids
// change: a program that keeps its ids and counts their changes passes that count, and the list compares nothing; 0
// compares the ids with the last build's.
//
// A row never measured counts for `est`, the average of those measured, which changes with each measure: so the tree
// keeps, per row, its measured height and whether it was measured, and the estimate is applied when a top is asked
// (top = measured heights above + est * rows above not measured), never written into every row.

@(private = "file") VLIST_FIRST_ESTIMATE_EM :: 2.4     // a row's height before any was measured
// Measured rows that may be gone from the data before they are looked for, beyond twice the rows there are.
@(private = "file") VLIST_MEASURED_SLACK :: 256
@(private = "file") VLIST_ANCHOR_SEARCH_ROWS :: 64     // looked at around where the anchor should be, before all
@(private = "file") VLIST_ANCHOR_MOVED_PX :: 0.01
@(private = "file") VLIST_REVEAL_WAIT_MAX_BUILDS :: 600
@(private = "file") VLIST_LONG_JUMP_SCREENS :: 3       // a move longer than this builds only what the view shows now

Virtual_List :: struct {
	using list:  List_State,
	measured:    map[u64]f32,      // row identity -> height, at `layout_key`
	layout_key:  u64,
	ids:         [dynamic]u64,     // this build's rows (a copy of the app's)
	// per row of `ids`: {its measured height, 1} or {0, 0} when never measured (f64: a million rows add up without
	// drift; the tops it gives are f32, as the view's place is)
	heights:     Fenwick([2]f64),
	est:         f32,              // height of a row never measured
	overscan:    f32,              // px built beyond each edge of the view (0: half a view)
	end_space:   f32,              // empty space kept after the last row (px): leaves room to start a band in a full list
	first, last: int,              // rows built this build
	prev_ids:    [dynamic]u64,     // identities of the rows built last build [prev_first, ...), to measure them
	prev_first:  int,
	anchor_id:   u64,              // the row at the top of the view last build, and where it was in the content then
	anchor_top:  f32,
	anchor_index: int,             // where the anchor was in `ids`: with the same ids, it is there still
	has_anchor:  bool,
	reveal_wait: int,              // builds the active row has been waited for (to be laid out, to measure it)
	scroll_to:   Maybe(f32),       // vlist_scroll_to on a list with no box: where the next build puts the view
	ids_version: u64,              // the `ids_version` the ids were copied at (0: compared)
	measured_sum: f64,             // the heights in `measured` added up (their average is `est`)
	heights_due: bool,             // the heights were forgotten: every row is placed again
	offsets_made: int,             // the builds that placed every row again (only new ids or forgotten heights do)
}

// The rows built. `guessed`: the list was not laid out yet (its first build), so the view's height is the window's
// and the rows are more than it shows: a caller that fetches rows waits for the next build.
Vlist_Rows :: struct {
	first, last: int,
	guessed:     bool,
}

vlist_destroy :: proc(st: ^Virtual_List) {
	list_state_destroy(&st.list)
	delete(st.measured)
	delete(st.ids)
	fenwick_destroy(&st.heights)
	delete(st.prev_ids)
}

// Forgets every measured height (the content of all rows changed in a way their identities do not tell).
vlist_invalidate :: proc(st: ^Virtual_List) {
	clear(&st.measured)
	st.measured_sum, st.heights_due = 0, true
}

// Puts the view at content position `y` at once (e.g. back to the top when the rows are filtered anew).
vlist_scroll_to :: proc(st: ^Virtual_List, y: f32) {
	st.has_anchor = false
	if b := box_from_key(st.key); b != nil {
		view_jump(b, y)
	} else {
		st.scroll_to = y
	}
}

// Top of row `i` in the content and its height (estimated if never laid out) as of this build.
vlist_row_extent :: proc(st: ^Virtual_List, i: int) -> (top, height: f32) {
	if i < 0 || i >= fenwick_len(&st.heights) { return }
	leaf := fenwick_get(&st.heights, i)
	return vlist_row_top(st, i), leaf[1] > 0 ? f32(leaf[0]) : st.est
}

// Top of row `i` in the content as of this build, in O(log n): the heights measured above it, and the estimate for
// each row above it never measured. `i` = the row count: the content's height (vlist_total).
vlist_row_top :: proc(st: ^Virtual_List, i: int) -> f32 {
	rows := min(i, fenwick_len(&st.heights))
	if rows <= 0 { return 0 }
	above := fenwick_sum(&st.heights, rows)
	return f32(above[0] + f64(st.est) * (f64(rows) - above[1]))
}

// The content's height as of this build: every row, measured or estimated.
vlist_total :: proc(st: ^Virtual_List) -> f32 {
	return vlist_row_top(st, fenwick_len(&st.heights))
}

// Row index at content position `y` (the last row whose top is <= y), in O(log n): a descent of the tree.
vlist_row_at :: proc(st: ^Virtual_List, y: f32) -> int {
	n := fenwick_len(&st.heights)
	if n <= 0 { return 0 }
	// (the most rows whose heights add up to <= y: the next one is the row at y, or the last when y is past the end)
	return min(fenwick_find_by(&st.heights, f64(y), vlist_weigh, f64(st.est)), n - 1)
}

// What `span` rows under one node of the tree are high: those measured, and the estimate for the others.
@(private = "file")
vlist_weigh :: proc(node: [2]f64, span: int, est: f64) -> f64 {
	return node[0] + est * (f64(span) - node[1])
}

// Every row placed again from the heights measured: a pass over the rows, only when the ids changed or the heights
// were forgotten.
@(private = "file")
vlist_place_all :: proc(st: ^Virtual_List, ids: []u64) {
	leaves := fenwick_leaves(&st.heights, len(ids))
	for id, i in ids {
		h, found := st.measured[id]
		leaves[i] = found ? [2]f64{f64(h), 1} : [2]f64{}
	}
	fenwick_build(&st.heights)
	st.heights_due = false
	st.offsets_made += 1
}

// Row `i` measured at `h`: a point update (nothing when the tree already has it).
@(private = "file")
vlist_place :: proc(st: ^Virtual_List, i: int, h: f32) {
	want := [2]f64{f64(h), 1}
	// (f32 heights added up in f64 come back exact: the leaf is what was put in, so equal means unchanged)
	leaf := fenwick_get(&st.heights, i)
	if leaf != want { fenwick_add(&st.heights, i, want - leaf) }
}

@(private)
vlist_row_key :: proc(list_key: Key, i: int) -> Key {
	buf: [32]u8
	return key_from_string(list_key, vlist_row_name(i, buf[:]))
}

// The name row `i` of a list is built under (list_row's): a row a program builds itself in a vlist, its own look and
// behaviour, takes it, so that the list measures its height (into `buf`, temp memory when none).
vlist_row_name :: proc(i: int, buf: []u8 = nil) -> string {
	if buf == nil { return fmt.tprintf("###lrow_%d", i) }
	return fmt.bprintf(buf, "###lrow_%d", i)
}

@(deferred_out = vlist_end)
vlist :: proc(id: string, st: ^Virtual_List, ids: []u64, labels: []string = nil, selectable: []bool = nil, ids_version: u64 = 0) -> (rows: Vlist_Rows, ok: bool) {
	s := gs()
	set_next_axis(.Y)
	b := build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Focusable, .Clickable, .Text_Input}, id)
	b.cursor = .Arrow
	s.virtual_depth += 1
	wheel := signal(b).scrolled   // the wheel (against last build's bounds)
	if wheel != {} { st.reveal, st.reveal_wait = 0, 0 }   // the user scrolls: the active row no longer pulls the view
	if y, asked := st.scroll_to.?; asked { view_jump(b, y); st.scroll_to = nil }
	st.virtual = true
	st.key = b.key
	st.activated, st.cancelled, st.changed, st.selected_changed = false, false, false, false
	st.focused = s.focus_key == b.key
	n := len(ids)

	// 1. this build's rows (the comparison is the only pass over them, and only with no `ids_version`)
	same := len(ids) == len(st.ids) && (ids_version != 0 ? ids_version == st.ids_version : slice.simple_equal(ids, st.ids[:]))
	if !same {
		resize(&st.ids, n)
		copy(st.ids[:], ids)
		st.ids_version = ids_version
	}
	st.row_ids = st.ids[:]

	// 2. heights of the rows laid out last build, for the size they were laid out at
	// (the box's size is last layout's: the size those rows were laid out at)
	key := u64(key_from_u64(key_from_u64(key_from_u64(0, u64(math.round(b.size.x))), u64(transmute(u32)s.scale)), u64(transmute(u32)(b.font_size * s.density))))
	if key != st.layout_key { vlist_invalidate(st); st.layout_key = key }
	// (with the same ids and heights kept, the tree holds these rows: each measure is a point update; otherwise every
	// row is placed again below, from `measured`)
	in_place := same && !st.heights_due && fenwick_len(&st.heights) == n
	for pid, k in st.prev_ids {
		i := st.prev_first + k
		r := box_from_key(vlist_row_key(b.key, i))
		if r == nil || r.last_build + 1 != s.build_index || r.size.y <= 0 { continue }
		old, had := st.measured[pid]
		if !had || old != r.size.y {
			st.measured[pid] = r.size.y
			st.measured_sum += f64(r.size.y) - (had ? f64(old) : 0)
		}
		// (the tree's leaf, not `measured`, says whether the row changed: an identity on two rows, which ids must not
		// have, still gets each of its rows right once it is laid out)
		if in_place && i < n && ids[i] == pid { vlist_place(st, i, r.size.y) }
	}
	// rows whose identity is gone (the data was replaced, filtered, rotated) are forgotten once they are the bulk
	// (none of them is in `ids`, so the tree has none of them: nothing to place again)
	if len(st.measured) > 2 * n + VLIST_MEASURED_SLACK {
		live := make(map[u64]struct{}, n, context.temp_allocator)
		for id in ids { live[id] = {} }
		gone := make([dynamic]u64, context.temp_allocator)
		for id in st.measured { if id not_in live { append(&gone, id) } }
		for id in gone {
			_, h := delete_key(&st.measured, id)
			st.measured_sum -= f64(h)
		}
	}
	// (the estimate is applied when a top is asked: a new average moves every row never measured at no cost)
	if len(st.measured) > 0 {
		st.est = f32(st.measured_sum / f64(len(st.measured)))
	} else if st.est <= 0 {
		st.est = math.round(b.font_size * VLIST_FIRST_ESTIMATE_EM)
	}
	if !in_place { vlist_place_all(st, ids) }
	total := vlist_total(st)

	// 3. the view stays on the row it showed, wherever that row is now
	view_h := b.size.y > 0 ? b.size.y : s.window_size.y
	tail := n > 0 ? max(st.end_space, 0) : 0
	limit := max(0, total + tail - view_h)   // (not view_limit: the bounds are last build's, these rows' are known)
	dragging := scrollbar_thumb_held(s, b)
	if st.has_anchor && !dragging && n > 0 {
		at := -1
		if same && st.anchor_index < n && ids[st.anchor_index] == st.anchor_id {
			at = st.anchor_index
		} else {
			// The ids changed: near where it should be, then all of them. A map from id to row would find it at once,
			// but it costs a hash and some 30 bytes per row at every change of the ids (30 MB at a million); this pass
			// runs only in a build whose new ids were just placed, a pass over the rows already.
			guess := vlist_row_at(st, b.view_off.y)
			for k in max(guess - VLIST_ANCHOR_SEARCH_ROWS, 0) ..< min(guess + VLIST_ANCHOR_SEARCH_ROWS, n) { if ids[k] == st.anchor_id { at = k; break } }
			if at < 0 { for k in 0 ..< n { if ids[k] == st.anchor_id { at = k; break } } }
		}
		if at >= 0 {
			moved := vlist_row_top(st, at) - st.anchor_top   // what the rows above it grew or shrank by
			if abs(moved) > VLIST_ANCHOR_MOVED_PX && b.view_off.y > 0 { view_shift(b, moved, limit) }
		}
	}
	b.view_target.y = clamp(b.view_target.y, 0, limit)
	b.view_off.y = clamp(b.view_off.y, 0, max(limit, b.view_off.y))

	// 4. keyboard, over all the rows
	// (none given: every row; a row past the end of `selectable` is selectable, so nothing per row is kept)
	if selectable != nil && len(selectable) == n {
		resize(&st.selectable, n)
		copy(st.selectable[:], selectable)
	} else {
		clear(&st.selectable)
	}
	st.count = n
	// (a row selected that is gone, or filtered out, is no longer selected)
	if !same { item_selection_keep(&st.selection, list_rows(st)) }
	old := st.sel
	if st.sel >= n { st.sel = n - 1 }
	list_select_resolve(st)
	if st.sel < 0 { st.reveal = 0 }   // (no row to bring into view)
	st.seek = false
	st.page_rows = max(int(view_h / max(st.est, 1)), 1)
	if st.focused { list_keys(s, st) }
	if st.seek {
		if labels != nil && len(labels) == n {
			for i in 0 ..< n { if i >= len(st.selectable) || st.selectable[i] { list_seek_row(st, i, labels[i]) } }
		}
		pick := st.seek_after >= 0 ? st.seek_after : st.seek_first
		if pick >= 0 { item_selection_one(&st.selection, list_rows(st), pick); st.reveal = LIST_REVEAL_FRAMES }
		st.seek = false
	}
	if st.sel != old && b.first_build != s.build_index { st.changed = true }   // (the zero value's row 0 of a list with none is no change)
	// the active row in view, at once (its place is known even when it is not built), and again for a few builds while
	// the rows around it get measured
	if st.reveal > 0 && st.sel >= 0 && st.sel < n {
		// (until the row itself has been laid out: its height was an estimate, the view may still be on its way)
		// (a row laid out with no height has none to measure: nothing more will come of waiting)
		r := box_from_key(vlist_row_key(b.key, st.sel))
		_, measured := st.measured[ids[st.sel]]
		if measured || (r != nil && r.last_build + 1 == s.build_index) || st.reveal_wait > VLIST_REVEAL_WAIT_MAX_BUILDS {
			st.reveal -= 1
			st.reveal_wait = 0
		} else {
			st.reveal_wait += 1
		}
		top, height := vlist_row_extent(st, st.sel)
		b.view_target.y = view_reveal_offset(b.view_target.y, top, top + height, view_h)
		s.anim_busy = true
	}

	// 5. the rows to build: the view, a margin, and the active row's neighbours are not needed (its place is known)
	over := st.overscan > 0 ? st.overscan : max(view_h * 0.5, st.est * 2)
	lo := min(b.view_off.y, b.view_target.y) - over
	hi := max(b.view_off.y, b.view_target.y) + view_h + over
	// a long animated jump only builds what the view shows now
	if hi - lo > view_h * VLIST_LONG_JUMP_SCREENS + over * 2 { lo, hi = b.view_off.y - over, b.view_off.y + view_h + over }
	st.first = n > 0 ? vlist_row_at(st, max(lo, 0)) : 0
	// (the rows built, each one step: O(log n) per row built, never per row there is)
	first_top := vlist_row_top(st, st.first)
	st.last = st.first
	for y := first_top; st.last < n && y < hi; st.last += 1 {
		_, h := vlist_row_extent(st, st.last)
		y += h
	}

	// the anchor for the next build: the row at the top of the view
	if n > 0 {
		a := vlist_row_at(st, b.view_off.y)
		st.anchor_id, st.anchor_top, st.anchor_index, st.has_anchor = ids[a], vlist_row_top(st, a), a, true
	} else {
		st.has_anchor = false
	}

	append(&s.list_stack, &st.list)
	push_parent(b)
	spacer(px(first_top), exact = true)
	guessed := b.size.y <= 0
	if guessed { s.anim_busy = true }   // (the next build has the list's height: its rows are the real ones)
	return {st.first, st.last, guessed}, true
}

@(private)
vlist_end :: proc(rows: Vlist_Rows, ok: bool) {
	s := gs()
	s.virtual_depth -= 1
	st := (^Virtual_List)(pop(&s.list_stack))
	n := len(st.ids)
	tail := n > 0 ? max(st.end_space, 0) : 0
	spacer(px(vlist_total(st) - vlist_row_top(st, st.last) + tail), exact = true)
	// (only the rows in view are built: the set's size tells a screen reader how many there are)
	b := parent_box()
	a11y_default(b, {role = .List_Box, multiselectable = st.multi, active_descendant = st.sel >= 0 ? vlist_row_key(b.key, st.sel) : 0})
	for c := b.first; c != nil; c = c.next {
		if c.a11y != nil && c.a11y.role == .List_Box_Option { c.a11y.set_size = n; c.a11y.selected = list_is_selected(&st.list, c.a11y.position - 1) }
	}
	pop_parent()
	list_selection_seen(&st.list)
	// the rows built, measured at the start of the next build
	resize(&st.prev_ids, st.last - st.first)
	copy(st.prev_ids[:], st.ids[st.first:st.last])
	st.prev_first = st.first
}
