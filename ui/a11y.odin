package ui

import "core:strings"
import "core:time"
import "../font"
import "../platform"

// Accessibility: the tree screen readers read, made from the boxes of each build (see docs/accessibility.md).
//
// Not every box is a node: a box is one when it has a role (given by its widget, or by the app with `a11y`), or when
// it shows text (a static text, role Label). Layout boxes are not: their nodes go to the nearest node above them. A
// node's id is its box's Key (stable across frames), its bounds its rect, its parent the nearest node above it. The
// widgets of the toolkit give their role, name and states (button, check box, radio, toggle, slider, stepper, fields,
// lists, menus, tabs, splitter, accordion, progress, dropdown, tooltip, toasts...); the app names what the toolkit
// cannot know (an icon button's purpose) and describes its own boxes:
//
//   ui.a11y({role = .Button, name = tr("Back")})   // applies to the next box built
//   if ui.icon_button("back", ICON_BACK).clicked { ... }
//
// The tree is only built when an assistive technology reads the window (platform.a11y_state), or when a test asks for
// it (a11y_capture); then only the nodes that changed go to the adapter (platform.A11y_Diff). Requests of assistive
// technologies (click, focus, set a value, increment, scroll) come back as the same signals as the mouse and keyboard
// give (a click is `clicked`); those the toolkit cannot answer itself wait in a11y_requests for the app.

A11y_Role :: platform.A11y_Role

// What a box is to assistive technologies. Zero fields say nothing (the widget's own value, if any, stands).
A11y_Info :: struct {
	role:             A11y_Role,             // .Unknown: the widget's (or none: a box that is no node)
	name:             string,                // what it is called ("Back", "Search"): for a static text, its text
	description:      string,                // more about it (a tooltip's text, a hint)
	value:            string,                // a field's text, a slider's value as read ("50 %")
	placeholder:      string,
	shortcut:         string,                // "Ctrl+L"
	role_description: string,                // replaces the role's name ("tab strip")
	toggled:          Maybe(platform.A11y_Toggled),   // check boxes, switches, toggle buttons
	selected:         Maybe(bool),           // tabs, list rows
	expanded:         Maybe(bool),           // menus, accordions, tree rows
	read_only, required, multiselectable, modal, hidden, busy: bool,
	numeric:          Maybe(f64),            // sliders, steppers, progress
	min, max, step:   Maybe(f64),
	level:            int,                   // headings, tree rows (1-based; 0: none)
	position, set_size: int,                 // "3 of 7" (1-based; 0: none)
	orientation:      Maybe(Axis),
	live:             platform.A11y_Live,    // changes are announced (toasts, status)
	popup:            Maybe(platform.A11y_Popup),
	current:          platform.A11y_Current,
	actions:          platform.A11y_Actions, // beyond those of the box's flags (Clickable: Click, Focusable: Focus)
	labelled_by, described_by, controls: Key,
	active_descendant: Key,                  // the item a focused container is on (a list's selected row): read as the focus
	graft:            Maybe(platform.A11y_Tree_Id),   // a tree of the app's own under this node (a document view)
	text:             ^A11y_Text,            // an editable text with its caret (text runs: reading by character, word, line)
	parts:            []A11y_Part,           // nodes of its own that are no boxes (the links of a rich paragraph), after its boxes' nodes
	ignore:           bool,                  // not a node, whatever it shows (decoration): its nodes go to its parent
	no_children:      Maybe(bool),           // its boxes are not exposed (default: by role, e.g. a button's label)
	write:            proc(u: ^platform.A11y_Update, b: ^Box, user: rawptr),   // more properties for the node
	write_user:       rawptr,
}

// A node that is part of a box without being a box (a link inside a paragraph): a leaf. A request for it comes to
// a11y_request with its id as the key.
A11y_Part :: struct {
	id:      u64,
	role:    A11y_Role,
	name:    string,
	url:     string,
	bounds:  Rect,
	actions: platform.A11y_Actions,
	focused: bool,                     // the focus is on it (the box's focus goes to it)
}

// The id of part `i` of box `b` (stable while the box and the part's place are).
a11y_part_id :: proc(b: ^Box, i: int) -> u64 { return u64(key_from_u64(b.key, 0xa11f_0000 + u64(i))) }

// The text of an editable box, for reading by character, word and line (text runs, one per visual line).
A11y_Text :: struct {
	text:         string,
	cursor, mark: int,         // byte indexes of the caret and of the selection's other end
	lines:        [][2]int,    // byte ranges of the visual lines (nil: one line)
	origin:       Vec2,        // window pixels of the first line's start (at its top)
	line_height:  f32,
	scroll:       Vec2,        // subtracted from the positions (a field scrolled to keep its caret visible)
	font:         font.Font_Id,
	size:         f32,
	password:     bool,
}

