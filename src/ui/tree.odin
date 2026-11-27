package ui

// A tree of rows of one line (src/md/features/tree-view.md): a folder tree, an outline, a scene's nodes. The program
// gives the rows shown, in order, as a flat list (a closed branch's children are not in it), and counts its changes;
// the tree builds only the rows in view (it is a vlist), draws the indent guides and the chevrons, and keeps the open
// set, the selection, the keys and the reveal.
//
//   if app.rows_seen != app.tree.open_version { make_rows(app); app.rows_version += 1; app.rows_seen = app.tree.open_version }
//   if shown, ok := ui.tree("###outline", &app.tree, app.rows[:], app.rows_version); ok {
//       for i in shown.first ..< shown.last {
//           row := ui.tree_row(&app.tree, i, {trailing = app.counts[i]})
//           if ui.parent(row.box) { ... }   // more at the row's end
//       }
//   }
//   if app.tree.chosen >= 0 { open(app.rows[app.tree.chosen]) }
//
// The keys: those of a vlist (Up, Down, Page Up, Page Down, Home, End, type-ahead, Ctrl and Shift with `multi`), and
// Right (open, then to the first child), Left (close, then to the parent), Enter and Space (a branch opens or closes, a
// leaf is chosen), F2 (rename_asked), Shift+F10 and the Menu key (menu).

import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import "../platform"

// A row's parts, in the text's ems: the inset before depth 0's chevron, a level's indent, the chevron's cell, the icon's
// cell, a row's height in the person's density (a dense scope: dense_row_height).
TREE_EDGE_EM :: 0.3
TREE_INDENT_EM :: 0.62
TREE_CHEVRON_EM :: 1.1
TREE_ICON_EM :: 1.25
TREE_ROW_EM :: 1.65
// The inset after a row's trailing text.
TREE_END_EM :: 0.45
// A rename's field takes the keyboard back for this many builds (a menu closing gives it to its opener).
@(private = "file") TREE_RENAME_SETTLE_BUILDS :: 8
// A branch a drag rests on opens after this long.
TREE_HOVER_OPEN_MS :: 600
// The icon's glyph, in the row's ems; the chevron's half height.
@(private = "file") TREE_ICON_GLYPH_EM :: 0.95
@(private = "file") TREE_CHEVRON_ARM_EM :: 0.2
@(private = "file") TREE_CHEVRON_RATE :: 30
// The guides' ink: the border's at rest; the active branch's, the weak text's.
@(private = "file") TREE_GUIDE_ALPHA :: 0.9

// One row shown: its identity (stable across changes: the selection, the open set and the cursor follow it), its
// depth (0: the top level), its label, its icon (a glyph of the icon font, Lucide's; "": none) and whether it is a
// branch (it has children, or may have: it shows a chevron).
Tree_Row :: struct {
	id:     u64,
	depth:  int,
	label:  string,
	icon:   string,
	branch: bool,
}

// What tree_row adds to a row: its label's tag ("bright": the open file; "weak": an ignored one), its icon's colour,
// a short text at its end (a git letter, a count) and that text's tag ("warn", "good"...).
Tree_Row_Options :: struct {
	tag:          string,
	icon_tint:    Maybe(Color),
	trailing:     string,
	trailing_tag: string,
}

