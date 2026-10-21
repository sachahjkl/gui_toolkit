package ui

import "core:fmt"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

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

List_State :: struct {
	sel:         int,     // active row (-1: none)
	activated:   bool,    // this frame: Enter or a double click on the active row
	cancelled:   bool,    // this frame: Escape while the list had the focus
	changed:     bool,    // this frame: the active row changed
	focused:     bool,    // the list has the keyboard focus (as of this frame's input)
	key:         Key,     // the list's box (give it the focus with set_focus)
	count:       int,     // rows built last frame
	selectable:  [dynamic]bool,   // last frame, per row
	building:    [dynamic]bool,   // this frame
	typed:       [32]u8,
	typed_len:   int,
	typed_ms:    f64,
	seek:        bool,    // type-ahead pending: resolved while the rows are built
	seek_after, seek_first: int,
	reveal:      int,     // frames left to keep scrolling the active row into view
	page_rows:   int,     // rows that fit in the view (last frame)
	virtual:     bool,    // a Virtual_List: the row count and selectability come from the app, not from the rows built
}

list_state_destroy :: proc(st: ^List_State) {
	delete(st.selectable)
	delete(st.building)
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
	if strings.has_prefix(strings.to_lower(label[:min(len(label), len(prefix) * 4)], context.temp_allocator), prefix) {
		if st.seek_first < 0 { st.seek_first = i }
		after := same ? i > st.sel : i >= st.sel
		if after && st.seek_after < 0 { st.seek_after = i }
	}
}

// The keys of a focused list: moves, Enter, Escape, type-ahead (resolved later, against the rows' labels).
@(private)
list_keys :: proc(s: ^State, st: ^List_State) {
	page := max(st.page_rows - 1, 1)
	up :: proc(st: ^List_State) -> int { return st.sel < 0 ? list_next_selectable(st, -1, 1) : list_next_selectable(st, st.sel, -1) }
	for e, i in s.events.list {
		if s.events.consumed[i] || e.mods != {} { continue }
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
		if used { s.events.consumed[i] = true; st.reveal = 3 }
	}
	if len(s.typed) > 0 {
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
	st.reveal = 3
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
	s := g
	set_next_axis(.Y)
	// .Text_Input: the list handles its own keys (no Enter / Space click, no arrow focus moves)
	b := build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Focusable, .Clickable, .Text_Input}, id)
	b.cursor = .Arrow
	_ = signal(b)
	st.key = b.key
	st.activated, st.cancelled, st.changed = false, false, false
	st.focused = s.focus_key == b.key
	st.selectable, st.building = st.building, st.selectable
	clear(&st.building)
	if st.sel >= st.count { st.sel = st.count - 1 }
	old := st.sel
	st.seek = false
	if st.focused { list_keys(s, st) }
	if st.sel != old { st.changed = true }
	append(&s.list_stack, st)
	push_parent(b)
	return true
}

@(private)
list_end :: proc() {
	s := g
	st := pop(&s.list_stack)
	b := parent_box()
	pop_parent()
	st.count = len(st.building)
	if st.seek {
		pick := st.seek_after >= 0 ? st.seek_after : st.seek_first
		if pick >= 0 && pick != st.sel { st.sel = pick; st.changed = true; st.reveal = 3 }
		st.seek = false
	}
	// rows that fit, from the rows of the previous frame (for Page Up / Page Down)
	if st.count > 0 && b.size.y > 0 {
		total, n: f32
		for i in 0 ..< min(st.count, 64) {
			if r := box_from_key(key_from_string(b.key, fmt.tprintf("###lrow_%d", i))); r != nil { total += r.size.y; n += 1 }
		}
		if n > 0 { st.page_rows = max(int(b.size.y / (total / n)), 1) }
	}
	// keep the active row in view (its rect is last frame's: done again on the next frames until it is settled)
	if st.reveal > 0 && st.sel >= 0 {
		st.reveal -= 1
		if r := box_from_key(key_from_string(b.key, fmt.tprintf("###lrow_%d", st.sel))); r != nil && r.last_build + 1 >= s.build_index {
			// rows are children of the list: rel_pos is their place in the content, whatever the scroll animation did
			top := r.rel_pos.y
			bottom := top + r.size.y
			if top < b.view_target.y { b.view_target.y = top }
			if bottom > b.view_target.y + b.size.y { b.view_target.y = bottom - b.size.y }
			s.anim_busy = true
		}
	}
}

// Row `i` of the list being built: a box laid out along X (full width, as tall as its cells unless `next` says
// otherwise). `label` is what type-ahead matches. Rows that are not `selectable` (headers) are skipped by the keys.
list_row :: proc(st: ^List_State, i: int, label: string, selectable := true) -> Signal {
	s := g
	if !st.virtual {
		for len(st.building) <= i { append(&st.building, true) }
		st.building[i] = selectable
		if selectable { list_seek_row(st, i, label) }
	}
	active := selectable && i == st.sel
	if active { push_tags(st.focused ? "selected" : "weak_selected") }
	m := g.has_next ? g.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = children_sum() }
	m.axis = .X
	g.next_mod = m
	g.has_next = true
	flags := Box_Flags{.Clickable}
	if active { flags += {.Draw_Background} }
	// rows that can be chosen light up under the pointer (theme: "list_row hover_fill"), headers do not
	if selectable { flags += {.Draw_Hot_Effects}; push_tags("list_row") }
	b := build_box(flags, fmt.tprintf("###lrow_%d", i))
	b.cursor = .Arrow
	if selectable { pop_tags() }
	if active { pop_tags() }
	sig := signal(b)
	if selectable && (sig.pressed || sig.right_clicked) {
		if st.sel != i { st.changed = true }
		st.sel = i
		s.focus_key = st.key
		s.focus_visible = false
	}
	if selectable && sig.double_clicked { st.activated = true }
	return sig
}