// Per state: what the accessibility layer keeps.
@(private)
A11y_Data :: struct {
	next:      A11y_Info,
	has_next:  bool,
	capture:   bool,                       // a test asked for the tree (no adapter needed)
	state:     platform.A11y_State,        // what the adapter needs, asked at the start of the build
	wanted:    bool,                       // the tree is built at the end of this build
	built:     bool,                       // the tree was built by the last build
	full:      platform.A11y_Update,       // the whole tree of the last build
	diff:      platform.A11y_Diff,
	sent_focus: u64,
	requests:  [dynamic]platform.A11y_Request,   // this build's requests the toolkit did not answer (for the app)
	handled:   [dynamic]platform.A11y_Request,   // this build's requests for widgets (a11y_request)
	injected:  [dynamic]platform.A11y_Request,   // a11y_inject: taken by the next build
	values:    [dynamic]string,            // values of the requests (copies, freed at the next build)
	updates, refused: int,
	kids:      [dynamic]u64,               // scratch
	focus_to:  Key,                        // a11y_focus_on: this build's focus for readers, over the toolkit's
	diff_window: ^platform.Window,         // the window the diff's nodes went to (another one: a whole tree)
	cost_ms:   f64,                        // the last build's tree: making it, the diff and the send
}

// This build, screen readers are on box `key` whatever has the toolkit's focus: a view of the app's own that has the
// keyboard (a web page under the chrome) and grafts a tree whose own focus then counts.
a11y_focus_on :: proc(key: Key) { g.a11y.focus_to = key }

// Gives the next box built its accessibility (merged over the widget's defaults: what is set here wins).
a11y :: proc(info: A11y_Info) {
	g.a11y.next = info
	g.a11y.has_next = true
}

// Gives a built box its accessibility (over what it had: the fields set here win).
a11y_set :: proc(b: ^Box, info: A11y_Info) {
	if b == nil { return }
	if b.a11y == nil { b.a11y = new_clone(info, frame_allocator()); return }
	a11y_merge(b.a11y, info)
}

// The default a widget gives its box: only the fields the app did not set.
a11y_default :: proc(b: ^Box, info: A11y_Info) {
	if b == nil { return }
	if b.a11y == nil { b.a11y = new_clone(info, frame_allocator()); return }
	app := b.a11y^
	b.a11y^ = info
	a11y_merge(b.a11y, app)
}

@(private)
a11y_merge :: proc(dst: ^A11y_Info, src: A11y_Info) {
	if src.role != .Unknown { dst.role = src.role }
	if src.name != "" { dst.name = src.name }
	if src.description != "" { dst.description = src.description }
	if src.value != "" { dst.value = src.value }
	if src.placeholder != "" { dst.placeholder = src.placeholder }
	if src.shortcut != "" { dst.shortcut = src.shortcut }
	if src.role_description != "" { dst.role_description = src.role_description }
	if src.toggled != nil { dst.toggled = src.toggled }
	if src.selected != nil { dst.selected = src.selected }
	if src.expanded != nil { dst.expanded = src.expanded }
	dst.read_only ||= src.read_only
	dst.required ||= src.required
	dst.multiselectable ||= src.multiselectable
	dst.modal ||= src.modal
	dst.hidden ||= src.hidden
	dst.busy ||= src.busy
	if src.numeric != nil { dst.numeric = src.numeric }
	if src.min != nil { dst.min = src.min }
	if src.max != nil { dst.max = src.max }
	if src.step != nil { dst.step = src.step }
	if src.level != 0 { dst.level = src.level }
	if src.position != 0 { dst.position = src.position }
	if src.set_size != 0 { dst.set_size = src.set_size }
	if src.orientation != nil { dst.orientation = src.orientation }
	if src.live != .Off { dst.live = src.live }
	if src.popup != nil { dst.popup = src.popup }
	if src.current != .False { dst.current = src.current }
	dst.actions += src.actions
	if src.labelled_by != 0 { dst.labelled_by = src.labelled_by }
	if src.described_by != 0 { dst.described_by = src.described_by }
	if src.controls != 0 { dst.controls = src.controls }
	if src.active_descendant != 0 { dst.active_descendant = src.active_descendant }
	if src.graft != nil { dst.graft = src.graft }
	if src.text != nil { dst.text = src.text }
	if src.parts != nil { dst.parts = src.parts }
	dst.ignore ||= src.ignore
	if src.no_children != nil { dst.no_children = src.no_children }
	if src.write != nil { dst.write, dst.write_user = src.write, src.write_user }
}

