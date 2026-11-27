package ui

// node_graph: the build of a frame (the area, the nodes' boxes) and what the pointer and the keys do to the graph. The
// drawing is node_graph_draw.odin's.

import "core:fmt"
import "core:math"
import "../draw"
import "../flowgraph"
import "../font"
import i18n "../i18n"
import "../platform"

// A move of the pointer under this (logical px) from its press is a click, not a drag.
@(private) GRAPH_DRAG_PX :: 4
// A port is hit this far from its centre at least (logical px), and a wire finds a port this many times further.
@(private) GRAPH_PORT_HIT_PX :: 8
@(private) GRAPH_WIRE_REACH :: 1.8
// A link is hit this close to its curve (logical px at the zoom 1, within GRAPH_LINK_ZOOMS; at least half its drawn width
// and GRAPH_LINK_HIT_LEAST_PX more).
@(private) GRAPH_LINK_HIT_PX :: 6
@(private) GRAPH_LINK_HIT_LEAST_PX :: 2
// A link's tooltip avoids this many pieces of its curve (their ends).
@(private) GRAPH_LINK_TIP_POINTS :: 48
// The zoom glides toward what the wheel asked at this rate (per second, in its logarithm).
@(private) GRAPH_ZOOM_RATE :: 18
// An arrow key moves the selection this far (graph units) when the graph has no snap; with Shift ten times.
@(private) GRAPH_NUDGE :: 1
// The minimap's default size: this share of the area's width, within these widths (logical px), its height this ratio of
// its width and at most this share of the area's height. Its margin from the area's corner (logical px).
@(private) GRAPH_MINIMAP_SHARE :: 0.25
@(private) GRAPH_MINIMAP_LEAST :: 100
@(private) GRAPH_MINIMAP_MOST :: 200
@(private) GRAPH_MINIMAP_RATIO :: 0.65
@(private) GRAPH_MINIMAP_TALL :: 0.35
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
	font:     font.Font_Id,            // the titles'
	down:     bool,                    // Graph_Direction.Down
	// a move let go in this frame: the program applies its Graph_Moved after the build, so until then its nodes are
	// drawn where they were let go (drawn back at their old place, they would jump there and back)
	landed:   Maybe(Graph_Gesture_Move),
}

// What is under a point of the area.
@(private)
Node_Graph_Hit_Kind :: enum u8 { None, Node, Port, Link, Minimap }

@(private)
Node_Graph_Hit :: struct {
	kind: Node_Graph_Hit_Kind,
	node: int,              // the node's index (Node, Port)
	port: flowgraph.Port_Ref,   // Port
	link: Graph_Link,       // Link
	links: int,             // Link: how many links are under the point (within the hit width)
	pick:  int,             // Link: the place of `link` among them, from 1, in the links' order
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
	f.font = top_style().font
	f.down = o.direction == .Down
	f.events = make([dynamic]Graph_Event, context.temp_allocator)
	f.index = make(map[u64]int, len(nodes), context.temp_allocator)
	f.sel = make(map[u64]bool, len(selected), context.temp_allocator)
	for n, i in nodes { f.index[n.id] = i }
	for x in selected { f.sel[x] = true }
	// (the area as last laid out: the pointer was over that)
	view.key, view.origin, view.size, view.scale, view.em = area.key, area.rect.min, area.rect.max - area.rect.min, f.sc, f.em
	view.direction, view.port_rows, view.font, view.minimap = o.direction, o.port_rows, f.font, o.minimap

	node_graph_glide(s, view)
	node_graph_shapes(&f)
	hit := s.mouse_valid ? node_graph_hit(&f, s.mouse) : Node_Graph_Hit{}
	area.cursor = node_graph_cursor(&f, hit)
	sig := signal(area)
	node_graph_input(&f, s, sig)
	node_graph_shapes(&f)   // (what the input moved)
	// what is under the pointer: the node (for the program), the link drawn thicker (not during a gesture: the pointer is busy)
	view.hover_link, view.hover_node = nil, 0
	under := Node_Graph_Hit{}
	if s.mouse_valid && node_graph_pointer_over(s, area) { under = node_graph_hit(&f, s.mouse) }
	#partial switch under.kind {
	case .Node, .Port: view.hover_node = f.nodes[under.node].id
	case .Link: if view.gesture == nil && s.hot_key == area.key { view.hover_link = under.link }
	}
	// (a pick lasts while its link is under the pointer; the wheel's fraction while several links are)
	if pick, ok := view.link_pick.?; ok && (under.kind != .Link || under.link != pick) { view.link_pick = nil }
	if under.kind != .Link || under.links < 2 { view.link_wheel = 0 }
	node_graph_build(&f)
	node_graph_tip(&f, s, under)
	a11y_default(area, {role = .Group, name = i18n.tr("Graph"), role_description = i18n.tr("node graph")})
	return f.events[:]
}

