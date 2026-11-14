package ui

import "../platform"

// The selection of a list's rows (src/md/features/selection.md): the active row (the cursor), the rows selected by
// identity, the anchor of a Shift range. `list`, `vlist`, `list_row` and `Table` keep one in their List_State; a program
// that builds its own grid calls these procedures with its rows. Pure: no State, no event.
//
//   multi, pointer: click: the row alone; Ctrl: toggle it; Shift: the range from the anchor; Ctrl+Shift: the range added.
//   multi, keys: arrows / Page / Home / End: the cursor's row alone; Shift: the range; Ctrl: the cursor alone moves;
//   Ctrl+Space: toggle; Ctrl+A: all; Escape: the cursor's row alone (when several are selected; else the program's).
//   single (multi false): the selection is `sel`; every gesture selects one row.

Item_Selection :: struct {
	sel:      int,                // the active row: where the keys are (-1: none)
	multi:    bool,
	selected: map[u64]struct{},   // multi: the identities of the rows selected
	anchor:   u64,                // multi: the identity of the row a Shift range starts from
	anchored: bool,
	base:     map[u64]struct{},   // multi: the selection when the anchor was set (what Ctrl+Shift adds its range to)
	version:  u64,                // moves with every change of the selection (compare it, not the set)
	// list_select on a multi list: the active row is selected alone at the next build, when the rows' ids are this build's
	select_pending: bool,
}

// The rows a selection is over: how many, their identities (nil: the index), which can be selected (nil, or past its
// end: every row).
Item_Rows :: struct {
	count:      int,
	ids:        []u64,
	selectable: []bool,
}

item_selection_destroy :: proc(sel: ^Item_Selection) {
	delete(sel.selected)
	delete(sel.base)
	sel.selected, sel.base = nil, nil
}

// The identity of row `i`.
item_rows_id :: proc(rows: Item_Rows, i: int) -> u64 {
	if i >= 0 && i < len(rows.ids) { return rows.ids[i] }
	return u64(i)
}

item_rows_selectable :: proc(rows: Item_Rows, i: int) -> bool {
	return i >= 0 && i < rows.count && (i >= len(rows.selectable) || rows.selectable[i])
}

// The next row that can be selected from `from` in direction `dir` (±1); `from` itself, or the nearest end, when none.
item_rows_next :: proc(rows: Item_Rows, from, dir: int) -> int {
	n := rows.count
	if n == 0 { return -1 }
	i := from
	for {
		i += dir
		if i < 0 || i >= n { return from >= 0 && from < n ? from : clamp(i, 0, n - 1) }
		if i >= len(rows.selectable) || rows.selectable[i] { return i }
	}
}

// The row of identity `id`, -1 when it is not in the rows (a pass over them: called on a gesture, not per frame).
item_rows_find :: proc(rows: Item_Rows, id: u64) -> int {
	if rows.ids == nil { return id < u64(rows.count) ? int(id) : -1 }
	for v, i in rows.ids { if v == id { return i } }
	return -1
}

// Whether row `i` is selected.
item_selection_has :: proc(sel: ^Item_Selection, rows: Item_Rows, i: int) -> bool {
	// (a `list`'s row built for the first time is past the last build's count: it may still be the active one)
	if !sel.multi { return i >= 0 && i == sel.sel }
	return len(sel.selected) > 0 && item_rows_id(rows, i) in sel.selected
}

// How many rows are selected.
item_selection_count :: proc(sel: ^Item_Selection, rows: Item_Rows) -> int {
	if !sel.multi { return sel.sel >= 0 && sel.sel < rows.count ? 1 : 0 }
	return len(sel.selected)
}

// The identities selected, in the rows' order (a pass over the rows).
item_selection_ids :: proc(sel: ^Item_Selection, rows: Item_Rows, allocator := context.temp_allocator) -> []u64 {
	out := make([dynamic]u64, 0, item_selection_count(sel, rows), allocator)
	if !sel.multi {
		if sel.sel >= 0 && sel.sel < rows.count { append(&out, item_rows_id(rows, sel.sel)) }
		return out[:]
	}
	if len(sel.selected) == 0 { return out[:] }
	for i in 0 ..< rows.count { if item_rows_id(rows, i) in sel.selected { append(&out, item_rows_id(rows, i)) } }
	return out[:]
}

@(private = "file")
set_copy :: proc(to: ^map[u64]struct{}, from: map[u64]struct{}) {
	clear(to)
	for id in from { to[id] = {} }
}

