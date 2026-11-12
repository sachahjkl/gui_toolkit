package ui

// node_graph: the build of a frame (the area, the nodes' boxes) and what the pointer and the keys do to the graph. The
// drawing is node_graph_draw.odin's.

import "core:math"
import "../draw"
import "../platform"

// A move of the pointer under this (logical px) from its press is a click, not a drag.
@(private) GRAPH_DRAG_PX :: 4
// A port is hit this far from its centre at least (logical px), and a wire finds a port this many times further.
@(private) GRAPH_PORT_HIT_PX :: 8
@(private) GRAPH_WIRE_REACH :: 1.8
// A link is hit this close to its curve (logical px).
@(private) GRAPH_LINK_HIT_PX :: 6
// The zoom glides toward what the wheel asked at this rate (per second, in its logarithm).
@(private) GRAPH_ZOOM_RATE :: 18
// An arrow key moves the selection this far (graph units) when the graph has no snap; with Shift ten times.
@(private) GRAPH_NUDGE :: 1
// The minimap: its size and its margin from the area's corner (logical px).
@(private) GRAPH_MINIMAP_SIZE :: [2]f32{200, 130}
@(private) GRAPH_MINIMAP_MARGIN :: 10
// What is drawn of a node reaches this far under it (its message), in ems: a node that far off the area is still drawn.
@(private) GRAPH_CULL_EM :: 2.5

// What a frame of the graph knows: the program's model and the shapes worked out from it.
@(private)
Node_Graph_Frame :: struct {
	view:     ^Graph_View,
	nodes:    []Graph_Node,
	links:    []Graph_Link,
	selected: []u64,
	o:        Graph_Options,
	area:     ^Box,
	geo:      []Node_Graph_Geometry,   // per node, graph units, the nodes being moved where they are moved to
	index:    map[u64]int,             // a node's index by its id
	sel:      map[u64]bool,            // the selected nodes
	events:   [dynamic]Graph_Event,
	sc, em:   f32,                     // the interface's scale; its em in graph units
}

// What is under a point of the area.
@(private)
Node_Graph_Hit_Kind :: enum u8 { None, Node, Port, Link, Minimap }

@(private)
Node_Graph_Hit :: struct {
	kind: Node_Graph_Hit_Kind,
	node: int,              // the node's index (Node, Port)
	port: Graph_Port_Ref,   // Port
	link: Graph_Link,       // Link
}

// The graph in a box of the size `next` gives it (else it fills). Returns what happened, in the temp allocator.
node_graph :: proc(id: string, view: ^Graph_View, nodes: []Graph_Node, links: []Graph_Link, selected: []u64, o: Graph_Options) -> []Graph_Event {
	s := gs()
	if !s.has_next || s.next_mod.width == nil { next_merge({width = fill()}) }
	if s.next_mod.height == nil { next_merge({height = fill()}) }
	area := build_box({.Clickable, .Focusable, .Scroll_Self, .Clip, .Middle_Click, .Ctrl_Wheel}, id)
	if view.zoom <= 0 { view.zoom = 1 }
	f := Node_Graph_Frame{view = view, nodes = nodes, links = links, selected = selected, o = o, area = area}
	f.sc = max(scale(), 0.01)
	f.em = font_size() / f.sc
	f.events = make([dynamic]Graph_Event, context.temp_allocator)
	f.index = make(map[u64]int, len(nodes), context.temp_allocator)
	f.sel = make(map[u64]bool, len(selected), context.temp_allocator)
	for n, i in nodes { f.index[n.id] = i }
	for x in selected { f.sel[x] = true }
	// (the area as last laid out: the pointer was over that)
	view.key, view.origin, view.size, view.scale, view.em = area.key, area.rect.min, area.rect.max - area.rect.min, f.sc, f.em

	node_graph_glide(s, view)
	node_graph_shapes(&f)
	hit := s.mouse_valid ? node_graph_hit(&f, s.mouse) : Node_Graph_Hit{}
	area.cursor = node_graph_cursor(&f, hit)
	sig := signal(area)
	node_graph_input(&f, s, sig)
	node_graph_shapes(&f)   // (what the input moved)
	// the link under the pointer is drawn thicker (not during a gesture: the pointer is busy)
	view.hover = nil
	if view.gesture == nil && s.mouse_valid && s.hot_key == area.key {
		if h := node_graph_hit(&f, s.mouse); h.kind == .Link { view.hover = h.link }
	}
	node_graph_build(&f)
	a11y_default(area, {role = .Group, name = "Graph", role_description = "node graph"})
	return f.events[:]
}