Tree :: struct {
	using vl:     Virtual_List,
	open:         map[u64]struct{},   // the open branches, by identity
	open_version: u64,                // moves with every change of `open`: the program makes its rows again
	highlight:    string,             // what the labels light where it matches, each word of it (not owned)
	fuzzy:        bool,               // the labels light the letters a fuzzy match of `highlight` found (fuzzy_words)
	// What the last call asked (read after the rows are built; the next call clears them):
	chosen:        int,               // a leaf chosen: a click, Enter, Space (-1: none)
	chosen_double: bool,              // ... by the second click of a double click
	menu:          int,               // the row whose context menu was asked (-1: none), at `menu_at` (frame px)
	menu_at:       Vec2,
	menu_keyboard: bool,              // asked from the keyboard (its first item gets the focus)
	menu_empty:    bool,              // a right click under the rows: the menu of the tree itself (`menu` is -1)
	rename_asked:  int,               // F2 on this row (-1: none): the program calls tree_rename_begin if it can
	renamed:       Maybe(string),     // the rename's text at Enter (frame memory); rename_id says which row
	drag_rows:     []u64,             // a drag of these rows began (frame memory): the selection, or the row pressed
	dropped:       bool,              // the drag was let go over the tree: drop_row says where
	// A drag held over the tree: the branch it would go in (-1: the top level), and whether it is over the tree.
	drop_row:      int,
	drop_over:     bool,
	dragging:      bool,              // a drag of rows began and the button is held
	drop_outside:  bool,              // a drag from elsewhere (another program) is over the tree: tree_drop_hover
	// The rename in place:
	renaming:      bool,
	rename_id:     u64,
	rename_edit:   Line_Edit,
	rename_focus:  bool,
	rename_builds: int,               // builds the field was built in
	// What the rows give, made again on a new version:
	rows:          []Tree_Row,        // this build's (the program's)
	rows_version:  u64,
	tree_ids:       [dynamic]u64,
	tree_labels:    [dynamic]string,
	parents:       [dynamic]i32,      // each row's parent row (-1: the top level)
	ends:          [dynamic]i32,      // the row after each row's subtree
	places:        [dynamic]i32,      // each row's place among its siblings (1-based)
	kids:          [dynamic]i32,      // each row's children in the rows
	roots:         i32,
	active:        int,               // the branch whose guide is lit (-1: none)
	cursor_id:     u64,               // the cursor's row, by identity: it follows its row through new rows
	has_cursor:    bool,
	reveal_id:     u64,
	revealing:     bool,
	space_pending: bool,
	drag_released: bool,              // the drag ended this build: its release clicks nothing
	hover_id:      u64,               // the branch a drag rests on, since `hover_ms`
	hover_ms:      f64,
}

tree_destroy :: proc(t: ^Tree) {
	vlist_destroy(&t.vl)
	delete(t.open)
	delete(t.tree_ids)
	delete(t.tree_labels)
	delete(t.parents)
	delete(t.ends)
	delete(t.places)
	delete(t.kids)
	line_edit_destroy(&t.rename_edit)
}

// A row's height: one line.
tree_row_height :: proc() -> f32 {
	if dense_shown() { return dense_row_height() }
	return math.round(dense(font_size() * TREE_ROW_EM))
}

// Whether the branch `id` is open.
tree_is_open :: proc(t: ^Tree, id: u64) -> bool { return id in t.open }

// Opens or closes the branch `id` (the program makes its rows again: open_version moved).
tree_set_open :: proc(t: ^Tree, id: u64, open: bool) {
	if open == (id in t.open) { return }
	if open { t.open[id] = {} } else { delete_key(&t.open, id) }
	t.open_version += 1
	if current != nil { keep_animating() }
}

// Selects the row `id` and brings it into view, once it is in the rows (the program opens its ancestors).
tree_reveal :: proc(t: ^Tree, id: u64) {
	t.reveal_id, t.revealing = id, true
	if current != nil { keep_animating() }
}

// A field in the row `id`'s label, holding `text` selected: Enter gives `renamed`, Escape or a click elsewhere
// gives nothing.
tree_rename_begin :: proc(t: ^Tree, id: u64, text: string) {
	t.renaming, t.rename_id, t.rename_focus, t.rename_builds = true, id, true, 0
	line_edit_set(&t.rename_edit, text)
	// (a name's stem selected, as a file manager does: the extension stays)
	dot := strings.last_index_byte(text, '.')
	t.rename_edit.mark, t.rename_edit.cursor = 0, dot > 0 ? dot : len(text)
	if current != nil { keep_animating() }
}

// The row under the frame position `pos` as a drop's target: the branch there, or a leaf's parent (-1: the top level).
// `over` false: the position is not on the tree's rows. A program gives it the system's drops (Drop_Over).
tree_drop_target :: proc(t: ^Tree, pos: Vec2) -> (row: int, over: bool) {
	b := box_from_key(t.key)
	if b == nil || len(t.rows) == 0 { return -1, false }
	r := b.rect
	if pos.x < r.min.x || pos.x >= r.max.x || pos.y < r.min.y || pos.y >= r.max.y { return -1, false }
	y := b.view_off.y + pos.y - r.min.y
	if y >= vlist_total(&t.vl) { return -1, true }   // (under the last row: the top level)
	i := vlist_row_at(&t.vl, y)
	if i < 0 || i >= len(t.rows) { return -1, true }
	if t.rows[i].branch { return i, true }
	return int(t.parents[i]), true
}

