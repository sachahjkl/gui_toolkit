package ui

// Docking, the model (docs/docking.md): where the app's panels are, as flat data the app owns and saves. A `Dock` is a
// tree of nodes in one array, addressed by index:
//
//   * a leaf holds a stack of panels (tabs) and shows one of them (`active`);
//   * a split holds two nodes side by side (.X) or stacked (.Y), `ratio` of the room to the first, the second folded to a
//     strip when `fold` is set;
//   * the main root fills the dock space; floating roots (`floats`, the topmost last) are panels over it at a place of
//     their own (`float`, logical px).
//
// Panels are the app's ids (u32: an enum's value); their stacks are `panels` in tab order, each naming its leaf. Nothing
// here is derived from something else that could go stale: `rect` is the layout of the frame (dock_layout writes it
// before anything reads it), the rest is the state itself.
//
// Changes (dock_move, dock_add, dock_close, dock_move_node, dock_activate...) keep the tree well formed: an emptied leaf
// goes away and its sibling takes the split's place; the main root stays (an empty leaf: the dock space is empty).
// `serial` counts them: the app saves when it moves (the widgets call Dock_Options.on_save).
//
// The text (dock_format / dock_parse), one line, panels by the names the app gives them:
//   dock1 x0.700([*elements,console] y0.500f([styles] [computed])) @40,30,320,200 [network]
// a leaf is [names] with * before the active one; a split is x or y, the first's ratio, f when the second is folded, and
// its two nodes in parentheses; each floating root follows its place (@x,y,w,h, logical px). Unknown names are dropped
// (and a leaf left empty with them); the panels the text does not name are the app's to place (dock_add).

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

DOCK_NONE :: i32(-1)         // no node
DOCK_NO_PANEL :: max(u32)    // no panel
DOCK_FORMAT_TAG :: "dock1"   // the first word of the text (its version)
DOCK_DEPTH_MAX :: 32         // splits inside splits a text may have
DOCK_NAME_CHARS_REFUSED :: "[]()*,@ \t\r\n"   // what a panel's name in the text cannot hold
DOCK_RATIO_MIN :: 0.02       // a split's ratio stays in [MIN, 1 - MIN]
DOCK_RATIO_DEFAULT :: 0.5
DOCK_DROP_SHARE :: 0.5       // a panel dropped at a side of a stack takes this share of it
DOCK_EDGE_SHARE :: 0.25      // ... at an edge of the dock space, this share of the space
DOCK_FLOAT_MIN_EM :: [2]f32{10, 6}        // the smallest floating panel (em)
DOCK_FLOAT_DEFAULT_EM :: [2]f32{28, 18}   // a panel floated from the keyboard, or larger than its stack was (em)
DOCK_FLOAT_STEP_EM :: 1.5                 // floating panels made from the keyboard: each one this far from the last (em)
DOCK_MARKER_EM :: 2          // a drop target's square (em)
DOCK_MARKER_GAP_EM :: 0.35   // between the squares, and from the edges of the dock space (em)

Dock_Kind :: enum u8 { Free, Leaf, Split }

Dock_Node :: struct {
	kind:   Dock_Kind,
	parent: i32,       // DOCK_NONE: a root (the main one or a floating one)
	a, b:   i32,       // a split's nodes: a left of b (.X) or above it (.Y)
	axis:   Axis,
	ratio:  f32,       // a split's: a's share of the room, the handle aside
	fold:   bool,      // a split's: b is folded to a strip
	active: u32,       // a leaf's: the panel it shows (DOCK_NO_PANEL: none, it is empty)
	float:  Rect,      // a floating root's place: logical px from the dock space's top left
	rect:   Rect,      // this frame's layout (dock_layout): frame px from the dock space's top left
}

Dock_Panel :: struct {
	id:   u32,
	node: i32,         // the leaf that holds it
	home: u32,         // floated: a panel it was docked with (a double click on its title takes it back there)
}

Dock_Place :: enum u8 {
	None,
	Tab,                                             // into the stack of `node`, before its `index`th tab
	Left, Right, Top, Bottom,                        // `node` split, the panel at that side
	Edge_Left, Edge_Right, Edge_Top, Edge_Bottom,    // the whole main tree split, the panel at that edge of the space
	Float,                                           // a floating panel at `rect`
}

Dock_Target :: struct {
	place: Dock_Place,
	node:  i32,
	index: int,        // .Tab: before this tab of the stack (-1 or past its last: at the end)
	rect:  Rect,       // .Float: logical px from the dock space's top left
}

// A drag of a tab (a panel) or of a floating panel's title (its root, `panel` = DOCK_NO_PANEL). Idle -> Pressed (the button
// went down on it) -> Dragging (it moved past DOCK_DRAG_EM: the drop targets show) -> dropped where `target` says when the
// button goes up; Escape: Cancelled until the button goes up. A floating panel moved follows the pointer while Dragging.
Dock_Drag_State :: enum u8 { Idle, Pressed, Dragging, Cancelled }

Dock_Drag :: struct {
	state:  Dock_Drag_State,
	key:    Key,       // the box held
	panel:  u32,
	node:   i32,       // a floating root moved (panel = DOCK_NO_PANEL)
	from:   Vec2,      // where the press was (window px)
	grab:   Vec2,      // the pointer from the top left of what is dragged (frame px)
	float_from: Rect,  // a floating root's place when the press was
	target: Dock_Target,
	under:  i32,       // the leaf under the pointer (its drop targets show)
	insert_x: f32,     // a .Tab target over a strip: where the tab goes (frame px from the space's left)
}

// What dock_layout and the drop targets measure with (frame px).
Dock_Metrics :: struct {
	strip:  f32,       // a stack's tab strip
	handle: f32,       // a split's handle, across it
	folded: f32,       // a folded split's strip
	min:    f32,       // the least a side of a split keeps
	marker: f32,       // a drop target's square
	gap:    f32,       // between them
	border: f32,       // a floating panel's frame, around its stacks
	em:     f32,
	scale:  f32,       // frame px per logical px
}

