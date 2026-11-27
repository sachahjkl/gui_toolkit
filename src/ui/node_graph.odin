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
@(private) GRAPH_TITLE_LINE_EM   :: 1.25   // a title's second line adds this
@(private) GRAPH_TITLE_MID_EM    :: 0.95   // the first title line's middle, from the header's top (alone)
@(private) GRAPH_TITLE_SUB_MID_EM :: 1.04  // the same with a subtitle
@(private) GRAPH_SUB_GAP_EM      :: 1.05   // the subtitle's middle under the last title line's
@(private) GRAPH_ICON_EM         :: 1.45   // an icon's room before the title
@(private) GRAPH_MARK_EM         :: 1.2    // the state's mark's room after it (kept for an idle node too)
@(private) GRAPH_ROW_EM          :: 1.55   // a port's row
@(private) GRAPH_PAD_EM          :: 0.55
@(private) GRAPH_BODY_GAP_PAD    :: 0.5    // the widgets' margin above and below them, a share of the pad
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

// Where a graph's ports are drawn, and so the way its links run.
Graph_Direction :: enum u8 {
	Right,   // in ports on a node's left side, out ports on its right: links run from left to right
	Down,    // in ports along a node's top edge, out ports along its bottom edge: links run from top to bottom (a tree)
}

// A link's stroke: whole, in dashes or in dots (their lengths in the link's widths: they scale with the zoom).
Graph_Dash :: enum u8 { Solid, Dashed, Dotted }

// How one link is drawn (Graph_Options.link_looks). The zero look: solid, in the colour of its out port's kind.
Graph_Link_Look :: struct {
	intent: Intent,       // .Neutral: its out port's kind colour; else the theme's hue of the intent
	dash:   Graph_Dash,
}

