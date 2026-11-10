package ui

// Sortable tables, in two layers.
//
// The layout and its header, for any table (a program that builds its own rows, with groups or tinted cells, uses these):
//   Table_Layout: the columns, their widths now (in ems), which are shown, the sort column and its direction
//   table_header: the columns' titles; a click sorts by a column, a second click reverses; the rule before a title,
//                 dragged, resizes the column; a right click asks for the columns' menu (table_column_items)
//   table_cell:   a cell under its title; says whether the pointer is on it and its text is cut (table_cell_tip shows it)
//
// The table of texts, on top of them (rows of texts and numbers, filtered and sorted by the table):
//   Table_Data:   the rows of a reading: every cell's text (made once, in its arena) and the number a numeric column
//                 sorts by, each row's identity, what the filter looks in, its tone
//   Table:        the layout, the rows shown (filtered, sorted), the virtual list that builds only those in view
//   table_apply:  filters and sorts again (new data, a new filter, a new sort); the same row stays selected
//   table_keys:   Up / Down, Page Up / Page Down, Ctrl+Home / Ctrl+End move the selection while the keyboard is elsewhere
//                 (a filter field); Enter activates; the Menu key and Shift+F10 ask for the row's menu
//   table_build:  the header and the rows; a cut cell shows its whole text in a tooltip; the selection is drawn strong
//                 while the window is the user's, whatever has the keyboard
//
// Sizes are in ems of the font size. Colours come from the theme: the "weak" tag for weak columns and dim rows, "bad" for
// rows in fault, "accent" and "border" for the rules.

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "../ascii"
import "../draw"

// Seconds the pointer rests on a cut cell before its whole text shows.
TABLE_TIP_DELAY_S :: 0.5
// A column's width, in ems, when dragged.
TABLE_COLUMN_MIN_EM :: 3
TABLE_COLUMN_MAX_EM :: 80
// Heights of the header and of a row, in ems (before ui.dense).
TABLE_HEADER_EM :: 2.2
TABLE_ROW_EM :: 1.9
// The grip of a column's rule, in ems: where a drag takes it.
@(private = "file") TABLE_RULE_GRIP_EM :: 0.7
// Room at the right of the last column for the rows' scroll bar, which floats over them.
@(private = "file") TABLE_SCROLLBAR_EM :: 1
// Room for the sort's arrow, and the pad of a number's cell at its right.
@(private = "file") TABLE_ARROW_EM :: 1.5
@(private = "file") TABLE_NUMBER_PAD_EM :: 0.6
// Where the Menu key opens a row's menu: this far into the selected row, under it.
@(private = "file") TABLE_MENU_INSET_EM :: 2.5

Table_Column :: struct {
	title:  string,
	width:  f32,    // in ems; 0: the room the others leave (one column has it)
	number: bool,   // right-aligned, sorted by its number, largest first at the first click
	weak:   bool,   // its text in the weak colour (details beside the name)
	hidden: bool,   // not shown until the user asks (table_column_items)
}

// What the header edits; a program saves it (the widths, which are shown, the sort).
Table_Layout :: struct {
	columns:    []Table_Column,
	width:      []f32,    // the columns' widths now, in ems (owned)
	shown:      []bool,   // (owned) the first column is always shown
	sort:       int,
	descending: bool,
}

table_layout_init :: proc(l: ^Table_Layout, columns: []Table_Column, sort := 0, descending := false) {
	l.columns = columns
	l.width = make([]f32, len(columns))
	l.shown = make([]bool, len(columns))
	table_layout_reset(l)
	l.sort, l.descending = sort, descending
}

table_layout_destroy :: proc(l: ^Table_Layout) {
	delete(l.width)
	delete(l.shown)
	l.width, l.shown = nil, nil
}

// The columns' own widths and visibility back. A sort on a column hidden now goes to the first column.
table_layout_reset :: proc(l: ^Table_Layout) {
	for c, i in l.columns {
		l.width[i] = c.width
		l.shown[i] = i == 0 || !c.hidden
	}
	if !l.shown[l.sort] { l.sort, l.descending = 0, false }
}

