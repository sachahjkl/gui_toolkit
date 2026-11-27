package ui

// node_graph: the boxes of a frame and what they draw. The area draws its grid and the links; each node is a box that draws
// its face and holds its widgets (a node over another covers its widgets too); a last box over them draws the link being
// drawn, the band and the minimap. Everything is placed relative to the area's top-left, laid out this frame.

import "core:math"
import turn "../turn"
import "core:strings"
import "../draw"
import "../flowgraph"
import "../font"
import i18n "../i18n"
import lucide "../lucide"
import "../render"

// The grid: its step in graph units, doubled while it is closer than GRAPH_GRID_LEAST_PX on the screen; a line in
// GRAPH_GRID_MAJOR is a major one. Its lines' opacities.
@(private) GRAPH_GRID :: 24
@(private) GRAPH_GRID_LEAST_PX :: 12
@(private) GRAPH_GRID_MAJOR :: 4
@(private) GRAPH_GRID_MINOR_ALPHA :: 0.22
@(private) GRAPH_GRID_MAJOR_ALPHA :: 0.45
// A link's width (logical px at the zoom 1, within these zooms); under the pointer or selected, this many times.
@(private) GRAPH_LINK_PX :: 2
@(private) GRAPH_LINK_ZOOMS :: [2]f32{0.6, 1.5}
@(private) GRAPH_LINK_HOT :: 1.8
// The emphasis of a link under the pointer, or of a node's links: their colour this far toward the text's (lighter on a
// dark theme, darker on a light one), a halo this many link widths wider than the link, of this share of the link's
// colour over the well. The other links keep this share of their colour over the well: less while a link is under the
// pointer (one path to follow) than while a node is (its links among the rest). The emphasis comes and goes at this rate
// (anim: halvings per second).
@(private) GRAPH_LINK_LIT :: 0.3
@(private) GRAPH_LINK_HALO :: 3
@(private) GRAPH_LINK_HALO_MIX :: 0.32
@(private) GRAPH_LINK_DIM_LINK :: 0.22
@(private) GRAPH_LINK_DIM_NODE :: 0.45
@(private) GRAPH_LIT_RATE :: 24
// The contrast on the well a lit link reaches at least (WCAG's for what is not text), and a faded link keeps.
@(private) GRAPH_LINK_LIT_CONTRAST :: 3
@(private) GRAPH_LINK_DIM_CONTRAST :: 1.5
// A dashed link's dash and gap, a dotted link's gap between dots: in the link's widths.
@(private) GRAPH_DASH :: [2]f32{3.5, 2.5}
@(private) GRAPH_DOT_GAP :: 2.5
// A node's header: this much of its accent over the panel (of the bad colour when it failed).
@(private) GRAPH_HEADER_TINT :: 0.30
@(private) GRAPH_FAILED_TINT :: 0.42
// A skipped node, a dimmed port: their opacity.
@(private) GRAPH_SKIPPED_ALPHA :: 0.45
@(private) GRAPH_DIM_ALPHA :: 0.3
// A running node's bar: its share of the header's width, and the time it takes to cross it.
@(private) GRAPH_RUN_BAR :: 0.3
@(private) GRAPH_RUN_MS :: 1100
// Text under this size (frame px) is not drawn: it would be a smear.
@(private) GRAPH_TEXT_LEAST_PX :: 6

// The theme's colours a graph draws with, read during the build.
@(private)
Node_Graph_Colors :: struct {
	text, weak, bad, good, accent, panel, border, well: Color,
}

@(private)
node_graph_colors :: proc() -> Node_Graph_Colors {
	return {
		text = color("text"), weak = color("weak text"), bad = color("bad text"), good = color("good text"),
		accent = color("accent"), panel = color("card background"), border = color("border"), well = color("well"),
	}
}

// How a port shows while a link is drawn: one it may end on glows, one it may not is dimmed.
@(private)
Node_Graph_Port_Mark :: enum u8 { Plain, Glow, Dim }

@(private)
Node_Graph_Port_Draw :: struct {
	name:      string,
	color:     Color,
	side:      flowgraph.Side,
	index:     int,
	linked:    bool,
	mark:      Node_Graph_Port_Mark,
	lit:       f32,     // an end of a link in the emphasis: how much (0..1)
}

@(private)
Node_Graph_Node_Draw :: struct {
	title:     [2]string,             // its lines (the second "" for one; cut with an ellipsis at the drawn size)
	subtitle, icon, message: string,
	font, icon_font: font.Font_Id,
	accent:    Color,
	state:     Graph_Node_State,
	selected:  bool,
	lit:       Color,                 // an end of a link in the emphasis: its edge in this colour (alpha: how much; 0: none)
	geo:       Node_Graph_Geometry,   // graph units: what is drawn at `k` frame px per unit from the box's top-left
	k:         f32,
	em:        f32,                   // the em, frame px
	ports:     []Node_Graph_Port_Draw,
	outputs:   int,                   // its out ports
	thumbnail: render.Texture,
	phase:     f32,                   // a running node's bar: where it is (0..1)
	colors:    Node_Graph_Colors,
	sc:        f32,
}

