// The accessibility tree the toolkit makes from its boxes, without a window nor a screen reader: roles, names, states
// and focus of the widgets, layout boxes left out, the incremental updates, and the requests of assistive technologies
// answered as clicks, focus and values. With -define:A11Y_ACCESSKIT=true (gt_a11y.lib built by tools\build_a11y.ps1),
// uia_test.odin also reads a real window through UI Automation, as a screen reader does.
//   odin test tests/a11y -vet -define:ODIN_TEST_THREADS=1
package a11y_test

import "core:sync"
import "core:testing"
import "../../font"
import "../../platform"
import "../../ui"

WINDOW :: ui.Vec2{900, 700}

Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	base_font: font.Font_Id,
}

// (the ui package keeps the current state in a global: one test at a time)
ui_state_lock: sync.Mutex

open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	icons, iok := font.load_embedded(&f.fonts, ui.ICON_FONT_DATA)
	if !iok { return false }
	ui.apply_palette(&f.theme, ui.PALETTE_GRAPHITE)
	ui.init(&f.s, &f.fonts, &f.theme)
	f.s.icon_font = icons
	f.base_font = id
	return true
}

close :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

App :: struct {
	wrap:     bool,
	volume:   f32,
	tab:      int,
	field:    ui.Text_Field,
	list:     ui.List_State,
	open:     bool,
	clicks:   int,
	back:     int,
	keys:     struct { back, save, wrap, volume, field, tabs, hello, list, row1, layout, accordion, graft: ui.Key },
}

app_destroy :: proc(a: ^App) {
	ui.field_destroy(&a.field)
	ui.list_state_destroy(&a.list)
}

body :: proc(a: ^App) {
	if ui.column() {
		ui.next({width = ui.px(400), height = ui.children_sum()})
		if ui.row(id = "###toolbar") {
			a.keys.layout = ui.parent_box().key
			ui.a11y({name = "Go back"})
			ui.next({width = ui.px(30), height = ui.px(30)})
			sig := ui.icon_button("back", ui.ICON_UP)
			a.keys.back = sig.box.key
			if sig.clicked { a.back += 1 }
			ui.next({width = ui.px(100), height = ui.px(30)})
			s := ui.button("Save###save")
			a.keys.save = s.box.key
			if s.clicked { a.clicks += 1 }
		}
		ui.next({width = ui.px(300), height = ui.px(30)})
		a.keys.wrap = ui.checkbox("###wrap", "Wrap lines", &a.wrap).box.key
		ui.next({width = ui.px(300), height = ui.px(30)})
		a.keys.volume = ui.slider("###volume", &a.volume, 0, 100, 1, "%.0f").box.key
		ui.next({width = ui.px(300), height = ui.px(30)})
		a.keys.field = ui.line_edit("###name", &a.field, "Your name").box.key
		ui.next({width = ui.px(400), height = ui.px(30)})
		if ui.row(id = "###tabs") {
			a.keys.tabs = ui.parent_box().key
			ui.tabs("t", {"One", "Two", "Three"}, nil, &a.tab)
		}
		ui.next({width = ui.px(300), height = ui.px(30)})
		a.keys.hello = ui.label("Hello###hello").box.key
		ui.next({width = ui.px(300), height = ui.px(120)})
		if ui.list("###list", &a.list) {
			a.keys.list = ui.parent_box().key
			for i in 0 ..< 3 {
				ui.next({height = ui.px(30)})
				names := [3]string{"Apples", "Pears", "Plums"}
				sig := ui.list_row(&a.list, i, names[i])
				if i == 1 { a.keys.row1 = sig.box.key }
				if ui.parent(sig.box) { ui.label(names[i]) }
			}
		}
		// a view of the app's own whose tree is grafted here (a document)
		ui.next({width = ui.px(300), height = ui.px(40)})
		gb := ui.build_box({.Focusable}, "###doc_view")
		ui.a11y_set(gb, {graft = platform.A11y_Tree_Id{0 = 1, 1 = 2, 2 = 3}})
		a.keys.graft = gb.key
		ui.next({width = ui.px(300)})
		if ui.accordion("###acc", "More", &a.open) {
			ui.label("Inside")
		}
		a.keys.accordion = ui.prev_box("###acc").key if ui.prev_box("###acc") != nil else 0
	}
}

