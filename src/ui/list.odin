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
// within Feel.typeahead_ms of each other add up). The active row stays in view. A click makes a row active and gives
// the list the focus; the wheel scrolls as in any scroll region. The focus ring shows on the list when it came from
// the keyboard; the selected rows are drawn with the "selected" tags (strong while the list is focused).
//
// The selection is the list's Item_Selection (item_selection.odin, src/md/features/selection.md): with `multi`, Ctrl,
// Shift and Ctrl+Shift clicks and keys, Ctrl+Space, Ctrl+A and Escape select several rows, by identity (a
// Virtual_List's id, a `list`'s index).

@(private) LIST_TYPED_MAX_BYTES :: 32
// Frames the active row keeps being scrolled into view (its rect is the last frame's).
@(private) LIST_REVEAL_FRAMES :: 3
// Rows measured for the average height behind Page Up / Page Down.
@(private = "file") LIST_PAGE_SAMPLE_ROWS :: 64
// Bytes of a label lowered per byte of the prefix (a rune's lower case may take another number of bytes).
@(private = "file") LIST_LOWER_BYTES_FACTOR :: 4

List_State :: struct {
	using selection: Item_Selection,   // `sel`: the active row (-1: none); `multi`: several rows can be selected
	// (the next four say what `list` saw: read them in a build that made the list, its next call clears them)
	activated:   bool,    // this frame: Enter or a double click on the active row
	cancelled:   bool,    // this frame: Escape while the list had the focus (and not several rows selected)
	changed:     bool,    // this frame: the active row changed (a key, a click, rows gone from under it)
	selected_changed: bool,   // this frame: the selection changed (`version` moved)
	version_seen: u64,    // the selection's version when the list was last built
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
	row_ids:     []u64,   // (a Virtual_List's ids, this build)
	// The look of the rows (list_row): `zebra` gives every second row the theme's "list_row zebra background" (a table
	// of numbers reads along its lines), `rules` a hairline under each row ("rule border").
	zebra:       bool,
	rules:       bool,
}

list_state_destroy :: proc(st: ^List_State) {
	delete(st.selectable)
	delete(st.building)
	item_selection_destroy(&st.selection)
}

// The rows the list's selection is over (as of the last build; a Virtual_List's, this build's).
list_rows :: proc(st: ^List_State) -> Item_Rows {
	return {count = st.count, ids = st.row_ids, selectable = st.selectable[:]}
}

// The identity of row `i`: a Virtual_List's id, else the index.
list_row_id :: proc(st: ^List_State, i: int) -> u64 { return item_rows_id(list_rows(st), i) }

// Whether row `i` is selected (single: it is the active row).
list_is_selected :: proc(st: ^List_State, i: int) -> bool { return item_selection_has(&st.selection, list_rows(st), i) }

// How many rows are selected.
list_selected_count :: proc(st: ^List_State) -> int { return item_selection_count(&st.selection, list_rows(st)) }

// The identities of the rows selected, in the rows' order (a pass over the rows: on an action, not per frame).
list_selected_ids :: proc(st: ^List_State, allocator := context.temp_allocator) -> []u64 {
	return item_selection_ids(&st.selection, list_rows(st), allocator)
}

// Nothing selected (a program's own Escape, a folder left).
list_selection_clear :: proc(st: ^List_State) { item_selection_clear(&st.selection) }

// Every row that can be selected (multi; as of the last build): the program's Ctrl+A when another field has the keyboard.
list_select_all :: proc(st: ^List_State) { item_selection_all(&st.selection, list_rows(st)) }

