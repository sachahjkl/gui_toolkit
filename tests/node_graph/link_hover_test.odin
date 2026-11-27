package node_graph_test

// The link under the pointer among others that overlap it: the nearest is picked, Alt+wheel walks the others, a tooltip
// names it; it is drawn over the others, lit, and the others fade; a node under the pointer lights its links. Read in
// pixels where the links cross.

import "core:testing"
import "gt:draw"
import flowgraph "gt:flowgraph"
import "gt:render"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") SIZE :: [2]int{900, 560}
@(private = "file") RED :: 0
@(private = "file") BLUE :: 1
@(private = "file") GREEN :: 2
// A node's header, at least (em at the zoom 1): its title's line.
@(private = "file") HEADER_EM :: 1.6
// The tooltips' delay here: a frame is slow on a software GPU.
@(private = "file") TIP_DELAY_MS :: 100

@(private = "file")
Hover :: struct {
	view:     ui.Graph_View,
	nodes:    [dynamic]ui.Graph_Node,
	links:    [dynamic]ui.Graph_Link,
	selected: [dynamic]u64,
	o:        ui.Graph_Options,
	// the theme's, read in the build
	well, text: ui.Color,
}

@(private = "file") kinds := []ui.Color{{0.85, 0.12, 0.10, 1}, {0.10, 0.30, 0.90, 1}, {0.10, 0.65, 0.20, 1}}
@(private = "file") out_red := []ui.Graph_Port{{id = 1, name = "out", kind = RED, side = .Out}}
@(private = "file") out_blue := []ui.Graph_Port{{id = 1, name = "out", kind = BLUE, side = .Out}}
@(private = "file") out_green := []ui.Graph_Port{{id = 1, name = "out", kind = GREEN, side = .Out}}
@(private = "file") in_any := []ui.Graph_Port{{id = 2, name = "in", kind = RED, side = .In, multiple = true}}

@(private = "file")
hover_build :: proc(s: ^session.Session) {
	h := (^Hover)(s.user)
	h.well, h.text = ui.color("well"), ui.color("text")
	events := ui.node_graph("###graph", &h.view, h.nodes[:], h.links[:], h.selected[:], h.o)
	for e in events {
		#partial switch v in e {
		case ui.Graph_Selected:
			clear(&h.selected)
			append(&h.selected, ..v.nodes)
		}
	}
}

@(private = "file")
hover_destroy :: proc(h: ^Hover) {
	delete(h.nodes)
	delete(h.links)
	delete(h.selected)
}

@(private = "file")
short_tips :: proc(s: ^session.Session) {
	f := ui.feel(s.state)
	f.tooltip_delay_ms = TIP_DELAY_MS
	ui.set_feel(s.state, f)
}

// Three sources on the left, three targets on the right, each source linked to the target across from another: S1 to
// T3, S2 to T2, S3 to T1. The three curves are symmetric about the middle and cross there.
@(private = "file")
three_crossing :: proc(h: ^Hover) {
	h.o.kind_colors = kinds
	outs := [3][]ui.Graph_Port{out_red, out_blue, out_green}
	sources := [3]string{"Source 1", "Source 2", "Source 3"}
	targets := [3]string{"Target 1", "Target 2", "Target 3"}
	for i in 0 ..< 3 {
		y := 40 + 160 * f32(i)
		append(&h.nodes, ui.Graph_Node{id = u64(1 + i), title = sources[i], pos = {40, y}, outputs = outs[i]})
		append(&h.nodes, ui.Graph_Node{id = u64(11 + i), title = targets[i], pos = {600, y}, inputs = in_any})
	}
	append(&h.links, ui.Graph_Link{1, 1, 13, 2}, ui.Graph_Link{2, 1, 12, 2}, ui.Graph_Link{3, 1, 11, 2})
}

@(private = "file")
port_at :: proc(h: ^Hover, id: u64, side: flowgraph.Side) -> [2]f32 {
	for &n in h.nodes {
		if n.id == id { return ui.graph_to_screen(&h.view, ui.graph_port_pos(&h.view, &n, side, 0)) }
	}
	return {}
}

// A point of link `l` on the screen at `t` (0: its out port, 1: its in port), by the curve node_graph draws (.Right).
@(private = "file")
link_at :: proc(h: ^Hover, l: ui.Graph_Link, t: f32) -> [2]f32 {
	a := port_at(h, l.from_node, .Out)
	b := port_at(h, l.to_node, .In)
	least := 3 * h.view.em * ui.graph_zoom(&h.view) * h.view.scale
	dx := max(abs(b.x - a.x) * 0.5, least)
	return draw.bezier_cubic_at(a, a + {dx, 0}, b - {dx, 0}, b, t)
}

