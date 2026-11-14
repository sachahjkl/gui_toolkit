package ui

import "core:fmt"
import "core:math"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// A tool bar whose groups fold into a "…" panel when the window is too narrow for them, rather than run past its edge:
//
//   ui.next({width = ui.fill(), height = ui.px(bar_h)})
//   if ui.toolbar("editor_bar") {
//       if ui.toolbar_group("tools", {priority = 2}) { ...the tools... }
//       if ui.toolbar_group("props", {separator = true}) { ...the properties... }
//       ui.spacer(ui.fill())
//       if ui.toolbar_group("acts", {priority = 1}) { ...undo, redo, copy, save... }
//       if ui.toolbar_group("end", {pinned = true}) { ...Cancel, Done... }
//   }
//
// A group is one block of the bar, built by the caller's code as anywhere else. When the groups do not fit, the bar folds
// them, the lowest `priority` first (of two alike, the later one), until the rest fits with the "…" button; a `pinned`
// group never folds (the bar's end buttons). The "…" button stands before the first pinned group (at the bar's end when
// there is none); a click opens a panel under it where each folded group is a row, built by the same code: what is in it
// works there as in the bar. A press outside the panel, or Escape, closes it.
//
// A group's width is measured where it is built (natural_width, before the layout: in the bar, or in the panel) and kept;
// a folded group is measured again each time its panel is open. The bar is a row: `next` gives its size, its children are
// centred across it.
//
// A group may be made of items (`if ui.toolbar_item(id) { ... }` in its block): the bar then folds the group item by
// item, its last item first, and folds the group whole only once all its items are folded and it still does not fit. A
// folded item is built in the panel, in a row of its group; the rest of the group stays in the bar, so a wide group of
// properties loses its last ones, not all of them, and no gap is left where it was. An item may have a priority of its
// own (toolbar_item's `priority`): the bar folds every group's items and rests together, by priority, so the rare tools
// of a group kept long fold before the needed items of a group that folds early.

// What a group of a tool bar is to its folding.
Toolbar_Group_Options :: struct {
	priority:  int,    // the lower folds first
	pinned:    bool,   // never folds (the bar's end buttons)
	separator: bool,   // a line before it in the bar (not in the panel)
}

// The words of a tool bar (zero: toolbar_default_labels).
Toolbar_Labels :: struct { more: string }   // the "…" button's tooltip and name to a screen reader
// The toolkit's words of a tool bar, in the language in use.
toolbar_default_labels :: proc() -> Toolbar_Labels { return {more = i18n.tr("More tools")} }

// What a tool bar keeps between builds (State.toolbars, by toolbar_key).
@(private)
Toolbar_Memory :: struct {
	groups:     [dynamic]Toolbar_Group_Memory,   // in the order the last build built them
	fixed:      f32,    // the width of what is in the bar besides its groups and the "…" button (spacers, words)
	open:       bool,   // the panel of the folded groups is open
	panel, more: Key,   // the panel's box and the "…" button's (the last build's)
}

@(private)
Toolbar_Group_Memory :: struct {
	key:      Key,
	width:    f32,    // what the caller builds in it, natural (0: not measured yet), as last built (its folded items not in it)
	rest:     f32,    // the part of `width` that is not an item
	sep:      f32,    // its separator's width in the bar (0: none)
	priority: int,
	pinned:   bool,
	folded:   bool,   // in this build
	seen:     u64,    // the build that last built it
	items:    [dynamic]Toolbar_Item_Memory,   // in the order the last build built them
}

// An item of a group (toolbar_item): it folds on its own.
@(private)
Toolbar_Item_Memory :: struct {
	key:      Key,
	width:    f32,    // natural, where it was last built
	priority: int,    // its own, else its group's (as last built)
	folded:   bool,   // in this build (its group in the bar)
	seen:     u64,
}

// The tool bar being built (State.toolbar).
@(private)
Toolbar_Build :: struct {
	active:   bool,
	key:      Key,
	bar:      ^Box,
	panel:    ^Box,   // the panel of the folded groups, once built in this build
	more:     ^Box,   // the "…" button, once built
	folded:   bool,   // a group is folded in this build
	labels:   Toolbar_Labels,
	side:     f32,    // the "…" button's side
	order:    int,    // the groups built so far
	group:    int,    // the group being built (its index in the memory)
	group_id: string, // ...its id (the caller's, for this build)
	in_panel: bool,   // ...in the panel
	inner:    ^Box,   // ...its box of what the caller builds
	items:    int,    // ...its items built so far
	row, row_outer: ^Box,   // ...its row of folded items in the panel (what they are built in, and the row), once built
	item:     int,    // the item being built (its index in its group's memory)
	item_box: ^Box,
	item_in_panel: bool,
}