frame :: proc(f: ^Fx, a: ^App, events: []platform.Event = nil) {
	ui.begin_build(&f.s, {
		window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
	})
	body(a)
	ui.end_build()
	free_all(context.temp_allocator)
}

node :: proc(f: ^Fx, k: ui.Key) -> (platform.A11y_Node, int) {
	i := ui.a11y_find(&f.s, k)
	if i < 0 { return {}, -1 }
	return ui.a11y_tree(&f.s).nodes[i], i
}

@(test)
tree_from_boxes :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	a: App
	defer app_destroy(&a)
	ui.field_set(&a.field, "Ada")
	a.volume = 40
	a.wrap = true
	a.open = true

	// nothing is built while nobody reads the window
	frame(&f, &a)
	testing.expect(t, !ui.a11y_active(&f.s), "no tree without a reader")
	testing.expect_value(t, len(ui.a11y_tree(&f.s).nodes), 0)

	ui.a11y_capture(&f.s, true)
	frame(&f, &a)
	frame(&f, &a)
	testing.expect(t, ui.a11y_active(&f.s), "captured")
	u := ui.a11y_tree(&f.s)
	root, ri := node(&f, ui.Key(u.root))
	testing.expect_value(t, ri >= 0, true)
	testing.expect_value(t, platform.A11y_Role(root.role), platform.A11y_Role.Window)

	// an icon button named by the app; a button named by its text
	back, bi := node(&f, a.keys.back)
	testing.expect_value(t, platform.A11y_Role(back.role), platform.A11y_Role.Button)
	testing.expect_value(t, platform.a11y_node_string(u, bi, .Label), "Go back")
	testing.expect(t, .Click in back.actions && .Focus in back.actions, "a button can be clicked and focused")
	save, si := node(&f, a.keys.save)
	testing.expect_value(t, platform.A11y_Role(save.role), platform.A11y_Role.Button)
	testing.expect_value(t, platform.a11y_node_string(u, si, .Label), "Save")
	testing.expect_value(t, len(platform.a11y_node_children(u, si)), 0)   // (its text is its name, not a child)

	// layout boxes are no nodes: the toolbar's buttons hang under the window
	_, li := node(&f, a.keys.layout)
	testing.expect_value(t, li, -1)
	parent_of :: proc(u: ^platform.A11y_Update, id: u64) -> u64 {
		for n, i in u.nodes { for c in platform.a11y_node_children(u, i) { if c == id { return n.id } } }
		return 0
	}
	testing.expect_value(t, parent_of(u, u64(a.keys.back)), u.root)

	// a check box: checked
	wrap, wi := node(&f, a.keys.wrap)
	testing.expect_value(t, platform.A11y_Role(wrap.role), platform.A11y_Role.Check_Box)
	testing.expect_value(t, platform.a11y_node_string(u, wi, .Label), "Wrap lines")
	toggled := -1
	for p in platform.a11y_node_props(u, wi) { if p.kind == .Toggled { toggled = int(p.a) } }
	testing.expect_value(t, toggled, int(platform.A11y_Toggled.True))

	// a slider: its value and range
	vol, vi := node(&f, a.keys.volume)
	testing.expect_value(t, platform.A11y_Role(vol.role), platform.A11y_Role.Slider)
	num, lo, hi: f64 = -1, -1, -1
	for p in platform.a11y_node_props(u, vi) {
		#partial switch p.kind {
		case .Numeric_Value: num = p.f
		case .Min_Numeric_Value: lo = p.f
		case .Max_Numeric_Value: hi = p.f
		}
	}
	testing.expect_value(t, num, 40)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, 100)
	testing.expect(t, .Increment in vol.actions && .Set_Value in vol.actions, "a slider can be stepped and set")

	// a field: its text and placeholder, one text run with a length per character
	fld, fi := node(&f, a.keys.field)
	testing.expect_value(t, platform.A11y_Role(fld.role), platform.A11y_Role.Text_Input)
	testing.expect_value(t, platform.a11y_node_string(u, fi, .Value), "Ada")
	testing.expect_value(t, platform.a11y_node_string(u, fi, .Placeholder), "Your name")
	runs := platform.a11y_node_children(u, fi)
	testing.expect_value(t, len(runs), 1)
	if len(runs) == 1 {
		run, rj := node(&f, ui.Key(runs[0]))
		testing.expect_value(t, platform.A11y_Role(run.role), platform.A11y_Role.Text_Run)
		testing.expect_value(t, platform.a11y_node_string(u, rj, .Value), "Ada")
		for p in platform.a11y_node_props(u, rj) {
			if p.kind == .Character_Lengths { testing.expect_value(t, p.len, 3) }
		}
	}

	// tabs: a tab list, the selected one says so, "2 of 3"
	tl, ti := node(&f, a.keys.tabs)
	testing.expect_value(t, platform.A11y_Role(tl.role), platform.A11y_Role.Tab_List)
	tabs := platform.a11y_node_children(u, ti)
	testing.expect_value(t, len(tabs), 3)
	if len(tabs) == 3 {
		t0, t0i := node(&f, ui.Key(tabs[0]))
		testing.expect_value(t, platform.A11y_Role(t0.role), platform.A11y_Role.Tab)
		testing.expect_value(t, platform.a11y_node_string(u, t0i, .Label), "One")
		testing.expect(t, .Has_Selected in t0.flags && .Selected in t0.flags, "the first tab is selected")
		t1, _ := node(&f, ui.Key(tabs[1]))
		testing.expect(t, .Has_Selected in t1.flags && .Selected not_in t1.flags, "the second is not")
	}

	// a static text: a Label whose text is its value
	hello, hi2 := node(&f, a.keys.hello)
	testing.expect_value(t, platform.A11y_Role(hello.role), platform.A11y_Role.Label)
	testing.expect_value(t, platform.a11y_node_string(u, hi2, .Value), "Hello")

	// a list: its rows are options, named by their label, the row's own label not repeated
	lst, lsi := node(&f, a.keys.list)
	testing.expect_value(t, platform.A11y_Role(lst.role), platform.A11y_Role.List_Box)
	rows := platform.a11y_node_children(u, lsi)
	testing.expect_value(t, len(rows), 3)
	r1, r1i := node(&f, a.keys.row1)
	testing.expect_value(t, platform.A11y_Role(r1.role), platform.A11y_Role.List_Box_Option)
	testing.expect_value(t, platform.a11y_node_string(u, r1i, .Label), "Pears")
	testing.expect_value(t, len(platform.a11y_node_children(u, r1i)), 0)

	// a graft node: a node with no children of its own, naming its tree
	_, gi := node(&f, a.keys.graft)
	if testing.expect(t, gi >= 0, "the graft is a node") {
		testing.expect_value(t, len(platform.a11y_node_children(u, gi)), 0)
		has_tree := false
		for p in platform.a11y_node_props(u, gi) { if p.kind == .Tree_Id { has_tree = true } }
		testing.expect(t, has_tree, "it names its tree")
	}

	// every node has bounds; every child exists
	ids := make(map[u64]bool, context.temp_allocator)
	for n in u.nodes { ids[n.id] = true; testing.expect(t, .Has_Bounds in n.flags, "bounds") }
	for _, i in u.nodes { for c in platform.a11y_node_children(u, i) { testing.expect(t, ids[c], "a child that is a node") } }
}