@(private)
Node_Graph_Link_Draw :: struct {
	a, b:  [2]f32,   // from the area's top-left, frame px: the out port, the in port
	color: Color,
	width: f32,
	dash:  Graph_Dash,
	layer: u8,       // 0 plain, 1 of the selection, 2 in the emphasis: drawn in this order
	halo:  Color,    // layer 2: under the link, opaque
	halo_width: f32,
}

@(private)
Node_Graph_Area_Draw :: struct {
	links:   []Node_Graph_Link_Draw,
	offset:  [2]f32,   // the graph's origin from the area's top-left, frame px
	k:       f32,      // frame px per graph unit
	least:   f32,      // node_graph_curve's least bend, frame px
	down:    bool,     // Graph_Direction.Down: the links bend vertically
	colors:  Node_Graph_Colors,
	sc:      f32,
}

@(private)
Node_Graph_Over_Draw :: struct {
	wire:     bool,
	wire_a, wire_b: [2]f32,   // from the area's top-left, frame px: out end, in end
	wire_color: Color,
	band:     Rect,             // empty: none
	minimap:  bool,
	map_rect: Rect,             // these from the area's top-left too
	map_nodes: []Rect,
	map_selected: []bool,
	map_view: Rect,
	least:    f32,
	down:     bool,
	width:    f32,
	colors:   Node_Graph_Colors,
	sc:       f32,
}

