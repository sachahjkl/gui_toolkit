package ui

// A table's views (src/md/features/view-modes.md): the same rows (Table.rows, Table.ids, filtered and sorted by
// table_apply) as details, as names alone, as names in columns, or as cards at four sizes. One index, Table.zoom, picks
// the step: its view and its cards' size.
//
//   table_zoom_step:  a step's view and card size; TABLE_ZOOMS steps, from the densest
//   table_view:       the view of the table's step
//   table_set_zoom, table_set_view: another step (the cursor's item stays in view)
//   table_zoom_label, table_zoom_icon: a step's words and icon, for a program's control
//   table_zoom_key, table_zoom_from_key: a step's stable name, to save it
//   table_card_name:  a name cut in its middle to fit a card's lines, its extension kept
//
// The selection is the table's list's (`vl`) in every view; in Grid and Columns the table keeps that list's rows and
// gives `vl.key` the box that has the keyboard.

import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// The views of a table's rows.
Table_View :: enum u8 {
	Details,   // the header and every column shown
	List,      // the first column alone (an icon and a name), one a line
	Columns,   // the names column by column, the columns scrolled sideways
	Grid,      // cards in rows: a picture, the name, a weak line
}

// A step of a table's zoom: its view and, in Grid, its cards' width in ems.
Table_Zoom :: struct {
	view:    Table_View,
	card_em: f32,
}

// The steps of the zoom, and the one table_set_view(.Grid) picks (Cards).
TABLE_ZOOMS :: 7
TABLE_ZOOM_CARDS :: 4
// A card's height and its picture's, of its width; a line of a card's name, in ems.
TABLE_CARD_HEIGHT :: 1.2
TABLE_CARD_PICTURE :: 0.72
TABLE_CARD_LINE_EM :: 1.3
// A column of the Columns view, in ems.
TABLE_COLUMN_EM :: 20
// The room between cards and around them, in ems (a step of the spacing scale).
@(private = "file") TABLE_CARD_GAP :: SPACE_2
// How fast a card's size follows a new step (anim's rate): the cards grow between the steps.
@(private = "file") TABLE_CARD_RATE :: 22
// The room under the last name of a column, in ems.
@(private = "file") TABLE_COLUMNS_FOOT_EM :: 0.4
// A name's second line's size, of the font's.
@(private = "file") TABLE_CARD_LINE_FONT :: 0.88
// A step of the zone's zoom this close to a whole one is whole (pow and log give 0.9999...).
@(private = "file") TABLE_ZOOM_STEP_EPS :: 0.001

// Step `i` (clamped): Details, List, Columns, then cards of 8.5, 11.5, 15 and 20 ems.
table_zoom_step :: proc(i: int) -> Table_Zoom {
	switch clamp(i, 0, TABLE_ZOOMS - 1) {
	case 0: return {.Details, 0}
	case 1: return {.List, 0}
	case 2: return {.Columns, 0}
	case 3: return {.Grid, 8.5}
	case 4: return {.Grid, 11.5}
	case 5: return {.Grid, 15}
	}
	return {.Grid, 20}
}

// The view of the table's step.
table_view :: proc(t: ^Table) -> Table_View { return table_zoom_step(t.zoom).view }

// The table at step `zoom` (clamped). The cursor's item is brought into view in the new layout. True when it changed.
// (Table_Events.zoomed says only the changes of the zoom keys and the wheel: a program that calls this knows.)
table_set_zoom :: proc(t: ^Table, zoom: int) -> (changed: bool) {
	z := clamp(zoom, 0, TABLE_ZOOMS - 1)
	if z == t.zoom { return false }
	t.zoom = z
	if t.vl.sel >= 0 { t.vl.reveal = LIST_REVEAL_FRAMES }
	return true
}

// The table in view `view`: its step (Grid: Cards, or the cards' size it has). True when it changed.
table_set_view :: proc(t: ^Table, view: Table_View) -> (changed: bool) {
	if table_view(t) == view { return false }
	switch view {
	case .Details: return table_set_zoom(t, 0)
	case .List:    return table_set_zoom(t, 1)
	case .Columns: return table_set_zoom(t, 2)
	case .Grid:    return table_set_zoom(t, TABLE_ZOOM_CARDS)
	}
	return false
}