Dock :: struct {
	nodes:  #soa[dynamic]Dock_Node,
	panels: #soa[dynamic]Dock_Panel,   // in tab order within each leaf
	main:   i32,
	floats: [dynamic]i32,              // floating roots, the topmost last
	serial: u64,                       // bumped by each change of the layout
	drag:   Dock_Drag,
	// the frame being built (the widgets, docking.odin)
	size:   Vec2,                      // the dock space (frame px)
	origin: Vec2,                      // its top left in the window (its last layout)
	metrics: Dock_Metrics,
	space_key: Key,
	opts:   Dock_Options,
	saved:  u64,                       // the serial on_save last saw
	begin_serial: u64,                 // the serial when this frame's dock_begin began
	held:   bool,                      // a handle or a grip of the dock is held this frame
	closed: u32,                       // the panel a user closed this frame
	menu_panel: u32,                   // the panel the open "Dock to" menu is for
	pending: Dock_Action,              // asked for while the boxes are built: done by dock_end
}

// A change of the tree asked for in the middle of the build (a close button, a double click on a floating panel's title):
// the stacks being built stay as they are until dock_end does it.
Dock_Action_Kind :: enum u8 { None, Close, Redock }
Dock_Action :: struct {
	kind:  Dock_Action_Kind,
	panel: u32,
	node:  i32,
}

////////////////////////////////
// Making, clearing

// A dock with one empty stack (the main root). The arrays take the context's allocator.
dock_init :: proc(d: ^Dock) { dock_clear(d) }

dock_destroy :: proc(d: ^Dock) {
	delete_soa(d.nodes)
	delete_soa(d.panels)
	delete(d.floats)
	d^ = {}
}

// Back to one empty stack.
dock_clear :: proc(d: ^Dock) {
	clear_soa(&d.nodes)
	clear_soa(&d.panels)
	clear(&d.floats)
	d.drag = {}
	d.main = node_new(d, .Leaf)
	d.serial += 1
}

@(private)
node_new :: proc(d: ^Dock, kind: Dock_Kind) -> i32 {
	n := Dock_Node{kind = kind, parent = DOCK_NONE, a = DOCK_NONE, b = DOCK_NONE, ratio = DOCK_RATIO_DEFAULT, active = DOCK_NO_PANEL}
	for i in 0 ..< len(d.nodes) {
		if d.nodes[i].kind == .Free { d.nodes[i] = n; return i32(i) }
	}
	append_soa(&d.nodes, n)
	return i32(len(d.nodes) - 1)
}

@(private)
node_free :: proc(d: ^Dock, n: i32) {
	d.nodes[n] = {kind = .Free, parent = DOCK_NONE, a = DOCK_NONE, b = DOCK_NONE, active = DOCK_NO_PANEL}
}

@(private)
dock_ready :: proc(d: ^Dock) { if len(d.nodes) == 0 { dock_clear(d) } }

////////////////////////////////
// Questions

dock_valid_node :: proc(d: ^Dock, n: i32) -> bool { return n >= 0 && int(n) < len(d.nodes) && d.nodes[n].kind != .Free }
dock_is_leaf :: proc(d: ^Dock, n: i32) -> bool { return dock_valid_node(d, n) && d.nodes[n].kind == .Leaf }

@(private)
panel_index :: proc(d: ^Dock, id: u32) -> int {
	for i in 0 ..< len(d.panels) { if d.panels[i].id == id { return i } }
	return -1
}

dock_has :: proc(d: ^Dock, id: u32) -> bool { return panel_index(d, id) >= 0 }

// The leaf that holds the panel (DOCK_NONE: it is not in the dock).
dock_leaf_of :: proc(d: ^Dock, id: u32) -> i32 {
	i := panel_index(d, id)
	return i < 0 ? DOCK_NONE : d.panels[i].node
}

// The panels of a leaf, in tab order (temp allocator unless told otherwise).
dock_tabs :: proc(d: ^Dock, leaf: i32, allocator := context.temp_allocator) -> []u32 {
	out := make([dynamic]u32, 0, len(d.panels), allocator)
	for i in 0 ..< len(d.panels) { if d.panels[i].node == leaf { append(&out, d.panels[i].id) } }
	return out[:]
}

dock_tab_count :: proc(d: ^Dock, leaf: i32) -> (n: int) {
	for i in 0 ..< len(d.panels) { if d.panels[i].node == leaf { n += 1 } }
	return
}

// The root of the tree `n` is in.
dock_root_of :: proc(d: ^Dock, n: i32) -> i32 {
	r := n
	for dock_valid_node(d, r) && d.nodes[r].parent != DOCK_NONE { r = d.nodes[r].parent }
	return r
}

dock_is_floating :: proc(d: ^Dock, n: i32) -> bool { return dock_valid_node(d, n) && dock_root_of(d, n) != d.main }

// Whether `n` is inside `root`'s tree.
dock_within :: proc(d: ^Dock, n, root: i32) -> bool {
	for r := n; dock_valid_node(d, r); r = d.nodes[r].parent { if r == root { return true } }
	return false
}

// Whether the node shows: no split above it folds the side it is on.
dock_node_visible :: proc(d: ^Dock, n: i32) -> bool {
	if !dock_valid_node(d, n) { return false }
	c := n
	for p := d.nodes[n].parent; p != DOCK_NONE; c, p = p, d.nodes[p].parent {
		if d.nodes[p].fold && d.nodes[p].b == c { return false }
	}
	return true
}

// The split that folds the side the node is on: the nearest above it that has it on its second side (DOCK_NONE: none).
dock_fold_split :: proc(d: ^Dock, n: i32) -> i32 {
	if !dock_valid_node(d, n) { return DOCK_NONE }
	c := n
	for p := d.nodes[n].parent; p != DOCK_NONE; c, p = p, d.nodes[p].parent {
		if d.nodes[p].b == c { return p }
	}
	return DOCK_NONE
}