// Builds the tree every frame without an adapter (tests: a11y_tree reads it).
a11y_capture :: proc(s: ^State, on: bool) { s.a11y.capture = on }

// Whether the last build made the tree (an assistive technology reads the window, or a test captures it).
a11y_active :: proc(s: ^State) -> bool { return s.a11y.built }

// During a build: whether this build makes the tree. An app with content of its own to describe (a document, the text
// of a custom editor) does that work only then.
a11y_wanted :: proc() -> bool { return g.a11y.wanted }

// The whole tree of the last build (empty when it was not built). Valid until the next build.
a11y_tree :: proc(s: ^State) -> ^platform.A11y_Update { return &s.a11y.full }

// The index of node `key` in a11y_tree (-1: not a node).
a11y_find :: proc(s: ^State, key: Key) -> int {
	for n, i in s.a11y.full.nodes { if n.id == u64(key) { return i } }
	return -1
}

// Updates sent to the adapter, refused by it, and the nodes the last one carried (tests, statistics).
a11y_stats :: proc(s: ^State) -> (updates, refused, last_nodes: int) { return s.a11y.updates, s.a11y.refused, s.a11y.diff.nodes_sent }

// What the tree cost the last build that made it: its nodes, and the milliseconds spent making it, comparing it with
// what the adapter has and sending the difference (0 when the build made no tree).
a11y_cost :: proc(s: ^State) -> (nodes: int, ms: f64) { return len(s.a11y.full.nodes), s.a11y.cost_ms }

// The requests of this build the toolkit did not answer itself: those for the trees of the app (a document view), and
// actions on its boxes no widget took. Valid until the next build.
a11y_requests :: proc() -> []platform.A11y_Request { return g.a11y.requests[:] }

// A request of this build for box `key` (a widget or the app answers it: set the value, increment, select text...).
a11y_request :: proc(key: Key, action: platform.A11y_Action) -> (platform.A11y_Request, bool) {
	for r in g.a11y.handled { if r.target == u64(key) && r.action == action { return r, true } }
	return {}, false
}

// Queues a request as if an assistive technology had made it (tests, remote control): the next build takes it.
a11y_inject :: proc(s: ^State, r: platform.A11y_Request) {
	r := r
	r.value = strings.clone(r.value)
	append(&s.a11y.injected, r)
}

@(private)
a11y_destroy :: proc(s: ^State) {
	platform.a11y_update_destroy(&s.a11y.full)
	platform.a11y_diff_destroy(&s.a11y.diff)
	delete(s.a11y.requests)
	delete(s.a11y.handled)
	for r in s.a11y.injected { delete(r.value) }
	delete(s.a11y.injected)
	for v in s.a11y.values { delete(v) }
	delete(s.a11y.values)
	delete(s.a11y.kids)
}

////////////////////////////////
// Requests (begin_build)

@(private)
a11y_begin_build :: proc(s: ^State, w: ^platform.Window) {
	s.a11y.state = platform.a11y_state(w) if w != nil else .Off
	s.a11y.wanted = s.a11y.state != .Off || s.a11y.capture
	s.a11y.focus_to = 0
	clear(&s.a11y.requests)
	clear(&s.a11y.handled)
	for v in s.a11y.values { delete(v) }
	clear(&s.a11y.values)
	s.a11y.has_next = false
	for w != nil {
		r, ok := platform.a11y_take_request(w)
		if !ok { break }
		r.value = strings.clone(r.value)
		append(&s.a11y.values, r.value)
		a11y_route(s, r)
	}
	for r in s.a11y.injected {
		append(&s.a11y.values, r.value)
		a11y_route(s, r)
	}
	clear(&s.a11y.injected)
}

