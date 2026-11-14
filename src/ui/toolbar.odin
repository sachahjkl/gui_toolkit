package ui

import "core:fmt"
import "core:math"
import "../font"
import i18n "../i18n"
import lucide "../lucide"

// A tool bar: groups of items, declared once, that the bar shows whatever the window's width (src/md/features/toolbar.md):
//
//   ui.next({width = ui.fill(), height = ui.px(bar_h)})
//   if ui.toolbar("editor_bar", {overflow = .Fold}) {
//       if ui.toolbar_group("tools", {title = "Tools", priority = 2}) {
//           if ui.toolbar_tool("pen", {label = "Pen", icon = ICON_PEN, shortcut = "P", on = tool == .Pen}) { tool = .Pen }
//       }
//       if ui.toolbar_group("props", {title = "Style", separator = true}) {
//           if ui.toolbar_control("width", {label = "Width"}) { ui.slider("###w", &width, 1, 20) }
//       }
//       if ui.toolbar_group("end", {pinned = true}) {
//           if ui.toolbar_tool("done", {label = "Done", words = true, intent = .Primary}) { done() }
//       }
//   }
//
// The program chooses what happens when the bar is too narrow (Toolbar_Options.overflow):
//   - .Wrap: the bar takes more lines. A group goes to the next line whole; a group wider than a line wraps its items,
//     each whole. The pinned groups stay at the end of the last line.
//   - .Fold: the bar keeps one line. What does not fit goes into the menu of a "…" button, the lowest priority first, a
//     group's last item first; a pinned group never folds. In the menu a folded group is a section (its title, a
//     separator between two), a tool a menu row (icon, label, shortcut), a control a row with its label at the left and
//     its widget at the right.
// An item's call answers the same wherever it is shown: a tool returns true when clicked, a control's block builds its
// widget. The bar puts its pinned groups at its end itself: build no spacer in it.

Toolbar_Overflow :: enum u8 {
	Fold,   // one line; what does not fit goes into the "…" button's menu
	Wrap,   // as many lines as it needs; each group moves whole
}

// The words of a tool bar (zero: toolbar_default_labels).
Toolbar_Labels :: struct { more: string }   // the "…" button's tooltip and name to a screen reader
// The toolkit's words of a tool bar, in the language in use.
toolbar_default_labels :: proc() -> Toolbar_Labels { return {more = i18n.tr("More tools")} }

Toolbar_Options :: struct {
	overflow: Toolbar_Overflow,
	labels:   Toolbar_Labels,
}

// What a group of a tool bar is.
Toolbar_Group_Options :: struct {
	title:     string,   // its section's heading in the "…" menu, its name to a screen reader ("" none)
	priority:  int,      // .Fold: the lower folds first
	pinned:    bool,     // at the bar's end; never folds, never wraps away from the end (Cancel, Done)
	separator: bool,     // a line before it in the bar (a separator between sections in the menu, whatever this says)
}

// A tool: an act, built by the toolkit as a button of the bar or as a row of the "…" menu.
Toolbar_Tool :: struct {
	label:     string,         // its words: the menu row's, the bar's tooltip (or its words, `words`)
	icon:      string,         // a glyph of `icon_font`
	shortcut:  string,         // its key's text ("Ctrl+Z"): the menu row's, in the bar's tooltip
	command:   Command,        // a command: its label, icon and first key, for what the fields above leave ""
	priority:  Maybe(int),     // .Fold: its own priority (nil: its group's)
	words:     bool,           // in the bar, a button with its words (and its icon), not its icon alone
	on:        bool,           // the tool chosen, a mode that is on: held down in the bar, checked in the menu
	disabled:  bool,
	intent:    Intent,         // what the act means (Done: Primary)
	icon_font: font.Font_Id,   // 0: State.icon_font
	// the id of a menu the program builds as always (`if ui.menu(id) { ... }`, outside the bar): the tool opens it, under
	// itself in the bar (lit while it is open), as its submenu when it is a row of the "…" menu ("": an act)
	menu:      string,
}

// A control: a property with a widget of the program (a slider, swatches, a toggle), which the block builds.
Toolbar_Control :: struct {
	label:    string,       // the menu row's left column, its name to a screen reader
	priority: Maybe(int),   // .Fold: its own priority (nil: its group's)
	labelled: bool,         // in the bar too, its label before its widget
}