// Whether the panel is shown: the tab on top of its stack, and the stack is not folded away.
dock_shown :: proc(d: ^Dock, id: u32) -> bool {
	leaf := dock_leaf_of(d, id)
	return leaf != DOCK_NONE && d.nodes[leaf].active == id && dock_node_visible(d, leaf)
}

// The leaves of a tree, left to right and top to bottom (temp allocator unless told otherwise).
dock_leaves :: proc(d: ^Dock, root: i32, allocator := context.temp_allocator) -> []i32 {
	out := make([dynamic]i32, 0, len(d.nodes), allocator)
	walk :: proc(d: ^Dock, n: i32, out: ^[dynamic]i32) {
		if !dock_valid_node(d, n) { return }
		switch d.nodes[n].kind {
		case .Leaf:  append(out, n)
		case .Split: walk(d, d.nodes[n].a, out); walk(d, d.nodes[n].b, out)
		case .Free:
		}
	}
	walk(d, root, &out)
	return out[:]
}

// The leaves of every tree: the main one's, then each floating root's (bottom to top).
dock_all_leaves :: proc(d: ^Dock, allocator := context.temp_allocator) -> []i32 {
	out := make([dynamic]i32, 0, len(d.nodes), allocator)
	append(&out, ..dock_leaves(d, d.main, context.temp_allocator))
	for f in d.floats { append(&out, ..dock_leaves(d, f, context.temp_allocator)) }
	return out[:]
}

////////////////////////////////
// Changes

@(private)
dock_changed :: proc(d: ^Dock) { d.serial += 1 }

// The panel shown in its stack (and the folded splits that hid it open). Returns whether it is in the dock.
dock_activate :: proc(d: ^Dock, id: u32) -> bool {
	leaf := dock_leaf_of(d, id)
	if leaf == DOCK_NONE { return false }
	if d.nodes[leaf].active != id { d.nodes[leaf].active = id; dock_changed(d) }
	c := leaf
	for p := d.nodes[leaf].parent; p != DOCK_NONE; c, p = p, d.nodes[p].parent {
		if d.nodes[p].fold && d.nodes[p].b == c { d.nodes[p].fold = false; dock_changed(d) }
	}
	if root := dock_root_of(d, leaf); root != d.main { dock_raise(d, root) }
	return true
}

// A floating root goes on top of the others.
dock_raise :: proc(d: ^Dock, root: i32) {
	for f, i in d.floats {
		if f != root || i == len(d.floats) - 1 { continue }
		ordered_remove(&d.floats, i)
		append(&d.floats, root)
		return
	}
}

// `old`'s place (its parent's slot, or a root's) is `new`'s.
@(private)
replace_in_parent :: proc(d: ^Dock, old, new: i32) {
	p := d.nodes[old].parent
	d.nodes[new].parent = p
	if p != DOCK_NONE {
		if d.nodes[p].a == old { d.nodes[p].a = new } else { d.nodes[p].b = new }
		return
	}
	d.nodes[new].float = d.nodes[old].float
	if d.main == old { d.main = new; return }
	for f, i in d.floats { if f == old { d.floats[i] = new } }
}

// An empty leaf goes (the main root stays, empty); its sibling takes the split's place.
@(private)
leaf_drop_if_empty :: proc(d: ^Dock, leaf: i32) {
	if !dock_is_leaf(d, leaf) || dock_tab_count(d, leaf) > 0 { return }
	d.nodes[leaf].active = DOCK_NO_PANEL
	p := d.nodes[leaf].parent
	if p == DOCK_NONE {
		if leaf == d.main { return }
		for f, i in d.floats { if f == leaf { ordered_remove(&d.floats, i); break } }
		node_free(d, leaf)
		return
	}
	sib := d.nodes[p].a == leaf ? d.nodes[p].b : d.nodes[p].a
	replace_in_parent(d, p, sib)
	node_free(d, p)
	node_free(d, leaf)
}

// `n`'s place becomes a split of `n` and `with` (a new leaf when DOCK_NONE), `with` at `side` with `share` of the room.
// Returns `with`.
@(private)
split_around :: proc(d: ^Dock, n: i32, side: Dock_Place, share: f32, with: i32 = DOCK_NONE) -> i32 {
	w := with != DOCK_NONE ? with : node_new(d, .Leaf)
	s := node_new(d, .Split)
	replace_in_parent(d, n, s)
	d.nodes[w].float = {}
	first := side == .Left || side == .Top
	d.nodes[s].axis = side == .Left || side == .Right ? .X : .Y
	d.nodes[s].a, d.nodes[s].b = first ? w : n, first ? n : w
	d.nodes[s].ratio = clamp(first ? share : 1 - share, DOCK_RATIO_MIN, 1 - DOCK_RATIO_MIN)
	d.nodes[n].parent, d.nodes[w].parent = s, s
	d.nodes[n].float = {}
	return w
}

// The panel in the stack `leaf`, before its `index`th tab (past the last: at the end), shown.
@(private)
insert_tab :: proc(d: ^Dock, id: u32, leaf: i32, index: int, home: u32) {
	at := len(d.panels)
	seen, last := 0, -1
	for i in 0 ..< len(d.panels) {
		if d.panels[i].node != leaf { continue }
		if index >= 0 && seen == index { at = i; break }
		seen += 1
		last = i
	}
	if at == len(d.panels) && last >= 0 { at = last + 1 }
	append_soa(&d.panels, Dock_Panel{})
	for i := len(d.panels) - 1; i > at; i -= 1 { d.panels[i] = d.panels[i - 1] }
	d.panels[at] = {id = id, node = leaf, home = home}
	d.nodes[leaf].active = id
}