// The boxes of the frame: the nodes in view, each with its widgets, and the box over them.
@(private)
node_graph_build :: proc(f: ^Node_Graph_Frame) {
	view := f.view
	s := gs()
	z := graph_zoom(view)
	k := z * f.sc
	colors := node_graph_colors()
	area_rect := Rect{view.origin, view.origin + view.size}
	visible := make([]bool, len(f.nodes), context.temp_allocator)
	for _, i in f.nodes { visible[i] = node_graph_visible(f, i, area_rect) }

	// the ports a wire may end on, and those it may not
	wire, wiring := view.gesture.(Graph_Gesture_Wire)
	detached, has_detached := wire.detached.?

	// the links, those in view
	ad := frame_new(Node_Graph_Area_Draw)
	ad^ = {offset = view.offset * f.sc, k = k, least = node_graph_curve_least(f), down = f.down, colors = colors, sc = f.sc}
	links := make([dynamic]Node_Graph_Link_Draw, 0, len(f.links), frame_allocator())
	linked := make(map[flowgraph.Port_Ref]bool, len(f.links) * 2, context.temp_allocator)
	selected_link, has_selected := view.link.?
	base_width := node_graph_link_width(f)
	lit_t := node_graph_emphasis(f)
	// the ends of the links in the emphasis: their ports and the edges of their nodes lit in the link's colour
	lit_ports := make(map[flowgraph.Port_Ref]bool, 8, context.temp_allocator)
	lit_nodes := make(map[u64]Color, 8, context.temp_allocator)
	lit_colors := make(map[[5]f32]Color, 8, context.temp_allocator)   // (readable steps in OKLCH: once per colour and level)
	for l, li in f.links {
		if wiring && has_detached && l == detached { continue }
		from := flowgraph.Port_Ref{l.from_node, l.from_port, .Out}
		to := flowgraph.Port_Ref{l.to_node, l.to_port, .In}
		linked[from], linked[to] = true, true
		lit := lit_t > 0 && node_graph_is_lit(view, l)
		if lit {
			lit_ports[from], lit_ports[to] = true, true
		}
		a, ok_a := node_graph_port_screen(f, from)
		b, ok_b := node_graph_port_screen(f, to)
		if !ok_a || !ok_b { continue }
		ca, cb := node_graph_curve(a, b, ad.least, f.down)
		lo := [2]f32{min(a.x, b.x, ca.x, cb.x), min(a.y, b.y, ca.y, cb.y)}
		hi := [2]f32{max(a.x, b.x, ca.x, cb.x), max(a.y, b.y, ca.y, cb.y)}
		if !node_graph_overlaps({lo - base_width, hi + base_width}, area_rect) { continue }
		look := li < len(f.o.link_looks) ? f.o.link_looks[li] : Graph_Link_Look{}
		c: Color
		if look.intent != .Neutral {
			c = hue_color(intent_hue(look.intent))
		} else {
			port, _, _ := node_graph_port(f, from)
			c = node_graph_kind_color(f, port.kind, colors.accent)
		}
		// (a link to a node that was skipped faded: an opaque mix, a translucent stroke goes through a layer)
		if i, ok := f.index[l.to_node]; ok && f.nodes[i].state == .Skipped { c = draw.mix(colors.well, c, GRAPH_SKIPPED_ALPHA) }
		ld := Node_Graph_Link_Draw{a = a - view.origin, b = b - view.origin, color = c, width = base_width, dash = look.dash}
		// (the selected link, the links of the selected nodes: over the others, thicker and lighter, not dimmed)
		if (has_selected && l == selected_link) || f.sel[l.from_node] || f.sel[l.to_node] {
			ld.layer, ld.width, ld.color = 1, base_width * GRAPH_LINK_HOT, node_graph_lit_color(&lit_colors, c, colors, 1)
		}
		if lit {
			for end in ([2]u64{l.from_node, l.to_node}) {
				if end != view.lit_node && end not_in lit_nodes { lit_nodes[end] = c }
			}
			ld.layer = 2
			ld.width = max(ld.width, base_width * (1 + (GRAPH_LINK_HOT - 1) * lit_t))
			ld.color = node_graph_lit_color(&lit_colors, c, colors, lit_t)
			ld.halo = draw.mix(colors.well, c, GRAPH_LINK_HALO_MIX)
			ld.halo.a = 1
			ld.halo_width = ld.width + base_width * GRAPH_LINK_HALO * lit_t
		} else if lit_t > 0 {
			// (an opaque mix toward the well, as a skipped node's links: no layer per link)
			keep := max(view.lit_dim, node_graph_dim_floor(ld.color, colors.well))
			ld.color = draw.mix(colors.well, ld.color, 1 - (1 - keep) * lit_t)
			ld.color.a = 1
		}
		append(&links, ld)
	}
	ad.links = links[:]
	f.area.custom, f.area.custom_user = node_graph_area_draw, ad

	running := false
	phase := f32(math.mod(s.time_ms, GRAPH_RUN_MS) / GRAPH_RUN_MS)
	if parent(f.area) {
		for &n, i in f.nodes {
			if !visible[i] { continue }
			g := f.geo[i]
			// (the node's box in whole pixels, both its edges rounded once: its body's box is cut from it below, so the
			// two share their pixel grid and the body's gaps are whole and equal. Rounded each on its own, as the layout
			// rounds a floating box, a gap was off by up to 1.6 px from its other side)
			lo := node_graph_local(f, g.rect.min)
			hi := node_graph_local(f, g.rect.max)
			// (half up, never away from zero: a node left of or above the area's origin keeps the width it has at the right)
			lo, hi = {math.floor(lo.x + 0.5), math.floor(lo.y + 0.5)}, {math.floor(hi.x + 0.5), math.floor(hi.y + 0.5)}
			size := hi - lo
			nd := frame_new(Node_Graph_Node_Draw)
			nd^ = {
				title = node_graph_title_lines(&n, &g, f.font, f.em, k), subtitle = strings.clone(n.subtitle, frame_allocator()),
				icon = strings.clone(n.icon, frame_allocator()), message = strings.clone(n.message, frame_allocator()),
				font = top_style().font, icon_font = f.o.icon_font,
				accent = n.color.a > 0 ? n.color : colors.accent,
				state = n.state, selected = f.sel[n.id], geo = g, k = k, em = f.em * k,
				lit = node_graph_lit_edge(lit_nodes, n.id, lit_t),
				thumbnail = n.thumbnail, phase = phase, colors = colors, sc = f.sc,
			}
			nd.geo.rect = {{}, g.rect.max - g.rect.min}   // (drawn from the box's top-left)
			ports := make([]Node_Graph_Port_Draw, len(n.inputs) + len(n.outputs), frame_allocator())
			at := 0
			for side in flowgraph.Side {
				for p, idx in (side == .In ? n.inputs : n.outputs) {
					ref := flowgraph.Port_Ref{n.id, p.id, side}
					mark := Node_Graph_Port_Mark.Plain
					if wiring && ref != wire.from {
						mark = node_graph_compatible(f, wire.from, ref) ? .Glow : .Dim
					}
					ports[at] = {
						name = strings.clone(p.name, frame_allocator()), color = node_graph_kind_color(f, p.kind, colors.accent),
						side = side, index = idx, linked = linked[ref], mark = mark, lit = lit_ports[ref] ? lit_t : 0,
					}
					at += 1
				}
			}
			nd.ports = ports
			nd.outputs = len(n.outputs)
			if n.state == .Running { running = true }

			next({fixed_x = lo.x, fixed_y = lo.y, fixed_w = size.x, fixed_h = size.y})
			nb := build_box({}, node_graph_node_id(n.id))
			nb.custom, nb.custom_user = node_graph_node_draw, nd
			a11y_default(nb, {role = .Group, name = n.title, description = n.subtitle, selected = f.sel[n.id]})
			if g.detail && f.o.body != nil {
				if parent(nb) {
					// (the widgets at the zoom: their em is the graph's)
					bem := font_size() * z
					inset := math.round(g.pad * k)
					next({fixed_x = inset, fixed_y = math.round(g.body_top * k), fixed_w = size.x - 2 * inset, height = children_sum(), axis = .Y})
					body := build_box({}, NODE_GRAPH_BODY_ID)
					if parent(body) {
						if style({font_size = bem}) { f.o.body(f.o.user, n.id, bem) }
					}
				}
			}
		}

		od := frame_new(Node_Graph_Over_Draw)
		od^ = {least = ad.least, down = f.down, width = base_width, colors = colors, sc = f.sc}
		if wiring {
			if a, ok := node_graph_port_screen(f, wire.from); ok {
				free_end := view.origin + node_graph_local(f, wire.at)
				if t, on := wire.target.?; on { free_end, _ = node_graph_port_screen(f, t) }
				od.wire = true
				od.wire_a, od.wire_b = a - view.origin, free_end - view.origin
				if wire.from.side == .In { od.wire_a, od.wire_b = od.wire_b, od.wire_a }
				port, _, _ := node_graph_port(f, wire.from)
				od.wire_color = node_graph_kind_color(f, port.kind, colors.accent)
			}
		}
		if band, ok := view.gesture.(Graph_Gesture_Band); ok && band.moved {
			a := node_graph_local(f, band.from)
			b := node_graph_local(f, band.to)
			od.band = {{min(a.x, b.x), min(a.y, b.y)}, {max(a.x, b.x), max(a.y, b.y)}}
		}
		mm_rect_local: Rect
		if f.o.minimap.show {
			mm: Node_Graph_Minimap
			mm_ok: bool
			if mg, dragging_mm := view.gesture.(Graph_Gesture_Minimap); dragging_mm && mg.k > 0 {
				mm, mm_ok = {rect = mg.rect, lo = mg.lo, pad = mg.pad, k = mg.k}, true
			} else {
				mm, mm_ok = node_graph_minimap(f, area_rect)
			}
			if mm_ok {
				od.minimap = true
				od.map_rect = {mm.rect.min - view.origin, mm.rect.max - view.origin}
				mm_rect_local = od.map_rect
				od.map_nodes = make([]Rect, len(f.nodes), frame_allocator())
				od.map_selected = make([]bool, len(f.nodes), frame_allocator())
				for g, i in f.geo {
					od.map_nodes[i] = {node_graph_minimap_from_graph(mm, g.rect.min) - view.origin, node_graph_minimap_from_graph(mm, g.rect.max) - view.origin}
					od.map_selected[i] = f.sel[f.nodes[i].id]
				}
				vlo := graph_from_screen(view, area_rect.min)
				vhi := graph_from_screen(view, area_rect.max)
				od.map_view = {node_graph_minimap_from_graph(mm, vlo) - view.origin, node_graph_minimap_from_graph(mm, vhi) - view.origin}
			}
		}
		next({fixed_x = 0, fixed_y = 0, width = pct(1), height = pct(1)})
		custom("###graph_over", node_graph_over_draw, od)
		// When the graph has nodes and none intersect the current viewport, offer a one-click return above the minimap
		// (or in the bottom-right corner) so the user is never stranded in empty space.
		if len(f.nodes) > 0 && view.size.x > 0 && view.size.y > 0 {
			vrect := Rect{graph_from_screen(view, area_rect.min), graph_from_screen(view, area_rect.max)}
			any_visible := false
			for g in f.geo {
				if node_graph_overlaps(g.rect, vrect) { any_visible = true; break }
			}
			if !any_visible {
				label_text := i18n.tr("Back to content")
				bw := button_width(label_text, glyph = true)
				bh := math.round(dense(font_size() * CONTROL_HEIGHT_EM))
				margin := GRAPH_MINIMAP_MARGIN * f.sc
				// (in the minimap's corner, beside it toward the middle; with no minimap, the bottom-right one)
				corner := od.minimap ? (f.o.minimap.corner.? or_else .Bottom_Right) : .Bottom_Right
				right := corner == .Top_Right || corner == .Bottom_Right
				bottom := corner == .Bottom_Left || corner == .Bottom_Right
				bx := right ? max(margin, view.size.x - margin - bw) : margin
				by := bottom ? max(margin, view.size.y - margin - bh) : margin
				if od.minimap { by = bottom ? max(margin, mm_rect_local.min.y - margin * 0.6 - bh) : mm_rect_local.max.y + margin * 0.6 }
				next({fixed_x = bx, fixed_y = by, width = px(bw), height = px(bh)})
				if button("###graph_back", label_text, lucide.MAXIMIZE_2, {icon_font = lucide_icons(), intent = .Primary, tip = i18n.tr("Fit the graph in view (F)")}).clicked {
					graph_fit(view, f.nodes, view.size / f.sc)
				}
			}
		}
	}
	// a running node's bar moves: frames while one shows, none at rest
	if running { keep_animating() }
}

