package ui

// The parameters of a flowgraph node as controls, drawn from its kind's schema (flowgraph.Param_Def) with no code per
// kind: a number (Int, Float), a toggle (Bool), a colour and its picker (Color), a segmented choice or a list (Choice), a
// text field (Text), a path and its "Choose…" (Folder), a list the program gives (List). The schema's words (titles, units,
// choices, placeholders) are the program's English (i18n.later), shown in the language in use; the List's names are data.
//
// The widget changes nothing: it returns the parameter changed and its new value, and the program applies it
// (flowgraph.param_set) after its undo step, which the result says when to take (`new_step`: a slider dragged is one).
//
//	res := ui.node_inspector("###params", &app.inspector, &CATALOG, node)
//	if res.changed >= 0 {
//		if res.new_step { undo.push(&app.history, flowgraph.graph_clone(app.graph), 100, graph_free) }
//		flowgraph.param_set(node, res.changed, res.value)
//	}

import "core:fmt"
import "core:math"
import "core:strings"
import flowgraph "../flowgraph"
import i18n "../i18n"
import lucide "../lucide"

// What the inspector keeps between frames. Its fields are made for one node: another node (or `node` set to 0, after the
// program changed the parameters itself: an undo) makes them again.
Node_Inspector :: struct {
	node:        u64,                                   // the node the fields were made for
	texts:       [flowgraph.PARAMS_MAX]Text_Field,      // Text and Folder
	color:       Color_Pick,
	color_open:  int,                                   // the parameter whose picker is open, plus one (0: none)
	last_change: [2]u64,                                // the node and the parameter (plus one) of the last change ({}: none)
}

Node_Inspector_Options :: struct {
	user:  rawptr,
	lists: proc(user: rawptr, n: ^flowgraph.Node, param: flowgraph.Param_Def) -> []string,   // a List parameter's names
	default_text: string,   // a List's first entry, its empty value, when its placeholder is "" ("The default")
}

Node_Inspector_Result :: struct {
	changed:     int,               // the parameter changed this frame (-1: none)
	value:       flowgraph.Param,   // its new value (its text in the temp allocator: param_set copies it)
	new_step:    bool,              // the change starts a new undo step: another parameter or node than the last change
	pick_folder: int,               // a Folder's "Choose…" was pressed (-1: none): the program opens the dialog off this thread
	typing:      bool,              // a text field has the keyboard: the program's own keys wait
}

node_inspector_destroy :: proc(ins: ^Node_Inspector) {
	for &f in ins.texts { field_destroy(&f) }
	color_pick_destroy(&ins.color)
	ins^ = {}
}

// The controls of `n`'s parameters, one under the other, each with its title, in a column of the width `next` gives.
node_inspector :: proc(id: string, ins: ^Node_Inspector, cat: ^flowgraph.Catalog, n: ^flowgraph.Node, opts: Node_Inspector_Options = {}) -> (res: Node_Inspector_Result) {
	res.changed, res.pick_folder = -1, -1
	def := flowgraph.node_def(cat, n)
	if def == nil { return }
	if ins.node != n.id {
		// (another node, or the parameters changed under the fields: they show its values)
		ins.node = n.id
		ins.color_open = 0
		for d, i in def.params {
			if i >= flowgraph.PARAMS_MAX { break }
			if d.type == .Text || d.type == .Folder { field_set(&ins.texts[i], n.params[i].text) }
		}
	}
	em := font_size()
	if !gs().has_next { next({width = fill(), height = children_sum()}) }
	if column(id = id) {
		for d, i in def.params {
			if i >= flowgraph.PARAMS_MAX { break }
			if i > 0 { spacer(px(math.round(em * 0.5))) }
			next({width = fill(), height = children_sum()})
			if column(id = fmt.tprintf("###param_%d", i)) {
				if d.type != .Bool {
					next({width = fill(), height = px(math.round(em * 1.6))})
					label(fmt.tprintf("%s###title", i18n.tr(d.title)))
				}
				value, changed := node_param_control(ins, n, i, d, em, opts, &res)
				if changed {
					res.changed, res.value = i, value
					key := [2]u64{n.id, u64(i + 1)}
					res.new_step = ins.last_change != key
					ins.last_change = key
				}
			}
		}
	}
	return
}