// The tree's rows made again from `rows`: a pass over them, only when their version moves.
@(private = "file")
tree_derive :: proc(t: ^Tree, rows: []Tree_Row) {
	n := len(rows)
	resize(&t.tree_ids, n)
	resize(&t.tree_labels, n)
	resize(&t.parents, n)
	resize(&t.ends, n)
	resize(&t.places, n)
	resize(&t.kids, n)
	stack := make([dynamic]i32, 0, 64, context.temp_allocator)
	t.roots = 0
	for r, i in rows {
		t.tree_ids[i] = r.id
		t.tree_labels[i] = r.label
		t.kids[i] = 0
		for len(stack) > 0 && rows[stack[len(stack) - 1]].depth >= r.depth {
			t.ends[pop(&stack)] = i32(i)
		}
		p := len(stack) > 0 ? stack[len(stack) - 1] : -1
		t.parents[i] = p
		if p >= 0 {
			t.kids[p] += 1
			t.places[i] = t.kids[p]
		} else {
			t.roots += 1
			t.places[i] = t.roots
		}
		append(&stack, i32(i))
	}
	for j in stack { t.ends[j] = i32(n) }
}

// The row `id` in this build's rows (-1: none): a pass, only when the rows changed or a reveal waits.
@(private = "file")
tree_find :: proc(t: ^Tree, id: u64) -> int {
	for x, i in t.tree_ids { if x == id { return i } }
	return -1
}

// A branch opens or closes, a leaf is chosen.
@(private = "file")
tree_act :: proc(t: ^Tree, i: int, double := false) {
	if i < 0 || i >= len(t.rows) { return }
	r := t.rows[i]
	if r.branch {
		tree_set_open(t, r.id, r.id not_in t.open)
	} else {
		t.chosen, t.chosen_double = i, double
	}
}

// The cursor to row `i`, alone selected, in view.
@(private = "file")
tree_move :: proc(t: ^Tree, i: int) {
	if i < 0 || i >= len(t.rows) || i == t.sel { return }
	item_selection_move(&t.selection, list_rows(&t.list), i, {})
	t.reveal = LIST_REVEAL_FRAMES
	t.changed = true
}

// `if shown, ok := ui.tree(id, &t, rows, version); ok { for i in shown.first ..< shown.last { ui.tree_row(&t, i) } }`:
// the tree's scroll region (it fills what `next` gives), the rows in view to build. `version` is the program's count of
// the changes of `rows` (0: they change at every build, a pass over them each time).
@(deferred_out = tree_end)
tree :: proc(id: string, t: ^Tree, rows: []Tree_Row, version: u64) -> (shown: Vlist_Rows, ok: bool) {
	return tree_open(id, t, rows, version)
}

