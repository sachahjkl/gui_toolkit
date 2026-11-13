package ui

// A node graph: boxes (nodes) with ports on their sides, joined by curves (links) from an out port to an in port. The
// program owns the model (its nodes, links, selection, undo) and applies the events the widget returns; the widget draws
// it and turns the pointer and the keys into those events.
//
//	events := ui.node_graph("###flow", &app.view, nodes, links, app.selected[:], {kind_colors = colors[:]})
//	for e in events {
//		switch v in e {
//		case ui.Graph_Moved:  for id in v.nodes { node_of(id).pos += v.delta }
//		case ui.Graph_Linked: ...
//		...
//		}
//	}
//
// Graph units: 1 is a logical pixel at the zoom 1. The middle button, or Space with the left one, drags the view; the wheel
// moves it (a touchpad's two fingers too), Ctrl with the wheel (a touchpad's pinch) zooms around the pointer. Details:
// docs/node_graph.md.

import "core:fmt"
import "core:math"
import "../draw"
import "../flowgraph"
import "../font"
import "../platform"
import "../render"

GRAPH_ZOOM_MIN  :: 0.2
GRAPH_ZOOM_MAX  :: 3.0
// A notch of the wheel with Ctrl: the zoom times this.
GRAPH_ZOOM_STEP :: 1.2
// Under this zoom a node shows its header and its ports' dots: names, thumbnails and widgets are too small to read.
GRAPH_DETAIL_ZOOM :: 0.5

// A node's parts, in ems of the interface's font at the zoom 1.
@(private) GRAPH_NODE_WIDTH_EM   :: 13
@(private) GRAPH_HEADER_EM       :: 1.9    // the title alone
@(private) GRAPH_HEADER_SUB_EM   :: 2.9    // the title and its subtitle
@(private) GRAPH_ROW_EM          :: 1.55   // a port's row
@(private) GRAPH_PAD_EM          :: 0.55
@(private) GRAPH_PORT_EM         :: 0.62   // a port's dot, across
@(private) GRAPH_THUMB_MAX_EM    :: 8      // a thumbnail's height at most
@(private) GRAPH_RADIUS_EM       :: 0.45

Graph_Port :: struct {
	id:       u32,
	name:     string,           // shown beside the port
	kind:     u8,               // the program's type of what flows (its colour: Graph_Options.kind_colors[kind])
	side:     flowgraph.Side,
	multiple: bool,             // an In port: takes several links (else a new link replaces the old one)
}

// A run's state, drawn on the node.
Graph_Node_State :: enum u8 { Idle, Running, Done, Failed, Skipped }

Graph_Node :: struct {
	id:        u64,
	title:     string,
	subtitle:  string,          // a line under the title (a summary of its parameters: "50 %", "PNG to ~/Pictures")
	icon:      string,          // a glyph of Graph_Options.icon_font ("": none)
	color:     draw.Color,      // its header's accent ({}: the theme's)
	pos:       [2]f32,          // its top-left, graph units (1 unit = 1 logical px at zoom 1)
	width:     f32,             // graph units (0: a default)
	inputs, outputs: []Graph_Port,
	state:     Graph_Node_State,
	message:   string,          // under the node (an error in red when state is Failed, else faint)
	thumbnail: render.Texture,
	thumbnail_size: [2]int,     // a small picture in the node (0: none)
}

Graph_Link :: struct {
	from_node: u64,
	from_port: u32,
	to_node:   u64,
	to_port:   u32,
}

// What the program keeps between frames: where the view is and how close (its own to set: graph_fit), and the gesture in
// progress (the widget's).
Graph_View :: struct {
	offset:  [2]f32,   // where the graph's origin is, in logical px from the area's top-left
	zoom:    f32,      // logical px per graph unit (0 is taken as 1)
	// the widget's
	zoom_to:   f32,          // the zoom it glides to (0: none)
	zoom_at:   [2]f32,       // the point that stays where it is meanwhile, logical px from the area's top-left
	origin:    [2]f32,       // the area's top-left on the screen (frame px), as last laid out
	size:      [2]f32,       // its size (frame px)
	scale:     f32,          // the interface's scale (ui.scale) of the last build
	em:        f32,          // the interface's em in graph units, of the last build
	key:       Key,          // the area's box
	gesture:   Graph_Gesture,
	link:      Maybe(Graph_Link),   // the link selected (a click on it): Delete removes it
	hover:     Maybe(Graph_Link),   // the link under the pointer
}

