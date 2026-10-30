package devtools

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "../platform"
import "../ui"

// The accessibility side: the tree a screen reader gets (ui.a11y_tree, the toolkit's own nodes, not a guess from the
// boxes), and its actions, sent as an assistive technology's would be (ui.a11y_inject). A script that says "press the
// button named Send" tests what a reader can do, and does not break when the layout moves.

// The name in the protocol's vocabulary (Chrome's), for what has a different one; else the role's name in lower case
// (Check_Box: checkbox).
@(private)
ax_role_name :: proc(role: platform.A11y_Role) -> string {
	#partial switch role {
	case .Window, .Root_Web_Area:              return "RootWebArea"
	case .Label:                               return "StaticText"
	case .Text_Input, .Multiline_Text_Input:   return "textbox"
	case .Search_Input:                        return "searchbox"
	case .Radio_Button:                        return "radio"
	case .Scroll_View:                         return "scrollable"
	case .Combo_Box, .Editable_Combo_Box:      return "combobox"
	case .Generic_Container:                   return "generic"
	}
	s, _ := strings.remove_all(fmt.tprintf("%v", role), "_", context.temp_allocator)
	return strings.to_lower(s, context.temp_allocator)
}

// The name a reader says: its label, else the value of a text node, else a field's placeholder.
@(private)
ax_name_of :: proc(u: ^platform.A11y_Update, i: int) -> string {
	if n := platform.a11y_node_string(u, i, .Label); n != "" { return n }
	if platform.A11y_Role(u.nodes[i].role) == .Label { return platform.a11y_node_string(u, i, .Value) }
	return platform.a11y_node_string(u, i, .Placeholder)
}

@(private)
ax_write_node :: proc(sb: ^strings.Builder, srv: ^Server, u: ^platform.A11y_Update, i: int, parent: map[u64]u64) {
	n := u.nodes[i]
	role := platform.A11y_Role(n.role)
	fmt.sbprintf(sb, `{{"nodeId":"%x","ignored":false,"role":{{"type":"role","value":%s}},"name":{{"type":"computedString","value":%s}},"backendDOMNodeId":%d`, n.id, json_quote(ax_role_name(role)), json_quote(ax_name_of(u, i)), i + 1)
	if role != .Label {
		if v := platform.a11y_node_string(u, i, .Value); v != "" { fmt.sbprintf(sb, `,"value":{{"type":"string","value":%s}}`, json_quote(v)) }
	}
	if d := platform.a11y_node_string(u, i, .Description); d != "" { fmt.sbprintf(sb, `,"description":{{"type":"computedString","value":%s}}`, json_quote(d)) }
	strings.write_string(sb, `,"properties":[`)
	count := 0
	prop :: proc(sb: ^strings.Builder, count: ^int, name, kind, value: string) {
		if count^ > 0 { strings.write_byte(sb, ',') }
		count^ += 1
		fmt.sbprintf(sb, `{{"name":"%s","value":{{"type":"%s","value":%s}}}}`, name, kind, value)
	}
	if n.id == u.focus { prop(sb, &count, "focused", "boolean", "true") }
	if .Focus in n.actions { prop(sb, &count, "focusable", "boolean", "true") }
	if .Disabled in n.flags { prop(sb, &count, "disabled", "boolean", "true") }
	if .Read_Only in n.flags { prop(sb, &count, "readonly", "boolean", "true") }
	if .Required in n.flags { prop(sb, &count, "required", "boolean", "true") }
	if .Busy in n.flags { prop(sb, &count, "busy", "boolean", "true") }
	if .Modal in n.flags { prop(sb, &count, "modal", "boolean", "true") }
	if .Has_Expanded in n.flags { prop(sb, &count, "expanded", "boolean", .Expanded in n.flags ? "true" : "false") }
	if .Has_Selected in n.flags { prop(sb, &count, "selected", "boolean", .Selected in n.flags ? "true" : "false") }
	for p in platform.a11y_node_props(u, i) {
		#partial switch p.kind {
		case .Toggled:
			prop(sb, &count, "checked", "tristate", p.a == 1 ? `"true"` : p.a == 2 ? `"mixed"` : `"false"`)
		case .Numeric_Value:     prop(sb, &count, "valuetext", "number", fmt.tprintf("%g", p.f))
		case .Min_Numeric_Value: prop(sb, &count, "valuemin", "number", fmt.tprintf("%g", p.f))
		case .Max_Numeric_Value: prop(sb, &count, "valuemax", "number", fmt.tprintf("%g", p.f))
		case .Level:             prop(sb, &count, "level", "integer", fmt.tprintf("%d", p.a))
		}
	}
	strings.write_string(sb, `]`)
	if par, ok := parent[n.id]; ok { fmt.sbprintf(sb, `,"parentId":"%x"`, par) }
	strings.write_string(sb, `,"childIds":[`)
	for c, k in platform.a11y_node_children(u, i) {
		if k > 0 { strings.write_byte(sb, ',') }
		fmt.sbprintf(sb, `"%x"`, c)
	}
	strings.write_string(sb, `]`)
	// (not the protocol's: what a tool needs and has no DOM to ask)
	if .Has_Bounds in n.flags {
		d := dpi(srv)
		fmt.sbprintf(sb, `,"bounds":{{"x":%.1f,"y":%.1f,"width":%.1f,"height":%.1f}}`, n.bounds[0] / d, n.bounds[1] / d, (n.bounds[2] - n.bounds[0]) / d, (n.bounds[3] - n.bounds[1]) / d)
	}
	strings.write_string(sb, `,"actions":[`)
	count = 0
	for a in platform.A11y_Action {
		if a not_in n.actions { continue }
		fmt.sbprintf(sb, count == 0 ? `"%v"` : `,"%v"`, a)
		count += 1
	}
	strings.write_string(sb, `]}`)
}