// Shows or hides column `k` (never the first). A sort on it goes to the first column. True when the sort changed.
table_layout_toggle :: proc(l: ^Table_Layout, k: int) -> (sort_changed: bool) {
	if k <= 0 || k >= len(l.columns) { return }
	l.shown[k] = !l.shown[k]
	if !l.shown[k] && l.sort == k {
		l.sort, l.descending = 0, false
		return true
	}
	return
}

// What happened in the header in a build.
Table_Header_Events :: struct {
	sorted:  bool,   // a title was clicked: the sort changed (the caller sorts its rows again)
	resized: bool,   // a column's rule was let go: its width changed (the caller saves the layout)
	menu:    bool,   // a right click on the header: the columns' menu, at the pointer
}

// The columns' titles in a row of the width `next` gives (its height: TABLE_HEADER_EM; `next` may set a background).
// `lead_em`: the room before the first title, in ems (where the rows put a chevron or an icon).
table_header :: proc(id: string, l: ^Table_Layout, lead_em: f32 = 0.6) -> (ev: Table_Header_Events) {
	s := gs()
	em := font_size()
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = px(dense(em * TABLE_HEADER_EM)) }
	flags := Box_Flags{.Draw_Side_Bottom, .Clickable}
	if m.bg != nil { flags += {.Draw_Background} }
	s.next_mod, s.has_next = m, true
	if row(.Center, flags, id) {
		if signal(parent_box()).right_clicked { ev.menu = true }
		for c, k in l.columns {
			if !l.shown[k] { continue }
			sorting := l.sort == k
			next({width = l.width[k] == 0 ? fill() : px(em * l.width[k]), height = pct(1)})
			sig: Signal
			if row(.Center, {.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###hd_%d", k)) {
				sig = signal(parent_box())
				if k > 0 && l.width[k] > 0 {
					if table_rule(l, k, em) { ev.resized = true }
				} else {
					spacer(px(em * (k == 0 ? lead_em : TABLE_RULE_GRIP_EM)))
				}
				if c.number { spacer(fill()) }
				if !sorting { push_tags("weak") }
				next({width = text_size(), height = pct(1), text_pad = 0})
				label(fmt.tprintf("%s###t", text_shown(c.title)))
				if !sorting { pop_tags() }
				if !c.number { spacer(fill()) }
				if sorting {
					if tags("weak") { table_arrow(l.descending, em * TABLE_ARROW_EM) }
				} else {
					spacer(px(em * TABLE_NUMBER_PAD_EM))
				}
			}
			a11y_default(sig.box, {role = .Column_Header, name = c.title})
			if sig.clicked {
				if l.sort == k {
					l.descending = !l.descending
				} else {
					l.sort, l.descending = k, c.number
				}
				ev.sorted = true
			}
			if sig.right_clicked { ev.menu = true }
		}
		spacer(px(em * TABLE_SCROLLBAR_EM))
	}
	return
}

// The line before a column's title: dragged, the column grows or shrinks (the fill column takes what is left). True
// when it is let go after a drag.
@(private = "file")
table_rule :: proc(l: ^Table_Layout, k: int, em: f32) -> (released: bool) {
	next({width = px(em * TABLE_RULE_GRIP_EM), height = pct(1), cursor = .Resize_H})
	grip := build_box({.Clickable}, "###rule")
	sig := signal(grip)
	if parent(grip) {
		spacer(fill())
		hot := grip.hot_t > 0 || sig.dragging
		next({width = px(max(1, scale()) * (hot ? 2 : 1)), height = px(em * 1.2), bg = hot ? color("accent") : color("border")})
		build_box({.Draw_Background}, "###line")
		spacer(fill())
	}
	if sig.pressed { drag_store({l.width[k], 0, 0, 0}) }
	if sig.dragging { l.width[k] = clamp(drag_load()[0] - sig.drag_delta.x / em, TABLE_COLUMN_MIN_EM, TABLE_COLUMN_MAX_EM) }
	return sig.released
}