// Answers what the toolkit can (clicks, focus, scrolling); hands the rest to the widgets (a11y_request) and the app.
@(private)
a11y_route :: proc(s: ^State, r: platform.A11y_Request) {
	if r.tree != {} { append(&s.a11y.requests, r); return }   // a tree of the app's own
	key := Key(r.target)
	b := s.boxes[key] if key != 0 else nil
	if b == nil || b.last_build + 1 < s.build_index {
		// a part of a box (a link in a paragraph: its widget asks with a11y_request), or something of the app's
		append(&s.a11y.handled, r)
		append(&s.a11y.requests, r)
		return
	}
	#partial switch r.action {
	case .Click, .Expand, .Collapse:
		if r.action != .Click {
			// already as asked (the last tree says): nothing to toggle
			if i := a11y_find(s, key); i >= 0 {
				f := s.a11y.full.nodes[i].flags
				if .Has_Expanded in f && (.Expanded in f) == (r.action == .Expand) { return }
			}
		}
		if .Clickable in b.flags && .Disabled not_in b.flags {
			s.pressed_key[.Left], s.released_key[.Left], s.clicked_key[.Left] = key, key, key
			if .Focusable in b.flags { s.focus_key = key }
			// a widget that answers the action itself (an accordion) sees it too
			append(&s.a11y.handled, r)
			return
		}
	case .Show_Context_Menu:
		if .Clickable in b.flags { s.clicked_key[.Right] = key; return }
	case .Focus:
		if .Focusable in b.flags && .Disabled not_in b.flags {
			s.focus_key = key
			s.focus_visible = true
			scroll_focus_into_view(s)
			return
		}
	case .Blur:
		if s.focus_key == key { s.focus_key = 0 }
		return
	case .Scroll_Into_View:
		scroll_into_view(b)
		return
	case .Scroll_Up, .Scroll_Down, .Scroll_Left, .Scroll_Right:
		if .View_Scroll_X in b.flags || .View_Scroll_Y in b.flags {
			page := r.data == .Scroll_Unit && r.num == 1
			sy := page ? b.size.y * 0.9 : b.font_size * 3
			sx := page ? b.size.x * 0.9 : b.font_size * 3
			#partial switch r.action {
			case .Scroll_Up:    b.view_target.y -= sy
			case .Scroll_Down:  b.view_target.y += sy
			case .Scroll_Left:  b.view_target.x -= sx
			case .Scroll_Right: b.view_target.x += sx
			}
			return
		}
	case .Set_Scroll_Offset:
		if .View_Scroll_X in b.flags || .View_Scroll_Y in b.flags {
			b.view_target = {f32(r.point.x), f32(r.point.y)}
			return
		}
	}
	// set a value, increment, select text...: the widget that built the box answers (a11y_request), else the app
	append(&s.a11y.handled, r)
	append(&s.a11y.requests, r)
}

@(private)
scroll_into_view :: proc(b: ^Box) {
	for p := b.parent; p != nil; p = p.parent {
		if .View_Scroll_Y in p.flags {
			if b.rect.min.y < p.rect.min.y { p.view_target.y -= p.rect.min.y - b.rect.min.y }
			if b.rect.max.y > p.rect.max.y { p.view_target.y += b.rect.max.y - p.rect.max.y }
		}
		if .View_Scroll_X in p.flags {
			if b.rect.min.x < p.rect.min.x { p.view_target.x -= p.rect.min.x - b.rect.min.x }
			if b.rect.max.x > p.rect.max.x { p.view_target.x += b.rect.max.x - p.rect.max.x }
		}
	}
}

////////////////////////////////
// The tree (end_build)

@(private)
a11y_end_build :: proc(s: ^State) {
	s.a11y.built = false
	state := s.a11y.state
	if !s.a11y.wanted { s.a11y.cost_ms = 0; return }
	start := time.tick_now()
	defer s.a11y.cost_ms = time.duration_milliseconds(time.tick_since(start))
	u := &s.a11y.full
	platform.a11y_update_clear(u)
	focus := a11y_focus_box(s)
	focus_node: u64
	a11y_walk(s, u, s.root, focus, &focus_node, true)
	u.root = u64(s.root.key)
	u.focus = focus_node != 0 ? focus_node : u.root
	u.tree_info = true
	s.a11y.built = true
	if state == .Off { return }
	if s.window != s.a11y.diff_window {
		// (one State built for another window: what the diff knows is the other adapter's)
		platform.a11y_diff_reset(&s.a11y.diff)
		s.a11y.diff_window, s.a11y.sent_focus = s.window, 0
	}
	out := platform.a11y_diff(&s.a11y.diff, u, state == .Full)
	if len(out.nodes) == 0 && out.focus == s.a11y.sent_focus { return }
	switch platform.a11y_send(s.window, out, "gui_toolkit", VERSION) {
	case .Applied:
		s.a11y.updates += 1
		s.a11y.sent_focus = out.focus
	case .Invalid:
		s.a11y.refused += 1
		platform.a11y_diff_reset(&s.a11y.diff)   // the next build sends the whole tree
	case .Inactive, .Failed:
		platform.a11y_diff_reset(&s.a11y.diff)
	}
}

