package ui

// Docking, the widgets (docs/docking.md): a dock space that lays out the app's `Dock` (dock_model.odin) and lets the user
// rearrange it, in the build like any widget:
//
//   ui.dock_begin(&app.dock, "###dock", {title = panel_title, on_save = save_layout, user = app})
//   if ui.dock_panel(&app.dock, PANEL_FILES) { files_view(app) }   // built only while shown, in its stack's room
//   if ui.dock_panel(&app.dock, PANEL_LOG) { log_view(app) }
//   ui.dock_end(&app.dock)
//
//   * Each stack has a strip of tabs (role tab list; each tab a Tab stop: the arrows go along the strip, Ctrl+Shift+arrows
//     move the tab, the menu key or Shift+F10 opens its menu, a middle click closes it) and a body (tab panel) the panel's
//     content goes into. Ctrl+Tab / Ctrl+Shift+Tab, with the focus in a stack, show its next or previous panel.
//   * A tab dragged out (DOCK_DRAG_EM) shows the drop targets: five squares over the stack under the pointer (into it, or
//     beside it at a side), four at the edges of the dock space, the strip itself (between two tabs: also how a tab is moved
//     along its own strip), and a translucent preview of where it lands; let go elsewhere, it floats there. Escape cancels.
//   * A floating panel is an overlay of the dock space with a frame and a shadow, moved by the empty part of its strip (the
//     drop targets show: it docks where it is let go over one), resized by its corner, back into the dock by a double click
//     on that part of its strip (the stack it came from) or its menu. A press on it brings it to the front.
//   * Splits have the handle of pane_split (panes.odin): sides of at least DOCK_MIN_EM, the second side folds to a strip
//     (a double click, Enter, a drag under half the minimum, the chevron button at the end of its stacks' strips: the
//     side's pane_toggle), the arrows resize it from the keyboard. The strip has the theme's "pane_strip" colours.
//   * The stack's menu (its button at the end of the strip, the tab's context menu): its tabs, "Dock to" every target a
//     drag can reach (for keyboard users), float, dock back, move along the strip, close.
//
// Floating panels stay inside the application's window (an overlay of the dock space): a panel in a window of the system
// would need a ui.State of its own for that window, and the content of a panel is built in the one the app builds.

import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import i18n "../i18n"
import "../platform"

DOCK_TAB_EM :: 2             // a stack's strip of tabs (em)
DOCK_TAB_PAD_EM :: 0.8       // around a tab's title (em)
DOCK_CLOSE_EM :: 1.3         // a tab's close button (em, square)
DOCK_CLOSE_GLYPH_FRACTION :: 0.7   // its cross, of the text's size
DOCK_MENU_EM :: 1.7          // the stack's menu button (em, square)
DOCK_DRAG_EM :: 0.5          // a press on a tab that moves this far drags it (em)
DOCK_MIN_EM :: PANE_MIN_EM   // the least a side of a split keeps (em)
DOCK_GRIP_EM :: 1.1          // a floating panel's resize grip (em, square)
DOCK_GRIP_DOTS :: 3          // the grip's rows of dots
DOCK_GRIP_DOT_PITCH_PX :: 3  // between them (logical px)
RESIZE_GRIP_BEVEL_PAST_PX :: 5   // the grip's bevel reaches this far past the corner's size, up and left: its box with it (logical px)
DOCK_MENU_WIDTH_EM :: 15
DOCK_INSERT_PX :: 2          // the line where a dragged tab goes in a strip (logical px)
DOCK_PREVIEW_BORDER_PX :: 2  // the preview's outline (logical px)
DOCK_MARKER_BORDER_PX :: 1
DOCK_MARKER_RADIUS_EM :: 0.25
DOCK_MARKER_INSET_FRACTION :: 0.2   // the drawing in a square: this far from its edges
DOCK_MARKER_UNLIT_ALPHA :: 0.55     // ... in the squares the pointer is not on
DOCK_GHOST_OFFSET_EM :: 0.8         // the dragged tab's title, this far right of and below the pointer
DOCK_FOCUS_DEPTH_MAX :: 64          // boxes looked up from the focus for the stack it is in

// What the menus say (Dock_Options.labels: nil is dock_default_labels, the toolkit's words in the language in use).
Dock_Labels :: struct {
	dock_to, join, left, right, above, below: string,
	edge_left, edge_right, edge_top, edge_bottom: string,
	floating, dock_back, move_left, move_right, close, close_panel, menu, empty: string,
	window: string,
}

// The toolkit's words of the dock's menus, in the language in use (asked at each build: the language is known only once
// the settings are read).
dock_default_labels :: proc() -> Dock_Labels {
	return {
		dock_to = i18n.tr("Dock %s to"), join = i18n.tr("Into this stack"), left = i18n.tr("At its left"), right = i18n.tr("At its right"),
		above = i18n.tr("Above it"), below = i18n.tr("Below it"),
		edge_left = i18n.tr("At the left edge"), edge_right = i18n.tr("At the right edge"), edge_top = i18n.tr("At the top edge"),
		edge_bottom = i18n.tr("At the bottom edge"),
		floating = i18n.tr("Float"), dock_back = i18n.tr("Dock back"), move_left = i18n.tr("Move the tab left"), move_right = i18n.tr("Move the tab right"),
		close = i18n.tr("Close"), close_panel = i18n.tr("Close %s"), menu = i18n.tr("Stack menu"), empty = i18n.tr("(empty)"),
		window = i18n.tr("Open in a window"),
	}
}

// A tab being built (Dock_Options.tab builds its content inside `box`, whose width is that of what it builds).
Dock_Tab :: struct {
	panel:   u32,
	box:     ^Box,
	active:  bool,      // shown in its stack
	hot:     bool,      // under the pointer
	focused: bool,
	held:    bool,      // being dragged
}

