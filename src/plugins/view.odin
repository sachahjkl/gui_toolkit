package tk_plugins

// A plugin's view on the interface's thread (plugins.md, decision 2): the last display list its plugin posted,
// replayed at each build as ordinary calls of `ui`. The box ids come from the nodes' keys, so hover, focus, scroll and
// animation are the toolkit's as for any widget; a new list replaces the old one between two builds, with no diff. What
// the person does is sent to the plugin as a message; no JavaScript runs here.
//
// A view is one of the window's views (ui.view_register: its id is plugin.<plugin id>.<view id>, its presentation the
// manifest's place, then the person's), or a part of the program's own layout (view_body: gt-runtime's window).

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"
import plugin_api "../plugin_api"
import "../ui"

// The palette's items that open a view: plugin-view.<plugin id>.<view id>.
VIEW_PREFIX :: "plugin-view."

// A view as the host keeps it, across the reloads of its plugin (the window's views keep its id).
View_Record :: struct {
	host:       ^Host,
	plugin_id:  string,   // (owned, the three of them)
	view_id:    string,
	ui_id:      string,   // plugin.<plugin id>.<view id>
	title:      string,   // (owned) the manifest's
	place:      View_Place,
	registered: bool,     // ui.view_register ran
	told_open:  bool,     // the plugin's runtime was told it is shown (View_Open)
	embedded:   bool,     // built by view_body in the program's layout: never closed by the window
	list:       ^plugin_api.List,   // the last list come
	old:        ^plugin_api.List,   // the one before, kept until `list` was replayed once (a widget may hold its strings)
	replayed:   bool,
	fitted_nodes: int,   // the nodes of the list the window last fitted to (ui.view_refit)
	controls:   map[string]^Control,   // the host's state of each field and box, by key (keys owned)
	lazies:     map[string]^Lazy,      // its lazy lists' rows, by the list node's key (lazy_list.odin)
}

// What the host keeps of a field or a box: the text typed or the state, and how many changes the person made.
@(private)
Control :: struct {
	edit:    ui.Line_Edit,
	on:      bool,
	changes: u64,
}

// The record of plugin `plugin_id`'s view `view_id` (nil: none was declared since the host opened).
view_record :: proc(h: ^Host, plugin_id, view_id: string) -> ^View_Record {
	for r in h.views { if r.plugin_id == plugin_id && r.view_id == view_id { return r } }
	return nil
}

// The ui id of a plugin's view.
view_ui_id :: proc(plugin_id, view_id: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"plugin.", plugin_id, ".", view_id}, allocator)
}

// The records of the plugins' views, made or updated after a read of the folder. Interface thread.
@(private)
views_declare :: proc(h: ^Host) {
	for p in h.plugins {
		if p.refused != "" { continue }
		for d in p.manifest.views {
			r := view_record(h, p.manifest.id, d.id)
			if r == nil {
				r = new(View_Record)
				r.host = h
				r.plugin_id, r.view_id = strings.clone(p.manifest.id), strings.clone(d.id)
				r.ui_id = view_ui_id(p.manifest.id, d.id, context.allocator)
				append(&h.views, r)
			}
			delete(r.title)
			r.title = strings.clone(d.title)
			r.place = d.place
			r.told_open = false   // (a new plugin: a new runtime, which must hear of it)
		}
	}
}

@(private)
view_record_free :: proc(r: ^View_Record) {
	plugin_api.list_free(r.list)
	plugin_api.list_free(r.old)
	for k, c in r.controls {
		ui.line_edit_destroy(&c.edit)
		free(c)
		delete(k)
	}
	delete(r.controls)
	for _, lz in r.lazies { lazy_free(lz) }   // (the map's keys are the lists' own)
	delete(r.lazies)
	delete(r.plugin_id); delete(r.view_id); delete(r.ui_id); delete(r.title)
	free(r)
}

// Each build (host_build): the views registered with the window, and the plugin told of a view the person closed.
@(private)
views_build :: proc(h: ^Host) {
	vs := ui.state_views(h.state)
	for r in h.views {
		if !r.registered && !r.embedded {
			r.registered = true
			first := [View_Place]ui.View_Presentation{.Internal = .Internal, .Dialog = .Dialog, .Panel = .Panel, .Window = .External}
			ui.view_register(vs, r.ui_id, view_build, ui.View_Options{
				title = r.title, home = r.place == .Panel ? .Panel : .Dialog, first = first[r.place],
				width_em = VIEW_WIDTH_EM, extent_em = VIEW_WIDTH_EM, resizable = true,
			})
		}
		if r.told_open && !r.embedded && !ui.view_is_open(vs, r.ui_id) {
			r.told_open = false
			if p := find(h, r.plugin_id); p != nil && p.alive { queue_push(p, {kind = .View_Close, view = strings.clone(r.view_id)}) }
		}
	}
}