////////////////////////////////
// Shapes

// The view's offset and zoom, in frame px: where graph point `p` is from the area's top-left.
@(private)
node_graph_local :: proc(f: ^Node_Graph_Frame, p: [2]f32) -> [2]f32 {
	return (f.view.offset + p * graph_zoom(f.view)) * f.sc
}

// Whether node `i` follows the pointer now (a move gesture past its threshold).
@(private)
node_graph_moving :: proc(f: ^Node_Graph_Frame, i: int) -> bool {
	m, ok := f.view.gesture.(Graph_Gesture_Move)
	if !ok || !m.moved { return false }
	id := f.nodes[i].id
	return id == m.node || (!m.alone && f.sel[id])
}

@(private)
node_graph_shapes :: proc(f: ^Node_Graph_Frame) {
	if f.geo == nil { f.geo = make([]Node_Graph_Geometry, len(f.nodes), context.temp_allocator) }
	detail := graph_zoom(f.view) >= GRAPH_DETAIL_ZOOM
	delta: [2]f32
	if m, ok := f.view.gesture.(Graph_Gesture_Move); ok { delta = m.delta }
	for &n, i in f.nodes {
		body := detail && f.o.body != nil ? node_graph_body_height(f.view, n.id) : 0
		f.geo[i] = node_graph_geometry(&n, f.em, body, detail)
		if node_graph_moving(f, i) {
			f.geo[i].rect.min += delta
			f.geo[i].rect.max += delta
		}
	}
}

// A node's rectangle on the screen (frame px), by the area as last laid out.
@(private)
node_graph_screen_rect :: proc(f: ^Node_Graph_Frame, i: int) -> Rect {
	r := f.geo[i].rect
	o := f.view.origin
	return {o + node_graph_local(f, r.min), o + node_graph_local(f, r.max)}
}

// Whether node `i` shows in the area (its message under it counted).
@(private)
node_graph_visible :: proc(f: ^Node_Graph_Frame, i: int, area: Rect) -> bool {
	r := node_graph_screen_rect(f, i)
	r.max.y += GRAPH_CULL_EM * f.em * graph_zoom(f.view) * f.sc
	return node_graph_overlaps(r, area)
}

// The port of `ref` and its index on its side; ok false: no such port.
@(private)
node_graph_port :: proc(f: ^Node_Graph_Frame, ref: Graph_Port_Ref) -> (port: Graph_Port, index: int, ok: bool) {
	i, found := f.index[ref.node]
	if !found { return }
	ports := ref.side == .In ? f.nodes[i].inputs : f.nodes[i].outputs
	for p, k in ports { if p.id == ref.port { return p, k, true } }
	return
}

// A port's centre on the screen (frame px).
@(private)
node_graph_port_screen :: proc(f: ^Node_Graph_Frame, ref: Graph_Port_Ref) -> (at: [2]f32, ok: bool) {
	_, k, found := node_graph_port(f, ref)
	if !found { return }
	return f.view.origin + node_graph_local(f, node_graph_port_at(&f.geo[f.index[ref.node]], ref.side, k)), true
}

// The link that joins two ports of opposite sides, from the out one to the in one.
@(private)
node_graph_link_of :: proc(a, b: Graph_Port_Ref) -> Graph_Link {
	o, i := a, b
	if a.side == .In { o, i = b, a }
	return {from_node = o.node, from_port = o.port, to_node = i.node, to_port = i.port}
}

// Whether a link from port `from` may end on port `to`: another node, the other side, and the program's can_link (else
// the same kind).
@(private)
node_graph_compatible :: proc(f: ^Node_Graph_Frame, from, to: Graph_Port_Ref) -> bool {
	if from.side == to.side || from.node == to.node { return false }
	if f.o.can_link != nil { return f.o.can_link(f.o.user, node_graph_link_of(from, to)) }
	a, _, ok_a := node_graph_port(f, from)
	b, _, ok_b := node_graph_port(f, to)
	return ok_a && ok_b && a.kind == b.kind
}