Dock_Options :: struct {
	title:       proc(user: rawptr, panel: u32) -> string,      // a panel's name (its tab, its menus, screen readers)
	tab:         proc(user: rawptr, t: Dock_Tab),                // the content of a tab (nil: its title)
	closable:    proc(user: rawptr, panel: u32) -> bool,         // nil: every panel can be closed
	strip_begin: proc(user: rawptr, d: ^Dock, leaf: i32),        // boxes at the start of a stack's strip, before its tabs
	strip_end:   proc(user: rawptr, d: ^Dock, leaf: i32),        // ... at its end, before its fold and menu buttons (a toolbar)
	strip_last:  proc(user: rawptr, d: ^Dock, leaf: i32),        // ... after them: the strip's last control (a window's close button)
	strip_space: proc(user: rawptr, d: ^Dock, leaf: i32, b: ^Box),   // the empty part of a docked stack's strip, built (the app may make it Clickable: what moves its own window)
	on_save:     proc(user: rawptr, d: ^Dock),                   // the user is done changing the layout: save it (dock_format)
	user:        rawptr,
	labels:      ^Dock_Labels,
	size:        Vec2,   // the dock space (frame px; 0: its last layout's, the window's at first): where `next` gives it pixels, the same
	tab_height:  f32,    // frame px (0: DOCK_TAB_EM)
	handle:      f32,    // a split's handle across it (frame px; 0: the splitter's)
	close_buttons: bool, // a close button on the tabs of the panels that can be closed
	// the menu offers a window of its own for a panel (Dock_Labels.window): the dock lets the panel go, as a close does,
	// and Dock_Result.windowed names it; the app opens the window and builds the panel there (its own host on the same
	// Shared), then brings it back with dock_add when the window closes
	windows:     bool,
}

Dock_Result :: struct {
	changed:  bool,      // the layout changed this frame
	finished: bool,      // ... and the user is done (on_save was called)
	dragging: bool,      // a tab or a floating panel is being dragged
	closed:   u32,       // the panel the user closed this frame (DOCK_NO_PANEL: none)
	windowed: u32,       // the panel the user asked a window of its own for this frame (Dock_Options.windows; DOCK_NO_PANEL: none)
}

@(private) DOCK_TABS_ID :: "###dock_tabs"   // a strip's tabs and its empty part
@(private) dock_leaf_id :: proc(leaf: i32) -> string { return fmt.tprintf("###dock_leaf_%d", leaf) }
@(private) dock_tab_id :: proc(panel: u32) -> string { return fmt.tprintf("###dock_tab_%d", panel) }
@(private) dock_body_id :: proc(panel: u32) -> string { return fmt.tprintf("###dock_body_%d", panel) }
@(private) dock_grip_id :: proc(root: i32) -> string { return fmt.tprintf("###dock_grip_%d", root) }
@(private) dock_split_id :: proc(split: i32) -> string { return fmt.tprintf("###dock_split_%d", split) }

@(private)
dock_labels :: proc(d: ^Dock) -> Dock_Labels { return d.opts.labels != nil ? d.opts.labels^ : dock_default_labels() }

dock_title :: proc(d: ^Dock, panel: u32) -> string {
	if d.opts.title == nil { return fmt.tprintf("%d", panel) }
	return d.opts.title(d.opts.user, panel)
}

@(private)
dock_closable :: proc(d: ^Dock, panel: u32) -> bool { return d.opts.closable == nil || d.opts.closable(d.opts.user, panel) }

// The key of a tab's box (in its stack's strip, in the box of its tabs).
dock_tab_key :: proc(d: ^Dock, leaf: i32, panel: u32) -> Key {
	return key_from_string(key_from_string(key_from_string(d.space_key, dock_leaf_id(leaf)), DOCK_TABS_ID), dock_tab_id(panel))
}
// The key of the box a panel's content goes into.
dock_body_key :: proc(d: ^Dock, panel: u32) -> Key { return key_from_string(d.space_key, dock_body_id(panel)) }

// The dock space: lays out the dock, takes the user's drags, drops and keys, and builds the strips, the handles and the
// floating panels' frames. The panels' content follows (dock_panel), then dock_end.
dock_begin :: proc(d: ^Dock, id: string, o := Dock_Options{}) {
	s := gs()
	dock_ready(d)
	d.opts = o
	d.closed, d.windowed = DOCK_NO_PANEL, DOCK_NO_PANEL
	if d.saved == 0 { d.saved = d.serial }   // (the layout the app made or loaded is not a change of the user's)
	d.begin_serial = d.serial
	em := font_size()
	d.space_key = key_from_string(parent_box().key, id)
	size := o.size
	if prev := box_from_key(d.space_key); prev != nil {
		d.origin = prev.rect.min
		if size.x <= 0 || size.y <= 0 { size = prev.rect.max - prev.rect.min }
	}
	if size.x <= 0 || size.y <= 0 { size = s.window_size - d.origin }
	m := Dock_Metrics{
		strip  = o.tab_height > 0 ? o.tab_height : math.round(DOCK_TAB_EM * em),
		handle = o.handle > 0 ? o.handle : math.round(SPLITTER_THICKNESS_PX * s.scale),
		folded = math.round(PANE_STRIP_EM * em),
		min    = DOCK_MIN_EM * em,
		marker = math.round(DOCK_MARKER_EM * em),
		gap    = math.round(DOCK_MARKER_GAP_EM * em),
		border = max(math.round(s.scale), 1),
		em     = em,
		scale  = s.scale,
	}
	dock_layout(d, size, m)
	dock_raise_pressed(d)
	dock_grips(d)
	dock_drag_frame(d)
	dock_keys(d)
	dock_layout(d, size, m)

	mod := s.has_next ? s.next_mod : Style_Mod{width = fill(), height = fill()}
	if mod.width == nil { mod.width = fill() }
	if mod.height == nil { mod.height = fill() }
	next(mod)
	space := build_box({}, id)
	push_parent(space)
	defer pop_parent()
	dock_build_tree(d, d.main)
	floats := make([]i32, len(d.floats), context.temp_allocator)   // (a tab shown from the keyboard brings its panel to the front)
	copy(floats, d.floats[:])
	for f in floats { if dock_valid_node(d, f) { dock_build_float(d, f) } }
}

// The panel's content follows in the block, in its stack's room, while it is shown (its stack's tab on top, not folded).
// `if dock_panel(d, p) { ... }`: the box is let go at the end of the statement (not `if !dock_panel(d, p) { continue }`).
@(require_results, deferred_in_out = dock_panel_end)
dock_panel :: proc(d: ^Dock, panel: u32) -> bool {
	if !dock_shown(d, panel) { return false }
	b := box_from_key(dock_body_key(d, panel))
	if b == nil || b.last_build != gs().build_index { return false }
	push_parent(b)
	return true
}