// What step `i` is called, in the language in use.
table_zoom_label :: proc(i: int) -> string {
	switch clamp(i, 0, TABLE_ZOOMS - 1) {
	case 0: return i18n.tr("Details")
	case 1: return i18n.tr("Names")
	case 2: return i18n.tr("Columns")
	case 3: return i18n.tr("Small cards")
	case 4: return i18n.tr("Cards")
	case 5: return i18n.tr("Large cards")
	}
	return i18n.tr("Huge cards")
}

// Step `i`'s icon (lucide).
table_zoom_icon :: proc(i: int) -> string {
	switch clamp(i, 0, TABLE_ZOOMS - 1) {
	case 0: return lucide.TABLE_2
	case 1: return lucide.LIST
	case 2: return lucide.COLUMNS_2
	case 3, 4: return lucide.LAYOUT_GRID
	}
	return lucide.IMAGE
}

// Step `i`'s stable name, for a program's saved state (the order of the steps may change; the names do not).
table_zoom_key :: proc(i: int) -> string {
	switch clamp(i, 0, TABLE_ZOOMS - 1) {
	case 0: return "details"
	case 1: return "list"
	case 2: return "columns"
	case 3: return "cards-small"
	case 4: return "cards"
	case 5: return "cards-large"
	}
	return "cards-huge"
}

// The step a name of table_zoom_key names; ok false for a name it does not know.
table_zoom_from_key :: proc(key: string) -> (zoom: int, ok: bool) {
	for i in 0 ..< TABLE_ZOOMS { if table_zoom_key(i) == key { return i, true } }
	return 0, false
}

// The steps the table's zone took since the last build (zoom_keys): Ctrl+wheel and the zoom keys multiply the zone's
// zoom by feel.zoom_step per step; its log in that base is a number of steps, its fraction kept for the next. The zone is
// then set back to 1. Ctrl+0 (the zone's reset leaves its zoom at 0) gives the first step back. True when the step changed.
@(private)
table_zoom_follow :: proc(s: ^State, t: ^Table) -> (changed: bool) {
	z := &t.zone
	if z.serial == t.zone_seen { return }
	t.zone_seen = z.serial
	if z.zoom == 0 {
		t.zoom_rest = 0
		changed = table_set_zoom(t, 0)
	} else {
		step := s.feel.zoom_step
		if step > 1 && z.zoom > 0 { t.zoom_rest += f32(math.ln(f64(z.zoom)) / math.ln(f64(step))) }
		whole := int(t.zoom_rest + (t.zoom_rest > 0 ? TABLE_ZOOM_STEP_EPS : -TABLE_ZOOM_STEP_EPS))
		t.zoom_rest -= f32(whole)
		if whole != 0 { changed = table_set_zoom(t, t.zoom + whole) }
		// (at an end of the steps, more of the same way is lost: the way back is one step)
		if t.zoom == 0 || t.zoom == TABLE_ZOOMS - 1 { t.zoom_rest = 0 }
	}
	// (1, not 0: 0 is what the zone's reset leaves)
	z.zoom = 1
	return
}

// What the items' keys go by in the table's view: the items in a line or a column, how they flow, a page in lines.
@(private)
table_item_flow :: proc(t: ^Table) -> (per: int, flow: Item_Flow, page: int) {
	switch table_view(t) {
	case .Details, .List: return 1, .Lines, max(t.vl.page_rows - 1, 1)
	case .Columns:        return max(t.line_items, 1), .Columns, 1
	case .Grid:           return max(t.line_items, 1), .Lines, max(t.grid.page_rows - 1, 1)
	}
	return 1, .Lines, 1
}

// Escape during a rectangle (Table.rubber_band): the selection there was before it. False when none runs: the Escape is
// someone else's (a program that reads Escape before the table is built asks this first).
table_band_cancel :: proc(t: ^Table) -> bool {
	return item_band_cancel(&t.band, &t.vl.selection, Item_Rows{count = len(t.ids), ids = t.ids[:]})
}