@(private = "file")
rgba8 :: proc(c: ui.Color) -> session.Color {
	b :: proc(v: f32) -> u8 { return u8(clamp(render.linear_to_srgb(v), 0, 1) * 255 + 0.5) }
	return {b(c.r), b(c.g), b(c.b), 255}
}

// The pixel nearest to `want` within `reach` pixels of `at`.
@(private = "file")
nearest_to :: proc(img: session.Image, at: [2]f32, want: session.Color, reach := 2) -> session.Color {
	best: session.Color
	least := max(int)
	for dy in -reach ..= reach {
		for dx in -reach ..= reach {
			p := session.pixel(img, int(at.x) + dx, int(at.y) + dy)
			d := 0
			for i in 0 ..< 3 { d = max(d, abs(int(p[i]) - int(want[i]))) }
			if d < least { least, best = d, p }
		}
	}
	return best
}

// What a link of kind colour `c` is drawn in: lit (in the emphasis: stepped toward the text, 3:1 on the well at least),
// dimmed (another is: `keep` of its colour over the well, or what keeps 1.5:1 on it).
@(private = "file") lit_of :: proc(h: ^Hover, c: ui.Color) -> session.Color { return rgba8(ui.readable(ui.srgb_step(c, h.text, 0.3), h.well, 3)) }
@(private = "file")
dim_of :: proc(h: ^Hover, c: ui.Color, keep: f32) -> session.Color {
	lc, lw := ui.luminance(c) + 0.05, ui.luminance(h.well) + 0.05
	floor := f32(1)
	if ui.contrast(c, h.well) > 1.5 { floor = ((lc > lw ? lw * 1.5 : lw / 1.5) - lw) / (lc - lw) }
	return rgba8(draw.mix(h.well, c, max(keep, floor)))
}

// A pixel's colour, linear.
@(private = "file")
linear :: proc(p: session.Color) -> ui.Color {
	return {render.srgb_to_linear(f32(p[0]) / 255), render.srgb_to_linear(f32(p[1]) / 255), render.srgb_to_linear(f32(p[2]) / 255), 1}
}

// The highest contrast on `ground` among the pixels within `reach` of `at`: a line's core.
@(private = "file")
core_contrast :: proc(img: session.Image, at: [2]f32, ground: ui.Color, reach := 2) -> f32 {
	best := f32(1)
	for dy in -reach ..= reach {
		for dx in -reach ..= reach { best = max(best, ui.contrast(linear(session.pixel(img, int(at.x) + dx, int(at.y) + dy)), ground)) }
	}
	return best
}

// Among three links under the pointer the nearest is the one hovered, not the first; Alt+wheel takes the next, then wraps;
// a click selects the one taken; a tooltip names it and says how many are there.
@(test)
the_nearest_link_is_picked_and_alt_wheel_walks_the_others :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	h: Hover
	defer hover_destroy(&h)
	three_crossing(&h)
	s := session.start(t, {size = SIZE, user = &h, build = hover_build})
	short_tips(s)
	// (4 px right of the middle: on the straight middle link, about 3 px from the two steep ones)
	at := link_at(&h, h.links[1], 0.5) + {4, 0}
	session.move(s, at)
	testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[1])
	session.advance(s, TIP_DELAY_MS + 3 * session.FRAME_MS)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Source 2 · out → Target 2 · in") != nil, "the tooltip names the link")
	testing.expect(t, session.find_text(s, "2 of 3 here · Alt+wheel for the next") != nil, "and its place among those there")
	offset := h.view.offset
	session.wheel(s, at, {0, 1}, {.Alt})
	testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[2])
	testing.expect_value(t, h.view.offset, offset)   // (it does not move the view)
	session.frames(s, 1)
	testing.expect(t, session.find_text(s, "3 of 3 here · Alt+wheel for the next") != nil, "the tooltip at once, of the next")
	session.wheel(s, at, {0, 1}, {.Alt})
	testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[0])
	session.click_at(s, at)
	testing.expect_value(t, h.view.link.? or_else {}, h.links[0])
	// (the pointer away: the pick is forgotten; back over the crossing, the nearest again)
	session.move(s, {450, 540})
	session.move(s, at)
	testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[1])
}) }