// Beside the "…" button, a panel row's margin at its ends and above and below, a separator's room on each side, in ems.
@(private = "file") TOOLBAR_MORE_GAP_EM :: 0.3
@(private = "file") TOOLBAR_ROW_PAD_EM :: 0.5
@(private = "file") TOOLBAR_ROW_GAP_EM :: 0.3
@(private = "file") TOOLBAR_SEPARATOR_PAD_EM :: 0.45
@(private = "file") TOOLBAR_SEPARATOR_HEIGHT :: 0.6   // of the bar's height

// The key of tool bar `id`: the window's, as a menu's (toolbar_menu_open finds it from anywhere).
@(private = "file")
toolbar_key :: proc(id: string) -> Key { return key_from_string(0, fmt.tprintf("###toolbar_%s", id)) }

// Whether the panel of tool bar `id`'s folded groups is open: Escape is its own (a program's Escape waits).
toolbar_menu_open :: proc(id: string) -> bool {
	m, ok := gs().toolbars[toolbar_key(id)]
	return ok && m.open
}

@(require_results, deferred_none = toolbar_end)
toolbar :: proc(id: string, labels := Toolbar_Labels{}) -> bool {
	s := gs()
	assert(!s.toolbar.active, "toolbar: a tool bar in a tool bar")
	key := toolbar_key(id)
	if key not_in s.toolbars { s.toolbars[key] = {} }
	mem := &s.toolbars[key]
	em := font_size()
	side := math.round(em * BUTTON_LINE_EM)
	set_next_axis(.X, .Center)
	bar := build_box({.Clip}, fmt.tprintf("###%s", id))
	a11y_default(bar, {role = .Toolbar, orientation = .X})
	// (what folds: the widths of the last builds against the bar's width in the last layout)
	folded := toolbar_fold(mem, bar, side + 2 * math.round(em * TOOLBAR_MORE_GAP_EM))
	if !folded { mem.open = false }
	if mem.open && toolbar_closes(s, mem) { mem.open = false }
	s.toolbar = {active = true, key = key, bar = bar, folded = folded, side = side, labels = labels == {} ? toolbar_default_labels() : labels}
	push_parent(bar)
	return true
}

// Folds what does not fit, the lowest priority first (of two alike the later group): a group of items item by item, its
// last first, then the group whole; a group without items whole. Against the bar's width in the last layout, less what
// is not a group, less the "…" button once one folds. A bar not laid out yet folds nothing. True: one folded.
@(private = "file")
toolbar_fold :: proc(mem: ^Toolbar_Memory, bar: ^Box, more_w: f32) -> bool {
	for &g in mem.groups {
		g.folded = false
		for &it in g.items { it.folded = false }
	}
	avail := bar.size.x - 2 * border_inset(bar)
	if bar.first_build == gs().build_index || avail <= 0 { return false }
	need := mem.fixed
	for g in mem.groups { need += toolbar_group_need(g) }
	if need <= avail + 0.5 { return false }
	// (what folds, one part at a time: each item, then the rest of its group once its items are all folded (its priority
	// the highest of them and the group's). The later group first, a group's last item first, then by priority, lowest
	// first: an insertion sort keeps the order of equals, so an item of another priority folds among another group's)
	Part :: struct { group, item, priority: int }   // item -1: the group's rest
	parts := make([dynamic]Part, 0, len(mem.groups) * 2, context.temp_allocator)
	#reverse for g, gi in mem.groups {
		if g.pinned { continue }
		top := g.priority
		#reverse for it, ii in g.items {
			append(&parts, Part{gi, ii, it.priority})
			top = max(top, it.priority)
		}
		append(&parts, Part{gi, -1, top})
	}
	for i in 1 ..< len(parts) {
		for j := i; j > 0 && parts[j].priority < parts[j - 1].priority; j -= 1 {
			parts[j], parts[j - 1] = parts[j - 1], parts[j]
		}
	}
	folded := false
	for p in parts {
		if need <= avail + 0.5 { break }
		g := &mem.groups[p.group]
		if p.item >= 0 {
			g.items[p.item].folded = true
			need -= g.items[p.item].width
		} else {
			g.folded = true
			need -= g.rest + g.sep
		}
		if !folded { need += more_w; folded = true }
	}
	return folded
}