// The colour of a port's kind (the accent when the program gave none).
@(private)
node_graph_kind_color :: proc(f: ^Node_Graph_Frame, kind: u8, accent: Color) -> Color {
	return int(kind) < len(f.o.kind_colors) ? f.o.kind_colors[kind] : accent
}

// The radius a port is hit within (frame px).
@(private)
node_graph_port_reach :: proc(f: ^Node_Graph_Frame) -> f32 {
	return max(GRAPH_PORT_EM * f.em * graph_zoom(f.view) * f.sc * 0.5 + 3 * f.sc, GRAPH_PORT_HIT_PX * f.sc)
}

////////////////////////////////
// Hit tests

@(private)
node_graph_hit :: proc(f: ^Node_Graph_Frame, p: [2]f32) -> (h: Node_Graph_Hit) {
	area := Rect{f.view.origin, f.view.origin + f.view.size}
	if !contains(area, p) { return }
	if f.o.minimap {
		if mm, ok := node_graph_minimap(f, area); ok && contains(mm.rect, p) { return {kind = .Minimap} }
	}
	// the ports first (they stand out of their node's sides), the nodes on top first
	reach := node_graph_port_reach(f)
	for i := len(f.nodes) - 1; i >= 0; i -= 1 {
		n := &f.nodes[i]
		r := node_graph_screen_rect(f, i)
		if !node_graph_overlaps(draw.rect_pad(r, reach), {p, p + 1}) { continue }
		for side in Graph_Port_Side {
			for port, k in (side == .In ? n.inputs : n.outputs) {
				c := f.view.origin + node_graph_local(f, node_graph_port_at(&f.geo[i], side, k))
				if node_graph_length(p - c) <= reach { return {kind = .Port, node = i, port = {n.id, port.id, side}} }
			}
		}
	}
	for i := len(f.nodes) - 1; i >= 0; i -= 1 {
		if contains(node_graph_screen_rect(f, i), p) { return {kind = .Node, node = i} }
	}
	best := GRAPH_LINK_HIT_PX * f.sc
	for l in f.links {
		a, ok_a := node_graph_port_screen(f, {l.from_node, l.from_port, .Out})
		b, ok_b := node_graph_port_screen(f, {l.to_node, l.to_port, .In})
		if !ok_a || !ok_b { continue }
		ca, cb := node_graph_curve(a, b, node_graph_curve_least(f))
		lo := [2]f32{min(a.x, b.x, ca.x, cb.x), min(a.y, b.y, ca.y, cb.y)} - best
		hi := [2]f32{max(a.x, b.x, ca.x, cb.x), max(a.y, b.y, ca.y, cb.y)} + best
		if !contains({lo, hi}, p) { continue }
		if d := node_graph_curve_distance(a, ca, cb, b, p); d <= best {
			best = d
			h = {kind = .Link, link = l}
		}
	}
	return
}

// How far a link leaves its out port before it bends (frame px).
@(private)
node_graph_curve_least :: proc(f: ^Node_Graph_Frame) -> f32 { return 3 * f.em * graph_zoom(f.view) * f.sc }

@(private)
node_graph_length :: proc(v: [2]f32) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y) }

@(private)
node_graph_cursor :: proc(f: ^Node_Graph_Frame, h: Node_Graph_Hit) -> platform.Cursor {
	switch g in f.view.gesture {
	case Graph_Gesture_Pan: return .Grabbing
	case Graph_Gesture_Move: return g.moved ? .Grabbing : .Arrow
	case Graph_Gesture_Wire: return .Crosshair
	case Graph_Gesture_Band: return .Crosshair
	case Graph_Gesture_Minimap: return .Grabbing
	}
	if key_held(.Space) { return .Grab }
	#partial switch h.kind {
	case .Port: return .Crosshair
	case .Link: return .Hand
	case .Minimap: return .Hand
	}
	return .Arrow
}

