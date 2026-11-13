package ui

// Sortable tables, in two layers.
//
// The layout and its header, for any table (a program that builds its own rows, with groups or tinted cells, uses these):
//   Table_Layout: the columns, their widths now (in ems), which are shown, the sort column and its direction
//   table_header: the columns' titles; a click sorts by a column, a second click reverses, a third gives the rows their
//                 own order back (unsorted); a title dragged sideways moves its column (not the first); the rule before
//                 a title, dragged, resizes the column; a right click asks for the columns' menu (table_column_items)
//   table_cell:   a cell under its title, what matches Table_Layout.highlight lit; says whether the pointer is on it and
//                 its text is cut (table_cell_tip shows it)
//   table_menu_items: the header's menu (a column reset, unsorted, the columns shown, the default columns)
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
import "core:strconv"
import "core:strings"
import "../ascii"
import "../draw"

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
// The fill column (width 0) never goes narrower: when the window is too narrow, the last columns go past the right edge
// (cut by the rows) instead of the fill column going to nothing under its neighbours' text.
TABLE_FILL_MIN_EM :: 10
// How far a title is dragged sideways before it moves its column (a shorter press is a click), in ems.
@(private = "file") TABLE_MOVE_EM :: 0.6
// The width of the line that shows where a moved column goes, in pixels before the scale.
@(private = "file") TABLE_DROP_PX :: 2
// The sort of a table that has none: its rows in the data's own order.
TABLE_UNSORTED :: -1
// Room for the sort's arrow, and the pad of a number's cell at its right.
@(private = "file") TABLE_ARROW_EM :: 1.5
@(private = "file") TABLE_NUMBER_PAD_EM :: 0.6
// Where the Menu key opens a row's menu: this far into the selected row, under it.
@(private = "file") TABLE_MENU_INSET_EM :: 2.5

Table_Column :: struct {
	title:  string,
	width:  f32,    // in ems; 0: the room the others leave (one column has it)
	number: bool,   // right-aligned, sorted by its number, largest first at the first click
	low_first: bool,   // a number sorted from the lowest at the first click (an id)
	weak:   bool,   // its text in the weak colour (details beside the name)
	hidden: bool,   // not shown until the user asks (table_column_items)
	unsorted: bool, // its title sorts nothing (a column with no order of its own): a click on it does nothing
	descending_first: bool,   // a text sorted from the largest at the first click, as a number is (a date: the newest first)
}

// What a program builds in the header besides the titles (every field optional). `user` is given back to each.
//   lead:  in the room before the first title (lead_em wide): a box that checks every row
//   title: in column k's title, after its words (a filter's funnel); `hot`: the pointer is on that title
Table_Header_Options :: struct {
	user:  rawptr,
	lead:  proc(user: rawptr, em: f32),
	title: proc(user: rawptr, k: int, hot: bool, em: f32),
}

// What the header edits; a program saves it (the widths, which are shown, their order, the sort).
Table_Layout :: struct {
	columns:    []Table_Column,
	width:      []f32,    // the columns' widths now, in ems (owned)
	shown:      []bool,   // (owned) the first column is always shown
	order:      []int,    // (owned) the columns from left to right, indices of `columns`; the first is always first
	sort:       int,      // the column the rows are sorted by; TABLE_UNSORTED: none, the data's own order
	descending: bool,
	scroll_x:   f32,      // the rows' and the titles' sideways scroll at the last build (table_scroll_sync)
	// a title dragged sideways (table_header): its column
	moving:     bool,
	moving_col: int,
	menu_column: int,     // the column whose title was right-clicked for the header's menu (-1: the header's empty part)
	highlight:  string,   // what the cells light where it matches, each word of it (the filter's text; not owned)
}