// tree without its deferred end: a widget made on a tree (ui.file_tree) calls tree_end at the end of its own.
@(private)
tree_open :: proc(id: string, t: ^Tree, rows: []Tree_Row, version: u64) -> (shown: Vlist_Rows, ok: bool) {
	s := gs()
	n := len(rows)
	t.rows = rows
	t.chosen, t.chosen_double, t.menu, t.menu_keyboard, t.menu_empty, t.rename_asked = -1, false, -1, false, false, -1
	t.renamed = nil
	t.drag_rows = nil
	t.dropped = false
	t.drag_released = false
	changed := version == 0 || version != t.rows_version || n != len(t.tree_ids)
	if changed {
		tree_derive(t, rows)
		t.rows_version = version
		// (the cursor's row moved: the cursor goes with it; its row gone, it stays where it was)
		if t.has_cursor && (t.sel < 0 || t.sel >= n || t.tree_ids[t.sel] != t.cursor_id) {
			if at := tree_find(t, t.cursor_id); at >= 0 { t.sel = at } else if t.sel >= n { t.sel = n - 1 }
		}
	}
	if t.revealing && (changed || t.reveal == 0) {
		if at := tree_find(t, t.reveal_id); at >= 0 {
			list_select(&t.list, at)
			t.revealing = false
		}
	}

	// Space before the list's type-ahead takes it as a letter: a row's act, unless a word is being typed
	t.space_pending = false
	if s.focus_key == t.key && t.key != 0 && !keys_held_by_dialog(s) && !t.renaming {
		typing := t.typed_len > 0 && s.time_ms - t.typed_ms <= f64(s.feel.typeahead_ms)
		for e, i in s.events.list {
			if s.events.consumed[i] || e.key != .Space || e.mods != {} || typing { continue }
			s.events.consumed[i] = true
			t.space_pending = true
			for r, k in s.typed { if r == ' ' { ordered_remove(&s.typed, k); break } }
		}
	}

	// a drag of rows: where it would go, a branch it rests on opened, its end
	if t.dragging {
		if .Left not_in s.buttons_down {
			t.dragging, t.drag_released = false, true
			t.dropped = t.drop_over
		} else {
			tree_drop_hover(t, s.mouse)
		}
	}

	a11y({role = .Tree, multiselectable = t.multi})
	shown, ok = vlist_open(id, &t.vl, t.tree_ids[:], t.tree_labels[:], nil, version)
	// (a right click on the list itself, under its rows: the tree's own menu)
	if lb := parent_box(); signal(lb).right_clicked {
		t.menu, t.menu_empty, t.menu_at, t.menu_keyboard = -1, true, mouse_pos(), false
	}

	// the tree's keys, after the list's (Up, Down... are the list's)
	if t.focused && !keys_held_by_dialog(s) && !t.renaming {
		for e, i in s.events.list {
			if s.events.consumed[i] { continue }
			c := t.sel
			used := true
			switch {
			case c < 0 || c >= n:
				used = false
			case e.key == .Right && e.mods == {}:
				r := rows[c]
				if r.branch && r.id not_in t.open {
					tree_set_open(t, r.id, true)
				} else if r.branch && c + 1 < n && int(t.parents[c + 1]) == c {
					tree_move(t, c + 1)
				}
			case e.key == .Left && e.mods == {}:
				r := rows[c]
				if r.branch && r.id in t.open {
					tree_set_open(t, r.id, false)
				} else if p := int(t.parents[c]); p >= 0 {
					tree_move(t, p)
				}
			case e.key == .F2 && e.mods == {}:
				t.rename_asked = c
			case (e.key == .Menu && e.mods == {}) || (e.key == .F10 && e.mods == {.Shift}):
				t.menu, t.menu_keyboard = c, true
				if rb := box_from_key(vlist_row_key(t.key, c)); rb != nil {
					t.menu_at = {rb.rect.min.x + font_size() * (TREE_EDGE_EM + f32(rows[c].depth) * TREE_INDENT_EM + TREE_CHEVRON_EM), rb.rect.max.y}
				}
			case:
				used = false
			}
			if used { s.events.consumed[i] = true }
		}
		if t.activated || t.space_pending { tree_act(t, t.sel) }
	}

	// the lit guide: the cursor's open branch, else its parent
	t.active = -1
	if t.sel >= 0 && t.sel < n {
		c := t.sel
		t.active = rows[c].branch && rows[c].id in t.open && int(t.ends[c]) > c + 1 ? c : int(t.parents[c])
		t.cursor_id, t.has_cursor = rows[c].id, true
	}
	return
}

@(private)
tree_end :: proc(shown: Vlist_Rows, ok: bool) {
	vlist_end(shown, ok)
}

// A drag over the tree at the frame position `pos`: drop_row and drop_over say where it would go, the target row is
// outlined, and a closed branch it rests on for TREE_HOVER_OPEN_MS opens. The tree's own drags call it; a program calls
// it for a drag from elsewhere (Drop_Enter, Drop_Over), with `outside`, and tree_drop_leave when it goes.
tree_drop_hover :: proc(t: ^Tree, pos: Vec2, outside := false) {
	t.drop_row, t.drop_over = tree_drop_target(t, pos)
	t.drop_outside = outside && t.drop_over
	tree_hover_open(t, gs())
}

// A drag from elsewhere left the tree (Drop_Leave), or was dropped.
tree_drop_leave :: proc(t: ^Tree) {
	t.drop_outside, t.drop_over, t.drop_row, t.hover_id = false, false, -1, 0
}