@(private = "file")
Arrow_Draw :: struct { down: bool, color: Color, scale: f32 }

// The sort's arrow: a stem and its head, pointing down for a descending sort.
@(private = "file")
table_arrow :: proc(down: bool, width: f32) {
	d := frame_new(Arrow_Draw)
	d^ = {down, color("text"), scale()}
	next({width = px(width), height = pct(1)})
	custom("###arrow", arrow_draw, d)
}

@(private = "file")
arrow_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Arrow_Draw)(user)
	c := draw.rect_center(b.rect)
	h := b.font_size * 0.36
	w := h * 0.7
	dir: f32 = d.down ? 1 : -1
	tip := Vec2{c.x, c.y + dir * h}
	line := max(1, math.round(d.scale * 1.25))
	draw.polyline(dc, {{c.x, c.y - dir * h}, tip}, line, d.color)
	draw.polyline(dc, {{c.x - w, tip.y - dir * w}, tip, {c.x + w, tip.y - dir * w}}, line, d.color)
}

// The menu items of the columns (in the caller's ctx_menu): each column but the first, checked when shown; a click
// shows or hides it and keeps the menu open. True when the sort changed (a hidden column was sorted by).
table_column_items :: proc(l: ^Table_Layout) -> (changed, sort_changed: bool) {
	for c, k in l.columns {
		if k == 0 { continue }
		if menu_item(c.title, checked = l.shown[k], keep_open = true).clicked {
			if table_layout_toggle(l, k) { sort_changed = true }
			changed = true
		}
	}
	return
}

// A cell of a row under column `col`'s title: its text clipped to the column's width, a number at the right. `bg`: a
// background (a busy cell's tint). True when the pointer is on the cell and its text does not fit (table_cell_tip).
table_cell :: proc(l: ^Table_Layout, col: int, text: string, bg: Maybe(Color) = nil) -> (cut: bool) {
	em := font_size()
	c := l.columns[col]
	pad := c.number ? em * TABLE_NUMBER_PAD_EM : em * TABLE_RULE_GRIP_EM * 0.5 + max(1, scale())
	flags := Box_Flags{.Draw_Text, .Clip}
	if bg != nil { flags += {.Draw_Background} }
	next({width = l.width[col] == 0 ? fill() : px(em * l.width[col]), height = pct(1), text_align = c.number ? .Right : .Left, text_pad = pad, bg = bg})
	b := build_box(flags, fmt.tprintf("%s###c%d", text_shown(text), col))
	return text_cut_under_mouse(b, text, pad)
}

// Text to show as it is in a box's id: a "##" in it would end the shown part (key.odin), so a zero-width space goes
// between the two signs.
text_shown :: proc(text: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(text, "##") { return text }
	out, _ := strings.replace_all(text, "##", "#​#", allocator)
	return out
}

// The end of a row's cells: the room of the rows' scroll bar.
table_row_end :: proc() { spacer(px(font_size() * TABLE_SCROLLBAR_EM)) }

// Whether the pointer is on the box and `text` does not fit in it with `pad` on each side (the box as laid out at the
// last build).
text_cut_under_mouse :: proc(b: ^Box, text: string, pad: f32) -> bool {
	m := mouse_pos()
	r := b.rect
	if m.x < r.min.x || m.x >= r.max.x || m.y < r.min.y || m.y >= r.max.y { return false }
	return text_width(b.font, b.font_size, text) + 2 * pad > r.max.x - r.min.x
}

// The whole text of a cut cell, beside the pointer, once it has rested on the row for TABLE_TIP_DELAY_S.
table_cell_tip :: proc(row: Signal, text: string) {
	if text == "" || !hovered_for(row, TABLE_TIP_DELAY_S) { return }
	if tooltip_beside() { tooltip_text(text) }
}