// The box screen readers should be on: the selected item of an open menu, else the focused box.
@(private)
a11y_focus_box :: proc(s: ^State) -> Key {
	if n := len(s.menus); n > 0 {
		lv := &s.menus[n - 1]
		if lv.sel >= 0 && lv.sel < len(lv.items) && lv.items[lv.sel].key != 0 { return lv.items[lv.sel].key }
		if lv.panel != 0 { return lv.panel }
	}
	if k := s.a11y.focus_to; k != 0 {
		if b := s.boxes[k]; b != nil && b.last_build == s.build_index { return k }
	}
	// a focused container on an item of its own (a list on its selected row): the item
	if b := s.boxes[s.focus_key] if s.focus_key != 0 else nil; b != nil && b.last_build == s.build_index && b.a11y != nil {
		if d := s.boxes[b.a11y.active_descendant] if b.a11y.active_descendant != 0 else nil; d != nil && d.last_build == s.build_index {
			return d.key
		}
	}
	return s.focus_key
}

// Roles whose boxes inside are not exposed (their text is their name).
@(private)
a11y_leaf_role :: proc(r: A11y_Role) -> bool {
	#partial switch r {
	case .Button, .Default_Button, .Check_Box, .Radio_Button, .Switch, .Menu_Item, .Menu_Item_Check_Box, .Menu_Item_Radio,
	     .Tab, .Slider, .Scroll_Bar, .Progress_Indicator, .Meter, .Image, .Splitter, .Spin_Button, .List_Box_Option,
	     .Text_Input, .Multiline_Text_Input, .Search_Input, .Password_Input, .Email_Input, .Number_Input, .Url_Input,
	     .Label, .Link, .Heading, .Combo_Box, .Color_Well, .Tree_Item, .Menu_List_Option, .Disclosure_Triangle:
		return true
	}
	return false
}

// The text box `b` shows that a screen reader reads ("" for none, or for a glyph of the icon font).
a11y_box_text :: proc(b: ^Box) -> string { return a11y_text_shown(g, b) }

@(private)
a11y_text_shown :: proc(s: ^State, b: ^Box) -> string {
	if b.text == "" || .Draw_Text not_in b.flags { return "" }
	if s.icon_font != 0 && b.font == s.icon_font { return "" }   // a glyph: decoration
	return b.text
}

// The text of a box's subtree (the name of a leaf node that has none: a button made of a label and an icon).
@(private)
a11y_subtree_text :: proc(s: ^State, b: ^Box, sb: ^strings.Builder) {
	if b.a11y != nil && b.a11y.ignore { return }
	if b.a11y != nil && b.a11y.name != "" {
		if strings.builder_len(sb^) > 0 { strings.write_byte(sb, ' ') }
		strings.write_string(sb, b.a11y.name)
		return
	}
	if t := a11y_text_shown(s, b); t != "" {
		if strings.builder_len(sb^) > 0 { strings.write_byte(sb, ' ') }
		strings.write_string(sb, t)
	}
	for c := b.first; c != nil; c = c.next { a11y_subtree_text(s, c, sb) }
}