@(test)
focus_follows_the_toolkit :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	a: App
	defer app_destroy(&a)
	ui.a11y_capture(&f.s, true)
	frame(&f, &a)
	frame(&f, &a)
	testing.expect_value(t, ui.a11y_tree(&f.s).focus, ui.a11y_tree(&f.s).root)   // nothing focused: the window

	// Tab moves the focus: the tree says where
	frame(&f, &a, {{kind = .Key_Press, key = .Tab}})
	frame(&f, &a)
	testing.expect_value(t, ui.a11y_tree(&f.s).focus, u64(a.keys.back))

	// a focused list: its selected row
	ui.set_focus(a.keys.list)
	a.list.sel = 1
	frame(&f, &a)
	testing.expect_value(t, ui.a11y_tree(&f.s).focus, u64(a.keys.row1))
}

@(test)
updates_carry_what_changed :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	a: App
	defer app_destroy(&a)
	ui.a11y_capture(&f.s, true)
	d: platform.A11y_Diff
	defer platform.a11y_diff_destroy(&d)
	frame(&f, &a)
	frame(&f, &a)
	total := len(ui.a11y_tree(&f.s).nodes)
	out := platform.a11y_diff(&d, ui.a11y_tree(&f.s))
	testing.expect_value(t, len(out.nodes), total)   // the first update: the whole tree
	testing.expect(t, out.tree_info, "a whole tree states its root")

	frame(&f, &a)
	out = platform.a11y_diff(&d, ui.a11y_tree(&f.s))
	testing.expect_value(t, len(out.nodes), 0)   // nothing changed: nothing to send

	a.wrap = true
	frame(&f, &a)
	out = platform.a11y_diff(&d, ui.a11y_tree(&f.s))
	testing.expect_value(t, len(out.nodes), 1)
	if len(out.nodes) == 1 { testing.expect_value(t, out.nodes[0].id, u64(a.keys.wrap)) }
	testing.expect(t, !out.tree_info, "an incremental update")

	// a node that goes away: its parent changes (its children), the node itself is not sent
	a.open = true
	frame(&f, &a)
	frame(&f, &a)
	_ = platform.a11y_diff(&d, ui.a11y_tree(&f.s))
	a.open = false
	frame(&f, &a)
	frame(&f, &a)
	out = platform.a11y_diff(&d, ui.a11y_tree(&f.s))
	testing.expect(t, len(out.nodes) >= 1 && len(out.nodes) < total, "only the nodes around the change")

	out = platform.a11y_diff(&d, ui.a11y_tree(&f.s), all = true)
	testing.expect_value(t, len(out.nodes), len(ui.a11y_tree(&f.s).nodes))
}