// What a tool bar keeps between builds (State.toolbars, by toolbar_key).
@(private)
Toolbar_Memory :: struct {
	groups: [dynamic]Toolbar_Group_Memory,   // in the order the last build built them
	fixed:  f32,   // the width of what is in the bar besides its groups and the "…" button (spacers, words)
	more:   Key,   // the "…" button's box (the last build's)
}

@(private)
Toolbar_Group_Memory :: struct {
	key:      Key,
	width:    f32,    // what is in it, natural (0: not measured yet), as last built in the bar (its folded items not in it)
	rest:     f32,    // the part of `width` that is not an item
	lead:     f32,    // its gap and its separator before it in the bar (0: none)
	priority: int,
	pinned:   bool,
	folded:   bool,   // in this build
	seen:     u64,    // the build that last built it
	items:    [dynamic]Toolbar_Item_Memory,   // in the order the last build built them
}

// An item of a group (toolbar_tool, toolbar_control): it folds on its own.
@(private)
Toolbar_Item_Memory :: struct {
	key:      Key,
	width:    f32,    // natural, as last built in the bar (0: never built there)
	priority: int,    // its own, else its group's (as last built)
	folded:   bool,   // in this build
	seen:     u64,
}

// The "…" menu in this build: not open; open, not entered yet; its level being built; built, left for the bar's code.
@(private)
Toolbar_Menu :: enum u8 { Closed, Open, Entered, Left }

// Where a group or an item is built: nowhere; in the bar; in an invisible box (a group folded whole); in the menu.
@(private)
Toolbar_Where :: enum u8 { None, Bar, Hidden, Menu }

// The tool bar being built (State.toolbar).
@(private)
Toolbar_Build :: struct {
	active:     bool,
	key:        Key,
	overflow:   Toolbar_Overflow,
	bar:        ^Box,
	line:       f32,      // a line's height: the items' (.Wrap) and the separators'
	side:       f32,      // a tool's side, the "…" button's
	labels:     Toolbar_Labels,
	folded:     bool,     // .Fold: a part is folded in this build
	ended:      bool,     // the bar's end began: the pinned groups follow
	pinned:     int,      // the pinned groups built so far
	more:       ^Box,     // the "…" button, once built
	menu_name:  string,
	menu:       Toolbar_Menu,
	menu_panel: ^Box,
	sections:   int,      // the menu's sections so far
	order:      int,      // the groups built so far
	group:      int,      // the group being built (its index in the memory)
	group_where: Toolbar_Where,
	group_title: string,
	group_section: bool,  // ...its section of the menu is begun
	inner:      ^Box,     // ...its box of items
	items:      int,      // ...its items built so far
	item:       int,      // the item being built (its index in its group's memory)
	item_box:   ^Box,
	item_where: Toolbar_Where,
}

// Beside the "…" button, between a control's label and its widget, a separator's room on each side, a line's room above
// and below its items (.Wrap), in ems; a separator's height, of a line.
// The gaps between parts are measured between what a person sees (src/md/features/toolbar.md, "Spacing"). A tool is a
// ghost button of a line's side around a glyph half as tall: its face shows only under the pointer, so its glyph already
// stands a quarter of the side from its edge, and ITEM_GAP only keeps two lit faces apart. A control's widget (a track,
// a swatch, a field's frame) is seen to its edge: it carries CONTROL_PAD on each side, two controls standing
// 2 * CONTROL_PAD + ITEM_GAP = 0.5 em apart. Two groups stand GROUP_GAP apart, more than any two items, or a separator's
// room when they have one. Each is a horizontal gap of the density (dense): a dense window's bars tighten as its lists do.
@(private = "file") TOOLBAR_MORE_GAP_EM :: 0.3
@(private = "file") TOOLBAR_ITEM_GAP_EM :: 0.2
@(private = "file") TOOLBAR_CONTROL_PAD_EM :: 0.15
@(private = "file") TOOLBAR_GROUP_GAP_EM :: 0.8
@(private = "file") TOOLBAR_LABEL_GAP_EM :: 0.4
@(private = "file") TOOLBAR_SEPARATOR_PAD_EM :: 0.45
@(private = "file") TOOLBAR_LINE_PAD_EM :: 0.3
@(private = "file") TOOLBAR_SEPARATOR_HEIGHT :: 0.6