// The minimap's place on the screen and how the graph maps into it.
@(private)
Node_Graph_Minimap :: struct {
	rect:  Rect,     // frame px
	lo:    [2]f32,   // the graph point at its top-left (after its padding)
	k:     f32,      // frame px per graph unit
	pad:   [2]f32,   // where the graph starts in it
}

// The minimap in the bottom-right corner of `area`: what it shows is every node and the view. ok false: no room.
@(private)
node_graph_minimap :: proc(f: ^Node_Graph_Frame, area: Rect) -> (m: Node_Graph_Minimap, ok: bool) {
	size := GRAPH_MINIMAP_SIZE * f.sc
	margin := GRAPH_MINIMAP_MARGIN * f.sc
	if area.max.x - area.min.x < size.x + 2 * margin || area.max.y - area.min.y < size.y + 2 * margin { return }
	m.rect = {area.max - margin - size, area.max - margin}
	// the view's own rectangle, then each node's
	lo := graph_from_screen(f.view, area.min)
	hi := graph_from_screen(f.view, area.max)
	for g in f.geo {
		lo = {min(lo.x, g.rect.min.x), min(lo.y, g.rect.min.y)}
		hi = {max(hi.x, g.rect.max.x), max(hi.y, g.rect.max.y)}
	}
	inner := size - 2 * (4 * f.sc)
	ext := hi - lo
	if ext.x <= 0 || ext.y <= 0 { return }
	m.k = min(inner.x / ext.x, inner.y / ext.y)
	m.lo = lo
	m.pad = (size - ext * m.k) * 0.5
	return m, true
}

@(private)
node_graph_minimap_to_graph :: proc(m: Node_Graph_Minimap, p: [2]f32) -> [2]f32 { return m.lo + (p - m.rect.min - m.pad) / m.k }

@(private)
node_graph_minimap_from_graph :: proc(m: Node_Graph_Minimap, p: [2]f32) -> [2]f32 { return m.rect.min + m.pad + (p - m.lo) * m.k }

// The view centred on graph point `p`.
@(private)
node_graph_center_on :: proc(f: ^Node_Graph_Frame, p: [2]f32) {
	f.view.offset = f.view.size / f.sc * 0.5 - p * graph_zoom(f.view)
	f.view.zoom_to = 0
}

////////////////////////////////
// Input

// The zoom toward `zoom`, about `at` (logical px from the area's top-left): gliding there when animations are on.
@(private)
node_graph_zoom_toward :: proc(view: ^Graph_View, zoom: f32, at: [2]f32) {
	z := clamp(zoom, GRAPH_ZOOM_MIN, GRAPH_ZOOM_MAX)
	if !animations_on() {
		graph_zoom_about(view, z, at)
		view.zoom_to = 0
		return
	}
	view.zoom_to, view.zoom_at = z, at
}

// A step of the glide of the zoom (in its logarithm: each frame the same share of the way, in and out alike).
@(private)
node_graph_glide :: proc(s: ^State, view: ^Graph_View) {
	if view.zoom_to <= 0 { return }
	z := graph_zoom(view)
	k := s.dt > 0 ? 1 - math.exp(-s.dt * GRAPH_ZOOM_RATE) : 1
	next := math.exp(math.lerp(math.ln(z), math.ln(view.zoom_to), k))
	if abs(next - view.zoom_to) < view.zoom_to * 0.002 {
		next = view.zoom_to
		view.zoom_to = 0
	} else {
		keep_animating()
	}
	graph_zoom_about(view, next, view.zoom_at)
}