@(test)
requests_act_like_input :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	a: App
	defer app_destroy(&a)
	ui.a11y_capture(&f.s, true)
	frame(&f, &a)
	frame(&f, &a)

	// Invoke: the button's click
	ui.a11y_inject(&f.s, {action = .Click, target = u64(a.keys.save)})
	frame(&f, &a)
	testing.expect_value(t, a.clicks, 1)
	ui.a11y_inject(&f.s, {action = .Click, target = u64(a.keys.back)})
	frame(&f, &a)
	testing.expect_value(t, a.back, 1)

	// Toggle: the check box
	ui.a11y_inject(&f.s, {action = .Click, target = u64(a.keys.wrap)})
	frame(&f, &a)
	testing.expect_value(t, a.wrap, true)
	_, wi := node(&f, a.keys.wrap)
	toggled := -1
	for p in platform.a11y_node_props(ui.a11y_tree(&f.s), wi) { if p.kind == .Toggled { toggled = int(p.a) } }
	testing.expect_value(t, toggled, int(platform.A11y_Toggled.True))   // (the tree of that same frame)

	// Value: the field's text, the slider's value; RangeValue steps
	ui.a11y_inject(&f.s, {action = .Set_Value, data = .Value, value = "Grace", target = u64(a.keys.field)})
	frame(&f, &a)
	testing.expect_value(t, ui.field_string(&a.field), "Grace")
	ui.a11y_inject(&f.s, {action = .Set_Value, data = .Numeric_Value, num = 70, target = u64(a.keys.volume)})
	frame(&f, &a)
	testing.expect_value(t, a.volume, 70)
	ui.a11y_inject(&f.s, {action = .Increment, target = u64(a.keys.volume)})
	frame(&f, &a)
	testing.expect_value(t, a.volume, 71)

	// Focus
	ui.a11y_inject(&f.s, {action = .Focus, target = u64(a.keys.wrap)})
	frame(&f, &a)
	testing.expect_value(t, ui.focus_key(), a.keys.wrap)

	// selecting a tab and a row
	frame(&f, &a)
	_, ti := node(&f, a.keys.tabs)
	tabs := platform.a11y_node_children(ui.a11y_tree(&f.s), ti)
	if len(tabs) == 3 {
		ui.a11y_inject(&f.s, {action = .Click, target = tabs[2]})
		frame(&f, &a)
		testing.expect_value(t, a.tab, 2)
	}
	ui.a11y_inject(&f.s, {action = .Click, target = u64(a.keys.row1)})
	frame(&f, &a)
	testing.expect_value(t, a.list.sel, 1)

	// Expand on a folded section opens it; Expand again leaves it open
	header := u64(0)
	for n in ui.a11y_tree(&f.s).nodes { if .Has_Expanded in n.flags && platform.A11y_Role(n.role) == .Button { header = n.id } }
	if testing.expect(t, header != 0, "the accordion's header") {
		ui.a11y_inject(&f.s, {action = .Expand, target = header})
		frame(&f, &a)
		testing.expect_value(t, a.open, true)
		ui.a11y_inject(&f.s, {action = .Expand, target = header})
		frame(&f, &a)
		testing.expect_value(t, a.open, true)
		ui.a11y_inject(&f.s, {action = .Collapse, target = header})
		frame(&f, &a)
		testing.expect_value(t, a.open, false)
	}

	// a request for nothing the toolkit knows waits for the app
	ui.a11y_inject(&f.s, {action = .Click, target = 12345})
	frame_keep :: proc(f: ^Fx, a: ^App) -> int {
		ui.begin_build(&f.s, {window_size = WINDOW, dt = 1.0 / 60, dpi_scale = 1,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6}})
		n := len(ui.a11y_requests())
		body(a)
		ui.end_build()
		free_all(context.temp_allocator)
		return n
	}
	testing.expect_value(t, frame_keep(&f, &a), 1)
}