@(private)
dock_panel_end :: proc(d: ^Dock, panel: u32, ok: bool) { if ok { pop_parent() } }

// The end of the dock space: the drop targets and the preview over it while something is dragged, the menu, and the save.
dock_end :: proc(d: ^Dock) -> (res: Dock_Result) {
	dock_do_pending(d)
	space := box_from_key(d.space_key)
	if space != nil && space.last_build == gs().build_index && d.drag.state == .Dragging {
		push_parent(space)
		dock_build_overlay(d)
		pop_parent()
	}
	if menu(dock_menu_id(d), font_size() * DOCK_MENU_WIDTH_EM) { dock_menu_items(d, d.menu_panel) }
	dock_do_pending(d)   // (the menu's Close)
	res.closed, res.windowed = d.closed, d.windowed
	res.dragging = d.drag.state == .Dragging
	res.changed = d.serial != d.begin_serial
	if d.serial != d.saved && d.drag.state == .Idle && !dock_held(d) {
		d.saved = d.serial
		res.finished = true
		if d.opts.on_save != nil { d.opts.on_save(d.opts.user, d) }
	}
	return
}

// Whether the left button holds one of the dock's own controls: a tab or a floating panel's title (pressed, dragged, or
// cancelled by Escape until the release), a split's handle, a floating panel's corner. What is held in a panel's content,
// or in what the app builds in a strip, is not the dock's. It is the press that says so: when the press ends (the button
// went up, the box held went, the user left the window), so does this, at once.
dock_held :: proc(d: ^Dock) -> bool {
	k := active_key()
	if k == 0 || len(d.nodes) == 0 { return false }
	if d.drag.state != .Idle && d.drag.key == k { return true }
	for f in d.floats { if k == key_from_string(d.space_key, dock_grip_id(f)) { return true } }
	for i in 0 ..< i32(len(d.nodes)) {
		if d.nodes[i].kind == .Split && k == key_from_string(d.space_key, dock_split_id(i)) { return true }
	}
	return false
}

// The stack's menu of a panel closed: it has nothing to say.
@(private)
dock_menu_of_gone :: proc(d: ^Dock, panel: u32) {
	if d.menu_panel != panel || current == nil { return }
	if menu_is_open(dock_menu_id(d)) { menu_close() }
}

// The id of the dock's menu: its space's, one per dock.
@(private = "file")
dock_menu_id :: proc(d: ^Dock) -> string { return fmt.tprintf("###dock_menu_%x", u64(d.space_key)) }

// Opens the stack's menu for `panel` (at `pos`, window px; `from_keyboard`: its first item is selected).
dock_open_menu :: proc(d: ^Dock, panel: u32, pos: Vec2, from_keyboard := false) {
	d.menu_panel = panel
	menu_open(dock_menu_id(d), pos, from_keyboard = from_keyboard)
}

////////////////////////////////
// Input before the build

// A press on a floating panel brings it to the front (before its boxes are built: in front this frame).
@(private)
dock_raise_pressed :: proc(d: ^Dock) {
	if !mouse_pressed(.Left) { return }
	p := mouse_pos() - d.origin
	for k := len(d.floats) - 1; k >= 0; k -= 1 {
		r := d.nodes[d.floats[k]].rect
		if p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y { dock_raise(d, d.floats[k]); return }
	}
}

// What the press of a floating panel's corner keeps (press_data): the panel's rect when it began, logical px.
@(private = "file")
Dock_Grip_Press :: struct { from: Rect, taken: bool }

// The floating panels' corners (their boxes of the last build): resized before the layout, so the frame follows at once.
@(private)
dock_grips :: proc(d: ^Dock) {
	for f in d.floats {
		gb := box_from_key(key_from_string(d.space_key, dock_grip_id(f)))
		if gb == nil { continue }
		sig := signal(gb)
		sc := d.metrics.scale
		press := press_data(Dock_Grip_Press, gb.key)
		if press != nil && !press.taken {
			r := d.nodes[f].rect
			press^ = {from = {r.min / sc, r.max / sc}, taken = true}
		}
		if !sig.dragging || press == nil { continue }
		from := press.from
		lo := DOCK_FLOAT_MIN_EM * d.metrics.em / sc
		w := max(from.max.x - from.min.x + sig.drag_delta.x / sc, lo.x)
		h := max(from.max.y - from.min.y + sig.drag_delta.y / sc, lo.y)
		nr := Rect{from.min, {from.min.x + w, from.min.y + h}}
		if nr != d.nodes[f].float { d.nodes[f].float = nr; dock_changed(d) }
	}
}

// The drag of a tab or a floating panel: past the threshold it drags, the target under the pointer, Escape, the drop when
// the button goes up.
@(private)
dock_drag_frame :: proc(d: ^Dock) {
	dr := &d.drag
	if dr.state == .Idle { return }
	build := gs().build_index
	if build > dr.seen + 1 {
		// the dock was not built: nothing here saw how the drag went
		if dr.panel == DOCK_NO_PANEL && dock_valid_node(d, dr.node) { d.nodes[dr.node].float = dr.float_from }
		dr^ = {}
		return
	}
	dr.seen = build
	if active_key() != dr.key {
		// the button went up: a drop. Else what was held went, or the user left the window: nothing was dropped
		if dr.state == .Dragging && gs().released_key[.Left] == dr.key {
			dock_drop(d)
		} else if dr.panel == DOCK_NO_PANEL && dock_valid_node(d, dr.node) {
			d.nodes[dr.node].float = dr.float_from
		}
		dr^ = {}
		return
	}
	switch dr.state {
	case .Idle, .Cancelled: return
	case .Pressed:
		dlt := mouse_pos() - dr.from
		if math.sqrt(dlt.x * dlt.x + dlt.y * dlt.y) < DOCK_DRAG_EM * d.metrics.em { return }
		dr.state = .Dragging
	case .Dragging:
	}
	if key_press(.Escape) {
		if dr.panel == DOCK_NO_PANEL && dock_valid_node(d, dr.node) { d.nodes[dr.node].float = dr.float_from }
		dr.state = .Cancelled
		return
	}
	local := mouse_pos() - d.origin
	if dr.panel == DOCK_NO_PANEL && dock_valid_node(d, dr.node) {
		// a floating panel follows the pointer
		dlt := (mouse_pos() - dr.from) / d.metrics.scale
		d.nodes[dr.node].float = {dr.float_from.min + dlt, dr.float_from.max + dlt}
		layout_float(d, dr.node, d.metrics)
	}
	dr.target, dr.under = dock_target_at(d, local, dr.panel, dr.node, dr.grab)
	dr.insert_x = -1
	if dr.target.place == .Tab && dr.under == dr.target.node && local.y < dock_strip_rect(d, dr.under).max.y {
		// over a strip: between the tabs the pointer is between (their boxes of the last build)
		idx := 0
		x := dock_strip_rect(d, dr.under).min.x
		for q, k in dock_tabs(d, dr.under) {
			b := box_from_key(dock_tab_key(d, dr.under, q))
			if b == nil { continue }
			if local.x > (b.rect.min.x + b.rect.max.x) * 0.5 - d.origin.x { idx, x = k + 1, b.rect.max.x - d.origin.x }
		}
		dr.target.index, dr.insert_x = idx, x
	}
}