// Row `i` alone; the anchor on it.
item_selection_one :: proc(sel: ^Item_Selection, rows: Item_Rows, i: int) {
	before := sel.sel
	sel.sel = i
	sel.select_pending = false
	if !sel.multi {
		if i != before { sel.version += 1 }
		return
	}
	id := item_rows_id(rows, i)
	same := len(sel.selected) == 1 && id in sel.selected
	clear(&sel.selected)
	clear(&sel.base)
	if i >= 0 {
		sel.selected[id] = {}
		sel.base[id] = {}
		sel.anchor, sel.anchored = id, true
	} else {
		sel.anchored = false
	}
	if !same { sel.version += 1 }
}

// Row `i` toggled; the anchor on it, the base the selection now (Ctrl+click, Ctrl+Space).
item_selection_toggle :: proc(sel: ^Item_Selection, rows: Item_Rows, i: int) {
	if !item_rows_selectable(rows, i) { return }
	if !sel.multi { item_selection_one(sel, rows, i); return }
	id := item_rows_id(rows, i)
	if id in sel.selected { delete_key(&sel.selected, id) } else { sel.selected[id] = {} }
	set_copy(&sel.base, sel.selected)
	sel.anchor, sel.anchored = id, true
	sel.sel = i
	sel.version += 1
}

// The range from the anchor to row `i` (the selectable rows between), over the base when `add` (Ctrl+Shift), alone
// otherwise; the cursor on `i`, the anchor where it was.
item_selection_range :: proc(sel: ^Item_Selection, rows: Item_Rows, i: int, add: bool) {
	if !item_rows_selectable(rows, i) { return }
	if !sel.multi { item_selection_one(sel, rows, i); return }
	from := sel.anchored ? item_rows_find(rows, sel.anchor) : -1
	if from < 0 {
		// (no anchor, or its row is gone: the range starts at the cursor, else at this row)
		from = sel.sel >= 0 && sel.sel < rows.count ? sel.sel : i
		sel.anchor, sel.anchored = item_rows_id(rows, from), true
		set_copy(&sel.base, sel.selected)
	}
	if add { set_copy(&sel.selected, sel.base) } else { clear(&sel.selected) }
	for k in min(from, i) ..= max(from, i) {
		if item_rows_selectable(rows, k) { sel.selected[item_rows_id(rows, k)] = {} }
	}
	sel.sel = i
	sel.version += 1
}

// A press on row `i` with `mods` (the rules: src/md/features/selection.md).
item_selection_click :: proc(sel: ^Item_Selection, rows: Item_Rows, i: int, mods: platform.Modifiers) {
	if !item_rows_selectable(rows, i) { return }
	ctrl, shift := .Ctrl in mods, .Shift in mods
	switch {
	case !sel.multi:    item_selection_one(sel, rows, i)
	case shift:         item_selection_range(sel, rows, i, ctrl)
	case ctrl:          item_selection_toggle(sel, rows, i)
	case:               item_selection_one(sel, rows, i)
	}
}

// A right click on row `i`: outside the selection, it is selected alone; on it, the selection stays (its menu acts on it).
item_selection_context :: proc(sel: ^Item_Selection, rows: Item_Rows, i: int) {
	if !item_rows_selectable(rows, i) { return }
	if item_selection_has(sel, rows, i) { sel.sel = i; return }
	item_selection_one(sel, rows, i)
}

// The cursor goes to row `to` (a key computed it: a list by rows, a grid by columns): alone, the row is selected alone;
// Shift: the range; Ctrl+Shift: the range over the base; Ctrl: the cursor alone moves (multi).
item_selection_move :: proc(sel: ^Item_Selection, rows: Item_Rows, to: int, mods: platform.Modifiers) {
	if to < 0 || to >= rows.count { return }
	ctrl, shift := .Ctrl in mods, .Shift in mods
	switch {
	case !sel.multi:    item_selection_one(sel, rows, to)
	case shift:         item_selection_range(sel, rows, to, ctrl)
	case ctrl:          sel.sel = to
	case:               item_selection_one(sel, rows, to)
	}
}

// Every row that can be selected (multi); the base is then all of them.
item_selection_all :: proc(sel: ^Item_Selection, rows: Item_Rows) {
	if !sel.multi { return }
	before := len(sel.selected)
	for i in 0 ..< rows.count { if item_rows_selectable(rows, i) { sel.selected[item_rows_id(rows, i)] = {} } }
	set_copy(&sel.base, sel.selected)
	if len(sel.selected) != before { sel.version += 1 }
}

// Nothing selected (multi: the cursor stays where it is; single: no active row).
item_selection_clear :: proc(sel: ^Item_Selection) {
	if !sel.multi {
		if sel.sel >= 0 { sel.sel = -1; sel.version += 1 }
		return
	}
	if len(sel.selected) > 0 { clear(&sel.selected); sel.version += 1 }
	clear(&sel.base)
}