// `sort`: the column sorted by at first (TABLE_UNSORTED: none).
table_layout_init :: proc(l: ^Table_Layout, columns: []Table_Column, sort := 0, descending := false) {
	l.columns = columns
	l.width = make([]f32, len(columns))
	l.shown = make([]bool, len(columns))
	l.order = make([]int, len(columns))
	l.sort, l.descending = sort, descending
	l.menu_column = -1
	table_layout_reset(l)
}

table_layout_destroy :: proc(l: ^Table_Layout) {
	delete(l.width)
	delete(l.shown)
	delete(l.order)
	l.width, l.shown, l.order = nil, nil, nil
}

// The columns' own widths, visibility and order back. A sort on a column hidden now goes to the first column.
table_layout_reset :: proc(l: ^Table_Layout) {
	for c, i in l.columns {
		l.width[i] = c.width
		l.shown[i] = i == 0 || !c.hidden
		l.order[i] = i
	}
	if l.sort >= 0 && !l.shown[l.sort] { l.sort, l.descending = 0, false }
}

// Shows or hides column `k` (never the first); shown again, it is where it was. A sort on it goes to the first
// column. True when the sort changed.
table_layout_toggle :: proc(l: ^Table_Layout, k: int) -> (sort_changed: bool) {
	if k <= 0 || k >= len(l.columns) { return }
	l.shown[k] = !l.shown[k]
	if !l.shown[k] && l.sort == k {
		l.sort, l.descending = 0, false
		return true
	}
	return
}

// Moves column `k` to place `to` of the order (1 and after: the first column stays first), the others shifted.
table_layout_move :: proc(l: ^Table_Layout, k, to: int) {
	from := -1
	for c, i in l.order { if c == k { from = i } }
	if from <= 0 || to <= 0 || to >= len(l.order) { return }
	list_move(l.order, from, to, from)
}

// The layout as a preference's text, and back. `keys[k]` names column k (a stable name: the titles may be translated).
//   widths: the columns whose width is not their own, "pid=6.5,command=30" (ems)
//   order:  the columns from left to right, "name,cpu,pid"
//   sort:   the sort's column, "-" before it when descending: "memory", "-memory"; "none": unsorted
table_widths_text :: proc(l: ^Table_Layout, keys: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for c, k in l.columns {
		if k >= len(keys) || l.width[k] == c.width { continue }
		if strings.builder_len(b) > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, "%s=%.1f", keys[k], l.width[k])
	}
	return strings.to_string(b)
}

// Sets the widths a text of table_widths_text names (bounded to TABLE_COLUMN_MIN_EM..TABLE_COLUMN_MAX_EM); a name it does
// not know or a width it cannot read is skipped. The fill column too: a width the user gave it (table_rule).
table_widths_apply :: proc(l: ^Table_Layout, keys: []string, text: string) {
	rest := text
	for pair in strings.split_iterator(&rest, ",") {
		eq := strings.index_byte(pair, '=')
		if eq < 0 { continue }
		k := table_key_index(keys, strings.trim_space(pair[:eq]))
		w, ok := strconv.parse_f32(strings.trim_space(pair[eq + 1:]))
		if k < 0 || !ok || k >= len(l.columns) { continue }
		l.width[k] = clamp(w, TABLE_COLUMN_MIN_EM, TABLE_COLUMN_MAX_EM)
	}
}

table_order_text :: proc(l: ^Table_Layout, keys: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for k, i in l.order {
		if k >= len(keys) { continue }
		if i > 0 { strings.write_byte(&b, ',') }
		strings.write_string(&b, keys[k])
	}
	return strings.to_string(b)
}

// Puts the columns a text of table_order_text names in its order, in the places they hold now: a column it does not
// name stays where it is (one added since the text was written), a name it does not know is skipped, the first column
// stays first.
table_order_apply :: proc(l: ^Table_Layout, keys: []string, text: string) {
	named := make([dynamic]int, context.temp_allocator)
	rest := text
	for name in strings.split_iterator(&rest, ",") {
		k := table_key_index(keys, strings.trim_space(name))
		if k <= 0 || k >= len(l.columns) || slice.contains(named[:], k) { continue }
		append(&named, k)
	}
	n := 0
	for k, i in l.order {
		if slice.contains(named[:], k) {
			l.order[i] = named[n]
			n += 1
		}
	}
}