// How much of the emphasis shows (0..1): of the link under the pointer, else of the node under it (with a link; its
// own during its move). It fades in and out (anim); Graph_View.lit_* keep what it is about while it fades out.
@(private)
node_graph_emphasis :: proc(f: ^Node_Graph_Frame) -> f32 {
	view := f.view
	link, on_link := view.hover_link.?
	node := u64(0)
	_, moving := view.gesture.(Graph_Gesture_Move)
	if !on_link && view.hover_node != 0 && (view.gesture == nil || moving) {
		for l in f.links {
			if l.from_node == view.hover_node || l.to_node == view.hover_node { node = view.hover_node; break }
		}
	}
	on := on_link || node != 0
	if on {
		view.lit_link, view.lit_node = nil, node
		if on_link { view.lit_link = link }
		view.lit_dim = on_link ? GRAPH_LINK_DIM_LINK : GRAPH_LINK_DIM_NODE
	}
	t := anim(key_from_string(view.key, "###graph_lit"), on ? 1 : 0, GRAPH_LIT_RATE)
	if !on && t <= 0 { view.lit_link, view.lit_node = nil, 0 }
	return t
}

// A link of colour `c` lit at `t` (0..1): stepped toward the text, and at least GRAPH_LINK_LIT_CONTRAST on the well
// at the full emphasis (the ratio grows with `t`). `cache` keeps the colours this build made: a hub node lights hundreds
// of links of a few colours.
@(private = "file")
node_graph_lit_color :: proc(cache: ^map[[5]f32]Color, c: Color, colors: Node_Graph_Colors, t: f32) -> Color {
	key := [5]f32{c.r, c.g, c.b, c.a, t}
	if x, ok := cache[key]; ok { return x }
	lit := readable(srgb_step(c, colors.text, GRAPH_LINK_LIT * t), colors.well, 1 + (GRAPH_LINK_LIT_CONTRAST - 1) * t)
	cache[key] = lit
	return lit
}