// A name in at most `lines` lines of `width` pixels at the style's font (wrapped at its spaces, as a card's paragraph
// wraps it): too long, it is cut in its middle, its end kept (the extension and a few letters before it say what the
// file is).
table_card_name :: proc(name: string, width: f32, lines: int) -> string {
	st := top_style()
	if len(wrap_lines_cached(st.font, st.font_size, name, width)) <= lines { return name }
	// (the starts of its letters: it is cut between them)
	starts := make([dynamic]int, 0, len(name), context.temp_allocator)
	for _, i in name { append(&starts, i) }
	n := len(starts)
	if n < 4 { return name }
	ext := 0
	if dot := strings.last_index_byte(name, '.'); dot > 0 { for _ in name[dot:] { ext += 1 } }
	tail := min(ext + 4, n / 2)
	tail_at := starts[n - tail]
	// the most letters of the start that fit before it (found by halves)
	lo, hi := 0, n - tail
	for lo < hi {
		mid := (lo + hi + 1) / 2
		cut := strings.concatenate({name[:starts[mid]], "…", name[tail_at:]}, context.temp_allocator)
		if len(wrap_lines(st.font, st.font_size, cut, width)) <= lines { lo = mid } else { hi = mid - 1 }
	}
	return strings.concatenate({name[:starts[lo]], "…", name[tail_at:]}, context.temp_allocator)
}

////////////////////////////////
// The views of items (Columns, Grid): the list's selection kept by the table

// Before a view of items is built: the list's rows are the items (its copy of the ids, made again when they change), its
// flags of the frame cleared as vlist clears them, and its keys when its box (`key`, the last build's) has the
// keyboard. Returns the cursor's item before them (table_items_end tells a change).
@(private = "file")
table_items_begin :: proc(s: ^State, t: ^Table, d: ^Table_Data, key: Key, ev: ^Table_Events) -> (sel_before: int) {
	n := len(t.ids)
	if t.vl.ids_version != t.ids_version || len(t.vl.ids) != n {
		resize(&t.vl.ids, n)
		copy(t.vl.ids[:], t.ids[:])
		t.vl.ids_version = t.ids_version
		// (the list's heights are its rows': Details places them again when it is back)
		t.vl.heights_due = true
		t.vl.row_ids, t.vl.count = t.vl.ids[:], n
		item_selection_keep(&t.vl.selection, list_rows(&t.vl))
	}
	t.vl.virtual = true
	t.vl.row_ids, t.vl.count = t.vl.ids[:], n
	clear(&t.vl.selectable)
	t.vl.activated, t.vl.cancelled, t.vl.changed, t.vl.selected_changed = false, false, false, false
	t.vl.focused = key != 0 && s.focus_key == key
	sel_before = t.vl.sel
	if t.vl.sel >= n { t.vl.sel = n - 1 }
	list_select_resolve(&t.vl)
	if t.vl.sel < 0 { t.vl.reveal = 0 }
	if t.vl.focused {
		table_item_keys(s, t, d)
		table_menu_key(t, ev)
	}
	return
}

// After the items: the list's change of the cursor and of the selection, said as vlist says them.
@(private = "file")
table_items_end :: proc(t: ^Table, sel_before: int) {
	if t.vl.sel != sel_before { t.vl.changed = true }
	list_selection_seen(&t.vl)
	// (the selection's look: strong while the window is the user's, as the rows')
	t.vl.focused = !inactive()
}

// The keys of a view of items that has the keyboard: the moves by item (item_move_target: a card, a row of cards, a
// name, a column), then the list's own keys (Enter, Escape, Ctrl+Space, Ctrl+A, type-ahead on the first column).
@(private = "file")
table_item_keys :: proc(s: ^State, t: ^Table, d: ^Table_Data) {
	if keys_held_by_dialog(s) { return }
	n := len(t.ids)
	rows := list_rows(&t.vl)
	per, flow, page := table_item_flow(t)
	moves := [?]platform.Key{.Down, .Up, .Right, .Left, .Page_Down, .Page_Up, .Home, .End}
	for mods in ([4]platform.Modifiers{{}, {.Shift}, {.Ctrl}, {.Ctrl, .Shift}}) {
		// (a single list gives Shift and Ctrl no meaning: those keys stay the program's)
		if mods != {} && !t.vl.multi { break }
		for k in moves {
			to, ok := item_move_target(k, t.vl.sel, n, per, flow, page)
			if !ok || !key_press(k, mods) { continue }
			item_selection_move(&t.vl.selection, rows, to, mods)
			t.vl.reveal = LIST_REVEAL_FRAMES
		}
	}
	list_keys(s, &t.vl)
	if t.vl.seek {
		// (type-ahead: a pass over the items, on a key typed)
		for i in 0 ..< n { list_seek_row(&t.vl, i, table_data_text(d, t.rows[i], 0)) }
		pick := t.vl.seek_after >= 0 ? t.vl.seek_after : t.vl.seek_first
		if pick >= 0 {
			item_selection_one(&t.vl.selection, rows, pick)
			t.vl.reveal = LIST_REVEAL_FRAMES
		}
		t.vl.seek = false
	}
}

