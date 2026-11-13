package showcase

// The graph scene: a workflow of gt:flowgraph (capture, annotate, encode, then save, upload and copy the link) shown by
// ui.node_graph, its nodes in the states of a run, and the selected node's parameters in ui.node_inspector. The run is
// fixed: each node's state is written below, not computed.

import "core:fmt"
import flowgraph "../../src/flowgraph"
import lucide "../../src/lucide"
import "../../src/ui"

PICTURE :: flowgraph.Port_Kind(1)
TEXT    :: flowgraph.Port_Kind(2)

Node_Kind :: enum { Capture, Blur, Annotate, Encode, Save, Upload, Copy, Notify }

CATALOG := flowgraph.Catalog{
	kinds = {{name = "action"}, {name = "picture", transient = true}, {name = "text"}},
	nodes = {   // (in the order of Node_Kind: Node.kind is an index in this list)
		{name = "capture", title = "Capture region", group = "Sources", icon = lucide.CAMERA, max_count = 1, min_count = 1,
			outputs = {{name = "picture", kind = PICTURE}},
			params = {{name = "delay", title = "Delay", type = .Float, lo = 0, hi = 10, step = 0.5, unit = "s"}, {name = "pointer", title = "Show the pointer", type = .Bool}}},
		{name = "blur", title = "Blur faces", group = "Edits", icon = lucide.SCAN,
			inputs = {{name = "picture", kind = PICTURE}}, outputs = {{name = "picture", kind = PICTURE}},
			params = {{name = "radius", title = "Radius", type = .Float, lo = 0.5, hi = 64, step = 0.5, unit = "px", default_number = 6}}},
		{name = "annotate", title = "Annotate", group = "Edits", icon = lucide.PENCIL,
			inputs = {{name = "picture", kind = PICTURE}},
			outputs = {{name = "picture", kind = PICTURE}, {name = "done", kind = flowgraph.ACTION, on = .Done}},
			params = {{name = "colour", title = "Colour", type = .Color, default_color = {232, 116, 59, 255}},
				{name = "caption", title = "Caption", type = .Text, placeholder = "No caption", default_text = "The harbour at dusk"},
				{name = "stroke", title = "Stroke", type = .Int, lo = 1, hi = 12, step = 1, unit = "px", default_number = 3}}},
		{name = "encode", title = "Encode", group = "Edits", icon = lucide.IMAGE,
			inputs = {{name = "picture", kind = PICTURE}}, outputs = {{name = "picture", kind = PICTURE}},
			params = {{name = "format", title = "Format", type = .Choice, choices = {"PNG", "JPEG", "WebP"}, default_number = 2},
				{name = "quality", title = "Quality", type = .Int, lo = 1, hi = 100, step = 1, unit = "%", default_number = 82},
				{name = "scale", title = "Scale", type = .Float, lo = 0.25, hi = 2, step = 0.05, unit = "×", default_number = 1},
				{name = "lossless", title = "Lossless", type = .Bool}}},
		{name = "save", title = "Save file", group = "Outputs", icon = lucide.SAVE, effect = true,
			inputs = {{name = "picture", kind = PICTURE}}, outputs = {{name = "path", kind = TEXT}},
			params = {{name = "folder", title = "Folder", type = .Folder, default_text = "~/Pictures/Shots"},
				{name = "name", title = "Name", type = .Text, default_text = "shot-14"}}},
		{name = "upload", title = "Upload", group = "Outputs", icon = lucide.UPLOAD, effect = true,
			inputs = {{name = "picture", kind = PICTURE}}, outputs = {{name = "link", kind = TEXT}},
			params = {{name = "host", title = "Host", type = .List, placeholder = "The default host"}}},
		{name = "copy", title = "Copy link", group = "Outputs", icon = lucide.CLIPBOARD, effect = true,
			inputs = {{name = "text", kind = TEXT, multiple = true}}},
		{name = "notify", title = "Notify", group = "Outputs", icon = lucide.BELL, effect = true,
			inputs = {{name = "when", kind = flowgraph.ACTION}},
			params = {{name = "message", title = "Message", type = .Text, default_text = "Shot saved"}}},
	},
}