// The share of colour `c` over the well that keeps GRAPH_LINK_DIM_CONTRAST on it (1: `c` has less; it does not fade).
// A mix toward the well is linear in luminance: the share is solved, not searched.
@(private = "file")
node_graph_dim_floor :: proc(c, well: Color) -> f32 {
	lc, lw := luminance(c) + 0.05, luminance(well) + 0.05
	if contrast(c, well) <= GRAPH_LINK_DIM_CONTRAST { return 1 }
	want := lc > lw ? lw * GRAPH_LINK_DIM_CONTRAST : lw / GRAPH_LINK_DIM_CONTRAST
	return clamp((want - lw) / (lc - lw), 0, 1)
}

// Whether link `l` is in the emphasis (Graph_View.lit_*).
@(private)
node_graph_is_lit :: proc(view: ^Graph_View, l: Graph_Link) -> bool {
	if x, ok := view.lit_link.?; ok { return x == l }
	return view.lit_node != 0 && (l.from_node == view.lit_node || l.to_node == view.lit_node)
}

// The colour of node `id`'s lit edge, its alpha the emphasis (none: not an end of a lit link).
@(private = "file")
node_graph_lit_edge :: proc(lit_nodes: map[u64]Color, id: u64, t: f32) -> Color {
	c, ok := lit_nodes[id]
	if !ok { return {} }
	c.a = t
	return c
}

////////////////////////////////
// Drawing