// The panel out of its stack (which goes when emptied; the tab next to it is shown).
@(private)
detach :: proc(d: ^Dock, id: u32) {
	i := panel_index(d, id)
	if i < 0 { return }
	leaf := d.panels[i].node
	pos := 0
	for j in 0 ..< i { if d.panels[j].node == leaf { pos += 1 } }
	ordered_remove_soa(&d.panels, i)
	if d.nodes[leaf].active == id {
		tabs := dock_tabs(d, leaf)
		d.nodes[leaf].active = len(tabs) == 0 ? DOCK_NO_PANEL : tabs[min(pos, len(tabs) - 1)]
	}
	leaf_drop_if_empty(d, leaf)
}

// Whether a panel (or the floating root `node`, `id` = DOCK_NO_PANEL) may go to `t`.
dock_target_valid :: proc(d: ^Dock, id: u32, node: i32, t: Dock_Target) -> bool {
	switch t.place {
	case .None: return false
	case .Float: return t.rect.max.x > t.rect.min.x && t.rect.max.y > t.rect.min.y
	case .Edge_Left, .Edge_Right, .Edge_Top, .Edge_Bottom:
		return id != DOCK_NO_PANEL || dock_valid_node(d, node)
	case .Tab, .Left, .Right, .Top, .Bottom:
		if !dock_is_leaf(d, t.node) { return false }
		if id == DOCK_NO_PANEL { return dock_valid_node(d, node) && !dock_within(d, t.node, node) }
		own := dock_leaf_of(d, id)
		if t.place != .Tab && own == t.node && dock_tab_count(d, own) <= 1 { return false }   // (beside itself)
		if t.place != .Tab && dock_tab_count(d, t.node) == 0 { return false }                 // (an empty stack takes it as a tab)
		return true
	}
	return false
}

@(private)
edge_side :: proc(p: Dock_Place) -> Dock_Place {
	#partial switch p {
	case .Edge_Left:   return .Left
	case .Edge_Right:  return .Right
	case .Edge_Top:    return .Top
	case .Edge_Bottom: return .Bottom
	}
	return p
}

// A panel docked with `id` (its stack's other shown tab, else one of the sibling's): where a floated panel goes home.
@(private)
neighbour_of :: proc(d: ^Dock, id: u32) -> u32 {
	leaf := dock_leaf_of(d, id)
	if leaf == DOCK_NONE { return DOCK_NO_PANEL }
	if a := d.nodes[leaf].active; a != id && a != DOCK_NO_PANEL { return a }
	for p in dock_tabs(d, leaf) { if p != id { return p } }
	if p := d.nodes[leaf].parent; p != DOCK_NONE {
		sib := d.nodes[p].a == leaf ? d.nodes[p].b : d.nodes[p].a
		for l in dock_leaves(d, sib) { if a := d.nodes[l].active; a != DOCK_NO_PANEL { return a } }
	}
	return d.panels[panel_index(d, id)].home   // (a floating panel alone: where it came from)
}

// The panel goes to `t` (into the dock when it was not in it). Returns whether it moved.
dock_move :: proc(d: ^Dock, id: u32, t: Dock_Target) -> bool {
	dock_ready(d)
	if id == DOCK_NO_PANEL || !dock_target_valid(d, id, DOCK_NONE, t) { return false }
	own := dock_leaf_of(d, id)
	if own != DOCK_NONE && t.place == .Tab && t.node == own {
		// along its own strip
		tabs := dock_tabs(d, own)
		pos := 0
		for p, k in tabs { if p == id { pos = k } }
		to := t.index < 0 || t.index > len(tabs) ? len(tabs) : t.index
		if to > pos { to -= 1 }
		if to == pos { dock_activate(d, id); return false }
		ordered_remove_soa(&d.panels, panel_index(d, id))
		insert_tab(d, id, own, to, DOCK_NO_PANEL)
		dock_changed(d)
		return true
	}
	home := DOCK_NO_PANEL
	if own != DOCK_NONE {
		if t.place == .Float { home = neighbour_of(d, id) }
		detach(d, id)
	}
	insert_at(d, id, t, home)
	dock_changed(d)
	return true
}

// Into the dock at `t` when it is not in it yet (a panel the saved text did not name, one opened again); else nothing.
dock_add :: proc(d: ^Dock, id: u32, t: Dock_Target) -> bool {
	if dock_has(d, id) { return false }
	return dock_move(d, id, t)
}

@(private)
insert_at :: proc(d: ^Dock, id: u32, t: Dock_Target, home: u32) {
	#partial switch t.place {
	case .Tab:
		insert_tab(d, id, t.node, t.index, home)
	case .Left, .Right, .Top, .Bottom:
		insert_tab(d, id, split_around(d, t.node, t.place, DOCK_DROP_SHARE), 0, home)
	case .Edge_Left, .Edge_Right, .Edge_Top, .Edge_Bottom:
		if dock_is_leaf(d, d.main) && dock_tab_count(d, d.main) == 0 {
			insert_tab(d, id, d.main, 0, home)
		} else {
			insert_tab(d, id, split_around(d, d.main, edge_side(t.place), DOCK_EDGE_SHARE), 0, home)
		}
	case .Float:
		n := node_new(d, .Leaf)
		d.nodes[n].float = t.rect
		append(&d.floats, n)
		insert_tab(d, id, n, 0, home)
	}
}

// The panel leaves the dock (the app may add it again: dock_add).
dock_close :: proc(d: ^Dock, id: u32) -> bool {
	if !dock_has(d, id) { return false }
	detach(d, id)
	dock_changed(d)
	return true
}

// The panel floats at `rect` (logical px from the dock space's top left).
dock_float :: proc(d: ^Dock, id: u32, rect: Rect) -> bool { return dock_move(d, id, {place = .Float, rect = rect}) }