// Where each node stands, and the state the run left it in (the message under it).
Placed :: struct {
	kind:    Node_Kind,
	pos:     [2]f32,
	state:   ui.Graph_Node_State,
	message: string,
}

PLACED := [?]Placed{
	{.Capture, {0, 130}, .Done, "1280 × 800"},
	{.Annotate, {220, 130}, .Done, ""},
	{.Encode, {440, 40}, .Running, ""},
	{.Notify, {440, 290}, .Idle, ""},
	{.Save, {660, 0}, .Done, "~/Pictures/Shots/shot-14.webp"},
	{.Upload, {660, 150}, .Failed, "413: the picture is too large"},
	{.Copy, {660, 310}, .Skipped, ""},
}

// From a node of PLACED to another, by their places in it: an output to an input.
LINKS := [?][4]int{{0, 0, 1, 0}, {1, 0, 2, 0}, {1, 1, 3, 0}, {2, 0, 4, 0}, {2, 0, 5, 0}, {5, 0, 6, 0}}

UPLOAD_HOSTS := []string{"imgur", "sxcu", "0x0.st"}

graph_make :: proc(app: ^App) {
	ids: [len(PLACED)]u64
	for p, i in PLACED { ids[i] = flowgraph.node_add(&app.graph, &CATALOG, int(p.kind), p.pos) }
	for l in LINKS {
		_, _ = flowgraph.link(&app.graph, &CATALOG, {from_node = ids[l[0]], from_port = u32(l[1]), to_node = ids[l[2]], to_port = u32(l[3])})
	}
	append(&app.selected, ids[2])   // (Encode: the inspector shows it)
	graph_shown(app)
}

graph_destroy :: proc(app: ^App) {
	ui.node_inspector_destroy(&app.inspector)
	ui.flow_nodes_destroy(&app.flow)
	flowgraph.graph_free(&app.graph)
	delete(app.selected)
}

// The widget's nodes made again from the model: after each change, not at each frame.
@(private = "file")
graph_shown :: proc(app: ^App) {
	ui.flow_nodes_make(&app.flow, &app.graph, &CATALOG, {user = app, look = node_look})
}

@(private = "file")
node_look :: proc(user: rawptr, n: ^flowgraph.Node, def: ^flowgraph.Node_Def) -> (look: ui.Flow_Node_Look) {
	for p in PLACED {
		if int(p.kind) == n.kind { look.state, look.message = p.state, p.message }
	}
	switch Node_Kind(n.kind) {
	case .Capture:  look.subtitle = flowgraph.param_bool(&CATALOG, n, "pointer") ? "with the pointer" : "no pointer"
	case .Blur:     look.subtitle = fmt.tprintf("%.1f px", flowgraph.param_float(&CATALOG, n, "radius"))
	case .Annotate: look.subtitle = flowgraph.param_text(&CATALOG, n, "caption")
	case .Encode:   look.subtitle = fmt.tprintf("%s, %d %%", flowgraph.param_choice_text(&CATALOG, n, "format"), flowgraph.param_int(&CATALOG, n, "quality"))
	case .Save:     look.subtitle = flowgraph.param_text(&CATALOG, n, "folder")
	case .Upload:   look.subtitle = flowgraph.param_text(&CATALOG, n, "host")
	case .Copy:     look.subtitle = "to the clipboard"
	case .Notify:   look.subtitle = flowgraph.param_text(&CATALOG, n, "message")
	}
	return
}

@(private = "file")
upload_hosts :: proc(user: rawptr, n: ^flowgraph.Node, param: flowgraph.Param_Def) -> []string { return UPLOAD_HOSTS }