// The key of tool bar `id`: the window's, as a menu's (toolbar_menu_open finds it from anywhere).
@(private = "file")
toolbar_key :: proc(id: string) -> Key { return key_from_string(0, fmt.tprintf("###toolbar_%s", id)) }

// The id of tool bar `id`'s "…" menu.
@(private = "file")
toolbar_menu_name :: proc(id: string) -> string { return fmt.tprintf("###toolbar_menu_%s", id) }

// Whether the "…" menu of tool bar `id` is open: Escape is its own (a program's Escape waits).
toolbar_menu_open :: proc(id: string) -> bool { return menu_is_open(toolbar_menu_name(id)) }

// Whether the item being built is in the "…" menu (a widget that sizes itself otherwise in a menu row).
toolbar_in_menu :: proc() -> bool { return gs().toolbar.item_where == .Menu }

// `if toolbar(id, o) { ...its groups... }`: a tool bar. `next` gives its size: in .Fold its height is its line's; in
// .Wrap a height in pixels is a line's, and the bar is as tall as its lines.
@(require_results, deferred_none = toolbar_end)
toolbar :: proc(id: string, o := Toolbar_Options{}) -> bool {
	s := gs()
	assert(!s.toolbar.active, "toolbar: a tool bar in a tool bar")
	key := toolbar_key(id)
	if key not_in s.toolbars { s.toolbars[key] = {} }
	mem := &s.toolbars[key]
	em := font_size()
	tb := Toolbar_Build{active = true, key = key, overflow = o.overflow, side = math.round(em * BUTTON_LINE_EM), menu_name = toolbar_menu_name(id)}
	tb.labels = o.labels == {} ? toolbar_default_labels() : o.labels
	given: f32   // the height `next` gives in pixels (0: none)
	if s.has_next {
		if h, ok := s.next_mod.height.?; ok && h.kind == .Pixels { given = h.value }
	}
	switch o.overflow {
	case .Fold:
		tb.line = given > 0 ? given : tb.side
		set_next_axis(.X, .Center)
		tb.bar = build_box({.Clip}, fmt.tprintf("###%s", id))
		// (what folds: the widths of the last builds against the bar's width in the last layout)
		tb.folded = toolbar_fold(mem, tb.bar, tb.side + 2 * math.round(em * TOOLBAR_MORE_GAP_EM))
		// (not measured yet: shown from the next frame, folded as it must be)
		if tb.bar.first_build == s.build_index { tb.bar.transparency = 1; s.anim_busy = true }
		if tb.folded && menu_is_open(tb.menu_name) { tb.menu = .Open }
		push_parent(tb.bar)
	case .Wrap:
		tb.line = given > 0 ? given : tb.side + 2 * math.round(em * TOOLBAR_LINE_PAD_EM)
		m := s.has_next ? s.next_mod : Style_Mod{}
		if m.width == nil { m.width = fill() }
		h := children_sum()
		h.least = tb.line
		m.height = h
		m.axis = .X
		m.cross = .End   // (the pinned groups at the end of the last line)
		s.next_mod, s.has_next = m, true
		tb.bar = build_box({}, fmt.tprintf("###%s", id))
		push_parent(tb.bar)
		// (no gap of the flow: each group carries its own before it, as in .Fold)
		next({width = fill(), height = children_sum(), axis = .X})
		push_parent(build_box({.Wrap}, "###flow"))
	}
	a11y_default(tb.bar, {role = .Toolbar, orientation = .X})
	s.toolbar = tb
	return true
}

// Folds what does not fit, the lowest priority first (of two alike the later group): a group of items item by item, its
// last first, then the group whole. Against the bar's width in the last layout, less what is not a group, less the "…"
// button once one folds. A bar not laid out yet folds nothing. True: one folded.
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
			need -= g.rest + g.lead
		}
		if !folded { need += more_w; folded = true }
	}
	return folded
}

// The room a group takes in the bar with nothing of it folded: its gap and separator, what is not an item, its items.
@(private = "file")
toolbar_group_need :: proc(g: Toolbar_Group_Memory) -> f32 {
	need := g.lead + g.rest
	for it in g.items { need += it.width }
	return need
}