// A view's first width, and a panel's.
VIEW_WIDTH_EM :: 28

// A field of a view: the text it shows (the host's), and the value the last list gives it (the plugin's). ok false: no
// such field in the last list.
view_field :: proc(h: ^Host, plugin_id, view_id, key: string) -> (shown, rendered: string, ok: bool) {
	r := view_record(h, plugin_id, view_id)
	if r == nil || r.list == nil { return }
	for n in r.list.nodes {
		if n.key != key || n.kind != .Field { continue }
		if c, has := r.controls[key]; has { shown = ui.line_edit_string(&c.edit) }
		return shown, plugin_api.node_props(n, plugin_api.Field_Node).value, true
	}
	return
}

// The keys of the last list of a view, in its order (temp memory): what a test reads of a render.
view_keys :: proc(h: ^Host, plugin_id, view_id: string) -> []string {
	r := view_record(h, plugin_id, view_id)
	if r == nil || r.list == nil { return nil }
	keys := make([]string, len(r.list.nodes), context.temp_allocator)
	for n, i in r.list.nodes { keys[i] = n.key }
	return keys
}

// The plugin's thread ended: its views' next runtime must hear that they are shown.
@(private)
views_ended :: proc(h: ^Host, p: ^Plugin) {
	for r in h.views { if r.plugin_id == p.manifest.id { r.told_open = false } }
}

// A list came (event_run): it is the one the next build replays.
@(private)
view_take_list :: proc(r: ^View_Record, l: ^plugin_api.List) {
	plugin_api.list_free(r.old)
	r.old = r.list
	r.list = l
	r.replayed = false
}

// Opens a plugin's view in the window, at its place, and starts its plugin when it does not run. False: no such view,
// or its plugin cannot run now.
open_view :: proc(h: ^Host, plugin_id, view_id: string) -> bool {
	context.allocator = runtime.heap_allocator()   // (the host's memory crosses threads: plugins.odin)
	r := view_record(h, plugin_id, view_id)
	if r == nil || r.embedded { return false }
	if !view_tell_open(h, r) { return false }
	ui.view_open(ui.state_views(h.state), r.ui_id, r)
	return true
}

// Builds a plugin's view in the program's own layout, in the box being built (gt-runtime's window). The plugin starts
// at its first call. False: no such view.
view_body :: proc(h: ^Host, plugin_id, view_id: string) -> bool {
	context.allocator = runtime.heap_allocator()
	r := view_record(h, plugin_id, view_id)
	if r == nil { return false }
	r.embedded = true
	if !r.told_open { _ = view_tell_open(h, r) }
	view_draw(r)
	return true
}

// The plugin hears that the view is shown (its render runs); its runtime starts first when it has none.
@(private)
view_tell_open :: proc(h: ^Host, r: ^View_Record) -> bool {
	p := find(h, r.plugin_id)
	if p == nil || !can_run(p) { return false }
	if r.told_open && p.alive { return true }
	if !p.alive { plugin_start(h, p) }
	queue_push(p, {kind = .View_Open, view = strings.clone(r.view_id)})
	r.told_open = true
	wake_after(h, h.o.bound_ms + WAKE_MARGIN_MS)
	return true
}

// The window's build of the view (ui.view_register's).
@(private)
view_build :: proc(v: ^ui.View, r: ^View_Record) {
	context.allocator = runtime.heap_allocator()
	// (the plugin's first list is the content's first real build: the window waits for it, bounded, and takes the
	// height of what is in it once it comes, and again when a list of another shape comes)
	if r.list == nil {
		ui.view_not_ready(v)
	} else if !r.replayed && len(r.list.nodes) != r.fitted_nodes {
		ui.view_refit(v)
		r.fitted_nodes = len(r.list.nodes)
	}
	view_draw(r, true)
}

// `scroll`: the body scrolls when what is in it is taller than its room (a view of the window's; a program's own layout
// scrolls itself).
@(private)
view_draw :: proc(r: ^View_Record, scroll := false) {
	h := r.host
	em := ui.font_size()
	// (the list before the last one was replayed once already: no widget holds its strings now)
	if r.replayed && r.old != nil {
		plugin_api.list_free(r.old)
		r.old = nil
		lazies_prune(r)   // (the lazy lists the new list no longer has: none was built since)
	}
	view_status(h, r, em)
	if r.list == nil {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
			ui.label(fmt.tprintf("%s###pv_waiting", i18n.tr("Starting…")))
		}
		return
	}
	if scroll {
		// (as tall as what is in it, and shrinking to the room when there is less: a window as tall as what is in it
		// shows it all, a smaller one scrolls it)
		ui.next({width = ui.fill(), height = ui.children_sum(0)})
		if ui.scroll_y("###pv_scroll") { view_nodes(r) }
	} else {
		view_nodes(r)
	}
	r.replayed = true
}