// The room a group takes in the bar with nothing of it folded: its separator, what is not an item, its items.
@(private = "file")
toolbar_group_need :: proc(g: Toolbar_Group_Memory) -> f32 {
	need := g.sep + g.rest
	for it in g.items { need += it.width }
	return need
}

// Escape, or a press outside the panel and its "…" button (as the last build laid them out): the panel closes.
@(private = "file")
toolbar_closes :: proc(s: ^State, mem: ^Toolbar_Memory) -> bool {
	if key_press(.Escape) { return true }
	panel := s.boxes[mem.panel] or_else nil
	for b in platform.Mouse_Button {
		if !s.pressed_any[b] { continue }
		hit := s.pressed_key[b]
		if hit != 0 && hit == mem.more { return false }   // (the button toggles it itself)
		hb: ^Box
		if hit != 0 { hb = s.boxes[hit] or_else nil }
		return hb == nil || panel == nil || !is_descendant(hb, panel)
	}
	return false
}

// `if toolbar_group(id, o) { ... }`: a group of the tool bar being built (toolbar): its block builds what is in it, in the
// bar, or in the panel of folded groups while that is open. False: folded, its panel closed (nothing to build).
@(require_results, deferred_out = toolbar_group_end)
toolbar_group :: proc(id: string, o := Toolbar_Group_Options{}) -> bool {
	s := gs()
	tb := &s.toolbar
	assert(tb.active, "toolbar_group: outside a tool bar")
	mem := &s.toolbars[tb.key]
	em := font_size()
	gkey := key_from_string(tb.key, id)
	// (kept in the order the caller builds them: the fold's "the later first" is that order)
	idx := -1
	for g, i in mem.groups { if g.key == gkey { idx = i; break } }
	if idx < 0 {
		append(&mem.groups, Toolbar_Group_Memory{key = gkey})
		idx = len(mem.groups) - 1
	}
	if idx != tb.order && tb.order < len(mem.groups) {
		mem.groups[idx], mem.groups[tb.order] = mem.groups[tb.order], mem.groups[idx]
		idx = tb.order
	}
	tb.order += 1
	g := &mem.groups[idx]
	g.priority, g.pinned, g.seen = o.priority, o.pinned, s.build_index
	g.sep = o.separator ? toolbar_separator_width(em) : 0
	tb.group, tb.group_id, tb.items, tb.row, tb.row_outer = idx, id, 0, nil, nil
	if g.pinned && tb.folded && tb.more == nil { toolbar_more(s, tb, mem, em) }
	if !g.folded {
		tb.in_panel = false
		next({width = children_sum(), height = pct(1), axis = .X, cross = .Center})
		push_parent(build_box({}, fmt.tprintf("###tg_%s", id)))
		if o.separator { toolbar_separator(tb, em) }
		next({width = children_sum(), height = pct(1), axis = .X, cross = .Center})
		tb.inner = build_box({}, "###in")
		push_parent(tb.inner)
		return true
	}
	if !mem.open { return false }
	panel := toolbar_panel(s, tb, mem, em)
	tb.in_panel = true
	push_parent(s.root)
	push_tags_isolated("floating")
	push_style_copy()
	push_parent(panel)
	tall := children_sum()
	tall.least = tb.side + 2 * math.round(em * TOOLBAR_ROW_GAP_EM)
	next({width = children_sum(), height = tall, axis = .X, cross = .Center})
	push_parent(build_box({}, fmt.tprintf("###tp_%s", id)))
	spacer(px(math.round(em * TOOLBAR_ROW_PAD_EM)))
	next({width = children_sum(), height = px(tb.side), axis = .X, cross = .Center})
	tb.inner = build_box({}, "###in")
	push_parent(tb.inner)
	return true
}

@(private)
toolbar_group_end :: proc(built: bool) {
	if !built { return }
	s := gs()
	tb := &s.toolbar
	mem := &s.toolbars[tb.key]
	em := font_size()
	pop_parent()   // its inner box
	// (measured as the layout will lay it out, wherever it is: the bar's room for it is that and its separator; what is
	// not an item is that less the items built in it)
	g := &mem.groups[tb.group]
	g.width = natural_width(tb.inner)
	inside: f32
	for i := len(g.items) - 1; i >= 0; i -= 1 {
		it := g.items[i]
		if it.seen != s.build_index { ordered_remove(&g.items, i); continue }
		if tb.in_panel || !it.folded { inside += it.width }
	}
	g.rest = max(0, g.width - inside)
	tb.inner = nil
	// (the row of its folded items, in the panel: its end's margin)
	if tb.row_outer != nil {
		push_parent(tb.row_outer)
		spacer(px(math.round(em * TOOLBAR_ROW_PAD_EM)))
		pop_parent()
		tb.row, tb.row_outer = nil, nil
	}
	if !tb.in_panel {
		pop_parent()   // the group
		return
	}
	spacer(px(math.round(em * TOOLBAR_ROW_PAD_EM)))
	pop_parent()           // the row
	pop_parent()           // the panel
	pop(&s.style_stack)
	pop_tags_isolated()
	pop_parent()           // the root
}