// Where two links cross, the one under the pointer is drawn over the other, lit; the other links are dimmed; with the
// pointer away, every link is in its own colour again.
@(test)
the_hovered_link_is_drawn_over_the_others_lit :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	h: Hover
	defer hover_destroy(&h)
	three_crossing(&h)
	s := session.start(t, {size = SIZE, user = &h, build = hover_build})
	cross := link_at(&h, h.links[1], 0.5)
	for target in ([2]int{0, 2}) {
		// (on the link, a quarter of the way: no other link near)
		session.move(s, link_at(&h, h.links[target], 0.25))
		testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[target])
		session.frame(s)
		img := session.capture(s)
		want := lit_of(&h, kinds[target == 0 ? RED : GREEN])
		got := nearest_to(img, cross, want)
		testing.expectf(t, session.near(got, want, 24), "link %d lit over the crossing: %v, want %v", target, got, want)
		// (the middle link, away from the crossing: dimmed)
		dim := dim_of(&h, kinds[BLUE], 0.22)
		got = nearest_to(img, link_at(&h, h.links[1], 0.15), dim)
		testing.expectf(t, session.near(got, dim, 24), "the others dimmed: %v, want %v", got, dim)
	}
	session.move(s, {450, 540})
	session.frame(s)
	img := session.capture(s)
	plain := rgba8(kinds[BLUE])
	got := nearest_to(img, link_at(&h, h.links[1], 0.15), plain)
	testing.expectf(t, session.near(got, plain, 24), "away, in its own colour: %v, want %v", got, plain)
}) }

// A node under the pointer lights its links; the links of other nodes are dimmed.
@(test)
a_hovered_node_lights_its_links :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	h: Hover
	defer hover_destroy(&h)
	three_crossing(&h)
	s := session.start(t, {size = SIZE, user = &h, build = hover_build})
	// (Target 1 has one link in: Source 3's, green)
	target := ui.graph_node_rect(&h.view, &h.nodes[1])
	session.move(s, ui.graph_to_screen(&h.view, {(target.min.x + target.max.x) * 0.5, target.min.y + 8}))
	testing.expect_value(t, h.view.hover_node, 11)
	session.frame(s)
	img := session.capture(s)
	lit := lit_of(&h, kinds[GREEN])
	got := nearest_to(img, link_at(&h, h.links[2], 0.8), lit)
	testing.expectf(t, session.near(got, lit, 24), "its link lit: %v, want %v", got, lit)
	dim := dim_of(&h, kinds[RED], 0.45)
	got = nearest_to(img, link_at(&h, h.links[0], 0.2), dim)
	testing.expectf(t, session.near(got, dim, 24), "another node's link dimmed: %v, want %v", got, dim)
}) }

// A touchpad's Alt+wheel comes in fractions: they add up to one step, not one step each.
@(test)
alt_wheel_fractions_add_up_to_a_step :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	h: Hover
	defer hover_destroy(&h)
	three_crossing(&h)
	s := session.start(t, {size = SIZE, user = &h, build = hover_build})
	at := link_at(&h, h.links[1], 0.5) + {4, 0}
	session.move(s, at)
	testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[1])
	session.wheel(s, at, {0, 0.4}, {.Alt})
	session.wheel(s, at, {0, 0.4}, {.Alt})
	testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[1])   // (0.8: not a step yet)
	session.wheel(s, at, {0, 0.4}, {.Alt})
	testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[2])   // (1.2: one step)
	session.wheel(s, at, {0, -0.4}, {.Alt})
	session.wheel(s, at, {0, -0.4}, {.Alt})
	session.wheel(s, at, {0, -0.4}, {.Alt})
	testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[1])   // (back: one step before)
}) }

// On a light theme with pale kinds, the hovered link reads at 3:1 on the well at least, and a faded link at 1.5:1.
@(test)
the_emphasis_keeps_its_contrast_on_a_light_theme :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	h: Hover
	defer hover_destroy(&h)
	three_crossing(&h)
	// (Catppuccin's light warn and rose: under 2:1 on its well, the palest of the themes)
	p := ui.palette_of("Catppuccin", light = true)
	pale := []ui.Color{draw.hex(p.warn | 0xff), draw.hex(p.rose | 0xff), draw.hex(p.good | 0xff)}
	h.o.kind_colors = pale
	s := session.start(t, {size = SIZE, user = &h, build = hover_build, palette = p})
	for target in 0 ..< 3 {
		session.move(s, link_at(&h, h.links[target], 0.25))
		testing.expect_value(t, h.view.hover_link.? or_else {}, h.links[target])
		session.frame(s)
		img := session.capture(s)
		hot := core_contrast(img, link_at(&h, h.links[target], 0.4), h.well)
		testing.expectf(t, hot >= 2.9, "link %d lit: %.2f:1 on the well", target, hot)
		other := (target + 1) % 3
		dim := core_contrast(img, link_at(&h, h.links[other], 0.15), h.well)
		testing.expectf(t, dim >= 1.4, "link %d faded: %.2f:1 on the well", other, dim)
	}
}) }