// Item `i` (data row t.rows[i]): a card (`card`) or a line of the columns view, `w` by `h`, its look the list's rows':
// lit when selected, the cursor outlined in a multi list that has the keyboard. A press selects as a row's (Ctrl, Shift),
// gives the keyboard to the view (`vl.key`); Ctrl and a press start a rectangle from it (rubber_band). True when it took
// a press.
@(private = "file")
table_item :: proc(s: ^State, t: ^Table, d: ^Table_Data, i: int, w, h, em, lead_em: f32, card: bool, ev: ^Table_Events) -> (pressed: bool) {
	r := t.rows[i]
	rows := list_rows(&t.vl)
	lit := item_selection_has(&t.vl.selection, rows, i)
	keyboard := s.focus_key == t.vl.key && t.vl.key != 0
	cursor := t.vl.multi && keyboard && i == t.vl.sel && !lit
	if lit { push_tags(!inactive() ? "selected" : "weak_selected") }
	push_tags("list_row")
	flags := Box_Flags{.Clickable, .Row, .Draw_Hot_Effects, .Hot_Within}
	if lit { flags += {.Draw_Background, .Chosen} }
	mod := Style_Mod{width = px(w), height = px(h), axis = card ? .Y : .X, radius = em * shape_of(.Row)}
	if !card { mod.cross = Cross_Align.Center }
	if cursor {
		flags += {.Draw_Border}
		mod.border = color("accent")
	}
	next(mod)
	b := build_box(flags, fmt.tprintf("###item%d", i))
	pop_tags()
	if lit { pop_tags() }
	b.cursor = .Arrow
	sig := signal(b)
	a11y_default(b, {role = .List_Box_Option, name = table_label(d, r), selected = lit, position = i + 1, set_size = len(t.ids)})
	tip := ""
	if parent(b) {
		tone := d.tones[r]
		table_tone_push(tone)
		if card {
			tip = table_card_body(t, d, r, w, h, em, lit)
		} else {
			tip = table_first_cell(t, d, r, em, lead_em, h, fill())
		}
		table_tone_pop(tone)
	}
	table_cell_tip(sig, tip)
	if i == t.vl.sel { t.sel_rect = b.rect }
	if !(sig.pressed || sig.right_clicked) {
		if sig.double_clicked { ev.activated = true }
		return
	}
	// (a screen reader's press has no modifiers of its own: the item alone)
	mods: platform.Modifiers
	if sig.pointer_pressed { mods = sig.mods }
	if sig.pressed {
		if t.rubber_band && t.vl.multi && .Ctrl in mods && .Shift not_in mods {
			// (Ctrl: the item toggled, and a drag from it does the same to the items it passes)
			item_band_begin(&t.band, box_from_key(t.vl.key), &t.vl.selection, lit)
		}
		item_selection_click(&t.vl.selection, rows, i, mods)
	} else {
		item_selection_context(&t.vl.selection, rows, i)
		ev.menu, ev.menu_at = true, mouse_pos()
	}
	if sig.double_clicked { ev.activated = true }
	s.focus_key = t.vl.key
	s.focus_visible = false
	return true
}

