package ui

import "core:fmt"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "../platform"

// Keyboard-driven lists and tables: a vertical scroll region that is one Tab stop, with an active row.
//
//   if ui.list("###prefs", &view.list) {
//       for item, i in items {
//           row := ui.list_row(&view.list, i, item.name)       // a row box (X axis); build its cells under it
//           if ui.parent(row.box) { ... }
//       }
//   }
//   if view.list.activated { edit(view.list.sel) }            // Enter or double click on the active row
//
// While the list has the keyboard focus: Up / Down move the active row, Page Up / Page Down by a page, Home / End to
// the ends (rows built with selectable = false, e.g. group headers, are skipped), Enter activates the row, Escape
// cancels (`cancelled`), typing letters jumps to the next row whose label starts with them (type-ahead: keys typed
// within LIST_TYPEAHEAD_MS of each other add up). The active row stays in view. A click makes a row active and gives
// the list the focus; the wheel scrolls as in any scroll region. The focus ring shows on the list when it came from
// the keyboard; the active row is drawn with the "selected" tags (strong while the list is focused).

LIST_TYPEAHEAD_MS :: 900.0
@(private) LIST_TYPED_MAX_BYTES :: 32
// Frames the active row keeps being scrolled into view (its rect is the last frame's).
@(private) LIST_REVEAL_FRAMES :: 3
// Rows measured for the average height behind Page Up / Page Down.
@(private = "file") LIST_PAGE_SAMPLE_ROWS :: 64
// Bytes of a label lowered per byte of the prefix (a rune's lower case may take another number of bytes).
@(private = "file") LIST_LOWER_BYTES_FACTOR :: 4

List_State :: struct {
	sel:         int,     // active row (-1: none)
	// (the next three say what `list` saw: read them in a build that made the list, its next call clears them)
	activated:   bool,    // this frame: Enter or a double click on the active row
	cancelled:   bool,    // this frame: Escape while the list had the focus
	changed:     bool,    // this frame: the active row changed (a key, a click, rows gone from under it)
	focused:     bool,    // the list has the keyboard focus (as of this frame's input)
	key:         Key,     // the list's box (give it the focus with set_focus)
	count:       int,     // rows built last frame
	selectable:  [dynamic]bool,   // last frame, per row
	building:    [dynamic]bool,   // this frame
	typed:       [LIST_TYPED_MAX_BYTES]u8,
	typed_len:   int,
	typed_ms:    f64,
	seek:        bool,    // type-ahead pending: resolved while the rows are built
	// the letters typed are not the list's: no type-ahead, they stay for the program (type_to_field: a filter that takes
	// what is typed over its list, as a file manager's does)
	no_typeahead: bool,
	seek_after, seek_first: int,
	reveal:      int,     // frames left to keep scrolling the active row into view
	page_rows:   int,     // rows that fit in the view (last frame)
	virtual:     bool,    // a Virtual_List: the row count and selectability come from the app, not from the rows built
	// Marks: with `multi`, a Ctrl click marks a row besides the active one (or unmarks it), a Shift click marks the rows
	// from the last row clicked to this one, a click alone clears them; the list's Ctrl+A marks every row. A row is
	// marked by its identity (a Virtual_List's id, a `list`'s index): the marks follow the rows through a sort.
	multi:       bool,
	marks:       map[u64]bool,
	marks_changed: bool,  // this frame: the marks changed
	mark_from:   u64,     // the identity of the row a Shift click's range starts from
	row_ids:     []u64,   // (a Virtual_List's ids, this build)
	// The look of the rows (list_row): `zebra` gives every second row the theme's "list_row zebra background" (a table
	// of numbers reads along its lines), `rules` a hairline under each row ("rule border").
	zebra:       bool,
	rules:       bool,
}

list_state_destroy :: proc(st: ^List_State) {
	delete(st.selectable)
	delete(st.building)
	delete(st.marks)
}

// The identity of row `i`: a Virtual_List's id, else the index.
list_row_id :: proc(st: ^List_State, i: int) -> u64 {
	if i >= 0 && i < len(st.row_ids) { return st.row_ids[i] }
	return u64(i)
}