@(private)
node_graph_input :: proc(f: ^Node_Graph_Frame, s: ^State, sig: Signal) {
	view := f.view
	area := f.area
	local := (s.mouse - view.origin) / f.sc   // the pointer, logical px from the area's top-left

	// the wheel: Ctrl zooms about the pointer, else it moves the view (a touchpad's two fingers both ways)
	if sig.scrolled != {} {
		if .Ctrl in sig.mods {
			from := view.zoom_to > 0 ? view.zoom_to : graph_zoom(view)
			node_graph_zoom_toward(view, from * math.pow(f32(GRAPH_ZOOM_STEP), -sig.scrolled.y), local)
		} else {
			d := sig.scrolled
			if .Shift in sig.mods && d.x == 0 { d = {d.y, 0} }
			view.offset -= {d.x * wheel_step(area, .X), d.y * wheel_step(area, .Y)} / f.sc
		}
	}

	// presses start a gesture
	if s.pressed_key[.Middle] == area.key && view.gesture == nil {
		view.gesture = Graph_Gesture_Pan{button = .Middle, press = s.press_pos[.Middle], from = view.offset}
	}
	if sig.pointer_pressed { node_graph_press(f, s, sig) }
	if sig.double_clicked {
		if h := node_graph_hit(f, s.press_pos[.Left]); h.kind == .Node {
			append(&f.events, Graph_Opened{node = f.nodes[h.node].id})
		}
	}
	if sig.right_clicked {
		h := node_graph_hit(f, s.mouse)
		e := Graph_Context{at = graph_from_screen(view, s.mouse)}
		#partial switch h.kind {
		case .Node: e.node = f.nodes[h.node].id
		case .Port: e.node, e.port = h.port.node, h.port
		}
		append(&f.events, e)
	}

	node_graph_follow(f, s, sig)
	if s.focus_key == area.key { node_graph_keys(f) }
}

// A left press on the area: what is under it says which gesture starts.
@(private)
node_graph_press :: proc(f: ^Node_Graph_Frame, s: ^State, sig: Signal) {
	view := f.view
	at := s.press_pos[.Left]
	if view.gesture != nil { return }
	if key_held(.Space) {
		view.gesture = Graph_Gesture_Pan{button = .Left, press = at, from = view.offset}
		return
	}
	additive := .Shift in sig.mods || .Ctrl in sig.mods
	h := node_graph_hit(f, at)
	switch h.kind {
	case .Minimap:
		view.gesture = Graph_Gesture_Minimap{}
		if mm, ok := node_graph_minimap(f, {view.origin, view.origin + view.size}); ok { node_graph_center_on(f, node_graph_minimap_to_graph(mm, at)) }
	case .Port:
		view.link = nil
		wire := Graph_Gesture_Wire{from = h.port, at = graph_from_screen(view, at)}
		if h.port.side == .In {
			// an in port with a link: that link comes off it, held by its other end
			for l in f.links {
				if l.to_node == h.port.node && l.to_port == h.port.port {
					wire.from = {l.from_node, l.from_port, .Out}
					wire.detached = l
				}
			}
		}
		view.gesture = wire
	case .Node:
		view.link = nil
		id := f.nodes[h.node].id
		if additive {
			// Shift / Ctrl: the node in or out of the selection; one taken out is not dragged
			out := make([dynamic]u64, 0, len(f.selected) + 1, context.temp_allocator)
			for x in f.selected { if x != id { append(&out, x) } }
			if !f.sel[id] { append(&out, id) }
			append(&f.events, Graph_Selected{nodes = out[:]})
			if !f.sel[id] { view.gesture = Graph_Gesture_Move{node = id, press = at} }
		} else if f.sel[id] {
			view.gesture = Graph_Gesture_Move{node = id, press = at, collapse = len(f.selected) > 1}
		} else {
			one := make([]u64, 1, context.temp_allocator)
			one[0] = id
			append(&f.events, Graph_Selected{nodes = one})
			view.gesture = Graph_Gesture_Move{node = id, alone = true, press = at}
		}
	case .Link:
		view.link = h.link
		if len(f.selected) > 0 { append(&f.events, Graph_Selected{}) }
	case .None:
		view.link = nil
		g := graph_from_screen(view, at)
		view.gesture = Graph_Gesture_Band{from = g, to = g, press = at, additive = additive}
	}
}