// A card's content: its picture (Table.picture, else the lead) at its size, its name on one or two lines cut in its
// middle, its weak line (Table.card_line). Returns the whole name when it is cut and the pointer is on the card.
@(private = "file")
table_card_body :: proc(t: ^Table, d: ^Table_Data, r: int, w, h, em: f32, lit: bool) -> (tip: string) {
	pic := math.round(w * TABLE_CARD_PICTURE)
	space(TABLE_CARD_GAP)
	next({width = fill(), height = px(pic), axis = .X, cross = .Center})
	if row(.Center, {}, "###pic") {
		space(TABLE_CARD_GAP)
		if t.picture != nil {
			t.picture(t, r, pic)
		} else if t.lead != nil {
			spacer(fill())
			t.lead(t, r, pic)
			spacer(fill())
		}
		space(TABLE_CARD_GAP)
	}
	spacer(fill())
	// the name on two lines where the card has room for them (under its picture, above its weak line), else on one
	text := table_data_text(d, r, 0)
	lines := h - pic - em * (2 * TABLE_CARD_GAP + TABLE_CARD_LINE_EM) >= em * TABLE_CARD_LINE_EM * 2 ? 2 : 1
	pad := top_style().text_pad
	name := table_card_name(text, w - 2 * pad - 1, lines)
	if name != text { tip = text }   // (shown by table_cell_tip while the pointer rests on the card)
	next({width = fill(), height = px(math.round(em * (lines == 2 ? TABLE_CARD_LINE_EM * 2 : 1.5))), text_align = .Center})
	// (a card's name is the card's: its press selects it; not text to select)
	paragraph(fmt.tprintf("%s###n", text_shown(name)), selectable = false)
	if t.card_line > 0 && t.card_line < d.cols {
		if !lit { push_tags("weak") }
		next({width = fill(), height = px(math.round(em * TABLE_CARD_LINE_EM)), text_align = .Center, font_size = em * TABLE_CARD_LINE_FONT})
		label(fmt.tprintf("%s###s", text_shown(table_data_text(d, r, t.card_line))))
		if !lit { pop_tags() }
	}
	space(TABLE_CARD_GAP)
	return
}

// The rows of cards' identities (a row: `per` cards, named by its first card, the count and the step), made again only
// when the ids, the cards in a row or the step changed: a new step's rows are measured anew, the others keep theirs.
@(private = "file")
table_grid_ids :: proc(t: ^Table, per: int) {
	from := [3]u64{t.ids_version, u64(per), u64(t.zoom)}
	if t.grid_ids_version != 0 && t.grid_from == from { return }
	mix := u64(key_from_u64(key_from_u64(0, u64(per)), u64(t.zoom)))
	lines := (len(t.ids) + per - 1) / per
	resize(&t.grid_ids, lines)
	for r in 0 ..< lines { t.grid_ids[r] = t.ids[r * per] ~ mix }
	t.grid_from = from
	t.grid_ids_version += 1
}

// The Grid view: cards in rows on a virtual list of rows of cards (Table.grid), as many in a row as the width laid out
// last time holds. Only the rows in view are built.
@(private)
table_grid_build :: proc(s: ^State, t: ^Table, d: ^Table_Data, empty: string, em, lead_em: f32, ev: ^Table_Events) {
	z := table_zoom_step(t.zoom)
	// (the cards grow from step to step)
	card_em := anim(key_from_string(parent_box().key, "###table_card_em"), z.card_em, TABLE_CARD_RATE)
	w := math.round(em * card_em)
	h := math.round(em * card_em * TABLE_CARD_HEIGHT)
	// (on whole pixels, as space lays it out: the rectangle's tests read the same gap as the spacers)
	gap := math.round(em * TABLE_CARD_GAP)
	room := w * 4
	if b := prev_box("###grid"); b != nil && b.size.x > 0 { room = b.size.x - scrollbar_room(b, .X) }
	per := max(1, int((room - gap) / (w + gap)))
	t.line_items = per
	table_grid_ids(t, per)
	n := len(t.ids)
	before := table_items_begin(s, t, d, t.grid.key, ev)
	// (the grid's list follows the cursor's card: its row is the one brought into view)
	t.grid.sel = t.vl.sel >= 0 ? t.vl.sel / per : -1
	if t.vl.reveal > 0 {
		t.grid.reveal = max(t.grid.reveal, t.vl.reveal)
		t.vl.reveal = 0
	}
	t.grid.no_typeahead = true   // (the letters are the items' list's: table_item_keys)
	pressed_item, pressed_empty := false, false
	next({width = fill(), height = fill()})
	if rows, ok := vlist("###grid", &t.grid, t.grid_ids[:], ids_version = t.grid_ids_version); ok {
		t.vl.key = t.grid.key
		for line in rows.first ..< rows.last {
			next({height = px(h + gap), radius = 0, cross = .Center})
			row := list_row(&t.grid, line, "", selectable = false)
			if row.pressed { pressed_empty = true }
			if parent(row.box) {
				space(TABLE_CARD_GAP)
				for c in 0 ..< per {
					i := line * per + c
					if i >= n { break }
					if table_item(s, t, d, i, w, h, em, lead_em, true, ev) { pressed_item = true }
					space(TABLE_CARD_GAP)
				}
			}
		}
		table_empty(t, empty, em)
		a11y_default(parent_box(), {role = .List_Box, multiselectable = t.vl.multi})
		if t.rubber_band {
			_ = item_band_update(&t.band, &t.vl.selection, list_rows(&t.vl), parent_box(), {kind = .Grid, vl = &t.grid, count = per, item_w = w, gap = gap}, pressed_item, pressed_empty)
		}
	}
	table_items_end(t, before)
}