graph_build :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###graph_row") {
		kinds := [3]ui.Color{ui.hue_color(.Yellow), ui.hue_color(.Blue), ui.hue_color(.Green)}
		ui.next({width = ui.fill(), height = ui.fill()})
		events := ui.node_graph("###flow", &app.graph_view, app.flow.nodes[:], app.flow.links[:], app.selected[:], {
			user = app, kind_colors = kinds[:], icon_font = ui.lucide_icons(), snap = 10, minimap = true,
			can_link = proc(user: rawptr, l: ui.Graph_Link) -> bool {
				app := (^App)(user)
				return flowgraph.can_link(&app.graph, &CATALOG, ui.flow_link(l))
			},
		})
		// (the box is laid out after the first build: the view fits the nodes then)
		if app.builds == 2 { ui.graph_fit(&app.graph_view, app.flow.nodes[:]) }
		graph_apply(app, events)
		ui.spacer(ui.px(em))
		inspector_build(app, em)
	}
}

@(private = "file")
graph_apply :: proc(app: ^App, events: []ui.Graph_Event) {
	changed := false
	for e in events {
		switch v in e {
		case ui.Graph_Moved:
			flowgraph.nodes_move(&app.graph, v.nodes, v.delta)
			changed = true
		case ui.Graph_Linked:
			_, ok := flowgraph.link(&app.graph, &CATALOG, ui.flow_link(v.link))
			changed ||= ok
		case ui.Graph_Unlinked:
			flowgraph.unlink(&app.graph, ui.flow_link(v.link))
			changed = true
		case ui.Graph_Selected:
			clear(&app.selected)
			append(&app.selected, ..v.nodes)
		case ui.Graph_Deleted:
			for l in v.links { flowgraph.unlink(&app.graph, ui.flow_link(l)) }
			flowgraph.nodes_delete(&app.graph, &CATALOG, v.nodes)
			clear(&app.selected)
			changed = true
		case ui.Graph_Context, ui.Graph_Opened, ui.Graph_Dropped_Link:
		}
	}
	if changed { graph_shown(app) }
}

// The panel of the node selected: its icon and title, its parameters by its kind's schema, then the run in words.
@(private = "file")
inspector_build :: proc(app: ^App, em: f32) {
	ui.next({width = ui.px(em * 19), height = ui.fill(), axis = .Y})
	if ui.column(id = "###inspector") {
		n: ^flowgraph.Node
		if len(app.selected) == 1 { n = flowgraph.graph_node(&app.graph, app.selected[0]) }
		if n == nil {
			if ui.tags("weak") { ui.next({width = ui.fill()}); ui.paragraph("Select a node to see its parameters.###none") }
			return
		}
		def := flowgraph.node_def(&CATALOG, n)
		if ui.card(def.title, def.icon) {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			res := ui.node_inspector("###params", &app.inspector, &CATALOG, n, {user = app, lists = upload_hosts})
			if res.changed >= 0 {
				flowgraph.param_set(n, res.changed, res.value)
				graph_shown(app)
			}
		}
		if ui.card("The last run", lucide.HISTORY) {
			ui.next({width = ui.fill(), height = ui.children_sum(), radius = em * 0.4})
			if ui.well("###run", .Y) {
				ui.spacer(ui.px(em * 0.4))
				for p, i in PLACED {
					ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
					if ui.row(id = fmt.tprintf("###run%d", i)) {
						ui.spacer(ui.px(em * 0.7))
						intent: Maybe(ui.Intent)
						#partial switch p.state {
						case .Done:    intent = .Success
						case .Running: intent = .Info
						case .Failed:  intent = .Danger
						case .Skipped: intent = .Warning
						}
						ui.dot(fmt.tprintf("###dot%d", i), em * 0.55, intent)
						ui.spacer(ui.px(em * 0.6))
						ui.next({width = ui.fill(), height = ui.pct(1), font = ui.mono_font(), text_pad = 0})
						ui.label(fmt.tprintf("%-10s %v###state%d", CATALOG.nodes[int(p.kind)].name, p.state, i))
					}
				}
				ui.spacer(ui.px(em * 0.4))
			}
		}
	}
}