// The end of a tool bar: the "…" button when no pinned group took it, what is not a group measured, the groups no longer
// built forgotten.
@(private)
toolbar_end :: proc() {
	s := gs()
	tb := &s.toolbar
	mem := &s.toolbars[tb.key]
	em := font_size()
	if tb.folded && tb.more == nil { toolbar_more(s, tb, mem, em) }
	pop_parent()   // the bar
	for i := len(mem.groups) - 1; i >= 0; i -= 1 {
		if mem.groups[i].seen != s.build_index {
			delete(mem.groups[i].items)
			ordered_remove(&mem.groups, i)
		}
	}
	total, groups: f32
	for c := tb.bar.first; c != nil; c = c.next {
		if !is_floating(c, .X) { total += natural_width(c) }
	}
	for g in mem.groups { if !g.folded { groups += g.width + g.sep } }
	more: f32 = tb.more != nil ? tb.side + 2 * math.round(em * TOOLBAR_MORE_GAP_EM) : 0
	mem.fixed = max(0, total - groups - more)
	mem.panel = tb.panel != nil && mem.open ? tb.panel.key : 0
	if tb.more == nil { mem.more = 0 }
	s.toolbar = {}
}

// `if toolbar_item(id) { ... }`, in a toolbar_group's block: a part of the group that folds on its own (toolbar_fold: the
// group's last item first). Its block builds it in the bar, or in the panel, in its group's row, while the panel is open.
// `priority` (nil: its group's) places it among the parts of every group that fold: a rare tool of a group kept long
// folds before another group's items. False: folded, the panel closed.
@(require_results, deferred_out = toolbar_item_end)
toolbar_item :: proc(id: string, priority: Maybe(int) = nil) -> bool {
	s := gs()
	tb := &s.toolbar
	assert(tb.active && tb.inner != nil, "toolbar_item: outside a tool bar's group")
	mem := &s.toolbars[tb.key]
	g := &mem.groups[tb.group]
	ikey := key_from_string(g.key, id)
	// (kept in the order the caller builds them: the fold's "the last first" is that order)
	idx := -1
	for it, i in g.items { if it.key == ikey { idx = i; break } }
	if idx < 0 {
		append(&g.items, Toolbar_Item_Memory{key = ikey})
		idx = len(g.items) - 1
	}
	if idx != tb.items && tb.items < len(g.items) {
		g.items[idx], g.items[tb.items] = g.items[tb.items], g.items[idx]
		idx = tb.items
	}
	tb.items += 1
	it := &g.items[idx]
	it.seen = s.build_index
	it.priority = priority.? or_else g.priority
	tb.item = idx
	tb.item_in_panel = false
	if tb.in_panel || !it.folded {
		next({width = children_sum(), height = pct(1), axis = .X, cross = .Center})
		tb.item_box = build_box({}, fmt.tprintf("###ti_%s", id))
		push_parent(tb.item_box)
		return true
	}
	if !mem.open { return false }
	row := toolbar_item_row(s, tb, mem, font_size())
	tb.item_in_panel = true
	push_parent(s.root)
	push_tags_isolated("floating")
	push_style_copy()
	push_parent(row)
	next({width = children_sum(), height = pct(1), axis = .X, cross = .Center})
	tb.item_box = build_box({}, fmt.tprintf("###ti_%s", id))
	push_parent(tb.item_box)
	return true
}

@(private)
toolbar_item_end :: proc(built: bool) {
	if !built { return }
	s := gs()
	tb := &s.toolbar
	mem := &s.toolbars[tb.key]
	pop_parent()   // the item
	mem.groups[tb.group].items[tb.item].width = natural_width(tb.item_box)
	tb.item_box = nil
	if !tb.item_in_panel { return }
	pop_parent()   // its group's row
	pop(&s.style_stack)
	pop_tags_isolated()
	pop_parent()   // the root
	tb.item_in_panel = false
}