// The Columns view: the names filled column by column, as many in a column as the height laid out last time holds, the
// columns side by side scrolled sideways (the wheel too). Only the columns in view are built.
@(private)
table_columns_build :: proc(s: ^State, t: ^Table, d: ^Table_Data, empty: string, em, lead_em: f32, ev: ^Table_Events) {
	row_h := dense(em * TABLE_ROW_EM)
	col_w := math.round(em * TABLE_COLUMN_EM)
	item_w := col_w - math.round(em * TABLE_CARD_GAP)
	size := [2]f32{col_w * 3, row_h * 12}
	if b := prev_box("###cols"); b != nil && b.size.y > 0 { size = {b.size.x, b.size.y - scrollbar_room(b, .Y)} }
	per := max(1, int((size.y - em * TABLE_COLUMNS_FOOT_EM) / row_h))
	t.line_items = per
	n := len(t.ids)
	ncols := (n + per - 1) / per
	before := table_items_begin(s, t, d, t.cols_key, ev)
	next({width = fill(), height = fill(), axis = .X})
	b := build_box({.Clip, .View_Scroll_X, .Allow_Overflow_X, .Scroll_Self, .Clickable, .Focusable, .Text_Input}, "###cols")
	b.cursor = .Arrow
	t.cols_key, t.vl.key = b.key, b.key
	sig := signal(b)
	a11y_default(b, {role = .List_Box, multiselectable = t.vl.multi})
	// the wheel, either way, scrolls sideways; the cursor moved by the keys is brought into view
	limit := max(0, f32(ncols) * col_w - size.x)
	if dx := sig.scrolled.x + sig.scrolled.y; dx != 0 { b.view_target.x = clamp(b.view_target.x + dx, 0, limit) }
	if t.vl.reveal > 0 && t.vl.sel >= 0 {
		c := f32(t.vl.sel / per)
		view_reveal(b, c * col_w, (c + 1) * col_w, .X)
		b.view_target.x = clamp(b.view_target.x, 0, limit)
		t.vl.reveal -= 1
	}
	off := b.view_off.x
	first := clamp(int(off / col_w) - 1, 0, ncols)
	last := clamp(int((off + size.x) / col_w) + 2, first, ncols)
	pressed_item := false
	if parent(b) {
		spacer(px(f32(first) * col_w))
		for c in first ..< last {
			next({width = px(col_w), height = fill(), axis = .Y})
			if column(.Start, {}, fmt.tprintf("###col%d", c)) {
				for k in 0 ..< per {
					i := c * per + k
					if i >= n { break }
					if table_item(s, t, d, i, item_w, row_h, em, lead_em, false, ev) { pressed_item = true }
				}
			}
		}
		spacer(px(f32(ncols - last) * col_w))
		if n == 0 {
			next({width = fill(), height = fill(), axis = .Y})
			if column(.Start, {}, "###cols_empty") { table_empty(t, empty, em) }
		}
	}
	if t.rubber_band {
		_ = item_band_update(&t.band, &t.vl.selection, list_rows(&t.vl), b, {kind = .Columns, count = per, item_w = item_w, step = col_w, row_h = row_h}, pressed_item)
	}
	table_items_end(t, before)
}