// What the pointer is doing on the graph (Graph_View.gesture). One at a time: a press starts one, its release ends it,
// Escape drops it.
Graph_Gesture :: union {
	Graph_Gesture_Pan,
	Graph_Gesture_Move,
	Graph_Gesture_Wire,
	Graph_Gesture_Band,
	Graph_Gesture_Minimap,
}

// The view follows the pointer (the middle button, or Space with the left one).
Graph_Gesture_Pan :: struct {
	button: platform.Mouse_Button,
	press:  [2]f32,   // the pointer at the press (frame px)
	from:   [2]f32,   // the offset at the press
}

// Nodes follow the pointer: the one pressed alone (it was not selected), or the selection.
Graph_Gesture_Move :: struct {
	node:     u64,
	alone:    bool,
	press:    [2]f32,   // frame px
	moved:    bool,     // past the drag threshold: a release is no click
	delta:    [2]f32,   // graph units, snapped
	collapse: bool,     // a plain click on a node of a selection of several: on release without a move, it alone is selected
}

// A link being drawn from a port; `detached` was taken off an in port to go elsewhere (dropped on nothing: removed).
Graph_Gesture_Wire :: struct {
	from:     flowgraph.Port_Ref,
	detached: Maybe(Graph_Link),
	at:       [2]f32,                // the free end, graph units
	target:   Maybe(flowgraph.Port_Ref), // the port it would link to if let go now
}

// A box drawn from a press on nothing: the nodes it touches are selected.
Graph_Gesture_Band :: struct {
	from, to: [2]f32,   // graph units
	press:    [2]f32,   // frame px
	additive: bool,     // Shift or Ctrl: added to the selection
	moved:    bool,
}

// The view follows the pointer over the minimap.
Graph_Gesture_Minimap :: struct {}

Graph_Options :: struct {
	user:        rawptr,
	kind_colors: []draw.Color,                                    // per Graph_Port.kind
	can_link:    proc(user: rawptr, link: Graph_Link) -> bool,    // nil: ports of the same kind only
	body:        proc(user: rawptr, node: u64, em: f32),          // optional widgets inside a node, under its ports
	icon_font:   font.Font_Id,
	snap:        f32,                                             // grid snap in graph units (0: none)
	minimap:     bool,
}

// What happened this frame, for the program to apply.
Graph_Event :: union {
	Graph_Moved,
	Graph_Linked,
	Graph_Unlinked,
	Graph_Selected,
	Graph_Deleted,
	Graph_Context,
	Graph_Opened,
	Graph_Dropped_Link,
}

// Nodes moved by `delta` (graph units): at the end of a drag, at an arrow key. One undo step.
Graph_Moved :: struct {
	nodes: []u64,
	delta: [2]f32,
}

// A link made; `replaced` is the one the in port had, which it no longer has (it takes one link).
Graph_Linked :: struct {
	link:     Graph_Link,
	replaced: Maybe(Graph_Link),
}

// A link taken off its in port and let go on nothing.
Graph_Unlinked :: struct {
	link: Graph_Link,
}

// The new selection, whole.
Graph_Selected :: struct {
	nodes: []u64,
}

// Delete or Backspace: the nodes selected, and the links to remove with them (the link selected, those of the nodes).
Graph_Deleted :: struct {
	nodes: []u64,
	links: []Graph_Link,
}

// A right click: where (graph units), on which node (0: the background) and port.
Graph_Context :: struct {
	at:   [2]f32,
	node: u64,
	port: Maybe(flowgraph.Port_Ref),
}

// A double click on a node.
Graph_Opened :: struct {
	node: u64,
}

// A link let go on the background: the program can offer to add a node there, linked to `from`.
Graph_Dropped_Link :: struct {
	from: flowgraph.Port_Ref,
	at:   [2]f32,
}

////////////////////////////////
// Coordinates

// The zoom of a view, never 0.
graph_zoom :: proc(view: ^Graph_View) -> f32 { return view.zoom > 0 ? view.zoom : 1 }