@(private)
node_graph_area_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Node_Graph_Area_Draw)(user)
	r := b.rect
	machined_well(dc, r, 0, d.colors.well)
	// the grid: lines every step, a major one every GRAPH_GRID_MAJOR, from the graph's origin.
	// Computed in f64 with a bounded integer step count: an f32 loop `i += 1` stalled forever once |offset/sp| >= 2^24.
	if d.k > 0 && !math.is_nan(d.k) && !math.is_inf(d.k, 0) && !math.is_nan(d.offset.x) && !math.is_nan(d.offset.y) && !math.is_inf(d.offset.x, 0) && !math.is_inf(d.offset.y, 0) {
		step := f32(GRAPH_GRID)
		for step * d.k < GRAPH_GRID_LEAST_PX * d.sc { step *= 2 }
		sp := f64(step) * f64(d.k)
		if sp >= 1 {
			px := max(1, math.round(d.sc))
			minor, major := d.colors.border, d.colors.border
			minor.a *= GRAPH_GRID_MINOR_ALPHA
			major.a *= GRAPH_GRID_MAJOR_ALPHA
			ox, oy := f64(r.min.x) + f64(d.offset.x), f64(r.min.y) + f64(d.offset.y)
			first_x := i64(math.floor((f64(r.min.x) - ox) / sp))
			count_x := int(math.ceil(f64(r.max.x - r.min.x) / sp)) + 2
			for k in 0 ..< count_x {
				idx := first_x + i64(k)
				x := f32(math.round(ox + f64(idx) * sp))
				if x >= r.max.x { break }
				if x + px > r.min.x { draw.rect(dc, {{x, r.min.y}, {x + px, r.max.y}}, idx % GRAPH_GRID_MAJOR == 0 ? major : minor) }
			}
			first_y := i64(math.floor((f64(r.min.y) - oy) / sp))
			count_y := int(math.ceil(f64(r.max.y - r.min.y) / sp)) + 2
			for k in 0 ..< count_y {
				idx := first_y + i64(k)
				y := f32(math.round(oy + f64(idx) * sp))
				if y >= r.max.y { break }
				if y + px > r.min.y { draw.rect(dc, {{r.min.x, y}, {r.max.x, y + px}}, idx % GRAPH_GRID_MAJOR == 0 ? major : minor) }
			}
		}
	}
	// the plain links, then the selection's over them, then the emphasis's over all: their halos first, so that none
	// covers another lit link
	for layer in u8(0) ..= 2 {
		if layer == 2 {
			for l in d.links {
				if l.layer != 2 || l.halo_width <= l.width { continue }
				a, e := r.min + l.a, r.min + l.b
				ca, cb := node_graph_curve(a, e, d.least, d.down)
				draw.bezier(dc, a, ca, cb, e, l.halo_width, l.halo)
			}
		}
		for l in d.links {
			if l.layer != layer { continue }
			node_graph_link_stroke(dc, r.min, l, d.least, d.down)
		}
	}
}

@(private = "file")
node_graph_link_stroke :: proc(dc: ^draw.Context, origin: [2]f32, l: Node_Graph_Link_Draw, least: f32, down: bool) {
	a, e := origin + l.a, origin + l.b
	ca, cb := node_graph_curve(a, e, least, down)
	if l.dash == .Solid {
		draw.bezier(dc, a, ca, cb, e, l.width, l.color)
		return
	}
	p := draw.path_make(allocator = context.temp_allocator)
	draw.path_move_to(&p, a)
	draw.path_cubic_to(&p, ca, cb, e)
	pattern := l.dash == .Dashed ? []f32{GRAPH_DASH.x * l.width, GRAPH_DASH.y * l.width} : []f32{0, GRAPH_DOT_GAP * l.width}
	cut := draw.path_dash(&p, pattern, 0, context.temp_allocator)
	draw.path_stroke(dc, &cut, l.width, l.color)
}

// A node's title as drawn: its first line, and its second cut with an ellipsis when the title had more (at the drawn
// size `em * k`, in the frame's memory). The lines are those of the zoom 1 (node_graph_title_wrap): the node keeps its
// shape while the zoom changes.
@(private)
node_graph_title_lines :: proc(n: ^Graph_Node, g: ^Node_Graph_Geometry, f: font.Font_Id, em, k: f32) -> (lines: [2]string) {
	title := strings.clone(n.title, frame_allocator())
	if g.title_lines < 2 {
		lines[0] = title
		return
	}
	room := node_graph_title_room(n, g.rect.max.x - g.rect.min.x, em)
	all := wrap_lines_cached(f, em, title, room)
	if len(all) < 2 {
		lines[0] = title
		return
	}
	lines[0] = title[all[0][0]:all[0][1]]
	lines[1] = title[all[1][0]:all[1][1]]
	if g.title_cut {
		// (the ellipsis already at the line's end: elide keeps it there, cutting the line before it)
		with := strings.concatenate({lines[1], ELLIPSIS}, context.temp_allocator)
		lines[1] = elide(f, em * k, with, room * k, allocator = frame_allocator())
	}
	return
}

// A box's text at baseline `y`, from `x`, within `right` (cut at it).
@(private = "file")
node_graph_text :: proc(dc: ^draw.Context, id: font.Font_Id, size: f32, x, middle, right: f32, c: Color, text: string) {
	if text == "" || size < GRAPH_TEXT_LEAST_PX || right <= x { return }
	s := gs()
	m := font.metrics(s.fonts, id, size)
	y := math.round(middle + (m.ascent - m.descent) * 0.5)
	draw.push_clip(dc, {{x, middle - size}, {right, middle + size}})
	draw.text(dc, id, size, {math.round(x), y}, c, text)
	draw.pop_clip(dc)
}