// Whether row `i` is marked.
list_is_marked :: proc(st: ^List_State, i: int) -> bool {
	return len(st.marks) > 0 && list_row_id(st, i) in st.marks
}

// The rows marked (0: none; the selection is then the active row alone).
list_mark_count :: proc(st: ^List_State) -> int { return len(st.marks) }

list_marks_clear :: proc(st: ^List_State) {
	if len(st.marks) > 0 { clear(&st.marks); st.marks_changed = true }
}

// Marks every row that can be selected (as of the last build).
list_mark_all :: proc(st: ^List_State) {
	for i in 0 ..< st.count {
		if i < len(st.selectable) && !st.selectable[i] { continue }
		st.marks[list_row_id(st, i)] = true
	}
	st.marks_changed = true
}

// Marks row `i` (`on`) or unmarks it.
list_mark :: proc(st: ^List_State, i: int, on := true) {
	id := list_row_id(st, i)
	if on { st.marks[id] = true } else { delete_key(&st.marks, id) }
	st.marks_changed = true
}

// A click on row `i` of a list with `multi`: Ctrl marks it or unmarks it (the active row joins the marks first), Shift
// marks the range from the last row clicked, a click alone clears the marks.
@(private = "file")
list_mark_click :: proc(st: ^List_State, i: int, mods: platform.Modifiers) {
	id := list_row_id(st, i)
	switch {
	case .Ctrl in mods:
		if len(st.marks) == 0 && st.sel >= 0 && st.sel != i && st.sel < st.count { st.marks[list_row_id(st, st.sel)] = true }
		if id in st.marks { delete_key(&st.marks, id) } else { st.marks[id] = true }
		st.mark_from = id
	case .Shift in mods:
		from := st.sel
		for k in 0 ..< st.count { if list_row_id(st, k) == st.mark_from { from = k; break } }
		if from < 0 { from = i }
		clear(&st.marks)
		for k in min(from, i) ..= max(from, i) {
			if k < len(st.selectable) && !st.selectable[k] { continue }
			st.marks[list_row_id(st, k)] = true
		}
	case:
		clear(&st.marks)
		st.mark_from = id
	}
	st.marks_changed = true
}

// Type-ahead: does row `i`, labelled `label`, match what was typed? Records the first match and the first one at or
// after the active row (st.seek_first / st.seek_after).
@(private)
list_seek_row :: proc(st: ^List_State, i: int, label: string) {
	if !st.seek || st.typed_len == 0 { return }
	// the same letter typed again cycles through the rows starting with it; different letters spell a prefix,
	// looked for from the active row on
	typed := string(st.typed[:st.typed_len])
	first_r, first_n := utf8.decode_rune_in_string(typed)
	same := true
	for r in typed { if r != first_r { same = false; break } }
	prefix := same ? typed[:first_n] : typed
	if len(label) < len(prefix) { return }
	if strings.has_prefix(strings.to_lower(label[:min(len(label), len(prefix) * LIST_LOWER_BYTES_FACTOR)], context.temp_allocator), prefix) {
		if st.seek_first < 0 { st.seek_first = i }
		after := same ? i > st.sel : i >= st.sel
		if after && st.seek_after < 0 { st.seek_after = i }
	}
}