// Writes the nodes of `b`'s subtree (children first); appends the ids of the nodes directly under it to s.a11y.kids.
@(private)
a11y_walk :: proc(s: ^State, u: ^platform.A11y_Update, b: ^Box, focus: Key, focus_node: ^u64, is_root := false) {
	info := b.a11y
	if info != nil && (info.ignore || info.hidden) { return }
	role := info != nil ? info.role : .Unknown
	name := info != nil ? info.name : ""
	if role == .Unknown && !is_root {
		switch {
		case .Text_Input in b.flags: role = .Text_Input
		case .Clickable in b.flags && a11y_text_shown(s, b) != "": role = .Button
		case a11y_text_shown(s, b) != "": role = .Label
		}
	}
	if is_root { role = .Window }
	is_node := role != .Unknown || name != "" || (info != nil && info.graft != nil)   // (a graft node: a tree of the app's below)
	if !is_node {
		// (a focused box that is no node: the focus goes to the nearest node above it)
		for c := b.first; c != nil; c = c.next { a11y_walk(s, u, c, focus, focus_node) }
		return
	}
	if role == .Unknown { role = .Generic_Container }

	// the children: nodes below, or the text runs of an editable text
	mark := len(s.a11y.kids)
	leaf := a11y_leaf_role(role)
	if info != nil { if v, ok := info.no_children.?; ok { leaf = v } }
	if !leaf {
		for c := b.first; c != nil; c = c.next { a11y_walk(s, u, c, focus, focus_node) }
	}
	runs := 0
	if info != nil && info.text != nil { runs = a11y_text_runs(s, u, b, info.text) }
	part_focus: u64
	if info != nil {
		for p in info.parts {
			acts := p.actions
			if p.role == .Link { acts += {.Click} }
			platform.a11y_node(u, p.id, p.role, {}, acts)
			platform.a11y_bounds(u, f64(p.bounds.min.x), f64(p.bounds.min.y), f64(p.bounds.max.x), f64(p.bounds.max.y))
			platform.a11y_children(u, nil)
			platform.a11y_str(u, p.role == .Label ? .Value : .Label, p.name)
			platform.a11y_str(u, .Url, p.url)
			append(&s.a11y.kids, p.id)
			if p.focused { part_focus = p.id }
		}
	}
	if part_focus != 0 && focus == b.key && focus_node^ == 0 { focus_node^ = part_focus }
	kids := make([]u64, len(s.a11y.kids) - mark, context.temp_allocator)
	copy(kids, s.a11y.kids[mark:])
	resize(&s.a11y.kids, mark)

	// the focus: this node, or a node of its own above the focused box
	if focus != 0 && focus_node^ == 0 {
		if b.key == focus {
			focus_node^ = u64(b.key)
		} else if fb := s.boxes[focus]; fb != nil && fb.last_build == s.build_index && is_descendant(fb, b) && !is_root {
			// the focused box is inside this node and is no node itself (or was not exposed): reached after the
			// children, so a node below that holds it already took it
			focus_node^ = u64(b.key)
		}
	}

	flags: platform.A11y_Flags
	actions: platform.A11y_Actions
	if .Disabled in b.flags { flags += {.Disabled} }
	if .Clickable in b.flags && .Disabled not_in b.flags && role != .Window && role != .Menu && role != .Generic_Container { actions += {.Click} }
	if .Focusable in b.flags && .Disabled not_in b.flags { actions += {.Focus} }
	if .View_Scroll_X in b.flags || .View_Scroll_Y in b.flags { actions += {.Scroll_Into_View} }
	if .Clip in b.flags { flags += {.Clips_Children} }
	if info != nil {
		actions += info.actions
		if info.read_only { flags += {.Read_Only} }
		if info.required { flags += {.Required} }
		if info.multiselectable { flags += {.Multiselectable} }
		if info.modal { flags += {.Modal} }
		if info.busy { flags += {.Busy} }
		if v, ok := info.selected.?; ok { flags += {.Has_Selected}; if v { flags += {.Selected} } }
		if v, ok := info.expanded.?; ok {
			flags += {.Has_Expanded}
			if v { flags += {.Expanded} }
			if .Clickable in b.flags && .Disabled not_in b.flags { actions += {.Expand, .Collapse} }
		}
		if info.numeric != nil && .Set_Value not_in actions && .Disabled not_in b.flags && !info.read_only {
			if role == .Slider || role == .Spin_Button { actions += {.Increment, .Decrement, .Set_Value} }
		}
		if info.text != nil && !info.read_only && .Disabled not_in b.flags { actions += {.Set_Value, .Replace_Selected_Text, .Set_Text_Selection} }
	}
	platform.a11y_node(u, u64(b.key), role, flags, actions)
	r := b.rect
	if is_root { r = {{0, 0}, s.window_size} }
	platform.a11y_bounds(u, f64(r.min.x), f64(r.min.y), f64(r.max.x), f64(r.max.y))
	if info != nil && info.graft != nil && len(kids) == 0 {
		platform.a11y_children(u, nil)
	} else {
		platform.a11y_children(u, kids)
	}

	// name: given, else the box's text (a leaf: the text of its boxes)
	if name == "" && role != .Window && role != .Generic_Container && role != .Combo_Box && !(info != nil && (info.text != nil || info.labelled_by != 0)) {
		if t := a11y_text_shown(s, b); t != "" {
			name = t
		} else if leaf {
			sb := strings.builder_make(context.temp_allocator)
			for c := b.first; c != nil; c = c.next { a11y_subtree_text(s, c, &sb) }
			name = strings.to_string(sb)
		}
	}
	if role == .Label {
		platform.a11y_str(u, .Value, name)   // (a static text's name is its value for AccessKit)
	} else {
		platform.a11y_str(u, .Label, name)
	}
	if info != nil {
		platform.a11y_str(u, .Description, info.description)
		if info.text != nil {
			platform.a11y_str(u, .Value, info.text.password ? "" : info.text.text)
		} else if role != .Label {
			platform.a11y_str(u, .Value, info.value)
		}
		platform.a11y_str(u, .Placeholder, info.placeholder)
		platform.a11y_str(u, .Keyboard_Shortcut, info.shortcut)
		platform.a11y_str(u, .Role_Description, info.role_description)
		if v, ok := info.toggled.?; ok { platform.a11y_int(u, .Toggled, u64(v)) }
		if v, ok := info.numeric.?; ok { platform.a11y_num(u, .Numeric_Value, v) }
		if v, ok := info.min.?; ok { platform.a11y_num(u, .Min_Numeric_Value, v) }
		if v, ok := info.max.?; ok { platform.a11y_num(u, .Max_Numeric_Value, v) }
		if v, ok := info.step.?; ok { platform.a11y_num(u, .Numeric_Value_Step, v) }
		if info.level > 0 { platform.a11y_int(u, .Level, u64(info.level)) }
		if info.position > 0 { platform.a11y_int(u, .Position_In_Set, u64(info.position)) }
		if info.set_size > 0 { platform.a11y_int(u, .Size_Of_Set, u64(info.set_size)) }
		if v, ok := info.orientation.?; ok { platform.a11y_int(u, .Orientation, v == .X ? 0 : 1) }
		if info.live != .Off { platform.a11y_int(u, .Live, u64(info.live)) }
		if v, ok := info.popup.?; ok { platform.a11y_int(u, .Has_Popup, u64(v)) }
		if info.current != .False { platform.a11y_int(u, .Aria_Current, u64(info.current)) }
		if info.labelled_by != 0 { platform.a11y_ids(u, .Labelled_By, {u64(info.labelled_by)}) }
		if info.described_by != 0 { platform.a11y_ids(u, .Described_By, {u64(info.described_by)}) }
		if info.controls != 0 { platform.a11y_ids(u, .Controls, {u64(info.controls)}) }
		if info.active_descendant != 0 && s.boxes[info.active_descendant] != nil { platform.a11y_int(u, .Active_Descendant, u64(info.active_descendant)) }
		if v, ok := info.graft.?; ok { platform.a11y_graft(u, v) }
		if info.text != nil && runs > 0 { a11y_text_selection(u, b, info.text) }
		if info.write != nil { info.write(u, b, info.write_user) }
	}
	if .View_Scroll_Y in b.flags {
		platform.a11y_num(u, .Scroll_Y, f64(b.view_off.y))
		platform.a11y_num(u, .Scroll_Y_Min, 0)
		platform.a11y_num(u, .Scroll_Y_Max, f64(max(0, b.view_bounds.y - b.size.y)))
	}
	if .View_Scroll_X in b.flags {
		platform.a11y_num(u, .Scroll_X, f64(b.view_off.x))
		platform.a11y_num(u, .Scroll_X_Min, 0)
		platform.a11y_num(u, .Scroll_X_Max, f64(max(0, b.view_bounds.x - b.size.x)))
	}
	append(&s.a11y.kids, u64(b.key))
}