@(private)
node_graph_node_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Node_Graph_Node_Draw)(user)
	c := d.colors
	r := b.rect
	k := d.k
	g := &d.geo
	p := max(1, math.round(d.sc))
	radius := rad(GRAPH_RADIUS_EM * d.em)
	if d.state == .Skipped { draw.push_alpha(dc, GRAPH_SKIPPED_ALPHA) }
	defer if d.state == .Skipped { draw.pop_alpha(dc) }

	// the selection's ring, outside the face
	if d.selected {
		ring := draw.rect_pad(r, 2 * p)
		// (a relief without halos has none here either: Relief.no_glow)
		if rl := relief_shown(); machined() && !rl.no_glow { draw.box_shadow(dc, ring, {radius, radius, radius, radius}, 4 * d.sc, {c.accent.r, c.accent.g, c.accent.b, 0.35}) }
		draw.rect(dc, ring, c.accent, radius + 2 * p, 2 * p)
	}
	machined_plate(dc, r, radius, c.panel, relief_darken(c.panel, 0.06), 6 * min(d.k / d.sc, 1))

	// the header: the node's accent over the panel, its icon, title and subtitle, the state's mark at its right
	header := Rect{r.min, {r.max.x, r.min.y + g.header * k}}
	tint := d.state == .Failed ? draw.mix(c.panel, c.bad, GRAPH_FAILED_TINT) : draw.mix(c.panel, d.accent, GRAPH_HEADER_TINT)
	tint.a = 1
	paint_rect_corners(dc, header, tint, {radius, 0, radius, 0}, 0.6)
	machined_groove(dc, {header.min.x, header.max.y - p}, {header.max.x, header.max.y - p})
	pad := g.pad * k
	x := r.min.x + pad
	// (the mark's room is kept for an idle node too: a run that starts does not move the title)
	mark_w := d.em * GRAPH_MARK_EM
	right := r.max.x - pad - mark_w
	title_mid := header.min.y + d.em * (d.subtitle != "" ? GRAPH_TITLE_SUB_MID_EM : GRAPH_TITLE_MID_EM)
	if d.icon != "" && d.icon_font != 0 {
		node_graph_text(dc, d.icon_font, d.em * 1.05, x, title_mid, right, c.text, d.icon)
		x += d.em * GRAPH_ICON_EM
	}
	last_mid := title_mid
	node_graph_text(dc, d.font, d.em, x, title_mid, right, c.text, d.title[0])
	if d.title[1] != "" {
		last_mid += d.em * GRAPH_TITLE_LINE_EM
		node_graph_text(dc, d.font, d.em, x, last_mid, right, c.text, d.title[1])
	}
	if d.subtitle != "" { node_graph_text(dc, d.font, d.em * 0.85, x, last_mid + d.em * GRAPH_SUB_GAP_EM, right, c.weak, d.subtitle) }
	mark := [2]f32{r.max.x - pad - mark_w * 0.5, title_mid}
	switch d.state {
	case .Idle:
	case .Skipped:
		// a ring crossed out: nothing ran here (what came before failed, or gave nothing), said beside the fading
		e := d.em * 0.3
		w := max(1.5 * d.sc, d.em * 0.11)
		draw.rect(dc, {mark - e, mark + e}, c.weak, e, w)
		draw.line(dc, mark + {-e * 0.7, e * 0.7}, mark + {e * 0.7, -e * 0.7}, w, c.weak)
	case .Running:
		machined_lamp(dc, mark, d.em * 0.55, c.accent, 1, 0.5 + 0.5 * turn.sin(d.phase))
		// a bar that crosses the header's bottom edge: the node is at work
		w := (header.max.x - header.min.x) * GRAPH_RUN_BAR
		bx := header.min.x - w + (header.max.x - header.min.x + w) * d.phase
		draw.push_clip(dc, header)
		draw.rect(dc, {{bx, header.max.y - 2 * p}, {bx + w, header.max.y}}, c.accent)
		draw.pop_clip(dc)
	case .Done:
		e := d.em * 0.32
		w := max(1.5 * d.sc, d.em * 0.13)
		draw.line(dc, mark + {-e, 0}, mark + {-e * 0.3, e * 0.7}, w, c.good)
		draw.line(dc, mark + {-e * 0.3, e * 0.7}, mark + {e, -e * 0.7}, w, c.good)
	case .Failed:
		e := d.em * 0.28
		w := max(1.5 * d.sc, d.em * 0.13)
		draw.line(dc, mark - e, mark + e, w, c.bad)
		draw.line(dc, mark + {-e, e}, mark + {e, -e}, w, c.bad)
	}

	// the ports: a dot on the side, coloured by kind (hollow while it has no link), the name beside it
	dot := GRAPH_PORT_EM * d.em * 0.5
	for port in d.ports {
		at := r.min + node_graph_port_at(g, port.side, port.index) * k
		y := at.y
		dim := port.mark == .Dim
		if dim { draw.push_alpha(dc, GRAPH_DIM_ALPHA) }
		dr := dot
		if port.mark == .Glow {
			dr *= 1.3
			draw.box_shadow(dc, {at - dr, at + dr}, {dr, dr, dr, dr}, dr, {port.color.r, port.color.g, port.color.b, 0.7})
		} else if port.lit > 0 {
			dr *= 1 + 0.3 * port.lit
			draw.box_shadow(dc, {at - dr, at + dr}, {dr, dr, dr, dr}, dr, {port.color.r, port.color.g, port.color.b, 0.7 * port.lit})
		}
		draw.rect(dc, {at - dr - p, at + dr + p}, c.well, dr + p)
		if port.linked || port.mark == .Glow {
			draw.rect(dc, {at - dr, at + dr}, port.color, dr)
		} else {
			draw.rect(dc, {at - dr, at + dr}, port.color, dr, max(p, dr * 0.4))
		}
		if g.names && port.name != "" {
			size := d.em * 0.85
			if port.side == .In {
				// (to the middle when an out port may stand beside it: its row's, or any on the edges; else across)
				shared := g.rows > 0 ? port.index < d.outputs : d.outputs > 0
				edge := shared ? (r.min.x + r.max.x) * 0.5 : r.max.x - pad
				node_graph_text(dc, d.font, size, r.min.x + pad + dot, y, edge, c.weak, port.name)
			} else {
				tw := font.text_width(gs().fonts, d.font, size, port.name)
				node_graph_text(dc, d.font, size, r.max.x - pad - dot - tw, y, r.max.x - pad - dot + 1, c.weak, port.name)
			}
		}
		if dim { draw.pop_alpha(dc) }
	}

	if g.detail && d.thumbnail != 0 && g.thumb.max.x > g.thumb.min.x {
		t := Rect{r.min + g.thumb.min * k, r.min + g.thumb.max * k}
		draw.image(dc, d.thumbnail, t, radius = rad(d.em * 0.25))
	}
	if d.state == .Failed { draw.rect(dc, r, c.bad, radius, 1.5 * p) }
	// (an end of a link in the emphasis: its edge in the link's colour, outside a failed node's)
	if d.lit.a > 0 { draw.rect(dc, draw.rect_pad(r, p), d.lit, radius + p, 1.5 * p) }
	if d.message != "" {
		size := d.em * 0.85
		ink := d.state == .Failed ? c.bad : c.weak
		if g.message_mid > 0 {
			node_graph_text(dc, d.font, size, r.min.x + pad, r.min.y + g.message_mid * k, r.max.x - pad, ink, d.message)
		} else {
			node_graph_text(dc, d.font, size, r.min.x + p, r.max.y + d.em * 0.85, r.max.x + d.em * 6, ink, d.message)
		}
	}
}