// A drag that rests on a closed branch for TREE_HOVER_OPEN_MS opens it.
@(private = "file")
tree_hover_open :: proc(t: ^Tree, s: ^State) {
	if !t.drop_over || t.drop_row < 0 { t.hover_id = 0; return }
	r := t.rows[t.drop_row]
	if r.id in t.open { t.hover_id = 0; return }
	if t.hover_id != r.id { t.hover_id, t.hover_ms = r.id, s.time_ms }
	waited := s.time_ms - t.hover_ms
	if waited >= TREE_HOVER_OPEN_MS {
		tree_set_open(t, r.id, true)
		t.hover_id = 0
	} else {
		wake_within(s, int(TREE_HOVER_OPEN_MS - waited) + 1)
	}
}

// What a row's custom draw needs: the guides above it and its chevron (tree_row_draw).
@(private = "file")
Tree_Row_Draw :: struct {
	depth:          int,
	branch:         bool,
	turn:           f32,      // the chevron: 0 right, 1 down
	lit_level:      int,      // the level whose guide is lit (-1: none)
	edge, indent, chevron, arm, line: f32,
	guide, guide_lit, ink: Color,
}

@(private = "file")
tree_row_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tree_Row_Draw)(user)
	r := b.rect
	// (each level's line under the centre of its chevron, on whole pixels: a hairline, not a blur over two)
	for level in 0 ..< d.depth {
		x := math.round(r.min.x + d.edge + f32(level) * d.indent + d.chevron * 0.5 - d.line * 0.5)
		draw.rect(dc, {{x, r.min.y}, {x + d.line, r.max.y}}, level == d.lit_level ? d.guide_lit : d.guide)
	}
	if !d.branch { return }
	c := Vec2{r.min.x + d.edge + f32(d.depth) * d.indent + d.chevron * 0.5, (r.min.y + r.max.y) * 0.5}
	angle := d.turn * math.PI * 0.5
	co, si := math.cos(angle), math.sin(angle)
	turn :: proc(p: Vec2, co, si: f32) -> Vec2 { return {p.x * co - p.y * si, p.x * si + p.y * co} }
	a := d.arm
	p0, p1, p2 := turn({-a * 0.5, -a}, co, si), turn({a * 0.5, 0}, co, si), turn({-a * 0.5, a}, co, si)
	draw.line(dc, c + p0, c + p1, d.line * 1.4, d.ink)
	draw.line(dc, c + p1, c + p2, d.line * 1.4, d.ink)
}