@(private)
dock_drop :: proc(d: ^Dock) {
	dr := d.drag
	if dr.panel == DOCK_NO_PANEL {
		if !dock_valid_node(d, dr.node) { return }
		if dr.target.place == .Float { dock_changed(d); return }   // (moved already)
		dock_move_node(d, dr.node, dr.target)
		return
	}
	leaf := dock_leaf_of(d, dr.panel)
	if dr.target.place == .Float && leaf != DOCK_NONE && d.nodes[leaf].parent == DOCK_NONE && leaf != d.main && dock_tab_count(d, leaf) == 1 {
		dock_move_node(d, leaf, dr.target)   // (the one tab of a floating panel: the panel moves)
		return
	}
	dock_move(d, dr.panel, dr.target)
}

// Ctrl+Tab / Ctrl+Shift+Tab with the focus in a stack (one of its tabs, or in its panel): its next or previous panel.
@(private)
dock_keys :: proc(d: ^Dock) { _ = dock_take_ctrl_tab(d) }

// Ctrl+Tab / Ctrl+Shift+Tab of this frame for the dock when the focus is in one of its stacks: the stack's next or previous
// panel, the key taken. For an app whose own shortcuts use Ctrl+Tab: called before them, the dock has it first where it has
// the focus (dock_begin calls it too).
dock_take_ctrl_tab :: proc(d: ^Dock) -> bool {
	fwd := key_pressed_peek(.Tab, {.Ctrl})
	if !fwd && !key_pressed_peek(.Tab, {.Ctrl, .Shift}) { return false }
	leaf, on_tab := dock_focus_leaf(d)
	if leaf == DOCK_NONE || dock_tab_count(d, leaf) < 2 { return false }
	_ = key_press(.Tab, fwd ? {.Ctrl} : {.Ctrl, .Shift})
	dock_cycle(d, leaf, fwd, on_tab)
	return true
}

// The stack the keyboard focus is in (one of its tabs, or in its panel's content), by the last build; `on_tab`: on a tab.
dock_focus_leaf :: proc(d: ^Dock) -> (leaf: i32, on_tab: bool) {
	fk := focus_key()
	if fk == 0 || len(d.nodes) == 0 { return DOCK_NONE, false }
	child: ^Box
	depth := 0
	for b := box_from_key(fk); b != nil && depth < DOCK_FOCUS_DEPTH_MAX; b, depth = b.parent, depth + 1 {
		if b.parent != nil && b.parent.key == d.space_key { child = b; break }
	}
	if child == nil { return DOCK_NONE, false }
	for l in dock_all_leaves(d) {
		a := d.nodes[l].active
		if a == DOCK_NO_PANEL { continue }
		if child.key == key_from_string(d.space_key, dock_leaf_id(l)) { return l, true }
		if child.key == dock_body_key(d, a) { return l, false }
	}
	return DOCK_NONE, false
}

// The next (or previous) panel of the stack shown; the focus goes to its tab when it was on one.
dock_cycle :: proc(d: ^Dock, leaf: i32, forward: bool, on_tab: bool) {
	tabs := dock_tabs(d, leaf)
	if len(tabs) < 2 { return }
	at := 0
	for t, k in tabs { if t == d.nodes[leaf].active { at = k } }
	to := tabs[(at + (forward ? 1 : len(tabs) - 1)) % len(tabs)]
	dock_activate(d, to)
	if on_tab { set_focus(dock_tab_key(d, leaf, to)) }
}
////////////////////////////////
// The boxes

// A tree: its handles first (a drag moves the stacks of this frame), then its stacks.
@(private)
dock_build_tree :: proc(d: ^Dock, root: i32) {
	Handle :: struct { split: i32, box: ^Box }
	handles := make([dynamic]Handle, 0, len(d.nodes), context.temp_allocator)
	serial := d.serial
	walk :: proc(d: ^Dock, n: i32, out: ^[dynamic]Handle) {
		if d.nodes[n].kind != .Split { return }
		walk(d, d.nodes[n].a, out)
		if !d.nodes[n].fold { walk(d, d.nodes[n].b, out) }
		append(out, Handle{n, dock_handle(d, n)})
	}
	walk(d, root, &handles)
	if d.serial != serial {
		layout_node(d, root, d.nodes[root].rect, d.metrics)
		for h in handles {
			r := dock_handle_rect(d, h.split)
			h.box.fixed_pos = r.min
			h.box.pref = {.X = px(r.max.x - r.min.x), .Y = px(r.max.y - r.min.y)}
		}
	}
	for l in dock_leaves(d, root) { if dock_node_visible(d, l) { dock_build_leaf(d, l) } }
}