table_sort_text :: proc(l: ^Table_Layout, keys: []string, allocator := context.temp_allocator) -> string {
	if l.sort == TABLE_UNSORTED { return strings.clone("none", allocator) }
	if l.sort < 0 || l.sort >= len(keys) { return "" }
	return strings.concatenate({l.descending ? "-" : "", keys[l.sort]}, allocator)
}

// Sets the sort a text of table_sort_text names, when it names a column shown ("none": unsorted); else the sort stays.
table_sort_apply :: proc(l: ^Table_Layout, keys: []string, text: string) {
	t := strings.trim_space(text)
	if t == "none" {
		l.sort, l.descending = TABLE_UNSORTED, false
		return
	}
	descending := strings.has_prefix(t, "-")
	k := table_key_index(keys, strings.trim_prefix(t, "-"))
	if k < 0 || k >= len(l.columns) || !l.shown[k] { return }
	l.sort, l.descending = k, descending
}

@(private = "file")
table_key_index :: proc(keys: []string, key: string) -> int {
	for k, i in keys { if k == key && key != "" { return i } }
	return -1
}

// What happened in the header in a build.
Table_Header_Events :: struct {
	sorted:  bool,   // a title was clicked: the sort changed (the caller sorts its rows again)
	resized: bool,   // a column's rule was let go: its width changed (the caller saves the layout)
	moved:   bool,   // a title was dragged to another place: the columns' order changed (the caller saves the layout)
	menu:    bool,   // a right click on the header: the columns' menu, at the pointer
	view:    Key,    // the box the titles scroll in, sideways (table_scroll_sync: with the rows)
}