// The id of text run `i` of box `b`.
a11y_run_id :: proc(b: ^Box, i: int) -> u64 { return u64(key_from_u64(b.key, 0xa11e_0000 + u64(i))) }

// Text runs (one per visual line) under an editable text's node: their ids go to s.a11y.kids.
@(private)
a11y_text_runs :: proc(s: ^State, u: ^platform.A11y_Update, b: ^Box, t: ^A11y_Text) -> int {
	one := [1][2]int{{0, len(t.text)}}
	lines := t.lines if len(t.lines) > 0 else one[:]
	lens := make([dynamic]u8, context.temp_allocator)
	pos := make([dynamic]f32, context.temp_allocator)
	wid := make([dynamic]f32, context.temp_allocator)
	words := make([dynamic]u8, context.temp_allocator)
	for l, li in lines {
		lo, hi := clamp(l[0], 0, len(t.text)), clamp(l[1], 0, len(t.text))
		if hi < lo { hi = lo }
		line := t.text[lo:hi]
		clear(&lens); clear(&pos); clear(&wid); clear(&words)
		x_prev: f32 = 0
		prev_word := false
		n := 0
		for i := 0; i < len(line); {
			j := font.grapheme_next(line, i)
			if j <= i { j = i + 1 }
			// (a character longer than 255 bytes: a length per byte run would break the run; cut it)
			append(&lens, u8(min(j - i, 255)))
			x := t.font != 0 && s.fonts != nil ? font.x_from_index(s.fonts, t.font, t.size, line, j) : f32(j) * t.size * 0.5
			append(&pos, x_prev)
			append(&wid, x - x_prev)
			x_prev = x
			r := rune(line[i])
			word := r >= 0x80 || is_word_rune(r)
			if word && !prev_word && n < 256 { append(&words, u8(n)) }
			prev_word = word
			n += 1
			i = j
		}
		id := a11y_run_id(b, li)
		y := t.origin.y + f32(li) * t.line_height - t.scroll.y
		x0 := t.origin.x - t.scroll.x
		platform.a11y_node(u, id, .Text_Run)
		platform.a11y_bounds(u, f64(x0), f64(y), f64(x0 + max(x_prev, 1)), f64(y + t.line_height))
		platform.a11y_children(u, nil)
		value := line
		if t.password { value = strings.repeat("\u2022", n, context.temp_allocator) }
		platform.a11y_str(u, .Value, value, keep_empty = true)
		platform.a11y_bytes(u, .Character_Lengths, lens[:])
		if !t.password {
			platform.a11y_floats(u, .Character_Positions, pos[:])
			platform.a11y_floats(u, .Character_Widths, wid[:])
			if len(words) > 0 && n <= 255 { platform.a11y_bytes(u, .Word_Starts, words[:]) }
		}
		append(&s.a11y.kids, id)
	}
	return len(lines)
}