// A split's handle: pane_split's, the second side the pane.
@(private)
dock_handle :: proc(d: ^Dock, split: i32) -> ^Box {
	n := d.nodes[split]
	m := d.metrics
	sc := m.scale
	hr := dock_handle_rect(d, split)
	ax := n.axis
	length := n.rect.max[int(ax)] - n.rect.min[int(ax)]
	room := max(length - m.handle, 1)
	p: Pane
	p.collapsed = n.fold
	p.size[ax] = (room - math.round(room * n.ratio)) / sc
	name := fmt.tprintf("%s | %s", dock_stack_label(d, dock_leaves(d, n.a)[0]), dock_stack_label(d, dock_leaves(d, n.b)[0]))
	opts := Pane_Options{side = .After, total = room / sc, min_size = m.min / sc, min_other = m.min / sc, collapsible = true, title = name, thickness = m.handle}
	if ax == .X { next({fixed_x = hr.min.x, fixed_y = hr.min.y, height = px(hr.max.y - hr.min.y)}) } else { next({fixed_x = hr.min.x, fixed_y = hr.min.y, width = px(hr.max.x - hr.min.x)}) }
	r := pane_split(dock_split_id(split), ax, &p, opts)
	if r.changed {
		ratio := p.collapsed ? n.ratio : 1 - p.size[ax] * sc / room
		dock_set_split(d, split, ratio, p.collapsed)
	}
	return r.sig.box
}

// The titles of a stack's panels, its shown one first ("(empty)" when it has none).
dock_stack_label :: proc(d: ^Dock, leaf: i32) -> string {
	if !dock_is_leaf(d, leaf) { return "" }
	a := d.nodes[leaf].active
	if a == DOCK_NO_PANEL { return dock_labels(d).empty }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, dock_title(d, a))
	for p in dock_tabs(d, leaf) {
		if p == a { continue }
		strings.write_string(&b, ", ")
		strings.write_string(&b, dock_title(d, p))
	}
	return strings.to_string(b)
}

@(private)
dock_build_leaf :: proc(d: ^Dock, leaf: i32) {
	tabs := dock_tabs(d, leaf)
	if len(tabs) == 0 { return }   // (the empty main stack: nothing but its room, a drop target)
	em := d.metrics.em
	root := dock_root_of(d, leaf)
	floating := root != d.main
	sr := dock_strip_rect(d, leaf)
	next({fixed_x = sr.min.x, fixed_y = sr.min.y, width = px(sr.max.x - sr.min.x), height = px(sr.max.y - sr.min.y), axis = .X, cross = .Center})
	strip: ^Box
	if tags("bar") { strip = build_box({.Clip, .Draw_Background}, dock_leaf_id(leaf)) }
	if edged() {   // (the edged finish: a stack's strip is a window's title, lit where the focus is)
		focus, _ := dock_focus_leaf(d)
		sd := frame_new(Dock_Strip_Draw)
		sd^ = {bar = strip.bg, lit = focus == leaf}
		strip.custom, strip.custom_user = dock_strip_draw, sd
	}
	a11y_set(strip, {role = .Tab_List, orientation = .X, name = dock_stack_label(d, leaf)})
	if parent(strip) {
		if d.opts.strip_begin != nil { d.opts.strip_begin(d.opts.user, d, leaf) }
		// the tabs and the rest of the strip, in the room the end's buttons leave (tabs too many for it are cut, the
		// buttons stay in view)
		next({width = fill(), height = pct(1), axis = .X, cross = .Center})
		if parent(build_box({.Clip}, DOCK_TABS_ID)) {
			for p, i in tabs { dock_build_tab(d, leaf, p, i, len(tabs)) }
			// the rest: a floating panel's title (moved by it, docked back by a double click)
			next({width = fill(), height = pct(1), cursor = floating ? platform.Cursor.Move : platform.Cursor.Arrow})
			grab := build_box(floating ? {.Clickable} : {}, "###dock_grab")
			if floating {
				gsig := signal(grab)
				if gsig.pointer_pressed {
					d.drag = {state = .Pressed, key = grab.key, seen = gs().build_index, panel = DOCK_NO_PANEL, node = root, from = mouse_pos(),
						grab = mouse_pos() - d.origin - d.nodes[root].rect.min, float_from = d.nodes[root].float}
				}
				if gsig.double_clicked {
					d.drag = {}
					append(&d.pending, Dock_Action{kind = .Redock, node = root})
				}
			} else if d.opts.strip_space != nil {
				d.opts.strip_space(d.opts.user, d, leaf, grab)
			}
		}
		if d.opts.strip_end != nil { d.opts.strip_end(d.opts.user, d, leaf) }
		// the button that folds the side the stack is on (to the strip pane_split shows in its place)
		mw := math.round(DOCK_MENU_EM * em)
		if split := dock_fold_split(d, leaf); split != DOCK_NONE {
			n := d.nodes[split]
			p := Pane{collapsed = n.fold}
			next({width = px(mw), height = px(mw)})
			if tags("icon_button") {
				if pane_toggle("###dock_fold", n.axis, &p, {side = .After, title = dock_stack_label(d, dock_leaves(d, n.b)[0])}) { dock_set_split(d, split, n.ratio, p.collapsed) }
			}
		}
		// the stack's menu
		next({width = px(mw), height = px(mw), font = widget_icons(), text_align = .Center, text_pad = 0})
		mb: ^Box
		if tags("icon_button") { mb = build_box({.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Effects, .Draw_Focus_Ring, .No_Text_Trunc}, fmt.tprintf("%s###dock_menu_btn", ICON_DOWN)) }
		msig := signal(mb)
		if msig.clicked { dock_open_menu(d, d.nodes[leaf].active, {mb.rect.min.x, mb.rect.max.y}, msig.focused && gs().focus_visible) }
		a11y_default(mb, {role = .Button, name = dock_labels(d).menu, popup = .Menu})
		if d.opts.strip_last != nil { d.opts.strip_last(d.opts.user, d, leaf) }
	}
	// the body: keyed by the panel (its content keeps its state wherever it goes)
	a := d.nodes[leaf].active
	br := dock_body_rect(d, leaf)
	next({fixed_x = br.min.x, fixed_y = br.min.y, width = px(br.max.x - br.min.x), height = px(br.max.y - br.min.y), axis = .Y})
	body := build_box({.Clip}, dock_body_id(a))
	a11y_set(body, {role = .Tab_Panel, name = dock_title(d, a), labelled_by = dock_tab_key(d, leaf, a)})
}