// The keys of a focused list: moves, Enter, Escape, type-ahead (resolved later, against the rows' labels).
@(private)
list_keys :: proc(s: ^State, st: ^List_State) {
	// (a dialog open over the list holds the keys: its Enter is its own, not the row's behind it)
	if keys_held_by_dialog(s) { return }
	page := max(st.page_rows - 1, 1)
	up :: proc(st: ^List_State) -> int { return st.sel < 0 ? list_next_selectable(st, -1, 1) : list_next_selectable(st, st.sel, -1) }
	for e, i in s.events.list {
		if s.events.consumed[i] { continue }
		if st.multi && e.key == .A && e.mods == {.Ctrl} {
			list_mark_all(st)
			s.events.consumed[i] = true
			continue
		}
		if e.mods != {} { continue }
		used := true
		#partial switch e.key {
		case .Down:      st.sel = list_next_selectable(st, st.sel, 1)
		case .Up:        st.sel = up(st)
		case .Home:      st.sel = list_next_selectable(st, -1, 1)
		case .End:       st.sel = list_next_selectable(st, st.count, -1)
		case .Page_Down: for _ in 0 ..< page { st.sel = list_next_selectable(st, st.sel, 1) }
		case .Page_Up:   for _ in 0 ..< page { st.sel = up(st) }
		case .Return:    if st.sel >= 0 { st.activated = true }
		case .Escape:    st.cancelled = true
		case:            used = false
		}
		if used {
			s.events.consumed[i] = true
			st.reveal = LIST_REVEAL_FRAMES
			if st.multi && e.key != .Return && e.key != .Escape { list_marks_clear(st) }   // (a move alone: the active row is the selection)
		}
	}
	if len(s.typed) > 0 && !st.no_typeahead {
		if s.time_ms - st.typed_ms > LIST_TYPEAHEAD_MS { st.typed_len = 0 }
		st.typed_ms = s.time_ms
		for r in s.typed {
			buf, n := utf8.encode_rune(unicode.to_lower(r))
			if st.typed_len + n <= len(st.typed) { copy(st.typed[st.typed_len:], buf[:n]); st.typed_len += n }
		}
		clear(&s.typed)
		st.seek = true
		st.seek_after, st.seek_first = -1, -1
	}
}

// Makes row `i` active and scrolls it into view (e.g. to restore a position).
list_select :: proc(st: ^List_State, i: int) {
	st.sel = i
	st.reveal = LIST_REVEAL_FRAMES
}

@(private)
list_next_selectable :: proc(st: ^List_State, from, dir: int) -> int {
	n := st.count
	if n == 0 { return -1 }
	i := from
	for {
		i += dir
		if i < 0 || i >= n { return from >= 0 && from < n ? from : clamp(i, 0, n - 1) }
		if i >= len(st.selectable) || st.selectable[i] { return i }
	}
}

// `if list(id, &state) { list_row(...) ... }`: the list's scroll region (fills what `next` / the style give it).
@(deferred_none = list_end)
list :: proc(id: string, st: ^List_State) -> bool {
	s := gs()
	set_next_axis(.Y)
	// .Text_Input: the list handles its own keys (no Enter / Space click, no arrow focus moves)
	b := build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Focusable, .Clickable, .Text_Input}, id)
	b.cursor = .Arrow
	_ = signal(b)
	st.key = b.key
	st.activated, st.cancelled, st.changed, st.marks_changed = false, false, false, false
	st.focused = s.focus_key == b.key
	st.selectable, st.building = st.building, st.selectable
	clear(&st.building)
	old := st.sel
	// (a row list_select asked for may not be counted yet: the first build, a row added now. list_end checks it.)
	if st.sel >= st.count && st.reveal == 0 { st.sel = st.count - 1 }
	st.seek = false
	if st.focused { list_keys(s, st) }
	if st.sel != old && b.first_build != s.build_index { st.changed = true }   // (the zero value's row 0 of a list with none is no change)
	append(&s.list_stack, st)
	push_parent(b)
	return true
}