// A floating root (all its panels) goes to `t`: moved (.Float), into a stack, at a side of one, at an edge of the space.
dock_move_node :: proc(d: ^Dock, root: i32, t: Dock_Target) -> bool {
	if !dock_valid_node(d, root) || d.nodes[root].parent != DOCK_NONE || root == d.main || !dock_target_valid(d, DOCK_NO_PANEL, root, t) { return false }
	#partial switch t.place {
	case .Float:
		d.nodes[root].float = t.rect
		dock_raise(d, root)
	case .Tab:
		moving := make([dynamic]u32, 0, len(d.panels), context.temp_allocator)
		for l in dock_leaves(d, root) { append(&moving, ..dock_tabs(d, l)) }
		for id in moving {
			detach(d, id)   // (the root goes with its last panel)
			insert_tab(d, id, t.node, -1, DOCK_NO_PANEL)
		}
	case:
		for f, i in d.floats { if f == root { ordered_remove(&d.floats, i); break } }
		if t.place >= .Edge_Left && dock_is_leaf(d, d.main) && dock_tab_count(d, d.main) == 0 {
			node_free(d, d.main)
			d.main = root
			d.nodes[root].float = {}
		} else {
			around := t.place >= .Edge_Left ? d.main : t.node
			split_around(d, around, edge_side(t.place), t.place >= .Edge_Left ? DOCK_EDGE_SHARE : DOCK_DROP_SHARE, root)
		}
		for i in 0 ..< len(d.panels) { if dock_within(d, d.panels[i].node, root) { d.panels[i].home = DOCK_NO_PANEL } }
	}
	dock_changed(d)
	return true
}

// Where a floating root goes back (a double click on its title): the stack of the panel its shown one came from when that
// one is docked, else the largest stack of the main tree.
dock_home_target :: proc(d: ^Dock, root: i32) -> Dock_Target {
	for l in dock_leaves(d, root) {
		a := d.nodes[l].active
		if a == DOCK_NO_PANEL { continue }
		h := d.panels[panel_index(d, a)].home
		if hl := dock_leaf_of(d, h); hl != DOCK_NONE && dock_root_of(d, hl) == d.main { return {place = .Tab, node = hl, index = -1} }
	}
	best, area := d.main, f32(-1)
	for l in dock_leaves(d, d.main) {
		r := d.nodes[l].rect
		if a := (r.max.x - r.min.x) * (r.max.y - r.min.y); a > area { best, area = l, a }
	}
	if !dock_is_leaf(d, best) { best = dock_leaves(d, d.main)[0] }
	return {place = .Tab, node = best, index = -1}
}

// A floating root back into the main tree (dock_home_target).
dock_redock :: proc(d: ^Dock, root: i32) -> bool { return dock_move_node(d, root, dock_home_target(d, root)) }

// A split's ratio (clamped) and fold.
dock_set_split :: proc(d: ^Dock, split: i32, ratio: f32, fold: bool) {
	if !dock_valid_node(d, split) || d.nodes[split].kind != .Split { return }
	r := clamp(ratio, DOCK_RATIO_MIN, 1 - DOCK_RATIO_MIN)
	if math.is_nan(ratio) { r = DOCK_RATIO_DEFAULT }
	if r == d.nodes[split].ratio && fold == d.nodes[split].fold { return }
	d.nodes[split].ratio, d.nodes[split].fold = r, fold
	dock_changed(d)
}

////////////////////////////////
// Targets for the app's own defaults

// Into the stack of `other` (at its end), or of the main tree's first stack when `other` is not docked.
dock_with :: proc(d: ^Dock, other: u32) -> Dock_Target {
	dock_ready(d)
	if l := dock_leaf_of(d, other); l != DOCK_NONE { return {place = .Tab, node = l, index = -1} }
	return {place = .Tab, node = dock_leaves(d, d.main)[0], index = -1}
}

// At a side (.Left, .Right, .Top, .Bottom) of the stack of `other`; into the main tree's first stack when `other` is not docked.
dock_beside :: proc(d: ^Dock, other: u32, side: Dock_Place) -> Dock_Target {
	dock_ready(d)
	l := dock_leaf_of(d, other)
	if l == DOCK_NONE { return dock_with(d, other) }
	return {place = side, node = l}
}

////////////////////////////////
// Layout and drop targets (frame px from the dock space's top left)

// Every node's `rect` for a dock space of `size`: the main tree fills it, each floating root at its place (kept inside it).
dock_layout :: proc(d: ^Dock, size: Vec2, m: Dock_Metrics) {
	dock_ready(d)
	d.size, d.metrics = size, m
	for i in 0 ..< len(d.nodes) { d.nodes[i].rect = {} }
	layout_node(d, d.main, {{0, 0}, size}, m)
	for f in d.floats { layout_float(d, f, m) }
}

@(private)
layout_float :: proc(d: ^Dock, root: i32, m: Dock_Metrics) {
	r := dock_float_rect(d, root, m)
	layout_node(d, root, {r.min + m.border, r.max - m.border}, m)
}

// A floating root's place in frame px, its size at least the minimum and its rect inside the space.
dock_float_rect :: proc(d: ^Dock, root: i32, m: Dock_Metrics) -> Rect {
	f := d.nodes[root].float
	sc := m.scale > 0 ? m.scale : 1
	lo := DOCK_FLOAT_MIN_EM * m.em
	sz := Vec2{max((f.max.x - f.min.x) * sc, lo.x), max((f.max.y - f.min.y) * sc, lo.y)}
	sz = {min(sz.x, max(d.size.x, lo.x)), min(sz.y, max(d.size.y, lo.y))}
	p := Vec2{clamp(f.min.x * sc, 0, max(d.size.x - sz.x, 0)), clamp(f.min.y * sc, 0, max(d.size.y - sz.y, 0))}
	return {{math.round(p.x), math.round(p.y)}, {math.round(p.x + sz.x), math.round(p.y + sz.y)}}
}