@(private)
dock_build_tab :: proc(d: ^Dock, leaf: i32, p: u32, i, n: int) {
	em := d.metrics.em
	title := dock_title(d, p)
	active := d.nodes[leaf].active == p
	push_tags("tab")
	if !active { push_tags("weak") }
	next({width = children_sum(), height = pct(1), axis = .X, cross = .Center})
	tb := build_box({.Clickable, .Focusable, .Draw_Hot_Effects, .Hot_Within}, dock_tab_id(p))
	if !active { pop_tags() }
	pop_tags()
	sig := signal(tb)
	td := frame_new(Tab_Draw)
	td.t, td.accent = active ? 1 : 0, color("accent")
	tb.custom, tb.custom_user = tab_draw, td
	held := d.drag.state == .Dragging && d.drag.panel == p
	closable := dock_closable(d, p)
	if parent(tb) {
		if d.opts.tab != nil {
			d.opts.tab(d.opts.user, {panel = p, box = tb, active = active, hot = sig.hovering || hot_within(tb.key), focused = sig.focused, held = held})
		} else {
			if !active { push_tags("weak") }
			spacer(px(math.round(DOCK_TAB_PAD_EM * em)))
			next({width = text_size(), height = pct(1)})
			build_box({.Draw_Text}, fmt.tprintf("%s###dock_title", title))
			spacer(px(math.round(DOCK_TAB_PAD_EM * em)))
			if !active { pop_tags() }
		}
		if d.opts.close_buttons && closable {
			// (shown on the tab on top and the one under the pointer; its room is kept on the others: no tab moves)
			cw := math.round(DOCK_CLOSE_EM * em)
			next({width = px(cw), height = px(cw), font = widget_icons(), font_size = em * DOCK_CLOSE_GLYPH_FRACTION, text_align = .Center, text_pad = 0})
			cb: ^Box
			show := active || sig.hovering || hot_within(tb.key)
			if tags("icon_button", "weak") { cb = build_box({.Clickable, .Draw_Hot_Effects, .No_Text_Trunc} + (show ? {.Draw_Text} : {}), fmt.tprintf("%s###dock_close", ICON_X)) }
			if signal(cb).clicked { dock_user_close(d, p) }
			a11y_default(cb, {role = .Button, name = fmt.tprintf(dock_labels(d).close_panel, title)})
			spacer(px(math.round(DOCK_TAB_PAD_EM * em * 0.5)))
		}
	}
	if sig.pressed {
		if !active { d.nodes[leaf].active = p; dock_changed(d) }
		if sig.pointer_pressed {
			d.drag = {state = .Pressed, key = tb.key, seen = gs().build_index, panel = p, node = DOCK_NONE, from = mouse_pos(), grab = mouse_pos() - tb.rect.min}
		}
	}
	if sig.clicked && !active { dock_activate(d, p) }   // (Enter, Space)
	if sig.middle_clicked && closable { dock_user_close(d, p) }
	if sig.right_clicked { dock_open_menu(d, p, mouse_pos()) }
	if sig.focused {
		tabs := dock_tabs(d, leaf)
		to := -1
		if key_press(.Left) { to = (i + n - 1) % n }
		if key_press(.Right) { to = (i + 1) % n }
		if key_press(.Home) { to = 0 }
		if key_press(.End) { to = n - 1 }
		if to >= 0 && to < len(tabs) {
			dock_activate(d, tabs[to])
			set_focus(dock_tab_key(d, leaf, tabs[to]))
		}
		if key_press(.Left, {.Ctrl, .Shift}) && i > 0 { dock_move(d, p, {place = .Tab, node = leaf, index = i - 1}) }
		if key_press(.Right, {.Ctrl, .Shift}) && i + 1 < n { dock_move(d, p, {place = .Tab, node = leaf, index = i + 2}) }
		if key_press(.Menu) || key_press(.F10, {.Shift}) { dock_open_menu(d, p, {tb.rect.min.x, tb.rect.max.y}, true) }
	}
	info := A11y_Info{role = .Tab, name = title, selected = active, position = i + 1, set_size = n}
	if active { info.controls = dock_body_key(d, p) }
	a11y_set(tb, info)
}

// (in the build: done by dock_end)
@(private)
dock_user_close :: proc(d: ^Dock, p: u32) { append(&d.pending, Dock_Action{kind = .Close, panel = p}) }

@(private)
dock_do_pending :: proc(d: ^Dock) {
	for a in d.pending {
		switch a.kind {
		case .Close:  if dock_close(d, a.panel) { d.closed = a.panel }
		case .Window: if dock_close(d, a.panel) { d.windowed = a.panel }
		case .Redock: if dock_valid_node(d, a.node) && dock_is_floating(d, a.node) { dock_redock(d, a.node) }
		}
	}
	clear(&d.pending)
}

// A floating root: its frame, its handles and stacks, its grip.
@(private)
dock_build_float :: proc(d: ^Dock, root: i32) {
	r := dock_float_rect(d, root, d.metrics)
	em := d.metrics.em
	next({fixed_x = r.min.x, fixed_y = r.min.y, width = px(r.max.x - r.min.x), height = px(r.max.y - r.min.y), cursor = platform.Cursor.Arrow})
	frame: ^Box
	if tags("floating") { frame = build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Plate}, fmt.tprintf("###dock_float_%d", root)) }   // (Clickable: what is under it gets no press)
	frame.square_corners = {.Bottom_Right}   // (the grip's corner, its bevel filling it: square by choice of the design, kept so)
	a11y_set(frame, {role = .Group, name = dock_stack_label(d, dock_leaves(d, root)[0]), role_description = i18n.tr("floating panel")})
	// The panels are not its children, and are drawn after it, square: within its corners from here to the box that closes it, whose
	// border goes over them.
	frame.custom = dock_float_clip
	dock_build_tree(d, root)
	next({fixed_x = r.min.x, fixed_y = r.min.y, width = px(r.max.x - r.min.x), height = px(r.max.y - r.min.y)})
	if tags("floating") {
		end := build_box({.Draw_Border}, fmt.tprintf("###dock_float_end_%d", root))
		end.square_corners = frame.square_corners
		end.custom = dock_float_unclip
	}
	g := math.round(DOCK_GRIP_EM * em) + RESIZE_GRIP_BEVEL_PAST_PX * scale()   // (the bevel's square: resize_grip_draw)
	// (the corner's own cursor, as a window's bottom right corner and a dialog's grip have it: se-resize is in every theme, and
	// nwse-resize is not; a theme without it fell back to a name some themes draw the other way, bd_double_arrow)
	next({fixed_x = r.max.x - g, fixed_y = r.max.y - g, width = px(g), height = px(g), cursor = platform.Cursor.Resize_SE})
	gb := build_box({.Clickable}, dock_grip_id(root))
	resize_grip_paint(gb, signal(gb))
}