////////////////////////////////
// The table of texts

// How a row reads: plain, quiet (the "weak" tag: a unit that is not running), or a fault (the "bad" tag).
Table_Tone :: enum u8 { Normal, Dim, Bad }

// The rows of a reading: made anew with each reading (table_data_reset), then given to table_apply.
Table_Data :: struct {
	arena:  virtual.Arena,      // every text of the rows
	cols:   int,
	cells:  [dynamic]string,    // row by row
	nums:   [dynamic]f64,       // row by row: what a numeric column sorts by
	ids:    [dynamic]u64,       // each row's identity: the selection follows it
	search: [dynamic]string,    // what the filter looks in, in lower case
	tones:  [dynamic]Table_Tone,
}

table_data_reset :: proc(d: ^Table_Data, cols: int) {
	virtual.arena_destroy(&d.arena)
	d.arena = {}
	d.cols = cols
	clear(&d.cells)
	clear(&d.nums)
	clear(&d.ids)
	clear(&d.search)
	clear(&d.tones)
}

table_data_destroy :: proc(d: ^Table_Data) {
	virtual.arena_destroy(&d.arena)
	delete(d.cells)
	delete(d.nums)
	delete(d.ids)
	delete(d.search)
	delete(d.tones)
	d^ = {}
}

table_data_count :: proc(d: ^Table_Data) -> int { return len(d.ids) }

// A copy of `text` that lives as long as the data's rows (what a row's lead hook reads: an icon's name).
table_data_clone :: proc(d: ^Table_Data, text: string) -> string { return strings.clone(text, virtual.arena_allocator(&d.arena)) }

// A new row; its cells follow (table_data_cell, as many as the columns). `search`: what the filter finds it by.
table_data_row :: proc(d: ^Table_Data, id: u64, search: string, tone := Table_Tone.Normal) {
	append(&d.ids, id)
	append(&d.search, strings.to_lower(search, virtual.arena_allocator(&d.arena)))
	append(&d.tones, tone)
}

// The next cell of the last row: its text, and the number it sorts by in a numeric column.
table_data_cell :: proc(d: ^Table_Data, text: string, num: f64 = 0) {
	append(&d.cells, strings.clone(text, virtual.arena_allocator(&d.arena)))
	append(&d.nums, num)
}

table_data_text :: proc(d: ^Table_Data, row, col: int) -> string { return d.cells[row * d.cols + col] }

Table :: struct {
	using layout: Table_Layout,
	order:     [dynamic]int,    // the rows shown: filtered, sorted (indices of the data)
	ids:       [dynamic]u64,    // their identities (the list's keys)
	vl:        Virtual_List,
	query:     string,          // the filter applied, in lower case (owned)
	sel_rect:  Rect,            // the selected row, as last built (where the Menu key opens the menu)
	// Builds what goes before the first cell's text of data row `row` (an icon `size` wide); nil: nothing.
	lead:      proc(t: ^Table, row: int, size: f32),
	lead_user: rawptr,
	lead_em:   f32,             // the room before the first title and the first cell (0: 0.6)
}

table_init :: proc(t: ^Table, columns: []Table_Column, sort := 0, descending := false) {
	table_layout_init(&t.layout, columns, sort, descending)
	t.vl.sel = -1
}

table_destroy :: proc(t: ^Table) {
	table_layout_destroy(&t.layout)
	delete(t.order)
	delete(t.ids)
	delete(t.query)
	vlist_destroy(&t.vl)
	t.order, t.ids, t.query = nil, nil, ""
}

// The data row selected, -1 for none.
table_selected :: proc(t: ^Table) -> int {
	if t.vl.sel < 0 || t.vl.sel >= len(t.order) { return -1 }
	return t.order[t.vl.sel]
}