// The map of the whole graph in a corner of the area (Graph_Options.minimap).
Graph_Minimap :: struct {
	show:   bool,
	corner: Maybe(Corner),   // nil: .Bottom_Right
	size:   [2]f32,          // logical px (0: a share of the area, within limits: node_graph_minimap_size)
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
	direction: Graph_Direction,     // of the last build
	port_rows: bool,                // of the last build
	font:      font.Font_Id,        // the titles' font, of the last build
	minimap:   Graph_Minimap,       // of the last build: graph_fit leaves its corner free
	gesture:   Graph_Gesture,
	link:      Maybe(Graph_Link),   // the link selected (a click on it): Delete removes it
	hover_link: Maybe(Graph_Link),  // the link under the pointer (the nearest, or the one Alt+wheel chose among those there)
	hover_node: u64,                // the node under the pointer (one of its ports too), 0: none
	link_pick: Maybe(Graph_Link),   // the link Alt+wheel chose among those under the pointer (nil: the nearest)
	link_wheel: f32,                // Alt+wheel's fraction of a step (a touchpad's), while the pointer stays over the links
	lit_link:  Maybe(Graph_Link),   // what the links' emphasis is about, kept while it fades out: a link,
	lit_node:  u64,                 // or a node's links (0: none)
	lit_dim:   f32,                 // how far the other links fade at the full emphasis (GRAPH_LINK_DIM_*)
	tip:       [2]u64,              // what the pointer rests on for a tooltip ({}: nothing): the node, its port's mark
	tip_since: f64,                 // when it came there (State.time_ms)
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
// The view jumps to where the pointer is in the minimap, using the minimap transform frozen at press so dragging near
// or past the minimap's edge cannot grow its bounds in an exponential feedback loop.
Graph_Gesture_Minimap :: struct {
	rect: Rect,     // frame px
	lo:   [2]f32,   // graph units
	pad:  [2]f32,   // frame px
	k:    f32,      // frame px per graph unit
}

Graph_Options :: struct {
	user:        rawptr,
	kind_colors: []draw.Color,                                    // per Graph_Port.kind
	can_link:    proc(user: rawptr, link: Graph_Link) -> bool,    // nil: ports of the same kind only
	body:        proc(user: rawptr, node: u64, em: f32),          // optional widgets inside a node, under its ports
	icon_font:   font.Font_Id,
	snap:        f32,                                             // grid snap in graph units (0: none)
	minimap:     Graph_Minimap,
	direction:   Graph_Direction,
	port_rows:   bool,                                            // .Right: each port on a row of its own with its name, the body under them
	link_looks:  []Graph_Link_Look,                               // in the order of the links (shorter: the others plain)
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
// The minimap of the last build keeps its corner: the nodes fit beside it or above it (below it, in a top corner),
// whichever shows them larger.
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
	z, offset, _ := graph_fit_in(lo, hi, {{}, size})
	if m, ok := node_graph_minimap_place(view.minimap, size); ok {
		// a column beside the map, or a band above or below it: the one that shows the nodes larger (on a tie, the larger room)
		gap := f32(GRAPH_MINIMAP_MARGIN)
		column, band := Rect{{}, size}, Rect{{}, size}
		if m.min.x > size.x * 0.5 { column.max.x = m.min.x - gap } else { column.min.x = m.max.x + gap }
		if m.min.y > size.y * 0.5 { band.max.y = m.min.y - gap } else { band.min.y = m.max.y + gap }
		// (a room narrower than the fit's margins holds nothing: it never wins, and with neither the map stays over the nodes)
		zc, oc, ok_c := graph_fit_in(lo, hi, column)
		zb, ob, ok_b := graph_fit_in(lo, hi, band)
		area_of :: proc(r: Rect) -> f32 { return max(r.max.x - r.min.x, 0) * max(r.max.y - r.min.y, 0) }
		if ok_c && (!ok_b || zc > zb || (zc == zb && area_of(column) >= area_of(band))) {
			z, offset = zc, oc
		} else if ok_b {
			z, offset = zb, ob
		}
	}
	view.zoom = z
	view.zoom_to = 0
	view.offset = offset
}

// The zoom and offset that show the graph's `lo`..`hi` in the middle of `room` (logical px from the area's top-left).
// ok false: the room has no inside within the fit's margins (the zoom is then 1).
@(private = "file")
graph_fit_in :: proc(lo, hi: [2]f32, room: Rect) -> (z: f32, offset: [2]f32, ok: bool) {
	inner := room.max - room.min - 2 * GRAPH_FIT_MARGIN
	extent := hi - lo
	ok = inner.x > 0 && inner.y > 0
	z = 1
	if extent.x > 0 && extent.y > 0 && ok { z = min(inner.x / extent.x, inner.y / extent.y, 1) }
	z = clamp(z, GRAPH_ZOOM_MIN, GRAPH_ZOOM_MAX)
	return z, (room.min + room.max) * 0.5 - (lo + hi) * 0.5 * z, ok
}

// The minimap's size of `m` in an area of `area` logical px: its own, else a share of the area within limits. ok
// false: hidden, or no room for it.
@(private)
node_graph_minimap_size :: proc(m: Graph_Minimap, area: [2]f32) -> (size: [2]f32, ok: bool) {
	if !m.show { return }
	size = m.size
	if size.x <= 0 || size.y <= 0 {
		w := clamp(area.x * GRAPH_MINIMAP_SHARE, GRAPH_MINIMAP_LEAST, GRAPH_MINIMAP_MOST)
		w = min(w, area.y * GRAPH_MINIMAP_TALL / GRAPH_MINIMAP_RATIO)
		if w < GRAPH_MINIMAP_LEAST { return }
		size = {w, w * GRAPH_MINIMAP_RATIO}
	}
	if area.x < size.x + 2 * GRAPH_MINIMAP_MARGIN || area.y < size.y + 2 * GRAPH_MINIMAP_MARGIN { return }
	return size, true
}

// The minimap's rectangle in an area of `area` logical px, from its top-left, in its corner.
@(private)
node_graph_minimap_place :: proc(m: Graph_Minimap, area: [2]f32) -> (r: Rect, ok: bool) {
	size := node_graph_minimap_size(m, area) or_return
	margin := f32(GRAPH_MINIMAP_MARGIN)
	corner := m.corner.? or_else .Bottom_Right
	x := corner == .Top_Right || corner == .Bottom_Right ? area.x - margin - size.x : margin
	y := corner == .Bottom_Left || corner == .Bottom_Right ? area.y - margin - size.y : margin
	return {{x, y}, {x + size.x, y + size.y}}, true
}

////////////////////////////////
// A node's shape

// Where a node's parts are, in graph units.
@(private)
Node_Graph_Geometry :: struct {
	rect:      Rect,
	header:    f32,    // its height
	ports_top: f32,    // the first port row's top, from the node's top
	row:       f32,    // a port row's height (on an edge: the least room of a port)
	dot:       f32,    // a port's dot's radius
	rows:      int,    // the port rows (Graph_Options.port_rows), else 0
	span:      f32,    // .Right without rows: the length of the edges the ports are spread over, from ports_top
	names:     bool,   // the ports' names are drawn on the node (else a named port has a tooltip)
	thumb:     Rect,   // the thumbnail (empty: none)
	body_top:  f32,    // the widgets' top, from the node's top
	pad:       f32,
	detail:    bool,   // names, thumbnail and widgets are drawn
	down:      bool,   // Graph_Direction.Down: the ports on the top and bottom edges, no rows
	inputs, outputs: int,
	title_lines: int,  // 1 or 2
	title_cut: bool,   // the title has more than two lines: the second ends in an ellipsis
	message_mid: f32,  // the message's line inside the node, from its top (.Down); 0: under the node
}

// How a node's title wraps in its header: its lines (1 or 2) and whether it is cut. `em` the interface's em in graph
// units; `f` the font it is drawn with. Outside a build (no State to measure with), one line.
@(private)
node_graph_title_wrap :: proc(n: ^Graph_Node, f: font.Font_Id, em: f32) -> (lines: int, cut: bool) {
	if current == nil || n.title == "" || f == 0 { return 1, false }
	w := n.width > 0 ? n.width : em * GRAPH_NODE_WIDTH_EM
	room := node_graph_title_room(n, w, em)
	all := wrap_lines_cached(f, em, n.title, room)
	return clamp(len(all), 1, 2), len(all) > 2
}

// The width a title has in a header `w` wide (any units, `em` in the same).
@(private)
node_graph_title_room :: proc(n: ^Graph_Node, w, em: f32) -> f32 {
	room := w - 2 * em * GRAPH_PAD_EM - em * GRAPH_MARK_EM
	if n.icon != "" { room -= em * GRAPH_ICON_EM }
	return max(room, em)
}

// How a graph lays its nodes out (of its options), and a node's title (node_graph_title_wrap).
@(private)
Node_Graph_Layout :: struct {
	down:        bool,   // Graph_Direction.Down
	rows:        bool,   // Graph_Options.port_rows
	title_lines: int,    // 1 or 2
	title_cut:   bool,
}

// A node's parts: `em` the interface's em in graph units, `body` its widgets' height (graph units), `detail` false at a
// small zoom.
@(private)
node_graph_geometry :: proc(n: ^Graph_Node, em: f32, body: f32, detail: bool, layout := Node_Graph_Layout{}) -> (g: Node_Graph_Geometry) {
	w := n.width > 0 ? n.width : em * GRAPH_NODE_WIDTH_EM
	down := layout.down
	g.pad = em * GRAPH_PAD_EM
	g.title_lines, g.title_cut = clamp(layout.title_lines, 1, 2), layout.title_cut
	g.header = em * ((n.subtitle != "" ? GRAPH_HEADER_SUB_EM : GRAPH_HEADER_EM) + f32(g.title_lines - 1) * GRAPH_TITLE_LINE_EM)
	g.row = em * GRAPH_ROW_EM
	g.dot = em * GRAPH_PORT_EM * 0.5
	g.down = down
	g.inputs, g.outputs = len(n.inputs), len(n.outputs)
	ports := max(g.inputs, g.outputs)
	g.rows = !down && layout.rows ? ports : 0
	// (on the edges: the ports beside the body, which starts under the header as in a node without ports)
	edge := !down && !layout.rows && ports > 0
	g.detail = detail
	g.ports_top = g.header + (g.rows > 0 || edge ? g.pad * 0.5 : 0)
	y := g.rows > 0 ? g.ports_top + f32(g.rows) * g.row : g.header
	if down && n.message != "" {
		// (under the node is where the links leave: the message is a line inside it, under the header)
		g.message_mid = y + g.row * 0.5
		y += g.row
	}
	if detail && n.thumbnail_size.x > 0 && n.thumbnail_size.y > 0 {
		tw := w - 2 * g.pad
		th := min(tw * f32(n.thumbnail_size.y) / f32(n.thumbnail_size.x), em * GRAPH_THUMB_MAX_EM)
		tw = th * f32(n.thumbnail_size.x) / f32(n.thumbnail_size.y)
		y += g.pad * 0.5
		g.thumb = {{(w - tw) * 0.5, y}, {(w + tw) * 0.5, y + th}}
		y += th
	}
	// (the body's margin, the same above and below it: a widget's frame inside the node reads as centred)
	gap := detail && body > 0 ? g.pad * GRAPH_BODY_GAP_PAD : 0
	g.body_top = y + gap
	if detail { y = g.body_top + body }
	body_end := y
	content := g.thumb.max.x > g.thumb.min.x || (detail && body > 0)
	if edge {
		// (the edges as long as the content, and a row's room per port at least)
		least := g.ports_top + f32(ports) * g.row
		g.span = max(y, least) - g.ports_top
		y = max(y, least)
	}
	// (a name stands across the node: it has room where no content is beside it)
	g.names = detail && !down && (g.rows > 0 || !content)
	h := y + g.pad * ((g.rows > 0 || edge || g.message_mid > 0) ? 0.7 : 0)
	// (the body ends the node, its ports' edge not longer: under it, its margin above)
	if gap > 0 && y == body_end { h = y + gap }
	g.rect = {n.pos, n.pos + {w, max(h, g.header)}}
	return
}

// The centre of a port, graph units.
@(private)
node_graph_port_at :: proc(g: ^Node_Graph_Geometry, side: flowgraph.Side, index: int) -> [2]f32 {
	if g.down {
		// (along the edge, spaced evenly: a port alone is in the middle. Outside it, touching it: a dot across the top edge
		// covers the title's first line, one across the bottom edge the message's line and the border)
		count := max(side == .In ? g.inputs : g.outputs, 1)
		x := g.rect.min.x + (g.rect.max.x - g.rect.min.x) * (f32(index) + 0.5) / f32(count)
		return {x, side == .In ? g.rect.min.y - g.dot : g.rect.max.y + g.dot}
	}
	y := g.rect.min.y + g.ports_top + (f32(index) + 0.5) * g.row
	if g.rows == 0 {
		// (spread evenly over the edge, each side on its own: a port alone is in the middle)
		count := max(side == .In ? g.inputs : g.outputs, 1)
		y = g.rect.min.y + g.ports_top + g.span * (f32(index) + 0.5) / f32(count)
	}
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

// A node's parts by the view's last build (its em, zoom, direction and title font).
@(private)
node_graph_view_geometry :: proc(view: ^Graph_View, n: ^Graph_Node) -> Node_Graph_Geometry {
	em := view.em > 0 ? view.em : 16
	detail := graph_zoom(view) >= GRAPH_DETAIL_ZOOM
	lines, cut := node_graph_title_wrap(n, view.font, em)
	layout := Node_Graph_Layout{down = view.direction == .Down, rows = view.port_rows, title_lines = lines, title_cut = cut}
	return node_graph_geometry(n, em, detail ? node_graph_body_height(view, n.id) : 0, detail, layout)
}

// A node's rectangle in graph units, by the last build's sizes.
graph_node_rect :: proc(view: ^Graph_View, n: ^Graph_Node) -> Rect {
	return node_graph_view_geometry(view, n).rect
}

// The centre of a node's port in graph units (`index` among the ports of its side), by the last build's sizes: where a
// program shows something by a port, where a test presses.
graph_port_pos :: proc(view: ^Graph_View, n: ^Graph_Node, side: flowgraph.Side, index: int) -> [2]f32 {
	g := node_graph_view_geometry(view, n)
	return node_graph_port_at(&g, side, index)
}

// A cubic curve from an out port at `a` to an in port at `b` (any units): its two control points, out of `a` along the
// flow (to the right; `down`: downward) and into `b` along it, further apart the further the ends are (a link that goes
// back loops round).
@(private)
node_graph_curve :: proc(a, b: [2]f32, least: f32, down := false) -> (ca, cb: [2]f32) {
	if down {
		dy := max(abs(b.y - a.y) * 0.5, least)
		if b.y < a.y { dy = max(dy, abs(b.x - a.x) * 0.25 + least) }
		return a + {0, dy}, b - {0, dy}
	}
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