@(private)
layout_node :: proc(d: ^Dock, n: i32, r: Rect, m: Dock_Metrics) {
	if !dock_valid_node(d, n) { return }
	d.nodes[n].rect = r
	if d.nodes[n].kind != .Split { return }
	ax := int(d.nodes[n].axis)
	length := r.max[ax] - r.min[ax]
	ra, rb := r, r
	if d.nodes[n].fold {
		ra.max[ax] = r.max[ax] - min(m.folded, length)
		rb.min[ax] = r.max[ax]
	} else {
		room := max(length - m.handle, 0)
		keep := min(m.min, room * 0.5)
		la := clamp(math.round(room * d.nodes[n].ratio), keep, room - keep)
		ra.max[ax] = r.min[ax] + la
		rb.min[ax] = ra.max[ax] + min(m.handle, length)
	}
	layout_node(d, d.nodes[n].a, ra, m)
	layout_node(d, d.nodes[n].b, rb, m)
}

// The handle of a split: between its nodes (folded: the strip at the end).
dock_handle_rect :: proc(d: ^Dock, split: i32) -> Rect {
	n := d.nodes[split]
	ax := int(n.axis)
	h := n.rect
	h.min[ax] = d.nodes[n.a].rect.max[ax]
	if !n.fold { h.max[ax] = d.nodes[n.b].rect.min[ax] }
	return h
}

// A stack's strip of tabs, and what is under it.
dock_strip_rect :: proc(d: ^Dock, leaf: i32) -> Rect {
	r := d.nodes[leaf].rect
	r.max.y = min(r.min.y + d.metrics.strip, r.max.y)
	return r
}

dock_body_rect :: proc(d: ^Dock, leaf: i32) -> Rect {
	r := d.nodes[leaf].rect
	r.min.y = min(r.min.y + d.metrics.strip, r.max.y)
	return r
}

// The size of the panel's room this frame (frame px; 0: not shown).
dock_panel_size :: proc(d: ^Dock, id: u32) -> Vec2 {
	if !dock_shown(d, id) { return {} }
	r := dock_body_rect(d, dock_leaf_of(d, id))
	return r.max - r.min
}

Dock_Marker :: enum u8 { Center, Left, Right, Top, Bottom }

// The five squares over a stack (join it, split it at a side).
dock_markers :: proc(r: Rect, m: Dock_Metrics) -> [Dock_Marker]Rect {
	c := (r.min + r.max) * 0.5
	h := m.marker * 0.5
	step := m.marker + m.gap
	sq :: proc(c: Vec2, h: f32) -> Rect { return {c - h, c + h} }
	return {
		.Center = sq(c, h),
		.Left   = sq(c - {step, 0}, h),
		.Right  = sq(c + {step, 0}, h),
		.Top    = sq(c - {0, step}, h),
		.Bottom = sq(c + {0, step}, h),
	}
}

// The four squares at the edges of the dock space (the top one under the strips: they keep their tabs as targets).
dock_edge_markers :: proc(size: Vec2, m: Dock_Metrics) -> [Dock_Marker]Rect {
	c := size * 0.5
	h := m.marker * 0.5
	e := m.gap + h
	sq :: proc(c: Vec2, h: f32) -> Rect { return {c - h, c + h} }
	return {.Center = {}, .Left = sq({e, c.y}, h), .Right = sq({size.x - e, c.y}, h), .Top = sq({c.x, m.strip + e}, h), .Bottom = sq({c.x, size.y - e}, h)}
}

// The place a square of a stack stands for, and one of the edges of the space.
@(private)
marker_side :: proc(k: Dock_Marker) -> Dock_Place {
	switch k {
	case .Center: return .Tab
	case .Left:   return .Left
	case .Right:  return .Right
	case .Top:    return .Top
	case .Bottom: return .Bottom
	}
	return .None
}
@(private)
marker_edge :: proc(k: Dock_Marker) -> Dock_Place {
	switch k {
	case .Center: return .None
	case .Left:   return .Edge_Left
	case .Right:  return .Edge_Right
	case .Top:    return .Edge_Top
	case .Bottom: return .Edge_Bottom
	}
	return .None
}

// The leaf under `pos`: the topmost floating panel's, else the main tree's (DOCK_NONE: none). `skip`: a floating root that
// is not looked at (the one being moved).
dock_leaf_at :: proc(d: ^Dock, pos: Vec2, skip: i32 = DOCK_NONE) -> i32 {
	inside :: proc(r: Rect, p: Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }
	for k := len(d.floats) - 1; k >= 0; k -= 1 {
		f := d.floats[k]
		if f == skip || !inside(d.nodes[f].rect, pos) { continue }
		for l in dock_leaves(d, f) { if inside(d.nodes[l].rect, pos) { return l } }
		return DOCK_NONE
	}
	for l in dock_leaves(d, d.main) { if dock_node_visible(d, l) && inside(d.nodes[l].rect, pos) { return l } }
	return DOCK_NONE
}