// Row `i` selected (`on`) or not: a program's own change; the anchor stays.
item_selection_set :: proc(sel: ^Item_Selection, rows: Item_Rows, i: int, on := true) {
	if !sel.multi {
		if on { item_selection_one(sel, rows, i) } else if sel.sel == i { item_selection_clear(sel) }
		return
	}
	id := item_rows_id(rows, i)
	if on == (id in sel.selected) { return }
	if on { sel.selected[id] = {} } else { delete_key(&sel.selected, id) }
	sel.version += 1
}

// The identities that are no longer in the rows leave the selection, the base and the anchor (new rows: a pass over them).
item_selection_keep :: proc(sel: ^Item_Selection, rows: Item_Rows) {
	if !sel.multi || (len(sel.selected) == 0 && len(sel.base) == 0 && !sel.anchored) { return }
	live := make(map[u64]struct{}, rows.count, context.temp_allocator)
	for i in 0 ..< rows.count { live[item_rows_id(rows, i)] = {} }
	gone := make([dynamic]u64, context.temp_allocator)
	for id in sel.selected { if id not_in live { append(&gone, id) } }
	for id in gone { delete_key(&sel.selected, id) }
	if len(gone) > 0 { sel.version += 1 }
	clear(&gone)
	for id in sel.base { if id not_in live { append(&gone, id) } }
	for id in gone { delete_key(&sel.base, id) }
	if sel.anchored && sel.anchor not_in live { sel.anchored = false }
}

// A row's identity changed (its row the same: a row unfolded whose id carries its height): its selection, its place in
// the base and the anchor follow it. The cursor is an index: it stays.
item_selection_rekey :: proc(sel: ^Item_Selection, old_id, new_id: u64) {
	if old_id == new_id { return }
	if old_id in sel.selected {
		delete_key(&sel.selected, old_id)
		sel.selected[new_id] = {}
		sel.version += 1
	}
	if old_id in sel.base { delete_key(&sel.base, old_id); sel.base[new_id] = {} }
	if sel.anchored && sel.anchor == old_id { sel.anchor = new_id }
}

// Escape (no modifier) on several rows selected: the cursor's row alone, and true. On one row or none: false, the
// Escape is the program's (clear its filter, hide, close). A list always shows the row an act would take: an Escape
// that left none lit, with Delete still acting on the cursor's, was refused (src/md/features/selection.md). A program
// that reads Escape itself (its list does not have the keyboard) calls it first.
item_selection_escape :: proc(sel: ^Item_Selection, rows: Item_Rows, mods: platform.Modifiers = {}) -> bool {
	if !sel.multi || mods != {} || len(sel.selected) < 2 { return false }
	if sel.sel >= 0 && sel.sel < rows.count && item_rows_selectable(rows, sel.sel) {
		item_selection_one(sel, rows, sel.sel)
	} else {
		item_selection_clear(sel)
	}
	return true
}

// A key of a list that has the keyboard: the moves (Up, Down, Page Up, Page Down by `page` rows, Home, End, with Shift
// and Ctrl), Ctrl+Space, Ctrl+A, Escape on several rows selected. Whether the key was the selection's (Enter and the
// other keys are not; an Escape on one row or none is not: it is the program's, the list's `cancelled`).
item_selection_key :: proc(sel: ^Item_Selection, rows: Item_Rows, key: platform.Key, mods: platform.Modifiers, page := 1) -> bool {
	if mods - {.Ctrl, .Shift} != {} { return false }   // (Alt+arrows are the program's: back, up a folder)
	// (a single list gives Shift and Ctrl no meaning: those keys stay the program's, as Shift+Page Down for its pages)
	if !sel.multi && mods != {} { return false }
	ctrl, shift := .Ctrl in mods, .Shift in mods
	n := rows.count
	up :: proc(rows: Item_Rows, at: int) -> int { return at < 0 ? item_rows_next(rows, -1, 1) : item_rows_next(rows, at, -1) }
	to := -2
	#partial switch key {
	case .Down:      to = item_rows_next(rows, sel.sel, 1)
	case .Up:        to = up(rows, sel.sel)
	case .Home:      to = item_rows_next(rows, -1, 1)
	case .End:       to = item_rows_next(rows, n, -1)
	case .Page_Down: to = sel.sel; for _ in 0 ..< max(page, 1) { to = item_rows_next(rows, to, 1) }
	case .Page_Up:   to = sel.sel; for _ in 0 ..< max(page, 1) { to = up(rows, to) }
	case .Space:
		if !ctrl || shift || sel.sel < 0 || sel.sel >= n { return false }
		item_selection_toggle(sel, rows, sel.sel)
		return true
	case .A:
		if !sel.multi || mods != {.Ctrl} { return false }
		item_selection_all(sel, rows)
		return true
	case .Escape:
		return item_selection_escape(sel, rows, mods)
	case:
		return false
	}
	if to < 0 { return true }   // (no row: the key is still the list's, it moves nothing)
	item_selection_move(sel, rows, to, mods)
	return true
}