// Node by node (a document that knows its mutations): only the nodes handed over go, a child taken away is forgotten
// with its subtree (put back, it goes whole), a child moved to another node is kept.
@(test)
patches_carry_only_their_nodes :: proc(t: ^testing.T) {
	tree :: proc(u: ^platform.A11y_Update, nodes: []struct { id: u64, kids: []u64, name: string }) {
		platform.a11y_update_clear(u)
		for n in nodes {
			platform.a11y_node(u, n.id, .Group if len(n.kids) > 0 else .Label)
			platform.a11y_children(u, n.kids)
			platform.a11y_str(u, .Label, n.name)
		}
		u.root, u.focus = 1, 1
	}
	u: platform.A11y_Update
	defer platform.a11y_update_destroy(&u)
	d: platform.A11y_Diff
	defer platform.a11y_diff_destroy(&d)
	tree(&u, {{1, {2, 3}, "root"}, {2, nil, "two"}, {3, {4}, "three"}, {4, nil, "four"}})
	out := platform.a11y_diff_patch(&d, &u)
	testing.expect(t, out.tree_info && len(out.nodes) == 4, "the first patch is the whole tree")

	tree(&u, {{2, nil, "two, renamed"}})
	out = platform.a11y_diff_patch(&d, &u)
	testing.expect(t, !out.tree_info && len(out.nodes) == 1 && out.nodes[0].id == 2, "one node changed: one node sent")
	out = platform.a11y_diff_patch(&d, &u)
	testing.expect_value(t, len(out.nodes), 0)   // the same again: nothing

	tree(&u, {{1, {2}, "root"}})   // three (and four under it) taken away
	out = platform.a11y_diff_patch(&d, &u)
	testing.expect_value(t, len(out.nodes), 1)
	testing.expect(t, !platform.a11y_diff_has(&d, 3) && !platform.a11y_diff_has(&d, 4), "the subtree is forgotten")
	testing.expect(t, platform.a11y_diff_has(&d, 2), "the rest is kept")

	tree(&u, {{1, {2, 3}, "root"}, {3, {4}, "three"}, {4, nil, "four"}})   // put back as it was
	out = platform.a11y_diff_patch(&d, &u)
	testing.expect_value(t, len(out.nodes), 3)   // (not skipped as "unchanged": the adapter dropped them)

	tree(&u, {{2, {4}, "two, renamed"}, {3, nil, "three"}})   // four moves from three to two
	out = platform.a11y_diff_patch(&d, &u)
	testing.expect_value(t, len(out.nodes), 2)
	testing.expect(t, platform.a11y_diff_has(&d, 4), "a moved node is kept")

	// a whole tree after patches: what the patches left is what a diff compares with
	tree(&u, {{1, {2, 3}, "root"}, {2, {4}, "two, renamed"}, {3, nil, "three"}, {4, nil, "four"}})
	out = platform.a11y_diff(&d, &u)
	testing.expect_value(t, len(out.nodes), 0)
}

// The tree's cost is measured, and nothing is made while no one reads the window (no adapter, no capture).
@(test)
tree_cost_is_measured :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	a: App
	defer app_destroy(&a)
	frame(&f, &a)
	n, ms := ui.a11y_cost(&f.s)
	testing.expect(t, n == 0 && ms == 0 && !ui.a11y_active(&f.s), "no reader: no tree, no cost")
	ui.a11y_capture(&f.s, true)
	frame(&f, &a)
	n, ms = ui.a11y_cost(&f.s)
	testing.expectf(t, n > 10 && ms > 0, "%d nodes in %.3f ms", n, ms)
}