// Row `i` selected (`on`) or not, the active row and the anchor where they are.
list_set_selected :: proc(st: ^List_State, i: int, on := true) { item_selection_set(&st.selection, list_rows(st), i, on) }

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
	rows := list_rows(st)
	for e, i in s.events.list {
		if s.events.consumed[i] { continue }
		used := item_selection_key(&st.selection, rows, e.key, e.mods, page)
		if used {
			st.reveal = LIST_REVEAL_FRAMES
		} else if e.mods == {} {
			used = true
			#partial switch e.key {
			case .Return: if st.sel >= 0 { st.activated = true }
			case .Escape: st.cancelled = true   // (several rows selected: that Escape was the selection's)
			case:         used = false
			}
		}
		if used { s.events.consumed[i] = true }
	}
	if len(s.typed) > 0 && !st.no_typeahead {
		if s.time_ms - st.typed_ms > f64(s.feel.typeahead_ms) { st.typed_len = 0 }
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

// Makes row `i` active and scrolls it into view (e.g. to restore a position). In a multi list, the row is selected alone
// at the next build (the list may still hold the last build's ids: a table filtered again).
list_select :: proc(st: ^List_State, i: int) {
	if st.sel != i { st.version += 1 }   // (the active row: a multi list's set follows at the next build, its own bump)
	st.sel = i
	st.reveal = LIST_REVEAL_FRAMES
	if st.multi { st.select_pending = true }
}

// The next build's rows are known: a list_select waiting for them selects its row (list_end, vlist).
@(private)
list_select_resolve :: proc(st: ^List_State) {
	if !st.select_pending { return }
	st.select_pending = false
	if st.sel >= 0 && st.sel < st.count { item_selection_one(&st.selection, list_rows(st), st.sel) }
}

// The frame's change of the selection, said once (`selected_changed`).
@(private)
list_selection_seen :: proc(st: ^List_State) {
	if st.version != st.version_seen { st.selected_changed = true }
	st.version_seen = st.version
}

// `if list(id, &state) { list_row(...) ... }`: the list's scroll region (fills what `next` / the style give it).
@(require_results, deferred_none = list_end)
list :: proc(id: string, st: ^List_State) -> bool {
	s := gs()
	set_next_axis(.Y)
	// .Text_Input: the list handles its own keys (no Enter / Space click, no arrow focus moves)
	b := build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Focusable, .Clickable, .Text_Input}, id)
	b.cursor = .Arrow
	_ = signal(b)
	st.key = b.key
	st.activated, st.cancelled, st.changed, st.selected_changed = false, false, false, false
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
	fewer := len(st.building) < st.count
	st.count = len(st.building)
	if st.sel >= st.count {
		st.sel = st.count - 1
		if b.first_build != s.build_index { st.changed = true }
	}
	// (the identities of a `list` are its indices: the rows past its end are gone)
	if fewer { item_selection_keep(&st.selection, list_rows(st)) }
	list_select_resolve(st)
	if st.sel < 0 { st.reveal = 0 }   // (no row to bring into view)
	a11y_default(b, {role = .List_Box, multiselectable = st.multi, active_descendant = st.sel >= 0 ? key_from_string(b.key, fmt.tprintf("###lrow_%d", st.sel)) : 0})
	// (a row clicked this frame changed the selection after the rows before it were built)
	for c := b.first; c != nil; c = c.next {
		if c.a11y != nil && c.a11y.role == .List_Box_Option { c.a11y.selected = list_is_selected(st, c.a11y.position - 1); c.a11y.set_size = st.count }
	}
	if st.seek {
		pick := st.seek_after >= 0 ? st.seek_after : st.seek_first
		if pick >= 0 && pick != st.sel { item_selection_one(&st.selection, list_rows(st), pick); st.changed = true; st.reveal = LIST_REVEAL_FRAMES }
		st.seek = false
	}
	list_selection_seen(st)
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
	lit := selectable && list_is_selected(st, i)
	// (strong where the user acts now: the list has the keyboard in the window the user is in; else calm, still read)
	if lit { push_tags(st.focused && !inactive() ? "selected" : "weak_selected") }
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = children_sum() }
	m.axis = .X
	// (its face's corners, inset in it, are a row's (the theme's): the rounding scales them; `next`'s radius = 0 squares them)
	if m.radius == nil { m.radius = font_size() * shape_of(.Row) }
	s.next_mod = m
	s.has_next = true
	flags := Box_Flags{.Clickable, .Row}
	if lit { flags += {.Draw_Background, .Chosen} }
	// rows that can be chosen lift their own face under the pointer (theme: "list_row hover_fill", face.odin), headers do not
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
	if selectable && (sig.pressed || sig.right_clicked) {
		if st.sel != i { st.changed = true }
		// (the rows are this build's for a Virtual_List; a `list` counts the row built now, past its last count)
		rows := list_rows(st)
		rows.count = max(rows.count, i + 1)
		if sig.pressed {
			// (a screen reader's press has no modifiers of its own: the row alone)
			item_selection_click(&st.selection, rows, i, sig.pointer_pressed ? sig.mods : {})
		} else {
			item_selection_context(&st.selection, rows, i)
		}
		s.focus_key = st.key
		s.focus_visible = false
	}
	if selectable && sig.double_clicked { st.activated = true }
	if selectable {
		a11y_default(b, {role = .List_Box_Option, name = label, selected = lit, position = i + 1})
	} else {
		a11y_default(b, {role = .Group, name = label})
	}
	return sig
}