// Where what is dragged (the panel `id`, or the floating root `node` when id = DOCK_NO_PANEL) would go if dropped at `pos`:
// a square of the stack under the pointer or of the space's edges, that stack's strip (a tab), else floating there (`grab`:
// the pointer from its top left). Also the stack under the pointer (its squares show).
dock_target_at :: proc(d: ^Dock, pos: Vec2, id: u32, node: i32, grab: Vec2) -> (t: Dock_Target, under: i32) {
	inside :: proc(r: Rect, p: Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }
	m := d.metrics
	moving := id == DOCK_NO_PANEL ? node : DOCK_NONE
	under = dock_leaf_at(d, pos, moving)
	main_empty := dock_is_leaf(d, d.main) && dock_tab_count(d, d.main) == 0
	pick :: proc(d: ^Dock, id: u32, node: i32, t: Dock_Target) -> (Dock_Target, bool) { return t, dock_target_valid(d, id, node, t) }
	// the edges of the space (not over a floating panel)
	if !main_empty && (under == DOCK_NONE || !dock_is_floating(d, under)) {
		for r, k in dock_edge_markers(d.size, m) {
			if k == .Center || !inside(r, pos) { continue }
			if c, ok := pick(d, id, node, {place = marker_edge(k)}); ok { return c, under }
		}
	}
	if under != DOCK_NONE {
		if inside(dock_strip_rect(d, under), pos) {
			if c, ok := pick(d, id, node, {place = .Tab, node = under, index = -1}); ok { return c, under }
		}
		for r, k in dock_markers(d.nodes[under].rect, m) {
			if !inside(r, pos) { continue }
			if c, ok := pick(d, id, node, {place = marker_side(k), node = under, index = -1}); ok { return c, under }
		}
	}
	// floating where it is let go, as large as what it was
	sc := m.scale > 0 ? m.scale : 1
	sz := DOCK_FLOAT_DEFAULT_EM * m.em
	if id == DOCK_NO_PANEL {
		if dock_valid_node(d, node) { r := d.nodes[node].rect; sz = r.max - r.min }
	} else if l := dock_leaf_of(d, id); l != DOCK_NONE {
		r := d.nodes[l].rect
		if r.max.x > r.min.x { sz = {min(r.max.x - r.min.x, sz.x), min(r.max.y - r.min.y, sz.y)} }
	}
	tl := pos - grab
	t = {place = .Float, rect = {tl / sc, (tl + sz) / sc}}
	return
}

// Where the dragged thing would land (frame px from the space's top left): the translucent preview.
dock_preview_rect :: proc(d: ^Dock, t: Dock_Target) -> Rect {
	sc := d.metrics.scale > 0 ? d.metrics.scale : 1
	half :: proc(r: Rect, side: Dock_Place, share: f32) -> Rect {
		o := r
		w, h := (r.max.x - r.min.x) * share, (r.max.y - r.min.y) * share
		#partial switch side {
		case .Left:   o.max.x = r.min.x + w
		case .Right:  o.min.x = r.max.x - w
		case .Top:    o.max.y = r.min.y + h
		case .Bottom: o.min.y = r.max.y - h
		}
		return o
	}
	switch t.place {
	case .None:  return {}
	case .Tab:   return dock_is_leaf(d, t.node) ? d.nodes[t.node].rect : {}
	case .Left, .Right, .Top, .Bottom:
		return dock_is_leaf(d, t.node) ? half(d.nodes[t.node].rect, t.place, DOCK_DROP_SHARE) : {}
	case .Edge_Left, .Edge_Right, .Edge_Top, .Edge_Bottom:
		return half({{0, 0}, d.size}, edge_side(t.place), DOCK_EDGE_SHARE)
	case .Float: return {t.rect.min * sc, t.rect.max * sc}
	}
	return {}
}

// A place for a panel floated from the keyboard: the default size, each one a step from the last.
dock_float_place :: proc(d: ^Dock) -> Rect {
	m := d.metrics
	sc := m.scale > 0 ? m.scale : 1
	em := m.em / sc
	at := Vec2{1, 1} * em * DOCK_FLOAT_STEP_EM * f32(len(d.floats) + 1)
	return {at, at + DOCK_FLOAT_DEFAULT_EM * em}
}

////////////////////////////////
// The text

// The layout as one line (temp allocator unless told otherwise). `name`: a panel's name in the text (one with a refused
// character, DOCK_NAME_CHARS_REFUSED, or none is left out).
dock_format :: proc(d: ^Dock, name: proc(user: rawptr, id: u32) -> string, user: rawptr, allocator := context.temp_allocator) -> string {
	dock_ready(d)
	b := strings.builder_make(allocator)
	strings.write_string(&b, DOCK_FORMAT_TAG)
	strings.write_byte(&b, ' ')
	format_node(d, &b, d.main, name, user)
	for f in d.floats {
		r := d.nodes[f].float
		fmt.sbprintf(&b, " @%d,%d,%d,%d ", int(r.min.x), int(r.min.y), int(r.max.x - r.min.x), int(r.max.y - r.min.y))
		format_node(d, &b, f, name, user)
	}
	return strings.to_string(b)
}

@(private)
format_node :: proc(d: ^Dock, b: ^strings.Builder, n: i32, name: proc(user: rawptr, id: u32) -> string, user: rawptr) {
	nd := d.nodes[n]
	if nd.kind == .Split {
		fmt.sbprintf(b, "%c%.3f", nd.axis == .X ? 'x' : 'y', nd.ratio)
		if nd.fold { strings.write_byte(b, 'f') }
		strings.write_byte(b, '(')
		format_node(d, b, nd.a, name, user)
		strings.write_byte(b, ' ')
		format_node(d, b, nd.b, name, user)
		strings.write_byte(b, ')')
		return
	}
	strings.write_byte(b, '[')
	first := true
	for i in 0 ..< len(d.panels) {
		if d.panels[i].node != n { continue }
		s := name(user, d.panels[i].id)
		if s == "" || strings.contains_any(s, DOCK_NAME_CHARS_REFUSED) { continue }
		if !first { strings.write_byte(b, ',') }
		first = false
		if d.panels[i].id == nd.active { strings.write_byte(b, '*') }
		strings.write_string(b, s)
	}
	strings.write_byte(b, ']')
}

@(private)
Dock_Parser :: struct {
	s:     string,
	i:     int,
	id_of: proc(user: rawptr, name: string) -> (u32, bool),
	user:  rawptr,
}