// `if toolbar_group(id, o) { ...its items... }`: a group of the tool bar being built. Its block builds its items
// (toolbar_tool, toolbar_control); each is shown in the bar or in the "…" menu. False: folded whole, the menu closed.
@(require_results, deferred_out = toolbar_group_end)
toolbar_group :: proc(id: string, o := Toolbar_Group_Options{}) -> bool {
	s := gs()
	tb := &s.toolbar
	assert(tb.active && tb.group_where == .None, "toolbar_group: outside a tool bar, or in a group")
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
	// (a group's gap before it, unless its separator's room stands there: not before the bar's first group, nor before its
	// first pinned one (a spacer and the "…" button, or the end of the flow, are there))
	leads := tb.pinned > 0 if o.pinned else tb.order > 0
	gap: f32 = leads && !o.separator ? dense(em * TOOLBAR_GROUP_GAP_EM) : 0
	tb.order += 1
	g := &mem.groups[idx]
	g.priority, g.pinned, g.seen = o.priority, o.pinned, s.build_index
	g.lead = gap + (o.separator ? toolbar_separator_width(em) : 0)
	tb.group, tb.items, tb.group_title, tb.group_section = idx, 0, o.title, false
	if o.pinned {
		if !tb.ended { toolbar_end_begins(s, tb, mem, em) }
		tb.pinned += 1
	}
	if tb.overflow == .Wrap || !g.folded {
		tb.group_where = .Bar
		next({width = children_sum(), height = tb.overflow == .Fold ? pct(1) : children_sum(), axis = .X, cross = .Center})
		gb := build_box({}, fmt.tprintf("###tg_%s", id))
		if o.title != "" { a11y_default(gb, {role = .Group, name = o.title}) }
		push_parent(gb)
		if gap > 0 { spacer(px(gap)) }
		if o.separator { toolbar_separator() }
		if tb.overflow == .Fold {
			next({width = children_sum(), height = pct(1), axis = .X, cross = .Center})
			tb.inner = build_box({}, "###in")
		} else {
			// (its items wrap in it, each whole, once it is wider than a line on its own)
			next({width = children_sum(), height = children_sum(), axis = .X, gap = Vec2{dense(em * TOOLBAR_ITEM_GAP_EM), 0}})
			tb.inner = build_box({.Wrap}, "###in")
		}
		push_parent(tb.inner)
		return true
	}
	if tb.menu == .Closed { return false }
	// (folded whole, the menu open: its items go to the menu; what the block builds besides them, nowhere to be seen)
	tb.group_where = .Hidden
	next({width = px(0), height = px(0)})
	tb.inner = build_box({.Clip}, fmt.tprintf("###tg_%s", id))
	tb.inner.transparency = 1
	push_parent(tb.inner)
	return true
}

@(private)
toolbar_group_end :: proc(built: bool) {
	if !built { return }
	s := gs()
	tb := &s.toolbar
	mem := &s.toolbars[tb.key]
	pop_parent()   // its box of items
	g := &mem.groups[tb.group]
	// (measured as the layout will lay it out: the bar's room for it is that and its lead; what is not an item is that
	// less the items built in it)
	inside: f32
	for i := len(g.items) - 1; i >= 0; i -= 1 {
		it := g.items[i]
		if it.seen != s.build_index { ordered_remove(&g.items, i); continue }
		if !it.folded { inside += it.width }
	}
	if tb.group_where == .Bar {
		g.width = natural_width(tb.inner)
		g.rest = max(0, g.width - inside)
		pop_parent()   // the group
	}
	tb.inner, tb.group_where = nil, .None
}

// The bar's end begins (at its first pinned group, or at its end): in .Wrap the flow closes, the pinned groups follow it
// at the end of its last line; in .Fold a spacer pushes them to the bar's end, the "…" button before them.
@(private = "file")
toolbar_end_begins :: proc(s: ^State, tb: ^Toolbar_Build, mem: ^Toolbar_Memory, em: f32) {
	tb.ended = true
	switch tb.overflow {
	case .Wrap:
		pop_parent()   // the flow
		spacer(px(dense(em * TOOLBAR_GROUP_GAP_EM)))
	case .Fold:
		spacer(fill())
		if tb.folded { toolbar_more(s, tb, mem, em) }
	}
}