// A point of the graph on the screen (frame px), by the area as last laid out.
graph_to_screen :: proc(view: ^Graph_View, p: [2]f32) -> [2]f32 {
	s := view.scale > 0 ? view.scale : 1
	return view.origin + (view.offset + p * graph_zoom(view)) * s
}

// The point of the graph at a point of the screen (frame px).
graph_from_screen :: proc(view: ^Graph_View, p: [2]f32) -> [2]f32 {
	s := view.scale > 0 ? view.scale : 1
	return ((p - view.origin) / s - view.offset) / graph_zoom(view)
}

// The zoom set to `zoom` (within its limits), the point `at` of the area (logical px from its top-left) staying where it is.
graph_zoom_about :: proc(view: ^Graph_View, zoom: f32, at: [2]f32) {
	z := graph_zoom(view)
	nz := clamp(zoom, GRAPH_ZOOM_MIN, GRAPH_ZOOM_MAX)
	view.offset = at - (at - view.offset) * (nz / z)
	view.zoom = nz
}

// Margin around the nodes graph_fit shows, logical px.
@(private = "file") GRAPH_FIT_MARGIN :: 32

// Zoom and pan to show all of `nodes` in an area of `area` logical px (0: the area of the last build), no closer than 1.
graph_fit :: proc(view: ^Graph_View, nodes: []Graph_Node, area: [2]f32 = {}) {
	size := area
	if size.x <= 0 || size.y <= 0 {
		s := view.scale > 0 ? view.scale : 1
		size = view.size / s
	}
	if len(nodes) == 0 || size.x <= 0 || size.y <= 0 {
		view.offset, view.zoom = {}, 1
		view.zoom_to = 0
		return
	}
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{-max(f32), -max(f32)}
	for &n in nodes {
		r := graph_node_rect(view, &n)
		lo = {min(lo.x, r.min.x), min(lo.y, r.min.y)}
		hi = {max(hi.x, r.max.x), max(hi.y, r.max.y)}
	}
	room := size - 2 * GRAPH_FIT_MARGIN
	extent := hi - lo
	z := f32(1)
	if extent.x > 0 && extent.y > 0 && room.x > 0 && room.y > 0 { z = min(room.x / extent.x, room.y / extent.y, 1) }
	z = clamp(z, GRAPH_ZOOM_MIN, GRAPH_ZOOM_MAX)
	view.zoom = z
	view.zoom_to = 0
	view.offset = size * 0.5 - (lo + hi) * 0.5 * z
}

////////////////////////////////
// A node's shape

// Where a node's parts are, in graph units.
@(private)
Node_Graph_Geometry :: struct {
	rect:      Rect,
	header:    f32,    // its height
	ports_top: f32,    // the first port row's top, from the node's top
	row:       f32,    // a port row's height
	rows:      int,
	thumb:     Rect,   // the thumbnail (empty: none)
	body_top:  f32,    // the widgets' top, from the node's top
	pad:       f32,
	detail:    bool,   // names, thumbnail and widgets are drawn
}

// A node's parts: `em` the interface's em in graph units, `body` its widgets' height (graph units), `detail` false at a
// small zoom.
@(private)
node_graph_geometry :: proc(n: ^Graph_Node, em: f32, body: f32, detail: bool) -> (g: Node_Graph_Geometry) {
	w := n.width > 0 ? n.width : em * GRAPH_NODE_WIDTH_EM
	g.pad = em * GRAPH_PAD_EM
	g.header = em * (n.subtitle != "" ? GRAPH_HEADER_SUB_EM : GRAPH_HEADER_EM)
	g.row = em * GRAPH_ROW_EM
	g.rows = max(len(n.inputs), len(n.outputs))
	g.detail = detail
	g.ports_top = g.header + (g.rows > 0 ? g.pad * 0.5 : 0)
	y := g.ports_top + f32(g.rows) * g.row
	if detail && n.thumbnail_size.x > 0 && n.thumbnail_size.y > 0 {
		tw := w - 2 * g.pad
		th := min(tw * f32(n.thumbnail_size.y) / f32(n.thumbnail_size.x), em * GRAPH_THUMB_MAX_EM)
		tw = th * f32(n.thumbnail_size.x) / f32(n.thumbnail_size.y)
		y += g.pad * 0.5
		g.thumb = {{(w - tw) * 0.5, y}, {(w + tw) * 0.5, y + th}}
		y += th
	}
	g.body_top = y + (detail && body > 0 ? g.pad * 0.5 : 0)
	if detail { y = g.body_top + body }
	h := y + g.pad * ((g.rows > 0 || (detail && body > 0)) ? 0.7 : 0)
	g.rect = {n.pos, n.pos + {w, max(h, g.header)}}
	return
}