// With animations, the emphasis fades in and comes to rest: no frame asked once it is there.
@(test)
the_emphasis_fades_then_rests :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	h: Hover
	defer hover_destroy(&h)
	three_crossing(&h)
	s := session.start(t, {size = SIZE, user = &h, build = hover_build, animations = true})
	session.frames(s, 2)
	testing.expect(t, !ui.needs_frame(s.state), "at rest before")
	session.move(s, link_at(&h, h.links[0], 0.25))
	testing.expect(t, ui.needs_frame(s.state), "the emphasis fades in")
	rested := false
	for _ in 0 ..< 60 {
		if !ui.needs_frame(s.state) { rested = true; break }
		session.frame(s)
	}
	testing.expect(t, rested, "it comes to rest")
	session.frames(s, 3)
	testing.expect(t, !ui.needs_frame(s.state), "no frame at rest")
}) }

// A dense bundle: four sources each linked to four targets, the pointer where four of them cross. The link hovered is
// lit on top there, and its tooltip says which of the four it is; the picture, dark and light, is left in the test's
// folder (link_hover_dark.png, link_hover_light.png).
@(test)
a_link_in_a_dense_bundle_stands_out :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for light in ([2]bool{false, true}) {
		h: Hover
		defer hover_destroy(&h)
		h.o.kind_colors = kinds
		outs := [4][]ui.Graph_Port{out_red, out_blue, out_blue, out_green}
		sources := [4]string{"Decode", "Resize", "Sharpen", "Watermark"}
		targets := [4]string{"Save PNG", "Save WebP", "Preview", "Upload"}
		for i in 0 ..< 4 {
			append(&h.nodes, ui.Graph_Node{id = u64(1 + i), title = sources[i], pos = {40, 30 + 125 * f32(i)}, outputs = outs[i]})
			append(&h.nodes, ui.Graph_Node{id = u64(11 + i), title = targets[i], pos = {620, 30 + 125 * f32(i)}, inputs = in_any})
		}
		for i in 0 ..< 4 { for j in 0 ..< 4 { append(&h.links, ui.Graph_Link{u64(1 + i), 1, u64(11 + j), 2}) } }
		s := session.start(t, {size = SIZE, user = &h, build = hover_build, palette = ui.palette_of("Midnight", light = light)})
		short_tips(s)
		// (the middle of Resize to Preview: by symmetry, the four links from source i to target 3 - i cross there)
		at := link_at(&h, h.links[1 * 4 + 2], 0.5) + {0, 2}
		session.move(s, at)
		hovered, ok := h.view.hover_link.?
		session.advance(s, TIP_DELAY_MS + 3 * session.FRAME_MS)
		session.frames(s, 2)
		name := light ? "link_hover_light.png" : "link_hover_dark.png"
		session.save_png(s, name)
		testing.expect(t, ok && hovered.from_node + hovered.to_node == 15, "a link of the crossing is hovered")
		// (the tooltip near the pointer, over neither the hovered link's middle nor a node's title)
		tip := session.get(s, "tooltip").rect
		for i in 0 ..= 20 {
			p := link_at(&h, hovered, 0.3 + 0.4 * f32(i) / 20)
			testing.expectf(t, !draw.rect_contains(tip, p), "the tooltip %v covers the hovered link at %v (%s)", tip, p, name)
		}
		for &n in h.nodes {
			r := ui.graph_node_rect(&h.view, &n)
			header := ui.Rect{ui.graph_to_screen(&h.view, r.min), ui.graph_to_screen(&h.view, {r.max.x, r.min.y + HEADER_EM * h.view.em})}
			covers := tip.min.x < header.max.x && header.min.x < tip.max.x && tip.min.y < header.max.y && header.min.y < tip.max.y
			testing.expectf(t, !covers, "the tooltip %v covers %s's header %v (%s)", tip, n.title, header, name)
		}
		gap := [2]f32{max(tip.min.x - at.x, at.x - tip.max.x, 0), max(tip.min.y - at.y, at.y - tip.max.y, 0)}
		testing.expectf(t, gap.x <= 24 && gap.y <= 24, "the tooltip %v near the pointer %v (%s)", tip, at, name)
		counted := false
		for text in ([4]string{"1 of 4 here · Alt+wheel for the next", "2 of 4 here · Alt+wheel for the next", "3 of 4 here · Alt+wheel for the next", "4 of 4 here · Alt+wheel for the next"}) {
			if session.find_text(s, text) != nil { counted = true }
		}
		testing.expect(t, counted, "the tooltip counts the four")
		img := session.capture(s)
		want := lit_of(&h, kinds[outs[hovered.from_node - 1][0].kind])
		got := nearest_to(img, at, want)
		testing.expectf(t, session.near(got, want, 24), "the lit link over the bundle (%s): %v, want %v", name, got, want)
	}
}) }