// The columns' titles in a row of the width `next` gives (its height: TABLE_HEADER_EM; `next` may set a background).
// `lead_em`: the room before the first title, in ems (where the rows put a chevron or an icon).
// `opts`: what the program builds in the lead and in the titles (Table_Header_Options).
table_header :: proc(id: string, l: ^Table_Layout, lead_em: f32 = 0.6, opts := Table_Header_Options{}) -> (ev: Table_Header_Events) {
	s := gs()
	em := font_size()
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = px(dense(em * TABLE_HEADER_EM)) }
	flags := Box_Flags{.Draw_Side_Bottom, .Clickable}
	if m.bg != nil { flags += {.Draw_Background} }
	s.next_mod, s.has_next = m, true
	if row(.Center, flags, id) {
		if signal(parent_box()).right_clicked { ev.menu, l.menu_column = true, -1 }
		// (the titles in a box that scrolls sideways with the rows: as wide as the columns, at least, past its edge)
		next({width = fill(), height = pct(1), axis = .X, cross = .Center})
		view := build_box({.Clip, .View_Scroll_X, .Allow_Overflow_X, .Scrollbar_None}, "###hd_view")
		ev.view = view.key
		push_parent(view)
		defer pop_parent()
		next({width = fill_least(table_min_width(l)), height = pct(1), axis = .X, cross = .Center})
		titles_row := build_box({}, "###hd_row")
		push_parent(titles_row)
		defer pop_parent()
		// (each title's place at the last layout, for a moved column's drop; the moved one's signal)
		places := make([]Rect, len(l.columns), context.temp_allocator)
		moving: Signal
		// (each column's right edge is a rule, at the start of the next title; the last one's after it)
		prev, prev_px := -1, f32(0)
		for k in l.order {
			if !l.shown[k] { continue }
			c := l.columns[k]
			sorting := l.sort == k
			next({width = table_width(l, k), height = pct(1)})
			sig: Signal
			if row(.Center, {.Clickable, .Draw_Hot_Effects, .Hot_Within}, fmt.tprintf("###hd_%d", k)) {
				sig = signal(parent_box())
				hot := parent_box().hot_t > 0
				if prev >= 0 {
					if table_rule(l, prev, em, prev_px) { ev.resized = true }
				} else if opts.lead != nil {
					next({width = px(em * lead_em), height = pct(1), axis = .X, cross = .Center})
					if row(.Center, {}, "###lead") { opts.lead(opts.user, em) }
				} else {
					spacer(px(em * lead_em))
				}
				// (a number's title keeps its edge over its values: what the program adds goes before it)
				if c.number { spacer(fill()) }
				if c.number && opts.title != nil { opts.title(opts.user, k, hot, em) }
				if !sorting { push_tags("weak") }
				next({width = text_size(), height = pct(1), text_pad = 0})
				label(fmt.tprintf("%s###t", text_shown(c.title)))
				if !sorting { pop_tags() }
				if !c.number { spacer(fill()) }
				if !c.number && opts.title != nil { opts.title(opts.user, k, hot, em) }
				if sorting {
					if tags("weak") { table_arrow(l.descending, em * TABLE_ARROW_EM) }
				} else {
					spacer(px(em * TABLE_NUMBER_PAD_EM))
				}
			}
			a11y_default(sig.box, {role = .Column_Header, name = c.title})
			if sig.box != nil { places[k] = sig.box.rect }
			// a title dragged sideways moves its column (the first stays): its release is no click then
			if k > 0 && !l.moving && sig.dragging && abs(sig.drag_delta.x) > em * TABLE_MOVE_EM { l.moving, l.moving_col = true, k }
			if l.moving && l.moving_col == k { moving = sig }
			if sig.clicked && !c.unsorted && !(l.moving && l.moving_col == k) {
				table_sort_click(l, k)
				ev.sorted = true
			}
			if sig.right_clicked { ev.menu, l.menu_column = true, k }
			prev, prev_px = k, sig.box != nil ? sig.box.size.x : 0
		}
		if prev >= 0 {
			next({width = px(em * TABLE_RULE_GRIP_EM), height = pct(1)})
			if row(id = "###last_rule") { if table_rule(l, prev, em, prev_px) { ev.resized = true } }
		}
		spacer(px(em * (TABLE_SCROLLBAR_EM - TABLE_RULE_GRIP_EM)))
		if l.moving { ev.moved = table_move_drag(l, moving, places, titles_row) }
	}
	return
}

// A column whose title is dragged: where it would go (before the first other title whose middle is right of the
// pointer), shown by a line in the accent's colour; let go, it goes there. True when the order changed.
@(private = "file")
table_move_drag :: proc(l: ^Table_Layout, sig: Signal, places: []Rect, titles: ^Box) -> (moved: bool) {
	if sig.box == nil {   // (its column was hidden while it was dragged)
		l.moving = false
		return
	}
	x := mouse_pos().x
	from := 0
	for k, i in l.order { if k == l.moving_col { from = i } }
	// its place among the others (it taken out), from 1: the first column stays first; `edge`: where the line goes
	to := len(l.order) - 1
	edge := f32(-1)
	slot := 0
	for k in l.order {
		if k == l.moving_col { continue }
		if slot > 0 && l.shown[k] && x < (places[k].min.x + places[k].max.x) * 0.5 {
			to, edge = slot, places[k].min.x
			break
		}
		if l.shown[k] { edge = places[k].max.x }
		slot += 1
	}
	if !sig.dragging {
		l.moving = false
		if to != from {
			table_layout_move(l, l.moving_col, to)
			moved = true
		}
		return
	}
	if edge >= 0 && titles != nil {
		w := max(1, TABLE_DROP_PX * scale())
		next({width = px(w), height = pct(1), bg = color("accent")})
		b := build_box({.Floating_X, .Draw_Background}, "###hd_drop")
		b.fixed_pos.x = edge - titles.rect.min.x - w * 0.5
	}
	return
}