// Filters and sorts the rows again (new data, a new filter, a new sort). `query` is matched in each row's search text,
// case ignored. The same row stays selected when it is shown; a new filter selects its first row.
table_apply :: proc(t: ^Table, d: ^Table_Data, query: string) {
	keep: u64
	has_keep := t.vl.sel >= 0 && t.vl.sel < len(t.ids)
	if has_keep { keep = t.ids[t.vl.sel] }
	q := strings.to_lower(query, context.temp_allocator)
	if q != t.query {
		delete(t.query)
		t.query = strings.clone(q)
		// a new search starts from its first row; a cleared one keeps the row selected, in view
		if q != "" {
			has_keep = false
			vlist_scroll_to(&t.vl, 0)
		}
	}
	clear(&t.order)
	for i in 0 ..< len(d.ids) {
		if q == "" || strings.contains(d.search[i], q) { append(&t.order, i) }
	}
	Sort_Ctx :: struct { d: ^Table_Data, col: int, number: bool }
	ctx := Sort_Ctx{d, t.sort, t.columns[t.sort].number}
	context.user_ptr = &ctx
	slice.sort_by(t.order[:], proc(a, b: int) -> bool {
		x := (^Sort_Ctx)(context.user_ptr)
		if x.number {
			na, nb := x.d.nums[a * x.d.cols + x.col], x.d.nums[b * x.d.cols + x.col]
			if na != nb { return na < nb }
		} else {
			c := ascii.compare_fold(table_data_text(x.d, a, x.col), table_data_text(x.d, b, x.col))
			if c != 0 { return c < 0 }
		}
		// ties: by the first column, then as read
		c := ascii.compare_fold(table_data_text(x.d, a, 0), table_data_text(x.d, b, 0))
		if c != 0 { return c < 0 }
		return a < b
	})
	if t.descending { slice.reverse(t.order[:]) }
	clear(&t.ids)
	for i in t.order { append(&t.ids, d.ids[i]) }
	vlist_invalidate(&t.vl)
	t.vl.sel = -1
	if has_keep {
		for id, i in t.ids {
			if id == keep {
				t.vl.sel = i
				if q == "" { list_select(&t.vl, i) }   // (a cleared filter: the row stays in view)
				break
			}
		}
	}
	if t.vl.sel < 0 && q != "" && len(t.ids) > 0 { list_select(&t.vl, 0) }
}

// Selects the row of `id` and brings it into view, when it is shown.
table_select_id :: proc(t: ^Table, id: u64) -> bool {
	for v, i in t.ids {
		if v == id {
			list_select(&t.vl, i)
			return true
		}
	}
	return false
}

// What happened to the rows in a build.
Table_Events :: struct {
	menu:      bool,   // a right click on a row (it is selected), or the Menu key: its menu, at `menu_at`
	menu_at:   Vec2,
	keyboard:  bool,   // the menu was asked from the keyboard (its first item gets the focus)
	activated: bool,   // a double click on a row, or Enter
	sorted:    bool,   // a title was clicked: table_apply again
	resized:   bool,   // a column's rule was let go (save the layout)
	columns:   bool,   // a right click on the header: the columns' menu at the pointer (table_column_items)
}

// The keys of the table while the keyboard is elsewhere in the window (a filter field): call it when no menu or dialog
// is open. A focused table's own list takes these keys itself.
table_keys :: proc(t: ^Table) -> (ev: Table_Events) {
	n := len(t.ids)
	if n == 0 { return }
	to := t.vl.sel
	page := max(t.vl.page_rows - 1, 1)
	if key_press(.Down) { to = t.vl.sel + 1 }
	if key_press(.Up) { to = t.vl.sel < 0 ? 0 : t.vl.sel - 1 }
	if key_press(.Page_Down) { to = t.vl.sel + page }
	if key_press(.Page_Up) { to = t.vl.sel - page }
	if key_press(.Home, {.Ctrl}) { to = 0 }
	if key_press(.End, {.Ctrl}) { to = n - 1 }
	to = clamp(to, 0, n - 1)
	if to != t.vl.sel { list_select(&t.vl, to) }
	if t.vl.sel >= 0 {
		if key_press(.Return) { ev.activated = true }
		if key_press(.Menu) || key_press(.F10, {.Shift}) {
			ev.menu, ev.keyboard = true, true
			ev.menu_at = {t.sel_rect.min.x + font_size() * TABLE_MENU_INSET_EM, t.sel_rect.max.y}
		}
	}
	return
}