@(private)
dock_float_clip :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	s := gs()
	line := max(math.round(scale()), 1)
	radius := max(box_drawn_radius(s, b) - line, 0)
	draw.push_clip_rounded(dc, draw.rect_pad(b.rect, -line), box_radii(radius, b.square_corners))
}

@(private)
dock_float_unclip :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) { draw.pop_clip(dc) }

// A resize grip in the bottom right corner of a dialog or a floating panel (the corner is square): a darker bevel cut across
// the corner, and dots on it. The bevel sets the dots off the surface whatever its colour.
@(private)
Resize_Grip_Draw :: struct { dots, shade: Color }

@(private)
resize_grip_paint :: proc(b: ^Box, sig: Signal) {
	gd := frame_new(Resize_Grip_Draw)
	gd.dots = sig.hovering || sig.dragging ? color("accent") : color("weak text")
	gd.shade = color("resize_grip shade")
	b.custom, b.custom_user = resize_grip_draw, gd
}

@(private)
resize_grip_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	gd := (^Resize_Grip_Draw)(user)
	s := max(math.round(scale()), 1)
	// inside the surface's border (its parent draws it after this), as far up and left as the grip's box goes: the box is the
	// bevel's square, so that all of what is drawn takes the press, with its cursor (a bevel past its box gave the edges'
	// cursors on its upper part)
	r := Rect{b.rect.min, b.rect.max - s}
	g := r.max.x - r.min.x
	// the bevel: a band as wide as the corner, one edge along the cut, clipped to the corner (an antialiased cut at 45°)
	h := g * math.SQRT_TWO * 0.5          // half the band's width
	n := Vec2{1, 1} / math.SQRT_TWO        // across the cut, toward the corner
	d := Vec2{-1, 1} / math.SQRT_TWO       // along the cut
	mid := Vec2{r.max.x - g * 0.5, r.max.y - g * 0.5} + n * h
	draw.push_clip(dc, {r.max - g, r.max})
	draw.line(dc, mid - d * 2 * g, mid + d * 2 * g, 2 * h, gd.shade)
	draw.pop_clip(dc)
	pitch := DOCK_GRIP_DOT_PITCH_PX * s
	for i in 0 ..< DOCK_GRIP_DOTS {
		for j in 0 ..= i {
			x := r.max.x - 2 * s - f32(j) * pitch
			y := r.max.y - 2 * s - f32(i - j) * pitch
			draw.rect(dc, {{x - s, y - s}, {x, y}}, gd.dots)
		}
	}
}

////////////////////////////////
// While dragging: the targets, the preview, the title under the pointer

@(private)
Dock_Overlay_Draw :: struct {
	preview:   Rect,         // local (frame px from the space's top left)
	markers:   [9]Rect,
	kinds:     [9]Dock_Marker,
	count:     int,
	lit:       int,          // the marker of the target (-1: none)
	insert:    Rect,         // the line where a tab goes (empty: none)
	preview_bg, preview_border, marker_bg, marker_border, accent: Color,
	radius, line, border: f32,
}

@(private)
dock_build_overlay :: proc(d: ^Dock) {
	dr := d.drag
	m := d.metrics
	sc := m.scale
	o := frame_new(Dock_Overlay_Draw)
	o.lit = -1
	o.preview = dock_preview_rect(d, dr.target)
	add :: proc(o: ^Dock_Overlay_Draw, r: Rect, k: Dock_Marker, lit: bool) {
		if lit { o.lit = o.count }
		o.markers[o.count], o.kinds[o.count] = r, k
		o.count += 1
	}
	main_empty := dock_is_leaf(d, d.main) && dock_tab_count(d, d.main) == 0
	if !main_empty && (dr.under == DOCK_NONE || !dock_is_floating(d, dr.under)) {
		for r, k in dock_edge_markers(d.size, m) {
			if k == .Center || !dock_target_valid(d, dr.panel, dr.node, {place = marker_edge(k)}) { continue }
			add(o, r, k, dr.target.place == marker_edge(k))
		}
	}
	if dr.under != DOCK_NONE {
		in_strip := dr.insert_x >= 0
		for r, k in dock_markers(d.nodes[dr.under].rect, m) {
			t := Dock_Target{place = marker_side(k), node = dr.under, index = -1}
			if !dock_target_valid(d, dr.panel, dr.node, t) { continue }
			add(o, r, k, !in_strip && dr.target.node == dr.under && dr.target.place == t.place)
		}
	}
	if dr.insert_x >= 0 {
		sr := dock_strip_rect(d, dr.under)
		w := math.round(DOCK_INSERT_PX * sc)
		o.insert = {{dr.insert_x - w * 0.5, sr.min.y}, {dr.insert_x + w * 0.5, sr.max.y}}
	}
	if tags("dock_preview") { o.preview_bg, o.preview_border = color("background"), color("border") }
	if tags("dock_marker") { o.marker_bg, o.marker_border = color("background"), color("border") }
	o.accent = color("accent")
	o.radius = DOCK_MARKER_RADIUS_EM * m.em
	o.line = math.round(DOCK_PREVIEW_BORDER_PX * sc)
	o.border = max(math.round(DOCK_MARKER_BORDER_PX * sc), 1)
	next({fixed_x = 0, fixed_y = 0, width = px(d.size.x), height = px(d.size.y)})
	ob := build_box({}, "###dock_overlay")
	ob.custom, ob.custom_user = dock_overlay_draw, o
	a11y_set(ob, {ignore = true})

	// what is dragged, by the pointer
	title := dr.panel != DOCK_NO_PANEL ? dock_title(d, dr.panel) : dock_stack_label(d, dock_leaves(d, dr.node)[0])
	local := mouse_pos() - d.origin
	off := DOCK_GHOST_OFFSET_EM * m.em
	next({fixed_x = local.x + off, fixed_y = local.y + off, width = text_size(math.round(DOCK_TAB_PAD_EM * m.em)), height = px(m.strip)})
	if tags("floating") {
		gh := build_box({.Draw_Background, .Draw_Border, .Draw_Shadow, .Draw_Text}, fmt.tprintf("%s###dock_ghost", title))
		a11y_set(gh, {ignore = true})
	}
}