@(private)
ax_parents :: proc(u: ^platform.A11y_Update) -> map[u64]u64 {
	parent := make(map[u64]u64, len(u.nodes), context.temp_allocator)
	for n, i in u.nodes { for c in platform.a11y_node_children(u, i) { parent[c] = n.id } }
	return parent
}

// The nodes that answer to a role and a name (case ignored; a name is contained in the node's, `exact` for all of it).
@(private)
ax_matches :: proc(u: ^platform.A11y_Update, p: json.Object) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	role := strings.to_lower(str(p["role"]), context.temp_allocator)
	name := strings.to_lower(str(p["accessibleName"]) != "" ? str(p["accessibleName"]) : str(p["name"]), context.temp_allocator)
	exact := bool_of(p["exact"])
	for n, i in u.nodes {
		if role != "" && strings.to_lower(ax_role_name(platform.A11y_Role(n.role)), context.temp_allocator) != role { continue }
		if name != "" {
			have := strings.to_lower(ax_name_of(u, i), context.temp_allocator)
			if exact ? have != name : !strings.contains(have, name) { continue }
		}
		append(&out, i)
	}
	return out
}

@(private)
ax_write_nodes :: proc(sb: ^strings.Builder, srv: ^Server, u: ^platform.A11y_Update, only: []int, all: bool) {
	parent := ax_parents(u)
	strings.write_string(sb, `{"nodes":[`)
	if all {
		for _, i in u.nodes {
			if i > 0 { strings.write_byte(sb, ',') }
			ax_write_node(sb, srv, u, i, parent)
		}
	} else {
		for i, k in only {
			if k > 0 { strings.write_byte(sb, ',') }
			ax_write_node(sb, srv, u, i, parent)
		}
	}
	strings.write_string(sb, "]}")
}

@(private)
ax_action_of :: proc(name: string) -> (platform.A11y_Action, bool) {
	for a in platform.A11y_Action {
		if strings.equal_fold(fmt.tprintf("%v", a), name) { return a, true }
	}
	return .Click, false
}

// Toolkit.axAction {role? name? exact? index? nodeId? action? value?}. Nothing to answer but the node asked of: the
// action is this next build's, as a reader's would be.
@(private)
ax_action :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State, p: json.Object) -> string {
	u := ui.a11y_tree(s)
	action, known := ax_action_of(str(p["action"]) != "" ? str(p["action"]) : "Click")
	if !known { return "no such action (A11y_Action: Click, Focus, Set_Value, Increment...)" }
	node := -1
	if id := str(p["nodeId"]); id != "" {
		for n, i in u.nodes { if fmt.tprintf("%x", n.id) == id { node = i } }
	} else {
		ms := ax_matches(u, p)
		idx := int(num(p["index"]))
		if idx >= 0 && idx < len(ms) { node = ms[idx] }
	}
	if node < 0 { return "no accessible node with that role and name" }
	n := u.nodes[node]
	if action not_in n.actions { return fmt.tprintf("the node does not offer %v", action) }
	r := platform.A11y_Request{action = action, target = n.id}
	if v, has := p["value"]; has {
		#partial switch x in v {
		case json.String:
			r.data, r.value = .Value, x
		case json.Integer, json.Float:
			r.data, r.num = .Numeric_Value, num(v)
		}
	}
	ui.a11y_inject(s, r)
	platform.wake(srv.win)
	fmt.sbprintf(sb, `{{"nodeId":"%x","name":%s}}`, n.id, json_quote(ax_name_of(u, node)))
	return ""
}

// Toolkit.axAudit: what a reader cannot name (ui.a11y_unnamed).
@(private)
ax_audit :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State) {
	strings.write_string(sb, `{"unnamed":[`)
	d := f32(dpi(srv))
	for b, i in ui.a11y_unnamed(s) {
		if i > 0 { strings.write_byte(sb, ',') }
		fmt.sbprintf(sb, `{{"key":"%x","name":%s,"x":%.1f,"y":%.1f,"w":%.1f,"h":%.1f}}`, u64(b.key), json_quote(b.name), b.rect.min.x / d, b.rect.min.y / d, (b.rect.max.x - b.rect.min.x) / d, (b.rect.max.y - b.rect.min.y) / d)
	}
	strings.write_string(sb, "]}")
}