// The gesture in progress follows the pointer; its button's release ends it.
@(private)
node_graph_follow :: proc(f: ^Node_Graph_Frame, s: ^State, sig: Signal) {
	view := f.view
	area := f.area
	threshold := GRAPH_DRAG_PX * f.sc
	held := s.active_key[.Left] == area.key
	// (the button let go elsewhere, or the window left: no release comes to end it)
	dropped := !held && !sig.released
	switch &g in view.gesture {
	case Graph_Gesture_Pan:
		if s.active_key[g.button] != area.key { view.gesture = nil; break }
		view.offset = g.from + (s.mouse - g.press) / f.sc
		view.zoom_to = 0
	case Graph_Gesture_Move:
		if dropped { view.gesture = nil; break }
		if !g.moved && node_graph_length(s.mouse - g.press) >= threshold { g.moved = true }
		if g.moved {
			raw := (s.mouse - g.press) / (f.sc * graph_zoom(view))
			g.delta = raw
			if f.o.snap > 0 {
				if i, ok := f.index[g.node]; ok {
					p := f.nodes[i].pos + raw
					g.delta = {math.round(p.x / f.o.snap), math.round(p.y / f.o.snap)} * f.o.snap - f.nodes[i].pos
				}
			}
		}
		if held { break }
		if g.moved && g.delta != {} {
			append(&f.events, Graph_Moved{nodes = node_graph_moved_ids(f, g), delta = g.delta})
		} else if !g.moved && g.collapse {
			one := make([]u64, 1, context.temp_allocator)
			one[0] = g.node
			append(&f.events, Graph_Selected{nodes = one})
		}
		view.gesture = nil
	case Graph_Gesture_Wire:
		if dropped { view.gesture = nil; break }
		g.at = graph_from_screen(view, s.mouse)
		g.target = node_graph_wire_target(f, g.from, s.mouse)
		if held { break }
		node_graph_wire_end(f, &g)
		view.gesture = nil
	case Graph_Gesture_Band:
		if dropped { view.gesture = nil; break }
		g.to = graph_from_screen(view, s.mouse)
		if !g.moved && node_graph_length(s.mouse - g.press) >= threshold { g.moved = true }
		if held { break }
		if g.moved {
			band := Rect{{min(g.from.x, g.to.x), min(g.from.y, g.to.y)}, {max(g.from.x, g.to.x), max(g.from.y, g.to.y)}}
			out := make([dynamic]u64, 0, len(f.nodes), context.temp_allocator)
			if g.additive { append(&out, ..f.selected) }
			for n, i in f.nodes {
				if node_graph_overlaps(f.geo[i].rect, band) && !(g.additive && f.sel[n.id]) { append(&out, n.id) }
			}
			append(&f.events, Graph_Selected{nodes = out[:]})
		} else if !g.additive && len(f.selected) > 0 {
			append(&f.events, Graph_Selected{})   // a click on nothing
		}
		view.gesture = nil
	case Graph_Gesture_Minimap:
		if !held { view.gesture = nil; break }
		if mm, ok := node_graph_minimap(f, {view.origin, view.origin + view.size}); ok { node_graph_center_on(f, node_graph_minimap_to_graph(mm, s.mouse)) }
	}
	if view.gesture != nil { wake_within(gs(), 1) }
}

// The nodes a move gesture moved: the one pressed, alone or with the selection.
@(private)
node_graph_moved_ids :: proc(f: ^Node_Graph_Frame, g: Graph_Gesture_Move) -> []u64 {
	if g.alone {
		one := make([]u64, 1, context.temp_allocator)
		one[0] = g.node
		return one
	}
	out := make([dynamic]u64, 0, len(f.selected) + 1, context.temp_allocator)
	append(&out, ..f.selected)
	if !f.sel[g.node] { append(&out, g.node) }
	return out[:]
}

// The port a wire from `from` would link to with the pointer at `p`: the nearest one it may link to, within reach.
@(private)
node_graph_wire_target :: proc(f: ^Node_Graph_Frame, from: Graph_Port_Ref, p: [2]f32) -> (target: Maybe(Graph_Port_Ref)) {
	reach := node_graph_port_reach(f) * GRAPH_WIRE_REACH
	best := reach
	side: Graph_Port_Side = from.side == .Out ? .In : .Out
	for &n, i in f.nodes {
		if n.id == from.node { continue }
		if !node_graph_overlaps(draw.rect_pad(node_graph_screen_rect(f, i), reach), {p, p + 1}) { continue }
		for port, k in (side == .In ? n.inputs : n.outputs) {
			c := f.view.origin + node_graph_local(f, node_graph_port_at(&f.geo[i], side, k))
			d := node_graph_length(p - c)
			ref := Graph_Port_Ref{n.id, port.id, side}
			if d <= best && node_graph_compatible(f, from, ref) {
				best = d
				target = ref
			}
		}
	}
	return
}