// A click on column `k`'s title: the column, in its own first direction (numbers from the largest, unless low_first); a
// second click the other way; a third unsorted (TABLE_UNSORTED: the rows in the data's own order).
table_sort_click :: proc(l: ^Table_Layout, k: int) {
	c := l.columns[k]
	first := (c.number && !c.low_first) || c.descending_first
	switch {
	case l.sort != k:           l.sort, l.descending = k, first
	case l.descending == first: l.descending = !first
	case:                       l.sort, l.descending = TABLE_UNSORTED, false
	}
}

// The line at a column's right edge (built at the start of the next column's title): dragged, that column grows or
// shrinks and the columns after it move with its edge, as in a file manager. The fill column takes its width of the
// moment (`from_px`) at the first drag: from then on every column has its own, and a table wider than its room scrolls.
// True when it is let go after a drag.
@(private = "file")
table_rule :: proc(l: ^Table_Layout, k: int, em: f32, from_px: f32) -> (released: bool) {
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
	if sig.pressed {
		if l.width[k] == 0 { l.width[k] = clamp(from_px / em, TABLE_COLUMN_MIN_EM, TABLE_COLUMN_MAX_EM) }
		drag_store({l.width[k], 0, 0, 0})
	}
	if sig.dragging { l.width[k] = clamp(drag_load()[0] + sig.drag_delta.x / em, TABLE_COLUMN_MIN_EM, TABLE_COLUMN_MAX_EM) }
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

// A column as the table gives it: its own width, and the rows unsorted when they go by it. True when the sort changed.
table_column_reset :: proc(l: ^Table_Layout, k: int) -> (sort_changed: bool) {
	if k < 0 || k >= len(l.columns) { return }
	l.width[k] = l.columns[k].width
	if l.sort == k {
		l.sort, l.descending = TABLE_UNSORTED, false
		sort_changed = true
	}
	return
}

// The words of a table's header menu (table_menu_items); "%s": the column's title.
Table_Menu_Labels :: struct { reset, unsorted, columns, defaults: string }
TABLE_MENU_LABELS :: Table_Menu_Labels{reset = "Reset %s", unsorted = "Unsorted", columns = "Columns", defaults = "Default columns"}

// The menu of a table's header (in the caller's ctx_menu, opened on Table_Header_Events.menu): the column whose title was
// right-clicked back to its own width and unsorted (table_column_reset), the rows unsorted, each column shown or not
// (table_column_items), every column as at first (table_layout_reset: widths, shown, order). `changed`: the layout to
// save; `sort_changed`: the rows to sort again.
table_menu_items :: proc(l: ^Table_Layout, labels := TABLE_MENU_LABELS) -> (changed, sort_changed: bool) {
	if k := l.menu_column; k >= 0 && k < len(l.columns) {
		own := l.width[k] == l.columns[k].width && l.sort != k
		if menu_item(fmt.tprintf(labels.reset, l.columns[k].title), enabled = !own).clicked {
			if table_column_reset(l, k) { sort_changed = true }
			changed = true
		}
	}
	if menu_item(labels.unsorted, checked = l.sort == TABLE_UNSORTED, enabled = l.sort != TABLE_UNSORTED).clicked {
		l.sort, l.descending = TABLE_UNSORTED, false
		changed, sort_changed = true, true
	}
	if len(l.columns) > 1 {
		menu_separator()
		menu_heading(labels.columns)
		c, s := table_column_items(l)
		changed, sort_changed = changed || c, sort_changed || s
	}
	menu_separator()
	if menu_item(labels.defaults).clicked {
		sort := l.sort
		table_layout_reset(l)
		changed, sort_changed = true, sort_changed || l.sort != sort
	}
	return
}

// The menu items of the columns (in the caller's ctx_menu): each column but the first, checked when shown; a click
// shows or hides it and keeps the menu open. True when the sort changed (a hidden column was sorted by).
table_column_items :: proc(l: ^Table_Layout) -> (changed, sort_changed: bool) {
	for k in l.order {
		if k == 0 { continue }
		c := l.columns[k]
		if menu_item(c.title, checked = l.shown[k], keep_open = true).clicked {
			if table_layout_toggle(l, k) { sort_changed = true }
			changed = true
		}
	}
	return
}

// The least width of a row of the columns shown, in frame pixels: the columns' own, the fill column's TABLE_FILL_MIN_EM
// and the room of the scroll bar. A wider room: the fill column takes the rest; a narrower one: the rows scroll sideways.
table_min_width :: proc(l: ^Table_Layout) -> f32 {
	em := font_size()
	w := em * TABLE_SCROLLBAR_EM
	for k in 0 ..< len(l.columns) {
		if !l.shown[k] { continue }
		w += em * (l.width[k] > 0 ? l.width[k] : TABLE_FILL_MIN_EM)
	}
	return w
}

// The rows' sideways scroll given to the titles (`header`: Table_Header_Events.view), in the build they are made in;
// the titles scrolled themselves (the wheel over them): the rows follow at the next build. Call it once the rows' list
// is built. A program that builds its rows itself gives its list View_Scroll_X and Allow_Overflow_X and each row
// fill_least(table_min_width), as table_build does.
table_scroll_sync :: proc(l: ^Table_Layout, header: Key, list: ^Virtual_List) {
	hb, lb := box_from_key(header), box_from_key(list.key)
	if hb == nil || lb == nil { return }
	if hb.view_target.x != l.scroll_x && lb.view_target.x == l.scroll_x {
		lb.view_target.x = hb.view_target.x   // (the titles were scrolled)
	}
	hb.view_off.x, hb.view_target.x = lb.view_off.x, lb.view_target.x
	hb.view_anim.x.active = false
	l.scroll_x = lb.view_target.x
}

// The width of column `k`: its own (in ems), or for the fill column (width 0) what the others leave, never under
// TABLE_FILL_MIN_EM (fill_least: the layout resolves it in the build it is in, a resize included). A program that builds a
// cell itself (an icon beside a name) gives it this width.
table_width :: proc(l: ^Table_Layout, k: int) -> Size {
	if l.width[k] > 0 { return px(font_size() * l.width[k]) }
	return fill_least(font_size() * TABLE_FILL_MIN_EM)
}

// A cell of a row under column `col`'s title: its text clipped to the column's width, a number at the right. `bg`: a
// background (a busy cell's tint); `fg`: its text's colour, the one that reads on that background; `border`: a 1 px
// outline (a stronger shade of the tint sets the cell apart from its neighbours). True when the pointer is on the cell
// and its text does not fit (table_cell_tip).
table_cell :: proc(l: ^Table_Layout, col: int, text: string, bg: Maybe(Color) = nil, fg: Maybe(Color) = nil, border: Maybe(Color) = nil) -> (cut: bool) {
	em := font_size()
	c := l.columns[col]
	pad := c.number ? em * TABLE_NUMBER_PAD_EM : em * TABLE_RULE_GRIP_EM * 0.5 + max(1, scale())
	flags := Box_Flags{.Draw_Text, .Clip}
	if bg != nil { flags += {.Draw_Background} }
	if border != nil { flags += {.Draw_Border} }
	// (square, whatever the style: a tinted cell is part of its row, side by side with the next one)
	if ranges := word_ranges(text, l.highlight); len(ranges) > 0 {
		// what matches the filter, lit: the cell keeps its text (a screen reader's, a test's), drawn by the line in it
		next({width = table_width(l, col), height = pct(1), axis = .X, cross = .Center, bg = bg, fg = fg, border = border, radius = 0})
		b := build_box(flags - {.Draw_Text}, fmt.tprintf("%s###c%d", text_shown(text), col))
		if parent(b) {
			next({width = fill(), text_align = c.number ? .Right : .Left, text_pad = pad})
			table_matched_line(text, ranges, fg)
		}
		return text_cut_under_mouse(b, text, pad)
	}
	next({width = table_width(l, col), height = pct(1), text_align = c.number ? .Right : .Left, text_pad = pad, bg = bg, fg = fg, border = border, radius = 0})
	b := build_box(flags, fmt.tprintf("%s###c%d", text_shown(text), col))
	return text_cut_under_mouse(b, text, pad)
}

// A line of a cell with its ranges lit (match_runs), in `fg` when the cell gives its text a colour.
@(private = "file")
table_matched_line :: proc(text: string, ranges: []Fuzzy_Range, fg: Maybe(Color) = nil) {
	runs := make([dynamic]Rich_Run, context.temp_allocator)
	style: Rich_Style
	if c, ok := fg.?; ok { style.color = c }
	match_runs(text, ranges, style, &runs)
	rich_paragraph("###lit", runs[:], max_lines = 1)
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

// The whole text of a cut cell, beside the pointer, once it has rested on the row for Feel.tooltip_delay_ms.
table_cell_tip :: proc(row: Signal, text: string) {
	if text == "" || !hovered_for(row) { return }
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
	rows:      [dynamic]int,    // the rows shown: filtered, sorted (indices of the data)
	ids:       [dynamic]u64,    // their identities (the list's keys)
	vl:        Virtual_List,
	query:     string,          // the filter applied, in lower case (owned)
	sel_rect:  Rect,            // the selected row, as last built (where the Menu key opens the menu)
	// Builds what goes before the first cell's text of data row `row`: `size` high (an icon, or with row_em a
	// thumbnail's height: its width is the lead's); nil: nothing.
	lead:      proc(t: ^Table, row: int, size: f32),
	lead_user: rawptr,
	lead_em:   f32,             // the room before the first title and the first cell (0: 0.6)
	row_em:    f32,             // a row's height in ems (0: TABLE_ROW_EM): taller rows for a lead that shows a thumbnail
	header_bg: Maybe(Color),    // the header's background (nil: none)
}

table_init :: proc(t: ^Table, columns: []Table_Column, sort := 0, descending := false) {
	table_layout_init(&t.layout, columns, sort, descending)
	t.vl.sel = -1
}

table_destroy :: proc(t: ^Table) {
	table_layout_destroy(&t.layout)
	delete(t.rows)
	delete(t.ids)
	delete(t.query)
	vlist_destroy(&t.vl)
	t.rows, t.ids, t.query = nil, nil, ""
}

// The data row selected, -1 for none.
table_selected :: proc(t: ^Table) -> int {
	if t.vl.sel < 0 || t.vl.sel >= len(t.rows) { return -1 }
	return t.rows[t.vl.sel]
}

// Filters and sorts the rows again (new data, a new filter, a new sort). `query` is matched in each row's search text,
// case ignored, and lit in the cells (Table_Layout.highlight). The same row stays selected when it is shown, where the
// list is scrolled (a cleared filter brings it into view); a new filter selects its first row.
table_apply :: proc(t: ^Table, d: ^Table_Data, query: string) {
	keep: u64
	has_keep := t.vl.sel >= 0 && t.vl.sel < len(t.ids)
	if has_keep { keep = t.ids[t.vl.sel] }
	q := strings.to_lower(query, context.temp_allocator)
	cleared := false
	if q != t.query {
		cleared = q == ""
		delete(t.query)
		t.query = strings.clone(q)
		t.highlight = t.query
		// a new search starts from its first row; a cleared one keeps the row selected, in view
		if q != "" {
			has_keep = false
			vlist_scroll_to(&t.vl, 0)
		}
	}
	clear(&t.rows)
	for i in 0 ..< len(d.ids) {
		if q == "" || strings.contains(d.search[i], q) { append(&t.rows, i) }
	}
	if t.sort >= 0 { table_sort_rows(t, d) }
	clear(&t.ids)
	for i in t.rows { append(&t.ids, d.ids[i]) }
	vlist_invalidate(&t.vl)
	t.vl.sel = -1
	if has_keep {
		for id, i in t.ids {
			if id == keep {
				t.vl.sel = i
				// (a cleared filter: the row comes into view; new rows of the same filter scroll nothing: the list stays where
				// the user scrolled it)
				if cleared { list_select(&t.vl, i) }
				break
			}
		}
	}
	if t.vl.sel < 0 && q != "" && len(t.ids) > 0 { list_select(&t.vl, 0) }
}

// The rows shown, by the sort's column (its number or its text, case ignored), ties by the first column, then as read.
@(private = "file")
table_sort_rows :: proc(t: ^Table, d: ^Table_Data) {
	Sort_Ctx :: struct { d: ^Table_Data, col: int, number: bool }
	ctx := Sort_Ctx{d, t.sort, t.columns[t.sort].number}
	context.user_ptr = &ctx
	slice.sort_by(t.rows[:], proc(a, b: int) -> bool {
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
	if t.descending { slice.reverse(t.rows[:]) }
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
	moved:     bool,   // a title was dragged to another place (save the layout)
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
		if t.header_bg != nil { next({bg = t.header_bg}) }
		h := table_header("###header", &t.layout, lead_em)
		ev.sorted, ev.resized, ev.moved, ev.columns = h.sorted, h.resized, h.moved, h.menu
		row_h := dense(em * (t.row_em > 0 ? t.row_em : TABLE_ROW_EM))
		least := table_min_width(&t.layout)
		next({width = fill(), height = fill(), flags = {.View_Scroll_X, .Allow_Overflow_X}})
		if rows, ok := vlist("###rows", &t.vl, t.ids[:]); ok {
			// (the keyboard may be in a filter field, yet the selection is the window's: strong while the window is the user's)
			t.vl.focused = !inactive()
			for i in rows.first ..< rows.last {
				r := t.rows[i]
				next({width = fill_least(least), height = px(row_h)})
				row := list_row(&t.vl, i, table_label(d, r))
				tip := ""
				if parent(row.box) { tip = table_cells(t, d, r, em, lead_em, row_h) }
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
		table_scroll_sync(&t.layout, h.view, &t.vl)
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
table_cells :: proc(t: ^Table, d: ^Table_Data, r: int, em, lead_em, row_h: f32) -> (tip: string) {
	tone := d.tones[r]
	if tone == .Dim { push_tags("weak") }
	if tone == .Bad { push_tags("bad") }
	defer if tone != .Normal { pop_tags() }
	for k in t.order {
		if !t.shown[k] { continue }
		c := t.columns[k]
		text := table_data_text(d, r, k)
		if k == 0 {
			// the first column: the lead (an icon), then the text
			next({width = table_width(&t.layout, 0), height = pct(1), axis = .X, cross = .Center})
			if row(id = "###c_first") {
				spacer(px(em * lead_em * 0.8))
				if t.lead != nil {
					// (an icon at the default height; a taller row's lead fills it, less a margin above and below)
					t.lead(t, r, t.row_em > 0 ? row_h - em * 0.5 : em * 1.5)
					spacer(px(em * 0.4))
				}
				if ranges := word_ranges(text, t.highlight); len(ranges) > 0 {
					next({width = fill(), height = pct(1), axis = .X, cross = .Center})
					b := build_box({.Clip}, fmt.tprintf("%s###c0", text_shown(text)))
					if parent(b) {
						next({width = fill(), text_pad = 0})
						table_matched_line(text, ranges)
					}
					if text_cut_under_mouse(b, text, 0) { tip = text }
				} else {
					next({width = fill(), height = pct(1), text_pad = 0})
					b := build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###c0", text_shown(text)))
					if text_cut_under_mouse(b, text, 0) { tip = text }
				}
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