// The layout `dock_format` wrote. `id_of`: the panel of a name (false: none now; it is dropped). Returns false, and leaves
// the dock as it was, when the text is not one.
dock_parse :: proc(d: ^Dock, text: string, id_of: proc(user: rawptr, name: string) -> (u32, bool), user: rawptr) -> bool {
	tmp: Dock
	p := Dock_Parser{s = strings.trim_space(text), id_of = id_of, user = user}
	ok := parse_all(&tmp, &p)
	if !ok { dock_destroy(&tmp); return false }
	serial := d.serial
	dock_destroy(d)
	d^ = tmp
	d.serial = serial + 1
	return true
}

@(private)
parse_all :: proc(d: ^Dock, p: ^Dock_Parser) -> bool {
	if !strings.has_prefix(p.s, DOCK_FORMAT_TAG) { return false }
	p.i = len(DOCK_FORMAT_TAG)
	if !parse_space(p) { return false }
	main, ok := parse_node(d, p, 0)
	if !ok { return false }
	d.main = main
	for {
		had := parse_space(p)
		if p.i >= len(p.s) { break }
		if !had || p.s[p.i] != '@' { return false }
		p.i += 1
		v: [4]f32
		for k in 0 ..< 4 {
			if k > 0 { if p.i >= len(p.s) || p.s[p.i] != ',' { return false }; p.i += 1 }
			n, ok2 := parse_number(p)
			if !ok2 { return false }
			v[k] = n
		}
		if v[2] <= 0 || v[3] <= 0 || !parse_space(p) { return false }
		f, ok3 := parse_node(d, p, 0)
		if !ok3 { return false }
		d.nodes[f].float = {{v[0], v[1]}, {v[0] + v[2], v[1] + v[3]}}
		append(&d.floats, f)
	}
	// stacks left empty by the names dropped go; a floating root with nothing in it too
	for changed := true; changed; {
		changed = false
		for i in 0 ..< len(d.nodes) {
			if d.nodes[i].kind != .Leaf || dock_tab_count(d, i32(i)) > 0 || i32(i) == d.main { continue }
			leaf_drop_if_empty(d, i32(i))
			changed = true
		}
	}
	for i in 0 ..< len(d.nodes) {
		if d.nodes[i].kind != .Leaf { continue }
		tabs := dock_tabs(d, i32(i))
		on := false
		for t in tabs { if t == d.nodes[i].active { on = true } }
		if !on { d.nodes[i].active = len(tabs) > 0 ? tabs[0] : DOCK_NO_PANEL }
	}
	return true
}

// One blank at least (false: none).
@(private)
parse_space :: proc(p: ^Dock_Parser) -> bool {
	start := p.i
	for p.i < len(p.s) && (p.s[p.i] == ' ' || p.s[p.i] == '\t') { p.i += 1 }
	return p.i > start || p.i >= len(p.s)
}

@(private)
parse_number :: proc(p: ^Dock_Parser) -> (f32, bool) {
	start := p.i
	for p.i < len(p.s) && (p.s[p.i] >= '0' && p.s[p.i] <= '9' || p.s[p.i] == '.' || p.s[p.i] == '-') { p.i += 1 }
	v, ok := strconv.parse_f32(p.s[start:p.i])
	if !ok || math.is_nan(v) || math.is_inf(v) { return 0, false }
	return v, true
}

@(private)
parse_node :: proc(d: ^Dock, p: ^Dock_Parser, depth: int) -> (n: i32, ok: bool) {
	if depth > DOCK_DEPTH_MAX || p.i >= len(p.s) { return DOCK_NONE, false }
	switch p.s[p.i] {
	case '[':
		p.i += 1
		n = node_new(d, .Leaf)
		for p.i < len(p.s) && p.s[p.i] != ']' {
			active := false
			if p.s[p.i] == '*' { active = true; p.i += 1 }
			start := p.i
			for p.i < len(p.s) && !strings.contains_rune(DOCK_NAME_CHARS_REFUSED, rune(p.s[p.i])) { p.i += 1 }
			name := p.s[start:p.i]
			if name == "" { return DOCK_NONE, false }
			if id, known := p.id_of(p.user, name); known && !dock_has(d, id) {
				append_soa(&d.panels, Dock_Panel{id = id, node = n, home = DOCK_NO_PANEL})
				if active || d.nodes[n].active == DOCK_NO_PANEL { d.nodes[n].active = id }
			}
			if p.i < len(p.s) && p.s[p.i] == ',' {
				p.i += 1
				if p.i >= len(p.s) || p.s[p.i] == ']' { return DOCK_NONE, false }   // (a name must follow)
				continue
			}
			if p.i >= len(p.s) || p.s[p.i] != ']' { return DOCK_NONE, false }
		}
		if p.i >= len(p.s) { return DOCK_NONE, false }
		p.i += 1
		return n, true
	case 'x', 'y':
		axis: Axis = p.s[p.i] == 'x' ? .X : .Y
		p.i += 1
		ratio, ok2 := parse_number(p)
		if !ok2 || ratio <= 0 || ratio >= 1 { return DOCK_NONE, false }
		fold := false
		if p.i < len(p.s) && p.s[p.i] == 'f' { fold = true; p.i += 1 }
		if p.i >= len(p.s) || p.s[p.i] != '(' { return DOCK_NONE, false }
		p.i += 1
		a, ok3 := parse_node(d, p, depth + 1)
		if !ok3 || p.i >= len(p.s) || p.s[p.i] != ' ' { return DOCK_NONE, false }
		p.i += 1
		b, ok4 := parse_node(d, p, depth + 1)
		if !ok4 || p.i >= len(p.s) || p.s[p.i] != ')' { return DOCK_NONE, false }
		p.i += 1
		n = node_new(d, .Split)
		d.nodes[n].axis, d.nodes[n].ratio, d.nodes[n].fold = axis, clamp(ratio, DOCK_RATIO_MIN, 1 - DOCK_RATIO_MIN), fold
		d.nodes[n].a, d.nodes[n].b = a, b
		d.nodes[a].parent, d.nodes[b].parent = n, n
		return n, true
	}
	return DOCK_NONE, false
}