// The centre of a port, graph units.
@(private)
node_graph_port_at :: proc(g: ^Node_Graph_Geometry, side: flowgraph.Side, index: int) -> [2]f32 {
	y := g.rect.min.y + g.ports_top + (f32(index) + 0.5) * g.row
	return {side == .In ? g.rect.min.x : g.rect.max.x, y}
}

// The id of a node's box under the area's (its key: node_graph_node_key), and of its widgets' box under it.
@(private)
node_graph_node_id :: proc(id: u64) -> string { return fmt.tprintf("###graph_node_%x", id) }
@(private)
node_graph_node_key :: proc(area: Key, id: u64) -> Key { return key_from_string(area, node_graph_node_id(id)) }
@(private) NODE_GRAPH_BODY_ID :: "###graph_body"

// A node's widgets' height in graph units, as last laid out (0: none yet).
@(private)
node_graph_body_height :: proc(view: ^Graph_View, id: u64) -> f32 {
	if current == nil || view.key == 0 { return 0 }
	b := box_from_key(key_from_string(node_graph_node_key(view.key, id), NODE_GRAPH_BODY_ID))
	if b == nil { return 0 }
	s := view.scale > 0 ? view.scale : 1
	return (b.rect.max.y - b.rect.min.y) / (s * graph_zoom(view))
}

// A node's rectangle in graph units, by the last build's sizes.
graph_node_rect :: proc(view: ^Graph_View, n: ^Graph_Node) -> Rect {
	em := view.em > 0 ? view.em : 16
	detail := graph_zoom(view) >= GRAPH_DETAIL_ZOOM
	return node_graph_geometry(n, em, detail ? node_graph_body_height(view, n.id) : 0, detail).rect
}

// The centre of a node's port in graph units (`index` among the ports of its side), by the last build's sizes: where a
// program shows something by a port, where a test presses.
graph_port_pos :: proc(view: ^Graph_View, n: ^Graph_Node, side: flowgraph.Side, index: int) -> [2]f32 {
	em := view.em > 0 ? view.em : 16
	detail := graph_zoom(view) >= GRAPH_DETAIL_ZOOM
	g := node_graph_geometry(n, em, detail ? node_graph_body_height(view, n.id) : 0, detail)
	return node_graph_port_at(&g, side, index)
}

// A cubic curve from an out port at `a` to an in port at `b` (any units): its two control points, out of `a` to the right
// and into `b` from the left, further apart the further the ends are (a link that goes back loops round).
@(private)
node_graph_curve :: proc(a, b: [2]f32, least: f32) -> (ca, cb: [2]f32) {
	dx := max(abs(b.x - a.x) * 0.5, least)
	if b.x < a.x { dx = max(dx, abs(b.y - a.y) * 0.25 + least) }
	return a + {dx, 0}, b - {dx, 0}
}

// The distance from `p` to a cubic curve, by its points at `pieces` steps.
@(private)
node_graph_curve_distance :: proc(a, ca, cb, b, p: [2]f32, pieces := 24) -> f32 {
	best := max(f32)
	prev := a
	for i in 1 ..= pieces {
		q := draw.bezier_cubic_at(a, ca, cb, b, f32(i) / f32(pieces))
		best = min(best, segment_distance(prev, q, p))
		prev = q
	}
	return best
}

@(private = "file")
segment_distance :: proc(a, b, p: [2]f32) -> f32 {
	d := b - a
	l := d.x * d.x + d.y * d.y
	t := l > 0 ? clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l, 0, 1) : 0
	q := a + d * t
	return math.sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y))
}

// Whether two rectangles overlap.
@(private)
node_graph_overlaps :: proc(a, b: Rect) -> bool {
	return a.min.x < b.max.x && b.min.x < a.max.x && a.min.y < b.max.y && b.min.y < a.max.y
}