////////////////////////////////
// Shapes

// The view's offset and zoom, in frame px: where graph point `p` is from the area's top-left.
@(private)
node_graph_local :: proc(f: ^Node_Graph_Frame, p: [2]f32) -> [2]f32 {
	return (f.view.offset + p * graph_zoom(f.view)) * f.sc
}

// The move whose nodes are drawn away from their place: the one in progress past its threshold, else the one let go in
// this frame.
@(private)
node_graph_shift :: proc(f: ^Node_Graph_Frame) -> (m: Graph_Gesture_Move, ok: bool) {
	m, ok = f.view.gesture.(Graph_Gesture_Move)
	if !ok { m, ok = f.landed.? }
	return m, ok && m.moved
}

@(private)
node_graph_shapes :: proc(f: ^Node_Graph_Frame) {
	if f.geo == nil { f.geo = make([]Node_Graph_Geometry, len(f.nodes), context.temp_allocator) }
	detail := graph_zoom(f.view) >= GRAPH_DETAIL_ZOOM
	m, shifted := node_graph_shift(f)
	for &n, i in f.nodes {
		body := detail && f.o.body != nil ? node_graph_body_height(f.view, n.id) : 0
		lines, cut := node_graph_title_wrap(&n, f.font, f.em)
		f.geo[i] = node_graph_geometry(&n, f.em, body, detail, {down = f.down, rows = f.o.port_rows, title_lines = lines, title_cut = cut})
		if shifted && (n.id == m.node || (!m.alone && f.sel[n.id])) {
			f.geo[i].rect.min += m.delta
			f.geo[i].rect.max += m.delta
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
	if f.down { r.min.y -= GRAPH_PORT_EM * f.em * graph_zoom(f.view) * f.sc }   // (its in ports stand over its top edge)
	return node_graph_overlaps(r, area)
}

// The port of `ref` and its index on its side; ok false: no such port.
@(private)
node_graph_port :: proc(f: ^Node_Graph_Frame, ref: flowgraph.Port_Ref) -> (port: Graph_Port, index: int, ok: bool) {
	i, found := f.index[ref.node]
	if !found { return }
	ports := ref.side == .In ? f.nodes[i].inputs : f.nodes[i].outputs
	for p, k in ports { if p.id == ref.port { return p, k, true } }
	return
}

// A port's centre on the screen (frame px).
@(private)
node_graph_port_screen :: proc(f: ^Node_Graph_Frame, ref: flowgraph.Port_Ref) -> (at: [2]f32, ok: bool) {
	_, k, found := node_graph_port(f, ref)
	if !found { return }
	return f.view.origin + node_graph_local(f, node_graph_port_at(&f.geo[f.index[ref.node]], ref.side, k)), true
}

// The link that joins two ports of opposite sides, from the out one to the in one.
@(private)
node_graph_link_of :: proc(a, b: flowgraph.Port_Ref) -> Graph_Link {
	o, i := a, b
	if a.side == .In { o, i = b, a }
	return {from_node = o.node, from_port = o.port, to_node = i.node, to_port = i.port}
}

// Whether a link from port `from` may end on port `to`: another node, the other side, and the program's can_link (else
// the same kind).
@(private)
node_graph_compatible :: proc(f: ^Node_Graph_Frame, from, to: flowgraph.Port_Ref) -> bool {
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
	if !draw.rect_contains(area, p) { return }
	if mm, ok := node_graph_minimap(f, area); ok && draw.rect_contains(mm.rect, p) { return {kind = .Minimap} }
	// the ports first (they stand out of their node's sides), the nodes on top first
	reach := node_graph_port_reach(f)
	for i := len(f.nodes) - 1; i >= 0; i -= 1 {
		n := &f.nodes[i]
		r := node_graph_screen_rect(f, i)
		if !node_graph_overlaps(draw.rect_pad(r, reach), {p, p + 1}) { continue }
		for side in flowgraph.Side {
			for port, k in (side == .In ? n.inputs : n.outputs) {
				c := f.view.origin + node_graph_local(f, node_graph_port_at(&f.geo[i], side, k))
				if node_graph_length(p - c) <= reach { return {kind = .Port, node = i, port = {n.id, port.id, side}} }
			}
		}
	}
	for i := len(f.nodes) - 1; i >= 0; i -= 1 {
		if draw.rect_contains(node_graph_screen_rect(f, i), p) { return {kind = .Node, node = i} }
	}
	under, nearest := node_graph_links_at(f, p)
	if len(under) == 0 { return }
	h = {kind = .Link, link = under[nearest], links = len(under), pick = nearest + 1}
	// (the link Alt+wheel chose, while it is still under the point)
	if pick, ok := f.view.link_pick.?; ok {
		for l, i in under { if l == pick { h.link, h.pick = l, i + 1 } }
	}
	return
}

// The links under point `p` (frame px), in the links' order (the temp allocator), and the nearest of them: the distance to
// its curve, a tie to the one drawn last.
@(private)
node_graph_links_at :: proc(f: ^Node_Graph_Frame, p: [2]f32) -> (under: []Graph_Link, nearest: int) {
	reach := node_graph_link_reach(f)
	out := make([dynamic]Graph_Link, 0, 4, context.temp_allocator)
	best := max(f32)
	for l in f.links {
		a, ok_a := node_graph_port_screen(f, {l.from_node, l.from_port, .Out})
		b, ok_b := node_graph_port_screen(f, {l.to_node, l.to_port, .In})
		if !ok_a || !ok_b { continue }
		ca, cb := node_graph_curve(a, b, node_graph_curve_least(f), f.down)
		lo := [2]f32{min(a.x, b.x, ca.x, cb.x), min(a.y, b.y, ca.y, cb.y)} - reach
		hi := [2]f32{max(a.x, b.x, ca.x, cb.x), max(a.y, b.y, ca.y, cb.y)} + reach
		if !draw.rect_contains({lo, hi}, p) { continue }
		d := node_graph_curve_distance(a, ca, cb, b, p)
		if d > reach { continue }
		if d <= best { best, nearest = d, len(out) }
		append(&out, l)
	}
	return out[:], nearest
}

// A link's drawn width (frame px): GRAPH_LINK_PX at the zoom, within GRAPH_LINK_ZOOMS.
@(private)
node_graph_link_width :: proc(f: ^Node_Graph_Frame) -> f32 {
	return GRAPH_LINK_PX * f.sc * clamp(graph_zoom(f.view), GRAPH_LINK_ZOOMS.x, GRAPH_LINK_ZOOMS.y)
}

// How far from its curve a link is hit (frame px): it scales with the zoom as the link does, and never less than the
// link under the pointer is wide.
@(private)
node_graph_link_reach :: proc(f: ^Node_Graph_Frame) -> f32 {
	z := clamp(graph_zoom(f.view), GRAPH_LINK_ZOOMS.x, GRAPH_LINK_ZOOMS.y)
	return max(GRAPH_LINK_HIT_PX * f.sc * z, node_graph_link_width(f) * GRAPH_LINK_HOT * 0.5 + GRAPH_LINK_HIT_LEAST_PX * f.sc)
}

// Whether the pointer is over the graph and not over something built over it (a popup, a panel): the area is the box it
// is on, or a box inside it (a node's widgets, the graph's own button).
@(private)
node_graph_pointer_over :: proc(s: ^State, area: ^Box) -> bool {
	if !draw.rect_contains(area.rect, s.mouse) { return false }
	if s.hot_key == area.key { return true }
	hb := s.boxes[s.hot_key] if s.hot_key != 0 else nil
	return hb != nil && is_descendant(hb, area)
}

// The graph's tooltips, once the pointer rested on what they are about: a cut title over its header, and a port's name
// where the node does not draw it (.Down, content beside the ports, a small zoom). The rest is the graph's own (Graph_View.tip): the area is one box, and the
// toolkit's rest (hovered_for) is per box.
@(private)
node_graph_tip :: proc(f: ^Node_Graph_Frame, s: ^State, h: Node_Graph_Hit) {
	view := f.view
	target: [2]u64
	text, more: string
	at: Rect
	avoid: []Vec2
	if view.gesture == nil {
		#partial switch h.kind {
		case .Link:
			// (only where links overlap: one link alone is read from its curve)
			if h.links > 1 {
				l := h.link
				target = node_graph_link_tip(l)
				text = fmt.tprintf("%s → %s", node_graph_end_name(f, {l.from_node, l.from_port, .Out}), node_graph_end_name(f, {l.to_node, l.to_port, .In}))
				more = fmt.tprintf(i18n.tr("%d of %d here · Alt+wheel for the next"), h.pick, h.links)
				reach := node_graph_link_reach(f)
				at = {s.mouse - reach, s.mouse + reach}
				avoid = node_graph_link_points(f, l)
			}
		case .Port:
			i, found := f.index[h.port.node]
			if port, _, ok := node_graph_port(f, h.port); ok && found && !f.geo[i].names && port.name != "" {
				target = {h.port.node, (u64(h.port.side) << 32 | u64(h.port.port)) + 1}
				text = port.name
				c, _ := node_graph_port_screen(f, h.port)
				reach := node_graph_port_reach(f)
				at = {c - reach, c + reach}
			}
		case .Node:
			g := &f.geo[h.node]
			r := node_graph_screen_rect(f, h.node)
			header := Rect{r.min, {r.max.x, r.min.y + g.header * graph_zoom(view) * f.sc}}
			if g.title_cut && draw.rect_contains(header, s.mouse) {
				target = {f.nodes[h.node].id, 0}
				text = f.nodes[h.node].title
				at = r   // (the whole node: the tooltip covers none of it, its message neither)
				if f.nodes[h.node].message != "" && !f.down {
					// (.Right draws the message under the node: node_graph_node_draw, its middle 0.85 em under it)
					at.max.y += 1.4 * f.em * graph_zoom(view) * f.sc
				}
			}
		}
	}
	if target != view.tip { view.tip, view.tip_since = target, s.time_ms }
	if target == {} { return }
	delay := f64(s.feel.tooltip_delay_ms)
	waited := s.time_ms - view.tip_since
	if waited < delay {
		wake_within(s, max(1, int(delay - waited) + WAKE_MARGIN_MS))
		return
	}
	if tooltip_near(at, avoid) {
		tooltip_text(text)
		if more != "" { if muted() { tooltip_text(more) } }
	}
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

// The minimap in its corner of `area` (frame px): what it shows is every node and the view. ok false: hidden, or no room.
@(private)
node_graph_minimap :: proc(f: ^Node_Graph_Frame, area: Rect) -> (m: Node_Graph_Minimap, ok: bool) {
	place := node_graph_minimap_place(f.o.minimap, (area.max - area.min) / f.sc) or_return
	m.rect = {area.min + place.min * f.sc, area.min + place.max * f.sc}
	size := m.rect.max - m.rect.min
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
		if .Alt in sig.mods && node_graph_cycle(f, s, sig.scrolled) {
			// (Alt+wheel over several links chose another of them; over one or none it moves the view)
		} else if .Ctrl in sig.mods {
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

// Alt+wheel over several links: the next of them (the wheel down) or the one before, in the links' order, with its
// tooltip at once; a notch is a step, fractions (a touchpad's) add up to one. false: fewer than two links under the
// pointer.
@(private)
node_graph_cycle :: proc(f: ^Node_Graph_Frame, s: ^State, scrolled: [2]f32) -> bool {
	if f.view.gesture != nil { return false }
	h := node_graph_hit(f, s.mouse)
	if h.kind != .Link || h.links < 2 { return false }
	f.view.link_wheel += scrolled.y != 0 ? scrolled.y : scrolled.x
	steps := int(f.view.link_wheel)   // (toward zero: the fraction stays)
	if steps == 0 { return true }
	f.view.link_wheel -= f32(steps)
	under, _ := node_graph_links_at(f, s.mouse)
	n := len(under)
	l := under[((h.pick - 1 + steps) % n + n) % n]
	f.view.link_pick = l
	f.view.tip, f.view.tip_since = node_graph_link_tip(l), s.time_ms - f64(s.feel.tooltip_delay_ms)
	return true
}

// Points along link `l`'s curve (frame px, the temp allocator), for its tooltip to avoid: nil when an end is not drawn.
@(private = "file")
node_graph_link_points :: proc(f: ^Node_Graph_Frame, l: Graph_Link) -> []Vec2 {
	a, ok_a := node_graph_port_screen(f, {l.from_node, l.from_port, .Out})
	b, ok_b := node_graph_port_screen(f, {l.to_node, l.to_port, .In})
	if !ok_a || !ok_b { return nil }
	ca, cb := node_graph_curve(a, b, node_graph_curve_least(f), f.down)
	points := make([]Vec2, GRAPH_LINK_TIP_POINTS + 1, context.temp_allocator)
	for &p, i in points { p = draw.bezier_cubic_at(a, ca, cb, b, f32(i) / GRAPH_LINK_TIP_POINTS) }
	return points
}

// A link as the target of a tooltip (Graph_View.tip): apart from a node's and a port's by its first word's top bit.
@(private)
node_graph_link_tip :: proc(l: Graph_Link) -> [2]u64 {
	return {(l.from_node ~ (l.to_node * 0x9e3779b97f4a7c15)) | 1 << 63, u64(l.from_port) << 32 | u64(l.to_port)}
}

// A port's name for a link's tooltip: its node's title, and the port's name after it when it has one.
@(private)
node_graph_end_name :: proc(f: ^Node_Graph_Frame, ref: flowgraph.Port_Ref) -> string {
	i, found := f.index[ref.node]
	if !found { return "?" }
	title := f.nodes[i].title
	if port, _, ok := node_graph_port(f, ref); ok && port.name != "" { return fmt.tprintf("%s · %s", title, port.name) }
	return title
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
		if mm, ok := node_graph_minimap(f, {view.origin, view.origin + view.size}); ok {
			view.gesture = Graph_Gesture_Minimap{rect = mm.rect, lo = mm.lo, pad = mm.pad, k = mm.k}
			node_graph_center_on(f, node_graph_minimap_to_graph(mm, at))
		}
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
			f.landed = g
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
		if !held || g.k <= 0 { view.gesture = nil; break }
		// (frozen minimap transform and clamped pointer: prevents dragging near the edge from feeding back into
		// node_graph_minimap's bounds and flinging the view out to f32 overflow)
		mm := Node_Graph_Minimap{rect = g.rect, lo = g.lo, pad = g.pad, k = g.k}
		p := [2]f32{clamp(s.mouse.x, g.rect.min.x, g.rect.max.x), clamp(s.mouse.y, g.rect.min.y, g.rect.max.y)}
		node_graph_center_on(f, node_graph_minimap_to_graph(mm, p))
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
node_graph_wire_target :: proc(f: ^Node_Graph_Frame, from: flowgraph.Port_Ref, p: [2]f32) -> (target: Maybe(flowgraph.Port_Ref)) {
	reach := node_graph_port_reach(f) * GRAPH_WIRE_REACH
	best := reach
	side: flowgraph.Side = from.side == .Out ? .In : .Out
	for &n, i in f.nodes {
		if n.id == from.node { continue }
		if !node_graph_overlaps(draw.rect_pad(node_graph_screen_rect(f, i), reach), {p, p + 1}) { continue }
		for port, k in (side == .In ? n.inputs : n.outputs) {
			c := f.view.origin + node_graph_local(f, node_graph_port_at(&f.geo[i], side, k))
			d := node_graph_length(p - c)
			ref := flowgraph.Port_Ref{n.id, port.id, side}
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