// The header and the rows, in the room `next` gives (else all that is left). `empty`: what the table says when it has
// no row to show (the caller's words: nothing read yet, nothing matches the filter).
table_build :: proc(id: string, t: ^Table, d: ^Table_Data, empty: string) -> (ev: Table_Events) {
	s := gs()
	em := font_size()
	lead_em := t.lead_em > 0 ? t.lead_em : 0.6
	m := s.has_next ? s.next_mod : Style_Mod{}
	s.has_next = false
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = fill() }
	m.axis = .Y
	next(m)
	if column(id = id) {
		h := table_header("###header", &t.layout, lead_em)
		ev.sorted, ev.resized, ev.columns = h.sorted, h.resized, h.menu
		row_h := dense(em * TABLE_ROW_EM)
		next({width = fill(), height = fill()})
		if rows, ok := vlist("###rows", &t.vl, t.ids[:]); ok {
			// (the keyboard may be in a filter field, yet the selection is the window's: strong while the window is the user's)
			t.vl.focused = !inactive()
			for i in rows.first ..< rows.last {
				r := t.order[i]
				next({height = px(row_h)})
				row := list_row(&t.vl, i, table_label(d, r))
				tip := ""
				if parent(row.box) { tip = table_cells(t, d, r, em, lead_em) }
				table_cell_tip(row, tip)
				if i == t.vl.sel { t.sel_rect = row.box.rect }
				if row.double_clicked { ev.activated = true }
				if row.right_clicked {
					t.vl.sel = i
					ev.menu, ev.menu_at = true, mouse_pos()
				}
			}
			if len(t.ids) == 0 && empty != "" {
				if tags("weak") {
					next({width = fill(), height = px(em * 5)})
					if style({text_align = .Center}) { label(fmt.tprintf("%s###empty", text_shown(empty))) }
				}
			}
		}
		if t.vl.activated { ev.activated = true }
	}
	return
}

// What a screen reader says of a row: its first two cells.
table_label :: proc(d: ^Table_Data, r: int) -> string {
	if d.cols < 2 { return table_data_text(d, r, 0) }
	return fmt.tprintf("%s, %s", table_data_text(d, r, 0), table_data_text(d, r, 1))
}

// The cells of data row `r`. Returns the whole text of the cell under the pointer when it is cut.
@(private = "file")
table_cells :: proc(t: ^Table, d: ^Table_Data, r: int, em, lead_em: f32) -> (tip: string) {
	tone := d.tones[r]
	if tone == .Dim { push_tags("weak") }
	if tone == .Bad { push_tags("bad") }
	defer if tone != .Normal { pop_tags() }
	for c, k in t.columns {
		if !t.shown[k] { continue }
		text := table_data_text(d, r, k)
		if k == 0 {
			// the first column: the lead (an icon), then the text
			next({width = t.width[0] == 0 ? fill() : px(em * t.width[0]), height = pct(1), axis = .X, cross = .Center})
			if row(id = "###c_first") {
				spacer(px(em * lead_em * 0.8))
				if t.lead != nil {
					t.lead(t, r, em * 1.5)
					spacer(px(em * 0.4))
				}
				next({width = fill(), height = pct(1), text_pad = 0})
				b := build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###c0", text_shown(text)))
				if text_cut_under_mouse(b, text, 0) { tip = text }
			}
			continue
		}
		if c.weak && tone == .Normal { push_tags("weak") }
		if table_cell(&t.layout, k, text) { tip = text }
		if c.weak && tone == .Normal { pop_tags() }
	}
	table_row_end()
	return
}