@(private)
dock_overlay_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	o := (^Dock_Overlay_Draw)(user)
	at := b.rect.min
	if o.preview.max.x > o.preview.min.x {
		r := Rect{o.preview.min + at, o.preview.max + at}
		draw.rect(dc, r, o.preview_bg)
		draw.rect(dc, r, o.preview_border, 0, o.line)
	}
	if o.insert.max.x > o.insert.min.x { draw.rect(dc, {o.insert.min + at, o.insert.max + at}, o.accent) }
	for i in 0 ..< o.count {
		r := Rect{o.markers[i].min + at, o.markers[i].max + at}
		draw.rect(dc, r, o.marker_bg, o.radius)
		draw.rect(dc, r, i == o.lit ? o.accent : o.marker_border, o.radius, o.border)
		// the drawing: the room it would take in the stack
		w := r.max - r.min
		inner := Rect{r.min + w * DOCK_MARKER_INSET_FRACTION, r.max - w * DOCK_MARKER_INSET_FRACTION}
		iw := inner.max - inner.min
		#partial switch o.kinds[i] {
		case .Left:   inner.max.x = inner.min.x + iw.x * DOCK_DROP_SHARE
		case .Right:  inner.min.x = inner.max.x - iw.x * DOCK_DROP_SHARE
		case .Top:    inner.max.y = inner.min.y + iw.y * DOCK_DROP_SHARE
		case .Bottom: inner.min.y = inner.max.y - iw.y * DOCK_DROP_SHARE
		}
		c := o.accent
		if i != o.lit { c.a *= DOCK_MARKER_UNLIT_ALPHA }
		draw.rect(dc, inner, c, o.radius * DOCK_MARKER_INSET_FRACTION)
	}
}

////////////////////////////////
// The menu: every target a drag can reach

@(private)
dock_menu_items :: proc(d: ^Dock, p: u32) {
	leaf := dock_leaf_of(d, p)
	if leaf == DOCK_NONE { return }
	lb := dock_labels(d)
	tabs := dock_tabs(d, leaf)
	for q in tabs {
		if menu_item(fmt.tprintf("%s###dock_m_tab_%d", dock_title(d, q), q), checked = d.nodes[leaf].active == q).clicked { dock_activate(d, q) }
	}
	menu_separator()
	title := dock_title(d, p)
	if menu_submenu(fmt.tprintf("%s###dock_m_to", fmt.tprintf(lb.dock_to, title))) { dock_to_items(d, p) }
	root := dock_root_of(d, leaf)
	if root != d.main {
		if menu_item(fmt.tprintf("%s###dock_m_back", lb.dock_back)).clicked { dock_redock(d, root) }
	} else if menu_item(fmt.tprintf("%s###dock_m_float", lb.floating)).clicked {
		dock_float(d, p, dock_float_place(d))
	}
	if d.opts.windows && menu_item(fmt.tprintf("%s###dock_m_window", lb.window)).clicked {
		append(&d.pending, Dock_Action{kind = .Window, panel = p})
	}
	at := 0
	for q, k in tabs { if q == p { at = k } }
	if len(tabs) > 1 {
		if menu_item(fmt.tprintf("%s###dock_m_ml", lb.move_left), chord_text({.Left, {.Ctrl, .Shift}}), disabled = at <= 0).clicked { dock_move(d, p, {place = .Tab, node = leaf, index = at - 1}) }
		if menu_item(fmt.tprintf("%s###dock_m_mr", lb.move_right), chord_text({.Right, {.Ctrl, .Shift}}), disabled = at + 1 >= len(tabs)).clicked { dock_move(d, p, {place = .Tab, node = leaf, index = at + 2}) }
	}
	if dock_closable(d, p) {
		menu_separator()
		if menu_item(fmt.tprintf("%s###dock_m_close", lb.close)).clicked { dock_user_close(d, p) }
	}
}

// "Dock <panel> to": each stack (into it, at a side of it), each edge of the space, floating.
@(private)
dock_to_items :: proc(d: ^Dock, p: u32) {
	lb := dock_labels(d)
	own := dock_leaf_of(d, p)
	sides := [5]Dock_Place{.Tab, .Left, .Right, .Top, .Bottom}
	names := [5]string{lb.join, lb.left, lb.right, lb.above, lb.below}
	for l in dock_all_leaves(d) {
		if dock_tab_count(d, l) == 0 { continue }
		any := false
		for pl in sides {
			if pl == .Tab && l == own { continue }
			if dock_target_valid(d, p, DOCK_NONE, {place = pl, node = l}) { any = true }
		}
		if !any { continue }
		if menu_submenu(fmt.tprintf("%s###dock_m_l%d", dock_stack_label(d, l), l)) {
			for pl, k in sides {
				t := Dock_Target{place = pl, node = l, index = -1}
				if (pl == .Tab && l == own) || !dock_target_valid(d, p, DOCK_NONE, t) { continue }
				if menu_item(fmt.tprintf("%s###dock_m_s%d", names[k], k)).clicked { dock_move(d, p, t) }
			}
		}
	}
	menu_separator()
	edges := [4]Dock_Place{.Edge_Left, .Edge_Right, .Edge_Top, .Edge_Bottom}
	edge_names := [4]string{lb.edge_left, lb.edge_right, lb.edge_top, lb.edge_bottom}
	for pl, k in edges {
		if menu_item(fmt.tprintf("%s###dock_m_e%d", edge_names[k], k)).clicked { dock_move(d, p, {place = pl}) }
	}
	if menu_item(fmt.tprintf("%s###dock_m_fl", lb.floating), disabled = dock_is_floating(d, own) && dock_tab_count(d, own) <= 1).clicked {
		dock_float(d, p, dock_float_place(d))
	}
}

@(private)
Dock_Strip_Draw :: struct { bar: Color, lit: bool }

@(private)
dock_strip_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dock_Strip_Draw)(user)
	caption_face(dc, b.rect, d.bar, d.bar, d.lit)
}