// The end of a tool bar: the "…" button when no pinned group took it, what is not a group measured, the groups no longer
// built forgotten, the menu's level ended.
@(private)
toolbar_end :: proc() {
	s := gs()
	tb := &s.toolbar
	mem := &s.toolbars[tb.key]
	em := font_size()
	if !tb.ended {
		switch tb.overflow {
		case .Wrap: pop_parent()   // the flow
		case .Fold: if tb.folded { toolbar_more(s, tb, mem, em) }
		}
	}
	pop_parent()   // the bar
	for i := len(mem.groups) - 1; i >= 0; i -= 1 {
		if mem.groups[i].seen != s.build_index {
			delete(mem.groups[i].items)
			ordered_remove(&mem.groups, i)
		}
	}
	if tb.overflow == .Fold {
		total, groups: f32
		for c := tb.bar.first; c != nil; c = c.next {
			if !is_floating(c, .X) { total += natural_width(c) }
		}
		for g in mem.groups { if !g.folded { groups += g.width + g.lead } }
		more: f32 = tb.more != nil ? tb.side + 2 * math.round(em * TOOLBAR_MORE_GAP_EM) : 0
		mem.fixed = max(0, total - groups - more)
	}
	if tb.more == nil { mem.more = 0 }
	if tb.menu == .Left && toolbar_menu_enter(s, tb) { menu_end() }
	s.toolbar = {}
}

// An item's start: where it is shown (none: folded, the menu closed). In the bar its box is the parent until
// toolbar_item_finish; in the menu the menu's level is entered, in the section of the item's group.
@(private = "file")
toolbar_item_begin :: proc(id: string, priority: Maybe(int)) -> Toolbar_Where {
	s := gs()
	tb := &s.toolbar
	assert(tb.active && tb.group_where != .None && tb.item_where == .None, "toolbar item: outside a tool bar's group, or in an item")
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
	if tb.overflow == .Wrap || (tb.group_where == .Bar && !it.folded) {
		next({width = children_sum(), height = tb.overflow == .Wrap ? px(tb.line) : pct(1), axis = .X, cross = .Center})
		tb.item_box = build_box({}, fmt.tprintf("###ti_%s", id))
		// (never measured: not shown until the bar places it)
		if tb.overflow == .Fold && it.width == 0 && tb.bar.first_build != s.build_index {
			tb.item_box.transparency = 1
			s.anim_busy = true
		}
		push_parent(tb.item_box)
		// (in .Fold its gap is its own: it leaves with it when it folds; the first item of a group has none, whatever folds)
		if tb.overflow == .Fold && idx > 0 { spacer(px(dense(font_size() * TOOLBAR_ITEM_GAP_EM))) }
		tb.item_where = .Bar
		return .Bar
	}
	if !toolbar_menu_enter(s, tb) { return .None }
	toolbar_menu_section(tb)
	tb.item_where = .Menu
	return .Menu
}

// An item's end: its box measured in the bar, or the menu's level left for the bar's code.
@(private = "file")
toolbar_item_finish :: proc() {
	s := gs()
	tb := &s.toolbar
	switch tb.item_where {
	case .Bar:
		pop_parent()   // the item
		s.toolbars[tb.key].groups[tb.group].items[tb.item].width = natural_width(tb.item_box)
		tb.item_box = nil
	case .Menu:
		toolbar_menu_leave(s, tb)
	case .None, .Hidden:
	}
	tb.item_where = .None
}

// `if toolbar_tool(id, t) { ...act... }`, in a toolbar_group's block: a tool, a button in the bar, a row in the "…"
// menu. True: clicked (or chosen by the keyboard in the menu), wherever it is shown; never while `t.disabled`. A tool
// with a `menu` opens it and is never true: what is chosen is in the menu's block.
toolbar_tool :: proc(id: string, t: Toolbar_Tool) -> bool {
	label, icon, shortcut := t.label, t.icon, t.shortcut
	if label == "" && t.command.label != "" { label = i18n.tr(t.command.label) }
	if icon == "" { icon = t.command.icon }
	if shortcut == "" { shortcut = command_shortcut(t.command) }
	clicked := false
	switch toolbar_item_begin(id, t.priority) {
	case .None, .Hidden: return false
	case .Bar: clicked = toolbar_tool_button(id, t, label, icon, shortcut)
	case .Menu:
		row := fmt.tprintf("%s###%s", label, id)
		if t.menu != "" {
			menu_submenu_of(row, icon, t.menu, t.disabled, t.icon_font)
		} else {
			clicked = menu_item(row, shortcut, t.on, icon, t.disabled, icon_font = t.icon_font).clicked
		}
	}
	toolbar_item_finish()
	return clicked
}