@(private)
view_nodes :: proc(r: ^View_Record) {
	nodes := r.list.nodes[:]
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###pv_body") {
		i := 0
		for i < len(nodes) {
			if i > 0 { ui.space(ui.LINE_GAP) }
			replay(r, nodes, &i, false)
		}
	}
}

// A line above the view when its plugin is not running as it should: not responding (Stop), stopped (Start), failed.
@(private)
view_status :: proc(h: ^Host, r: ^View_Record, em: f32) {
	p := find(h, r.plugin_id)
	words := ""
	button := ""
	switch {
	case p == nil:                   words = i18n.tr("This plugin is gone.")
	case p.state == .Not_Responding: words, button = i18n.tr("Not responding."), i18n.tr("Stop")
	case p.state == .Failed:         words, button = p.failure, p.alive ? "" : i18n.tr("Restart")
	case p.state == .Suspended:      words = i18n.tr("Suspended: its process crashed again and again. Turn it on in the settings' Plugins page.")
	case !p.alive && r.list != nil:  words, button = i18n.tr("Stopped."), i18n.tr("Start")
	}
	if words == "" { return }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(id = "###pv_status") {
		ui.push_tags(p != nil && p.state == .Failed || p != nil && p.state == .Not_Responding ? "bad" : "weak")
		ui.next({width = ui.fill(), font_size = math.round(em * 0.9), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###pv_status_words", words))
		ui.pop_tags()
		if button != "" {
			ui.space(ui.CONTROL_GAP)
			if ui.button("pv_status_act", button).clicked {
				switch p.state {
				case .Not_Responding: plugin_stop(p)
				case .Failed:         if restart(h, p.manifest.id) { _ = view_tell_open(h, r) }
				case .Found, .Refused, .Off, .Ready, .Starting, .Running, .Suspended: _ = view_tell_open(h, r)
				}
			}
		}
	}
	ui.space(ui.LINE_GAP)
}

// One node and its children, as ordinary calls of `ui`. `in_row`: its parent lays out across (a text takes its own
// width there, a column's whole width otherwise).
@(private)
replay :: proc(r: ^View_Record, nodes: []plugin_api.List_Node, i: ^int, in_row: bool) {
	n := nodes[i^]
	i^ += 1
	em := ui.font_size()
	id := fmt.tprintf("pv:%s", n.key)
	box := fmt.tprintf("###pv:%s", n.key)
	switch n.kind {
	case .Text:
		t := plugin_api.node_props(n, plugin_api.Text_Node)
		if t.weak { ui.push_tags("weak") }
		if in_row {
			ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2))})
			ui.label(fmt.tprintf("%s%s", t.text, box))
		} else {
			ui.next({width = ui.fill()})
			ui.paragraph(fmt.tprintf("%s%s", t.text, box))
		}
		if t.weak { ui.pop_tags() }
	case .Heading:
		t := plugin_api.node_props(n, plugin_api.Heading_Node)
		ui.next({width = in_row ? ui.text_size(0) : ui.fill(), height = ui.px(math.round(em * 2)), font_size = math.round(em * 1.25), text_pad = 0})
		ui.label(fmt.tprintf("%s%s", t.text, box))
	case .Button:
		b := plugin_api.node_props(n, plugin_api.Button_Node)
		intents := [plugin_api.Button_Intent]ui.Intent{.neutral = .Neutral, .primary = .Primary, .success = .Success, .warning = .Warning, .danger = .Danger}
		looks := [plugin_api.Button_Look]ui.Button_Face{.raised = .Raised, .ghost = .Ghost, .link = .Link}
		sizes := [plugin_api.Button_Size]ui.Button_Size{.medium = .Medium, .small = .Small, .large = .Large}
		if ui.button(id, b.label, o = {intent = intents[b.intent], face = looks[b.look], size = sizes[b.size], disabled = b.disabled}).clicked {
			view_send(r, n.key, .onClick)
		}
	case .Row, .Column:
		across := n.kind == .Row
		ui.next({width = ui.fill(), height = ui.children_sum()})
		// (two calls, each in its own `if`: row and column close their box at the end of the if's scope)
		if across {
			if ui.row(.Center, id = box) { replay_children(r, nodes, i, n.children, true) } else { skip_children(nodes, i, n.children) }
		} else {
			if ui.column(id = box) { replay_children(r, nodes, i, n.children, false) } else { skip_children(nodes, i, n.children) }
		}
	case .Card:
		c := plugin_api.node_props(n, plugin_api.Card_Node)
		title := c != nil ? c.title : ""
		if ui.card(title, id = box) { replay_children(r, nodes, i, n.children, false) } else { skip_children(nodes, i, n.children) }
	case .Space:
		s := plugin_api.node_props(n, plugin_api.Space_Node)
		switch s.size {
		case .small:  ui.space(ui.LINE_GAP)
		case .medium: ui.space(ui.ITEM_GAP)
		case .large:  ui.space(ui.GROUP_GAP)
		case .fill:   ui.spacer(ui.fill())
		}
	case .Field:
		f := plugin_api.node_props(n, plugin_api.Field_Node)
		c := control(r, n.key)
		// (the plugin's value, unless the person typed since the plugin last heard: plugins.md, "Subtle points")
		if n.controlled && n.seen >= c.changes && ui.line_edit_string(&c.edit) != f.value { ui.line_edit_set(&c.edit, f.value) }
		ui.next({width = in_row ? ui.px(math.round(em * 14), 0) : ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		res := ui.line_edit(box, &c.edit, {placeholder = f.placeholder})
		if res.changed {
			c.changes += 1
			view_send(r, n.key, .onChange, text = ui.line_edit_string(&c.edit), serial = c.changes)
		}
		if res.committed { view_send(r, n.key, .onSubmit, text = ui.line_edit_string(&c.edit)) }
	case .Check, .Switch:
		label: string
		state: bool
		if n.kind == .Check {
			b := plugin_api.node_props(n, plugin_api.Check_Node)
			label, state = b.label, b.checked
		} else {
			b := plugin_api.node_props(n, plugin_api.Switch_Node)
			label, state = b.label, b.on
		}
		c := control(r, n.key)
		if n.controlled && n.seen >= c.changes { c.on = state }
		// (in a row, no width: a check box and a switch are a mark and a label, which fit their row themselves; the size of
		// their own text, which they have none of, left the label no room)
		if in_row {
			ui.next({height = ui.px(ui.dense(em * 2))})
		} else {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		}
		changed := n.kind == .Check ? ui.checkbox(box, label, &c.on) : ui.toggle(box, label, &c.on)
		if changed {
			c.changes += 1
			view_send(r, n.key, .onChange, flag = c.on, is_flag = true, serial = c.changes)
		}
	case .Separator:
		ui.hline(ui.fill())
	case .List:
		lazy_replay(r, n)
	}
}