@(private)
node_graph_over_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Node_Graph_Over_Draw)(user)
	o := b.rect.min
	c := d.colors
	p := max(1, math.round(d.sc))
	if d.wire {
		a, e := o + d.wire_a, o + d.wire_b
		ca, cb := node_graph_curve(a, e, d.least, d.down)
		draw.bezier(dc, a, ca, cb, e, d.width * GRAPH_LINK_HOT, d.wire_color)
	}
	if d.band.max.x > d.band.min.x {
		band := Rect{o + d.band.min, o + d.band.max}
		draw.rect(dc, band, {c.accent.r, c.accent.g, c.accent.b, 0.12})
		draw.rect(dc, band, c.accent, 0, p)
	}
	if d.minimap {
		mr := Rect{o + d.map_rect.min, o + d.map_rect.max}
		radius := rad(4 * d.sc)
		machined_plate(dc, mr, radius, c.panel, c.panel, 4)
		draw.push_clip(dc, mr)
		for nr, i in d.map_nodes {
			q := Rect{o + nr.min, o + nr.max}
			draw.rect(dc, q, d.map_selected[i] ? c.accent : c.weak, rad(1.5 * d.sc))
		}
		v := Rect{o + d.map_view.min, o + d.map_view.max}
		draw.rect(dc, v, {c.text.r, c.text.g, c.text.b, 0.06})
		draw.rect(dc, v, c.text, 0, p)
		draw.pop_clip(dc)
	}
}