// A tool's look in the bar: its glyph alone (a tool among many), or its words beside it (`words`, or no glyph). A tool
// with a menu toggles it, under its own box, and is lit while it is open.
@(private = "file")
toolbar_tool_button :: proc(id: string, t: Toolbar_Tool, label, icon, shortcut: string) -> bool {
	side := gs().toolbar.side
	tip := shortcut != "" ? fmt.tprintf("%s (%s)", label, shortcut) : label
	open := t.menu != "" && menu_is_open(t.menu)
	sig: Signal
	if t.words || icon == "" {
		o := Button_Options{intent = t.intent, disabled = t.disabled, icon_font = t.icon_font, lit = open}
		if t.on {
			o.face = Button_Face.Toggled
			o.intent = .Primary
		}
		if shortcut != "" { o.tip = tip }
		sig = button(id, label, icon, o)
	} else {
		next({width = px(side), height = px(side), radius = math.round(side * 0.22), font_size = math.round(side * 0.5)})
		o := Button_Options{tip = tip, face = t.on ? .Toggled : .Ghost, intent = t.on ? .Primary : t.intent, disabled = t.disabled, icon_font = t.icon_font, lit = open}
		sig = button(id, icon = icon, o = o)
	}
	clicked := sig.clicked && !t.disabled
	if t.menu == "" || sig.box == nil { return clicked }
	if sig.box.a11y != nil { sig.box.a11y.popup = .Menu; sig.box.a11y.expanded = open }
	if clicked {
		if open { menu_close() } else { menu_open(t.menu, sig.box.rect, anchor = sig.box.key) }
	}
	return false
}

// `if toolbar_control(id, c) { ...a widget... }`, in a toolbar_group's block: a property whose widget the block builds,
// in the bar (its label before it with `c.labelled`), or in a row of the "…" menu, its label at the left, the widget at
// the right, in a column with the other control rows. False: folded, the menu closed (nothing to build).
@(require_results, deferred_out = toolbar_control_end)
toolbar_control :: proc(id: string, c: Toolbar_Control) -> bool {
	switch toolbar_item_begin(id, c.priority) {
	case .None, .Hidden: return false
	case .Bar:
		// (a widget is seen to its edge: room of its own on each side, toolbar_control_end the end's)
		spacer(px(dense(font_size() * TOOLBAR_CONTROL_PAD_EM)))
		if c.labelled && c.label != "" {
			next({width = text_size(), height = pct(1)})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###lbl", c.label))
			spacer(px(math.round(font_size() * TOOLBAR_LABEL_GAP_EM)))
		}
		return true
	case .Menu:
		if menu_control_begin(c.label, id) { return true }
		toolbar_item_finish()   // (a search that its label does not match)
		return false
	}
	return false
}

@(private)
toolbar_control_end :: proc(built: bool) {
	if !built { return }
	switch gs().toolbar.item_where {
	case .Menu: menu_control_end(true)
	case .Bar: spacer(px(dense(font_size() * TOOLBAR_CONTROL_PAD_EM)))
	case .None, .Hidden:
	}
	toolbar_item_finish()
}