// A wire let go: a link made (replacing what its in port had), a link taken off and dropped, or one dropped on nothing.
@(private)
node_graph_wire_end :: proc(f: ^Node_Graph_Frame, g: ^Graph_Gesture_Wire) {
	detached, had := g.detached.?
	t, on_port := g.target.?
	if !on_port {
		if had {
			append(&f.events, Graph_Unlinked{link = detached})
		} else {
			append(&f.events, Graph_Dropped_Link{from = g.from, at = g.at})
		}
		return
	}
	l := node_graph_link_of(g.from, t)
	if had && detached == l { return }   // back where it was
	if had { append(&f.events, Graph_Unlinked{link = detached}) }
	for x in f.links { if x == l && !(had && x == detached) { return } }   // there already
	replaced: Maybe(Graph_Link)
	if in_port, _, ok := node_graph_port(f, {l.to_node, l.to_port, .In}); ok && !in_port.multiple {
		for x in f.links {
			if x.to_node == l.to_node && x.to_port == l.to_port && !(had && x == detached) { replaced = x }
		}
	}
	append(&f.events, Graph_Linked{link = l, replaced = replaced})
}

@(private)
node_graph_keys :: proc(f: ^Node_Graph_Frame) {
	view := f.view
	if key_press(.Escape) {
		if view.gesture != nil {
			view.gesture = nil
		} else if len(f.selected) > 0 || view.link != nil {
			view.link = nil
			append(&f.events, Graph_Selected{})
		}
	}
	if view.gesture != nil { return }
	if key_press(.Delete) || key_press(.Backspace) { node_graph_delete(f) }
	if key_press(.A, {.Ctrl}) {
		all := make([]u64, len(f.nodes), context.temp_allocator)
		for n, i in f.nodes { all[i] = n.id }
		append(&f.events, Graph_Selected{nodes = all})
	}
	if key_press(.F) { graph_fit(view, f.nodes, view.size / f.sc) }
	middle := view.size / f.sc * 0.5
	if key_press(.Equal) || key_press(.Equal, {.Shift}) || key_press(.Num_Add) { node_graph_zoom_toward(view, graph_zoom(view) * GRAPH_ZOOM_STEP, middle) }
	if key_press(.Minus) || key_press(.Num_Subtract) { node_graph_zoom_toward(view, graph_zoom(view) / GRAPH_ZOOM_STEP, middle) }
	if len(f.selected) == 0 { return }
	step := f.o.snap > 0 ? f.o.snap : GRAPH_NUDGE
	dirs := [?]struct { key: platform.Key, d: [2]f32 }{{.Left, {-1, 0}}, {.Right, {1, 0}}, {.Up, {0, -1}}, {.Down, {0, 1}}}
	for it in dirs {
		n := 0
		if key_press(it.key) { n = 1 }
		if key_press(it.key, {.Shift}) { n = 10 }
		if n == 0 { continue }
		nodes := make([]u64, len(f.selected), context.temp_allocator)
		copy(nodes, f.selected)
		append(&f.events, Graph_Moved{nodes = nodes, delta = it.d * step * f32(n)})
	}
}

// Delete: the nodes selected, the link selected and the links of those nodes.
@(private)
node_graph_delete :: proc(f: ^Node_Graph_Frame) {
	l, has_link := f.view.link.?
	if len(f.selected) == 0 && !has_link { return }
	nodes := make([]u64, len(f.selected), context.temp_allocator)
	copy(nodes, f.selected)
	out := make([dynamic]Graph_Link, 0, 8, context.temp_allocator)
	if has_link { append(&out, l) }
	for x in f.links {
		if has_link && x == l { continue }
		if f.sel[x.from_node] || f.sel[x.to_node] { append(&out, x) }
	}
	f.view.link = nil
	append(&f.events, Graph_Deleted{nodes = nodes, links = out[:]})
}