// One parameter's control: its new value when it changed.
@(private = "file")
node_param_control :: proc(ins: ^Node_Inspector, n: ^flowgraph.Node, i: int, d: flowgraph.Param_Def, em: f32, opts: Node_Inspector_Options, res: ^Node_Inspector_Result) -> (value: flowgraph.Param, changed: bool) {
	p := n.params[i]
	value = p
	row_height := px(math.round(em * 1.9))
	switch d.type {
	case .Int:
		v := int(p.number)
		lo, hi: Maybe(int)
		if d.hi > d.lo { lo, hi = int(d.lo), int(d.hi) }
		next({width = fill(), height = row_height})
		if number("###number", &v, lo, hi, max(int(d.step), 0), unit = i18n.tr(d.unit), track = d.hi > d.lo) {
			value.number, changed = f64(v), true
		}
	case .Float:
		v := p.number
		lo, hi: Maybe(f64)
		if d.hi > d.lo { lo, hi = d.lo, d.hi }
		next({width = fill(), height = row_height})
		if number("###number", &v, lo, hi, d.step, unit = i18n.tr(d.unit), track = d.hi > d.lo) {
			value.number, changed = v, true
		}
	case .Bool:
		on := p.number != 0
		next({width = fill(), height = row_height})
		toggle("###toggle", i18n.tr(d.title), &on)
		if on != (p.number != 0) { value.number, changed = on ? 1 : 0, true }
	case .Choice:
		chosen := clamp(int(p.number), 0, max(len(d.choices) - 1, 0))
		was := chosen
		next({width = fill(), height = row_height})
		words := make([]string, len(d.choices), context.temp_allocator)
		for c, k in d.choices { words[k] = i18n.tr(c) }
		if len(words) <= 3 { segmented("choice", words, &chosen) } else { dropdown("###choice", words, &chosen) }
		if chosen != was { value.number, changed = f64(chosen), true }
	case .Color:
		open := ins.color_open == i + 1
		next({width = fill(), height = row_height})
		if button("###color", flowgraph.color_text(p.color), lucide.PALETTE).clicked {
			ins.color_open = open ? 0 : i + 1
			if !open { color_pick_set(&ins.color, srgba_of_rgba8(p.color), {format = .Hex}) }
		}
		if open {
			spacer(px(math.round(em * 0.4)))
			if color_picker("###picker", &ins.color) {
				value.color, changed = rgba8_of_srgba(color_pick_rgba(&ins.color)), true
			}
		}
	case .Text, .Folder:
		next({width = fill(), height = row_height})
		r := line_edit("###text", &ins.texts[i], i18n.tr(d.placeholder), clearable = true)
		res.typing ||= r.focused
		if r.changed {
			text := strings.trim_space(field_string(&ins.texts[i]))
			if text != p.text { value.text, changed = strings.clone(text, context.temp_allocator), true }
		}
		if d.type == .Folder {
			spacer(px(math.round(em * 0.4)))
			next({width = text_size(em * 0.8), height = row_height})
			if button("choose", i18n.tr("Choose…")).clicked { res.pick_folder = i }
		}
	case .List:
		names: []string
		if opts.lists != nil { names = opts.lists(opts.user, n, d) }
		items := make([]string, len(names) + 1, context.temp_allocator)
		items[0] = d.placeholder != "" ? i18n.tr(d.placeholder) : (opts.default_text != "" ? i18n.tr(opts.default_text) : i18n.tr("The default"))
		chosen := 0
		for name, k in names {
			items[k + 1] = name
			if name == p.text { chosen = k + 1 }
		}
		was := chosen
		next({width = fill(), height = row_height})
		dropdown("###list", items, &chosen)
		if chosen != was { value.text, changed = chosen > 0 ? names[chosen - 1] : "", true }
	}
	return
}

@(private = "file")
srgba_of_rgba8 :: proc(c: [4]u8) -> Srgba {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
}

@(private = "file")
rgba8_of_srgba :: proc(c: Srgba) -> [4]u8 {
	return {u8(math.round(clamp(c.r, 0, 1) * 255)), u8(math.round(clamp(c.g, 0, 1) * 255)), u8(math.round(clamp(c.b, 0, 1) * 255)), u8(math.round(clamp(c.a, 0, 1) * 255))}
}