// The "…" menu's level, entered to build an item in it: opened and begun at the first folded item of the build, entered
// again after the bar's code ran between two (toolbar_menu_leave). False: not open, or no longer this bar's (Escape, a
// press outside it, a menu of the bar's own opened in its place).
@(private = "file")
toolbar_menu_enter :: proc(s: ^State, tb: ^Toolbar_Build) -> bool {
	key := menu_key(tb.menu_name)
	switch tb.menu {
	case .Closed: return false
	case .Entered: return true
	case .Open:
		if len(s.menus) == 0 || s.menus[0].key != key { tb.menu = .Closed; return false }
		if s.build_index > s.menus[0].open_build && menu_pressed_outside(s, 0, s.menus[0].anchor) {
			menu_close()
			tb.menu = .Closed
			return false
		}
		next_drop(s)   // (what the program said with `next` was for its widget, not for the menu's panel)
		if !menu_level_begin(0, 0) {
			pop(&s.popup_stack)
			tb.menu = .Closed
			return false
		}
		tb.menu_panel = parent_box()
	case .Left:
		if len(s.menus) == 0 || s.menus[0].key != key { tb.menu = .Closed; return false }
		// (as menu_level_begin left it: the root, the menu's tags and the window's style, the panel)
		push_parent(s.root)
		push_tags_isolated("floating")
		append(&s.style_stack, s.style_stack[0])
		push_parent(tb.menu_panel)
		append(&s.popup_stack, true)
		append(&s.menu_build, 0)
	}
	tb.menu = .Entered
	return true
}

// The bar's code goes on outside the menu's level: what toolbar_menu_enter pushed, taken back.
@(private = "file")
toolbar_menu_leave :: proc(s: ^State, tb: ^Toolbar_Build) {
	pop_parent()   // the panel
	pop(&s.style_stack)
	pop_tags_isolated()
	pop_parent()   // the root
	pop(&s.popup_stack)
	pop(&s.menu_build)
	tb.menu = .Left
}

// The menu's section of the group being built, at its first item in the menu: a separator after another section, its
// title.
@(private = "file")
toolbar_menu_section :: proc(tb: ^Toolbar_Build) {
	if tb.group_section { return }
	tb.group_section = true
	if tb.sections > 0 { menu_separator() }
	if tb.group_title != "" { menu_heading(tb.group_title) }
	tb.sections += 1
}

// The "…" button: a click opens the menu of what is folded under it, or closes it.
@(private = "file")
toolbar_more :: proc(s: ^State, tb: ^Toolbar_Build, mem: ^Toolbar_Memory, em: f32) {
	gap := math.round(em * TOOLBAR_MORE_GAP_EM)
	open := menu_is_open(tb.menu_name)
	spacer(px(gap))
	next({width = px(tb.side), height = px(tb.side), radius = math.round(tb.side * 0.22), font_size = math.round(tb.side * 0.5)})
	sig := button("###toolbar_more", icon = lucide.ELLIPSIS, o = {tip = tb.labels.more, icon_font = lucide_icons(), lit = open})
	spacer(px(gap))
	tb.more = sig.box
	mem.more = sig.box != nil ? sig.box.key : 0
	if sig.box != nil && sig.box.a11y != nil { sig.box.a11y.popup = .Menu; sig.box.a11y.expanded = open }
	if sig.clicked && sig.box != nil {
		if open { menu_close() } else { menu_open(tb.menu_name, sig.box.rect, anchor = sig.box.key, search = false) }
	}
}

// A separator's width in a bar: its line and its room on each side.
@(private = "file")
toolbar_separator_width :: proc(em: f32) -> f32 {
	return 2 * dense(em * TOOLBAR_SEPARATOR_PAD_EM) + max(math.round(gs().scale), 1)
}

// A vertical line between parts of a bar, its room on each side: in a tool bar a line's height, elsewhere its parent's
// (a height in pixels) or a button's line. In a tool bar, a group's `separator` puts one before the group; in the "…"
// menu this builds nothing (its sections have their own).
toolbar_separator :: proc() {
	s := gs()
	tb := &s.toolbar
	if tb.active && tb.item_where == .Menu { return }
	em := font_size()
	h := math.round(em * BUTTON_LINE_EM)
	if tb.active {
		h = tb.line
	} else if p := parent_box(); p.pref[.Y].kind == .Pixels {
		h = p.pref[.Y].value
	}
	spacer(px(dense(em * TOOLBAR_SEPARATOR_PAD_EM)))
	next({width = px(max(math.round(s.scale), 1)), height = px(math.round(h * TOOLBAR_SEPARATOR_HEIGHT)), bg = color("border")})
	build_box({.Draw_Background}, "")
	spacer(px(dense(em * TOOLBAR_SEPARATOR_PAD_EM)))
}