@(private)
list_end :: proc() {
	s := gs()
	st := pop(&s.list_stack)
	b := parent_box()
	pop_parent()
	st.count = len(st.building)
	if st.sel >= st.count {
		st.sel = st.count - 1
		if b.first_build != s.build_index { st.changed = true }
	}
	if st.sel < 0 { st.reveal = 0 }   // (no row to bring into view)
	a11y_default(b, {role = .List_Box, active_descendant = st.sel >= 0 ? key_from_string(b.key, fmt.tprintf("###lrow_%d", st.sel)) : 0})
	// (a row clicked this frame changed the selection after the rows before it were built)
	for c := b.first; c != nil; c = c.next {
		if c.a11y != nil && c.a11y.role == .List_Box_Option { c.a11y.selected = c.a11y.position - 1 == st.sel; c.a11y.set_size = st.count }
	}
	if st.seek {
		pick := st.seek_after >= 0 ? st.seek_after : st.seek_first
		if pick >= 0 && pick != st.sel { st.sel = pick; st.changed = true; st.reveal = LIST_REVEAL_FRAMES }
		st.seek = false
	}
	// rows that fit, from the rows of the previous frame (for Page Up / Page Down)
	if st.count > 0 && b.size.y > 0 {
		total, n: f32
		for i in 0 ..< min(st.count, LIST_PAGE_SAMPLE_ROWS) {
			if r := box_from_key(key_from_string(b.key, fmt.tprintf("###lrow_%d", i))); r != nil { total += r.size.y; n += 1 }
		}
		if n > 0 { st.page_rows = max(int(b.size.y / (total / n)), 1) }
	}
	// keep the active row in view (its rect is last frame's: done again on the next frames until it is settled)
	if st.reveal > 0 && st.sel >= 0 {
		st.reveal -= 1
		s.anim_busy = true   // (a row not laid out yet, the first build: the next frames have it)
		if r := box_from_key(key_from_string(b.key, fmt.tprintf("###lrow_%d", st.sel))); r != nil && r.last_build + 1 >= s.build_index {
			// rows are children of the list: rel_pos is their place in the content, whatever the scroll animation did
			view_reveal(b, r.rel_pos.y, r.rel_pos.y + r.size.y)
		}
	}
}

// Row `i` of the list being built: a box laid out along X (full width, as tall as its cells unless `next` says
// otherwise). `label` is what type-ahead matches. Rows that are not `selectable` (headers) are skipped by the keys.
// `tint`: the row's background when it is not the active or a marked row (a row that just came, a row in alert), in
// place of the zebra's shade.
list_row :: proc(st: ^List_State, i: int, label: string, selectable := true, tint: Maybe(Color) = nil) -> Signal {
	s := gs()
	if !st.virtual {
		for len(st.building) <= i { append(&st.building, true) }
		st.building[i] = selectable
		if selectable { list_seek_row(st, i, label) }
	}
	active := selectable && i == st.sel
	lit := active || (selectable && st.multi && list_is_marked(st, i))   // (a marked row shows as the active one)
	if lit { push_tags(st.focused ? "selected" : "weak_selected") }
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = children_sum() }
	m.axis = .X
	m.radius = 0   // (a row is square, whatever the style: its fill runs from edge to edge, row under row)
	s.next_mod = m
	s.has_next = true
	flags := Box_Flags{.Clickable}
	if lit { flags += {.Draw_Background} }
	// rows that can be chosen light up under the pointer (theme: "list_row hover_fill"), headers do not
	// (and stay lit while the pointer is on a button of theirs)
	if selectable { flags += {.Draw_Hot_Effects, .Hot_Within}; push_tags("list_row") }
	// (the zebra goes by the row's index, a header's too: the stripes stay put while the rows scroll)
	zebra := st.zebra && !lit && i & 1 == 1 && tint == nil
	if zebra { flags += {.Draw_Background}; push_tags("zebra") }
	if tint != nil && !lit {
		flags += {.Draw_Background}
		m.bg = tint
		s.next_mod = m
	}
	if st.rules { flags += {.Draw_Side_Bottom}; push_tags("rule") }
	b := build_box(flags, vlist_row_name(i))
	if st.rules { pop_tags() }
	if zebra { pop_tags() }
	if m.cursor == nil { b.cursor = .Arrow }   // (a row that opens something: `next({cursor = .Hand})`)
	if selectable { pop_tags() }
	if lit { pop_tags() }
	sig := signal(b)
	if selectable && st.multi {
		if sig.pointer_pressed { list_mark_click(st, i, sig.mods) }
		// (a right click on a row outside the marks makes it the selection alone; on a marked row, the marks stay)
		if sig.right_clicked && len(st.marks) > 0 && !list_is_marked(st, i) { list_marks_clear(st) }
	}
	if selectable && (sig.pressed || sig.right_clicked) {
		if st.sel != i { st.changed = true }
		st.sel = i
		s.focus_key = st.key
		s.focus_visible = false
	}
	if selectable && sig.double_clicked { st.activated = true }
	if selectable {
		a11y_default(b, {role = .List_Box_Option, name = label, selected = i == st.sel, position = i + 1})
	} else {
		a11y_default(b, {role = .Group, name = label})
	}
	return sig
}