// Row `i` of the tree being built (between ui.tree and its end): its guides, chevron, icon and label, cut at its end
// (the whole label in a tooltip); `o` adds a tag, an icon's colour, a text at its end. More at the row's end:
// `if ui.parent(row.box) { ... }`. A click selects it, and with no modifier opens or closes a branch or chooses a leaf.
tree_row :: proc(t: ^Tree, i: int, o := Tree_Row_Options{}) -> Signal {
	s := gs()
	r := t.rows[i]
	em := font_size()
	h := tree_row_height()
	open := r.branch && r.id in t.open
	lit_drop := (t.dragging || t.drop_outside) && t.drop_over && t.drop_row >= 0 && t.drop_row == i
	next({width = fill(), height = px(h), cross = .Center, radius = math.round(em * 0.2)})
	if lit_drop {
		// (the branch a drag would go in: the face of a row under the pointer)
		m := s.next_mod
		m.border = color("accent")
		s.next_mod = m
	}
	sig := list_row(&t.list, i, r.label)
	b := sig.box
	if lit_drop { b.flags += {.Draw_Border} }
	selected := list_is_selected(&t.list, i)
	ink := b.ink.a > 0 ? b.ink : color("weak text")
	lit_level := -1
	if t.active >= 0 && i > t.active && i < int(t.ends[t.active]) { lit_level = t.rows[t.active].depth }
	// (the guides keep their inks on a selected row: a line in the row's ink cuts the selection in two)
	guide := color("border")
	guide_lit := color("weak text")
	guide.a *= TREE_GUIDE_ALPHA
	d := new(Tree_Row_Draw, frame_allocator())
	d^ = {
		depth = r.depth, branch = r.branch, lit_level = lit_level,
		turn = r.branch ? anim(key_from_u64(t.key, r.id ~ 0x7ee_c4e7), open ? 1 : 0, TREE_CHEVRON_RATE) : 0,
		edge = math.round(em * TREE_EDGE_EM), indent = math.round(em * TREE_INDENT_EM), chevron = math.round(em * TREE_CHEVRON_EM),
		arm = em * TREE_CHEVRON_ARM_EM, line = max(1, math.round(scale())),
		guide = guide, guide_lit = guide_lit, ink = ink,
	}
	b.custom, b.custom_user = tree_row_draw, d

	label_box: ^Box
	if parent(b) {
		spacer(px(d.edge + f32(r.depth) * d.indent + d.chevron))
		if r.icon != "" {
			next({width = px(math.round(em * TREE_ICON_EM)), height = pct(1), font = lucide_icons(), font_size = math.round(em * TREE_ICON_GLYPH_EM), text_align = .Center, text_pad = 0, fg = o.icon_tint})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###icon", r.icon))
		}
		if o.tag != "" { push_tags(o.tag) }
		if t.renaming && r.id == t.rename_id {
			next({width = fill(), height = px(h - 2 * max(1, math.round(scale())))})
			res := line_edit("###rename", &t.rename_edit)
			// (the keyboard taken, and taken back while it settles: a menu that closed gives it back to its opener late)
			if t.rename_focus || (t.rename_builds < TREE_RENAME_SETTLE_BUILDS && s.focus_key != res.box.key && !s.pressed_any[.Left]) {
				set_focus(res.box.key)
				t.rename_focus = false
			}
			t.rename_builds += 1
			switch {
			case res.committed:
				t.renamed = strings.clone(string(t.rename_edit.buf[:]), frame_allocator())
				t.renaming = false
				set_focus(t.key)
			case res.cancelled:
				t.renaming = false
				set_focus(t.key)
			case s.focus_key != res.box.key && t.rename_builds > TREE_RENAME_SETTLE_BUILDS:
				t.renaming = false   // (a click elsewhere)
			}
		} else {
			ranges: []Fuzzy_Range
			if t.highlight != "" {
				if t.fuzzy { _, ranges, _ = fuzzy_words(t.highlight, r.label) } else { ranges = word_ranges(r.label, t.highlight) }
			}
			next({width = fill(), height = len(ranges) > 0 ? text_size() : pct(1)})
			label_box = matched_label("###label", r.label, ranges)
		}
		if o.tag != "" { pop_tags() }
		if o.trailing != "" {
			// (the text's own width, no padding: the label's end padding is the gap, and the label takes the rest)
			if o.trailing_tag != "" { push_tags(o.trailing_tag) }
			next({width = text_size(), height = pct(1), text_pad = 0})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###trailing", text_shown(o.trailing)))
			if o.trailing_tag != "" { pop_tags() }
			spacer(px(math.round(em * TREE_END_EM)))
		}
	}
	if label_box != nil && text_cut_under_mouse(label_box, r.label, label_box.text_pad) { table_cell_tip(sig, r.label) }

	expanded: Maybe(bool)
	if r.branch { expanded = open }
	a11y_set(b, {role = .Tree_Item, name = r.label, level = r.depth + 1, position = int(t.places[i]),
		set_size = int(t.parents[i] >= 0 ? t.kids[t.parents[i]] : t.roots), expanded = expanded, selected = selected})

	if sig.clicked && sig.mods == {} && !t.drag_released && !(r.branch && sig.second_click) {
		tree_act(t, i, sig.second_click)
	}
	if sig.right_clicked { t.menu, t.menu_at, t.menu_keyboard = i, mouse_pos(), false }
	if sig.dragging && !t.dragging && .Left in s.buttons_down {
		th := platform.drag_threshold(s.window)
		if abs(sig.drag_delta.x) >= th.x || abs(sig.drag_delta.y) >= th.y {
			t.dragging = true
			t.drop_row, t.drop_over = -1, false
			if selected && t.multi && list_selected_count(&t.list) > 1 {
				t.drag_rows = list_selected_ids(&t.list, frame_allocator())
			} else {
				one := make([]u64, 1, frame_allocator())
				one[0] = r.id
				t.drag_rows = one
			}
		}
	}
	return sig
}