// The byte index of character `index` of text run `run` (a11y_run_id) of box `b`, whose visual lines are `lines`
// (nil: one line): where a screen reader asks the caret to go (Set_Text_Selection).
a11y_run_byte :: proc(text: string, lines: [][2]int, b: ^Box, run: u64, index: int) -> int {
	one := [1][2]int{{0, len(text)}}
	ls := lines if len(lines) > 0 else one[:]
	for l, li in ls {
		if a11y_run_id(b, li) != run { continue }
		i := clamp(l[0], 0, len(text))
		hi := clamp(l[1], i, len(text))
		for n := 0; n < index && i < hi; n += 1 {
			j := font.grapheme_next(text, i)
			i = j > i ? j : i + 1
		}
		return min(i, hi)
	}
	return 0
}

// The caret and selection of an editable text, as positions in its runs.
@(private)
a11y_text_selection :: proc(u: ^platform.A11y_Update, b: ^Box, t: ^A11y_Text) {
	one := [1][2]int{{0, len(t.text)}}
	lines := t.lines if len(t.lines) > 0 else one[:]
	at :: proc(t: ^A11y_Text, lines: [][2]int, b: ^Box, at_byte: int) -> (u64, int) {
		idx := clamp(at_byte, 0, len(t.text))
		li := len(lines) - 1
		for l, i in lines { if idx < l[1] || (idx == l[1] && i == len(lines) - 1) { li = i; break } }
		lo := clamp(lines[li][0], 0, len(t.text))
		n := 0
		for i := lo; i < idx; {
			j := font.grapheme_next(t.text, i)
			if j <= i { j = i + 1 }
			n += 1
			i = j
		}
		return a11y_run_id(b, li), n
	}
	an, ai := at(t, lines, b, t.mark)
	fnode, fi := at(t, lines, b, t.cursor)
	platform.a11y_selection(u, an, ai, fnode, fi)
}

// What a reader cannot name: boxes to click or type in, enabled, with no accessible name and no text in them. In a11y_walk
// a clickable box with neither is no node at all, so a screen reader does not know the control exists. (A box that says
// a11y({ignore = true}) chose that.) Temp memory.
a11y_unnamed :: proc(s: ^State) -> []^Box {
	out := make([dynamic]^Box, context.temp_allocator)
	walk :: proc(s: ^State, b: ^Box, out: ^[dynamic]^Box) {
		if b.last_build != s.build_index { return }
		info := b.a11y
		if info != nil && (info.ignore || info.hidden) { return }
		if b.flags & {.Clickable, .Text_Input} != {} && .Disabled not_in b.flags && b.rect.max.x > b.rect.min.x && b.rect.max.y > b.rect.min.y {
			named := info != nil && (info.name != "" || info.placeholder != "")   // (a placeholder names a field last, as in HTML)
			if !named {
				sb := strings.builder_make(context.temp_allocator)
				a11y_subtree_text(s, b, &sb)
				named = strings.builder_len(sb) > 0 || box_text(b) != ""
			}
			if !named { append(out, b) }
		}
		for c := b.first; c != nil; c = c.next { walk(s, c, out) }
	}
	if s.root != nil { walk(s, s.root, &out) }
	return out[:]
}