// A container's `count` children, the layout's gap between two (none next to the plugin's own space).
@(private)
replay_children :: proc(r: ^View_Record, nodes: []plugin_api.List_Node, i: ^int, count: int, across: bool) {
	prev_space := false
	for k in 0 ..< count {
		is_space := nodes[i^].kind == .Space
		if k > 0 && !is_space && !prev_space { ui.space(across ? ui.CONTROL_GAP : ui.LINE_GAP) }
		prev_space = is_space
		replay(r, nodes, i, across)
	}
}

@(private)
skip_children :: proc(nodes: []plugin_api.List_Node, i: ^int, count: int) {
	for _ in 0 ..< count { skip(nodes, i) }
}

// Past a node and its children.
@(private)
skip :: proc(nodes: []plugin_api.List_Node, i: ^int) {
	n := nodes[i^]
	i^ += 1
	skip_children(nodes, i, n.children)
}

@(private)
control :: proc(r: ^View_Record, key: string) -> ^Control {
	if c, ok := r.controls[key]; ok { return c }
	c := new(Control)
	r.controls[strings.clone(key)] = c
	return c
}

// A node was used: a message to the plugin. A plugin that does not run hears nothing (the view says Stopped, Start).
@(private)
view_send :: proc(r: ^View_Record, key: string, event: View_Event, text := "", flag := false, is_flag := false, serial: u64 = 0) {
	context.allocator = runtime.heap_allocator()
	h := r.host
	p := find(h, r.plugin_id)
	if p == nil || !p.alive || !r.told_open { return }
	queue_push(p, Message{
		kind = .View_Event, view = strings.clone(r.view_id), key = strings.clone(key), event = event,
		text = strings.clone(text), flag = flag, is_flag = is_flag, serial = serial,
	})
	wake_after(h, h.o.bound_ms + WAKE_MARGIN_MS)
}