// The panel's row of the folded items of the group being built: made at its first folded item, its start's margin in it
// (toolbar_group_end adds its end's).
@(private = "file")
toolbar_item_row :: proc(s: ^State, tb: ^Toolbar_Build, mem: ^Toolbar_Memory, em: f32) -> ^Box {
	if tb.row != nil { return tb.row }
	panel := toolbar_panel(s, tb, mem, em)
	push_parent(s.root)
	push_tags_isolated("floating")
	push_style_copy()
	push_parent(panel)
	tall := children_sum()
	tall.least = tb.side + 2 * math.round(em * TOOLBAR_ROW_GAP_EM)
	next({width = children_sum(), height = tall, axis = .X, cross = .Center})
	tb.row_outer = build_box({}, fmt.tprintf("###tpi_%s", tb.group_id))
	push_parent(tb.row_outer)
	spacer(px(math.round(em * TOOLBAR_ROW_PAD_EM)))
	next({width = children_sum(), height = px(tb.side), axis = .X, cross = .Center})
	tb.row = build_box({}, "###in")
	pop_parent()   // the row
	pop_parent()   // the panel
	pop(&s.style_stack)
	pop_tags_isolated()
	pop_parent()   // the root
	return tb.row
}

// The "…" button: a click opens the panel of the folded groups, or closes it.
@(private = "file")
toolbar_more :: proc(s: ^State, tb: ^Toolbar_Build, mem: ^Toolbar_Memory, em: f32) {
	gap := math.round(em * TOOLBAR_MORE_GAP_EM)
	spacer(px(gap))
	next({width = px(tb.side), height = px(tb.side), radius = math.round(tb.side * 0.22), font_size = math.round(tb.side * 0.5)})
	sig := button("###toolbar_more", icon = lucide.ELLIPSIS, o = {tip = tb.labels.more, icon_font = lucide_icons(), lit = mem.open})
	spacer(px(gap))
	tb.more = sig.box
	mem.more = sig.box != nil ? sig.box.key : 0
	if sig.clicked { mem.open = !mem.open }
}

// The panel of the folded groups, under the "…" button (its right edge at the button's, as the last build laid it out),
// over the page; built once in a build, at the first folded group.
@(private = "file")
toolbar_panel :: proc(s: ^State, tb: ^Toolbar_Build, mem: ^Toolbar_Memory, em: f32) -> ^Box {
	if tb.panel != nil { return tb.panel }
	id := fmt.tprintf("###toolbar_panel_%x", u64(tb.key))
	prev := s.boxes[key_from_string(s.root.key, id)] or_else nil
	size := prev != nil ? prev.size : Vec2{em * 12, em * 6}
	anchor := tb.bar.rect
	if more := s.boxes[mem.more] or_else nil; more != nil && mem.more != 0 { anchor = more.rect }
	pos := clamp_popup({anchor.max.x - size.x, anchor.max.y + math.round(em * 0.25)}, size, s.window_size)
	push_parent(s.root)
	push_tags_isolated("floating")
	push_style_copy()
	set_next_axis(.Y)
	s.next_mod.fixed_x = pos.x
	s.next_mod.fixed_y = pos.y
	s.next_mod.width = children_sum()
	s.next_mod.height = children_sum()
	s.next_mod.radius = em * 0.5
	if prev == nil { s.next_mod.transparency = 1; s.anim_busy = true }   // (measured on this frame, shown on the next)
	p := build_box({.Clickable, .Press_Stop, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip}, id)
	p.cursor = .Arrow
	a11y_default(p, {role = .Toolbar, orientation = .Y, name = tb.labels.more})
	_ = signal(p)
	push_parent(p)
	spacer(px(math.round(em * TOOLBAR_ROW_GAP_EM)))
	pop_parent()
	pop(&s.style_stack)
	pop_tags_isolated()
	pop_parent()
	tb.panel = p
	return p
}

// A separator's width in the bar: its line and its room on each side.
@(private = "file")
toolbar_separator_width :: proc(em: f32) -> f32 {
	return 2 * math.round(em * TOOLBAR_SEPARATOR_PAD_EM) + max(math.round(gs().scale), 1)
}

@(private = "file")
toolbar_separator :: proc(tb: ^Toolbar_Build, em: f32) {
	spacer(px(math.round(em * TOOLBAR_SEPARATOR_PAD_EM)))
	h := tb.bar.pref[.Y].kind == .Pixels ? tb.bar.pref[.Y].value : tb.side
	next({width = px(max(math.round(gs().scale), 1)), height = px(math.round(h * TOOLBAR_SEPARATOR_HEIGHT)), bg = color("border")})
	build_box({.Draw_Background}, "###sep")
	spacer(px(math.round(em * TOOLBAR_SEPARATOR_PAD_EM)))
}
