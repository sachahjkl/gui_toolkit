package ui

import "core:fmt"
import "core:math"
import turn "../turn"
import "../draw"
import "../platform"

// The exploded view (src/md/features/exploded-view.md): instead of the page, one plane per depth of the box tree, each
// box drawn without its children, each parent behind its children, the whole turned with the mouse. The nesting of a
// page and its overlays reads at a glance.
//
//   ui.set_exploded(s, true)               a program's own switch
//   Ctrl+Alt+Shift+E                       in a build with the devtools (TOOLKIT_DEVTOOLS), any window
//   drag: turn; wheel: spread; Escape: off; its panel (a view, "exploded"): the mode, the angles, the spread, the zoom

// How the boxes go to planes (Tab: the next one).
//   Layers   a plane for each box that paints a surface and is at least EXPLODED_LAYER_LEAST_EM on both sides (a
//            panel, a card, a view); what it holds without one (text, icons, pills, buttons, a strip of a band) stays on
//            its panel's plane: the real content, in a few planes, as a browser's view of its layers
//   Depths   a plane for each depth of the tree, every box on its own depth's
//   Outlines the depths' planes, each box only its outline in its plane's colour
Exploded_Mode :: enum u8 { Layers, Depths, Outlines }

// What the view keeps between frames. `yaw` and `pitch` in turns; `spread` in logical pixels between two planes;
// `fit` the share of the window the stack is shrunk to. `t` goes from 0 (the page, flat) to 1 (the view, open) while
// `on`, and back while not: the picture is the view's while t > 0.
Exploded_View :: struct {
	on:          bool,
	mode:        Exploded_Mode,
	yaw:         f32,
	pitch:       f32,
	spread:      f32,
	fit:         f32,
	t:           f32,
	dragging:    bool,   // the left button went down on the planes: moves turn it
	at:          Vec2,   // where the drag was at its last move
	panel_held:  bool,   // the left button went down on the panel: the pointer is the panel's until its release
	in_panel:    bool,   // the pointer's last place was on the panel: the page sees it there
}

// Turns the view on or off: it eases from the flat page to its angles, or back (EXPLODED_TRANSITION_MS). Its panel, a
// view of the window's Views (EXPLODED_VIEW), opens as it eases in and closes as it eases out.
set_exploded :: proc(s: ^State, on: bool) {
	v := &s.exploded
	if v.on == on { return }
	v.on = on
	v.dragging = false
	if on && v.spread == 0 { exploded_reset(v) }
	if on && v.t == 0 {
		// (the page takes no input meanwhile: nothing stays hot or held under the pointer)
		s.mouse_valid = false
		s.active_key = {}
		// (what partial redraw remembers is of the other picture)
		draw.damage_memory_reset(&s.damage)
	}
	vs := state_views(s)
	if on {
		if !view_registered(vs, EXPLODED_VIEW) {
			view_register(vs, EXPLODED_VIEW, exploded_view_build, View_Options{
				title = "Exploded view", home = .Panel, home_place = {edge = .Right}, first = .Internal,
				float_edge = .Right, width_em = EXPLODED_PANEL_EM, extent_em = EXPLODED_PANEL_EM,
			})
		}
		view_open(vs, EXPLODED_VIEW, v, exploded_instance(s), s)
	} else {
		view_close(vs, EXPLODED_VIEW, exploded_instance(s))
	}
	s.anim_busy = true
}

// The panel's view id. One instance per window (its State): a program's Views shared by its windows holds the panel of
// each window that shows the view.
EXPLODED_VIEW :: "exploded"

@(private = "file")
exploded_instance :: proc(s: ^State) -> string { return fmt.tprintf("%x", uintptr(s)) }

// Whether the view is on (or opening); false from the moment it is turned off, while it eases back to the page.
exploded :: proc(s: ^State) -> bool { return s.exploded.on }

// Whether the view is drawn instead of the page: on, or on its way back.
@(private)
exploded_shown :: proc(s: ^State) -> bool { return s.exploded.on || s.exploded.t > 0 }

@(private = "file")
exploded_reset :: proc(v: ^Exploded_View) {
	v.yaw, v.pitch, v.spread, v.fit = EXPLODED_YAW, EXPLODED_PITCH, EXPLODED_SPREAD, EXPLODED_FIT
}

// The view's first angles and spread, and their bounds.
@(private = "file") EXPLODED_YAW :: -1.0 / 12
@(private = "file") EXPLODED_PITCH :: 1.0 / 18
@(private = "file") EXPLODED_SPREAD :: 40
@(private = "file") EXPLODED_SPREAD_MIN :: 4
@(private = "file") EXPLODED_SPREAD_MAX :: 400
@(private = "file") EXPLODED_PITCH_MAX :: 85.0 / 360
@(private = "file") EXPLODED_YAW_MAX :: 0.5
@(private = "file") EXPLODED_FIT_MIN :: 0.3
@(private = "file") EXPLODED_FIT_MAX :: 1.2
// The way from the page to the view, and back. A frame's step is held under a few frames' worth: a frame that comes
// after a long rest (the program turned it on from idle) does not skip the way.
@(private = "file") EXPLODED_TRANSITION_MS :: 600
@(private = "file") EXPLODED_STEP_DT_MAX :: 0.05
// Layers: a surface smaller than this on either side (a pill, a button, a toggle's track, a strip of a band) stays on
// its parent's plane.
@(private = "file") EXPLODED_LAYER_LEAST_EM :: 3
// The panel: its first width (floating or docked), the column of its sliders' names.
@(private = "file") EXPLODED_PANEL_EM :: 16
@(private = "file") EXPLODED_LABEL_EM :: 4.5
// Turns per pixel of a drag; the factor of the spread per wheel notch.
@(private = "file") EXPLODED_TURN_PER_PX :: 0.4 / 360
@(private = "file") EXPLODED_SPREAD_STEP :: 1.15
// The stack is first shrunk to this share of the window (the panel's zoom), so that turned it stays in view; the eye is this many window sizes
// from it; the stack's depth is held under this share of the eye's distance (nothing passes behind the eye).
@(private = "file") EXPLODED_FIT :: 0.7
@(private = "file") EXPLODED_EYE :: 2
@(private = "file") EXPLODED_DEPTH_SHARE :: 0.8
// Deeper boxes share the last plane: each plane is a texture of the window's size.
@(private = "file") EXPLODED_MAX_PLANES :: 48
// The ground: a deep blue at the top fading to near black, a vignette at its edges.
@(private = "file") EXPLODED_GROUND_TOP :: Color{0.09, 0.12, 0.22, 1}
@(private = "file") EXPLODED_GROUND_FOOT :: Color{0.02, 0.02, 0.04, 1}
@(private = "file") EXPLODED_VIGNETTE :: Color{0, 0, 0, 0.55}
// A plane's colour: its hue moves this far (turns) from one plane to the next (a golden angle: neighbours differ).
@(private = "file") EXPLODED_HUE_STEP :: 137.5 / 360
@(private = "file") EXPLODED_TINT :: 0.10      // how much of its colour a plane's boxes wear (Depths)
@(private = "file") EXPLODED_EDGE :: 0.9       // the outline's opacity

// The key, read at the start of a build in a build with the devtools (as the wireframe's). While the view is on,
// exploded_events takes the key itself.
@(private)
EXPLODED_KEY :: #config(TOOLKIT_DEVTOOLS, ODIN_DEBUG || ODIN_TEST)

@(private)
exploded_keys :: proc(s: ^State) {
	when EXPLODED_KEY {
		if !s.exploded.on && key_press_any(.E, {.Ctrl, .Alt, .Shift}) { set_exploded(s, true) }
	}
}

// While the view is shown: the pointer, the wheel and the keys of the frame are the view's, the rest goes to the page
// (a resize, a close, the window's activation, a pointer that leaves). The pointer over the panel (its view, floating
// or docked in this window) is the panel's: the page sees it there, and the view takes it. Then `t` takes its step.
// Off: the events untouched.
@(private)
exploded_events :: proc(s: ^State, events: []platform.Event) -> []platform.Event {
	v := &s.exploded
	if !exploded_shown(s) { return events }
	vs := state_views(s)
	// (the view's close cross, or its Escape: the view goes with its panel)
	if _, ended := view_ended(vs, EXPLODED_VIEW, exploded_instance(s)); ended && v.on { set_exploded(s, false) }
	kept := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	panel, has_panel := exploded_panel_rect(s)
	off, toggle := false, false
	for e in events {
		#partial switch e.kind {
		case .Mouse_Press, .Mouse_Move, .Mouse_Release, .Scroll:
			over := has_panel && draw.rect_contains(panel, e.pos)
			// (a press on the panel keeps the pointer there until its release: a slider's drag goes off its edge)
			if v.panel_held || (over && !v.dragging) {
				if e.button == .Left && e.kind == .Mouse_Press { v.panel_held = true }
				if e.button == .Left && e.kind == .Mouse_Release { v.panel_held = false }
				// (the wheel stays out: the page's scrolling views under the panel would take it)
				if e.kind != .Scroll { append(&kept, e) }
				v.in_panel = true
				if !over && !v.panel_held { exploded_leave_panel(v, &kept) }
				continue
			}
			exploded_leave_panel(v, &kept)
		}
		#partial switch e.kind {
		case .Mouse_Press:
			if e.button == .Left { v.dragging, v.at = true, e.pos }
		case .Mouse_Move:
			if v.dragging {
				d := e.pos - v.at
				// (held in -0.5..0.5, the panel's slider's range: a turn past it comes round the other side)
				v.yaw = math.mod(v.yaw + d.x * EXPLODED_TURN_PER_PX + 1.5, 1) - 0.5
				v.pitch = clamp(v.pitch - d.y * EXPLODED_TURN_PER_PX, -EXPLODED_PITCH_MAX, EXPLODED_PITCH_MAX)
				v.at = e.pos
				s.anim_busy = true
			}
		case .Mouse_Release:
			if e.button == .Left { v.dragging = false }
		case .Scroll:
			v.spread = clamp(v.spread * math.pow(f32(EXPLODED_SPREAD_STEP), -e.delta.y), EXPLODED_SPREAD_MIN, EXPLODED_SPREAD_MAX)
			s.anim_busy = true
		case .Key_Press:
			if e.key == .Escape && e.mods == {} { off = true }
			if e.key == .Tab && (e.mods == {} || e.mods == {.Shift}) {
				n := len(Exploded_Mode)
				v.mode = Exploded_Mode((int(v.mode) + (e.mods == {} ? 1 : n - 1)) % n)
				s.anim_busy = true
			}
			when EXPLODED_KEY { if e.key == .E && e.mods == {.Ctrl, .Alt, .Shift} { toggle = true } }
		case .Key_Release, .Text, .Pointer_Down, .Pointer_Move, .Pointer_Up:
		case .Mouse_Leave:
			v.in_panel = false
			append(&kept, e)
		case:
			append(&kept, e)
		}
	}
	// (the pointer on the planes: the page sees none)
	if !v.in_panel { s.mouse_valid = false }
	if off { set_exploded(s, false) }
	// (the key on the way back opens it again from where it is)
	if toggle { set_exploded(s, !v.on) }
	exploded_step(s)
	return kept[:]
}

// The pointer left the panel for the planes: the page sees it go, so nothing of the panel stays hot.
@(private = "file")
exploded_leave_panel :: proc(v: ^Exploded_View, kept: ^[dynamic]platform.Event) {
	if !v.in_panel { return }
	append(kept, platform.Event{kind = .Mouse_Leave})
	v.in_panel = false
}

// `t` toward 1 while on, toward 0 while off, by the frame's time; at once when the window does not animate. At 0 the
// page is drawn again and takes the pointer from its next move.
@(private = "file")
exploded_step :: proc(s: ^State) {
	v := &s.exploded
	target: f32 = v.on ? 1 : 0
	if v.t == target { return }
	if s.anim_rate == 0 {
		v.t = target
	} else {
		step := min(s.dt, EXPLODED_STEP_DT_MAX) * 1000 / EXPLODED_TRANSITION_MS
		v.t = v.on ? min(v.t + step, 1) : max(v.t - step, 0)
	}
	s.anim_busy = true
	if v.t == 0 {
		v.dragging, v.panel_held, v.in_panel = false, false, false
		// (what partial redraw remembers is of the view's picture)
		draw.damage_memory_reset(&s.damage)
	}
}

// The way's ease: leaving and arriving gently, as tween's.
@(private = "file")
exploded_ease :: proc(t: f32) -> f32 { return t * t * (3 - 2 * t) }

// The box of the panel's view in this window (its floating window's frame, its docked stack); 0 when it is in a window
// of its own: then the planes' window has all of its pointer.
@(private = "file")
exploded_panel_key :: proc(s: ^State) -> Key {
	if s.views == nil { return 0 }
	return view_box_in(s.views, EXPLODED_VIEW, s, exploded_instance(s))
}

// The panel's rect in the last layout, if it was built: where the pointer is the panel's.
@(private = "file")
exploded_panel_rect :: proc(s: ^State) -> (Rect, bool) {
	b := s.boxes[exploded_panel_key(s)] or_else nil
	if b == nil || b.last_build + 1 < s.build_index { return {}, false }
	return b.rect, true
}

// The panel's body, a view's (the header, its title and its close cross are the views'): the mode, then a row per
// slider, then Reset. In the program's theme and finish, as any view; the sliders write the view's fields. Built
// wherever the view is (floating, docked, in its own window): `v` is the planes' window's.
@(private = "file")
exploded_view_build :: proc(view: ^View, v: ^Exploded_View) {
	em := font_size()
	before := v^
	next({width = fill(), height = children_sum(), axis = .X})
	if row() {
		space(INNER_PAD)
		next({width = fill(), height = children_sum(), axis = .Y})
		if column() {
			space(INNER_PAD)
			words := []string{"Layers", "Depths", "Outlines"}
			mode := int(v.mode)
			next({width = fill()})
			if segmented("###exploded_mode", words, &mode) { v.mode = Exploded_Mode(mode) }
			space(ITEM_GAP)
			// (a person reads the angles in degrees: the sliders show them so, the view keeps turns)
			yaw, pitch := turn.to_degrees(v.yaw), turn.to_degrees(v.pitch)
			if exploded_slider_row("Yaw", "###exploded_yaw", &yaw, turn.to_degrees(f32(-EXPLODED_YAW_MAX)), turn.to_degrees(f32(EXPLODED_YAW_MAX)), 1, "%.0f°", turn.to_degrees(f32(EXPLODED_YAW)), em) {
				v.yaw = turn.from_degrees(yaw)
			}
			space(LINE_GAP)
			if exploded_slider_row("Pitch", "###exploded_pitch", &pitch, turn.to_degrees(f32(-EXPLODED_PITCH_MAX)), turn.to_degrees(f32(EXPLODED_PITCH_MAX)), 1, "%.0f°", turn.to_degrees(f32(EXPLODED_PITCH)), em) {
				v.pitch = turn.from_degrees(pitch)
			}
			space(LINE_GAP)
			exploded_slider_row("Spread", "###exploded_spread", &v.spread, EXPLODED_SPREAD_MIN, EXPLODED_SPREAD_MAX, 1, "%.0f", EXPLODED_SPREAD, em)
			space(LINE_GAP)
			exploded_slider_row("Zoom", "###exploded_fit", &v.fit, EXPLODED_FIT_MIN, EXPLODED_FIT_MAX, 0.01, "%.2f", EXPLODED_FIT, em)
			space(ITEM_GAP)
			next({width = fill(), height = children_sum(), axis = .X})
			if row(.Center) {
				spacer(fill())
				if button("exploded_reset", "Reset", o = {face = .Ghost}).clicked { exploded_reset(v) }
			}
			space(INNER_PAD)
		}
		space(INNER_PAD)
	}
	// (the panel in a window of its own: the planes' window draws the change; its frames come only while it moves)
	if v^ != before && view.record.owner != nil { view.record.owner.anim_busy = true }
}

// A slider's row: its name in a column of its own at the left, the slider and its value after it.
@(private = "file")
exploded_slider_row :: proc(name, id: string, value: ^f32, lo, hi, step: f32, format: string, default: f32, em: f32) -> (changed: bool) {
	next({width = fill(), height = children_sum(), axis = .X})
	if row(.Center) {
		next({width = px(math.round(em * EXPLODED_LABEL_EM)), height = px(dense(em * 2))})
		build_box({.Draw_Text}, name)
		next({width = fill(), height = px(dense(em * 2))})
		changed = slider(id, value, lo, hi, step, format, default)
	}
	return
}

@(private = "file")
Exploded_Entry :: struct {
	b:       ^Box,
	clip:    Rect,   // its ancestors' clips (.Clip), when `clipped`
	clipped: bool,
}

@(private)
exploded_draw :: proc(s: ^State, dc: ^draw.Context) {
	if s.root == nil { return }
	// (every plane moves when the view turns: no part of the last picture stays)
	draw.damage_whole(dc)
	win := s.root.rect
	v := &s.exploded
	mode := v.mode
	// (the way in starts from the page as drawn: no angle, no spread, no shrink, the view's marks and ground faded out)
	e := exploded_ease(v.t)
	draw.rect(dc, win, s.backdrop)
	draw.push_alpha(dc, e)
	exploded_ground(dc, win)
	draw.pop_alpha(dc)

	levels := make([dynamic][dynamic]Exploded_Entry, 0, 16, context.temp_allocator)
	panel_key := exploded_panel_key(s)
	least := EXPLODED_LAYER_LEAST_EM * math.round(s.base_style.font_size * s.scale)
	// (`plane`: the box's plane; Layers: its parent's, one further when it is a layer of its own)
	walk :: proc(s: ^State, b: ^Box, plane: int, mode: Exploded_Mode, least: f32, panel_key: Key, clip: Rect, clipped: bool, levels: ^[dynamic][dynamic]Exploded_Entry) {
		// (the panel is drawn flat over the planes, not in them)
		if !box_current(s, b) || (panel_key != 0 && b.key == panel_key) { return }
		d := min(plane, EXPLODED_MAX_PLANES - 1)
		for len(levels^) <= d { append(levels, make([dynamic]Exploded_Entry, 0, 16, context.temp_allocator)) }
		append(&levels^[d], Exploded_Entry{b = b, clip = clip, clipped = clipped})
		inner, inner_clipped := clip, clipped
		if .Clip in b.flags {
			inner = clipped ? draw.rect_intersect(clip, b.rect) : b.rect
			inner_clipped = true
		}
		for c := b.first; c != nil; c = c.next {
			next := plane + 1
			if mode == .Layers && !is_a_layer(c, least) { next = plane }
			walk(s, c, next, mode, least, panel_key, inner, inner_clipped, levels)
		}
	}
	walk(s, s.root, 0, mode, least, panel_key, {}, false, &levels)
	n := len(levels)
	if n == 0 { return }

	size := Vec2{win.max.x - win.min.x, win.max.y - win.min.y}
	mid := (win.min + win.max) * 0.5
	eye := EXPLODED_EYE * max(size.x, size.y)
	fit := math.lerp(f32(1), v.fit, e)
	// (the stack's half depth, shrunk by the fit, stays in front of the eye)
	spread := e * min(v.spread * s.scale, EXPLODED_DEPTH_SHARE * 2 * eye / (f32(n) * fit))
	turned := exploded_turn(e * v.yaw, e * v.pitch, fit, eye)
	line := max(1, math.round(s.scale))

	items := make([]draw.Plane_Item, n, context.temp_allocator)
	for level, d in levels {
		hue := draw.hsv(f32(d) * EXPLODED_HUE_STEP, 0.65, 1, EXPLODED_EDGE * e)
		draw.push_plane(dc, win, 1, {mips = true})
		// (the root's plane is the page's ground: the theme's background under its boxes; Outlines: it fades out with
		// the boxes)
		if d == 0 && (mode != .Outlines || e < 1) {
			ground := s.backdrop
			if mode == .Outlines { ground.a *= 1 - e }
			draw.rect(dc, win, ground)
		}
		for en in level {
			r := en.b.rect
			has_area := r.max.x > r.min.x && r.max.y > r.min.y
			if en.clipped { draw.push_clip(dc, en.clip) }
			if mode != .Outlines {
				draw_box(s, dc, en.b, s.scale, children = false)
			} else if e < 1 {
				// (Outlines: the boxes fade out as the outlines come)
				draw.push_alpha(dc, 1 - e)
				draw_box(s, dc, en.b, s.scale, children = false)
				draw.pop_alpha(dc)
			}
			if mode == .Depths && has_area && .Gap not_in en.b.flags {
				tint := hue
				tint.a = EXPLODED_TINT * e
				draw.rect(dc, r, tint)
			}
			// (Layers: a plane's own surfaces outlined, not each word on it)
			outline := e > 0 && has_area && .Gap not_in en.b.flags && (mode != .Layers || is_a_layer(en.b, least) || d == 0)
			if outline { draw.rect(dc, r, hue, 0, line) }
			if en.clipped { draw.pop_clip(dc) }
		}
		layer := draw.pop_plane(dc)
		z := (f32(d) - f32(n - 1) * 0.5) * spread
		at := draw.Mat4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -mid.x, -mid.y, z, 1}
		back := draw.Mat4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, mid.x, mid.y, 0, 1}
		items[d] = draw.plane_item(layer, draw.mat4_mul(back, draw.mat4_mul(turned, at)))
	}
	draw.draw_planes(dc, items)
	// (flat, over the planes: real widgets, read as the page's)
	if p := s.boxes[panel_key] or_else nil; panel_key != 0 && box_current(s, p) {
		// (a docked panel paints no ground of its own: on the page it lies on the window's)
		if .Draw_Background not_in p.flags { draw.rect(dc, p.rect, s.backdrop) }
		draw_box(s, dc, p, s.scale)
	}
}

// Whether a box is a layer of its own (Layers: it starts a plane): it paints a surface (a background, a drawing, an
// image) and is at least `least` on both sides. A smaller surface (a pill, a button, a toggle's track, a thin strip of
// a band) is a part of its parent's layer: on a plane in front, it crossed the words beside it.
@(private = "file")
is_a_layer :: proc(b: ^Box, least: f32) -> bool {
	if .Draw_Background not_in b.flags && b.custom == nil { return false }
	return b.rect.max.x - b.rect.min.x >= least && b.rect.max.y - b.rect.min.y >= least
}

// The ground under the planes: a deep blue fading down to near black, darker at its edges.
@(private = "file")
exploded_ground :: proc(dc: ^draw.Context, win: Rect) {
	h := win.max.y - win.min.y
	w := win.max.x - win.min.x
	down := [2]draw.Gradient_Stop{{color = EXPLODED_GROUND_TOP, pos = 0}, {color = EXPLODED_GROUND_FOOT, pos = 1}}
	draw.gradient(dc, win, {kind = .Linear, start = {0, 0}, end = {0, h}, stops = down[:], dither = true})
	clear := EXPLODED_VIGNETTE
	clear.a = 0
	edge := [2]draw.Gradient_Stop{{color = clear, pos = 0.55}, {color = EXPLODED_VIGNETTE, pos = 1}}
	draw.gradient(dc, win, {kind = .Radial, center = {w * 0.5, h * 0.45}, radii = {w * 0.75, h * 0.75}, stops = edge[:], dither = true})
}

// The turn of the stack about its middle: yaw about y, then pitch about x, shrunk to `k` of its size, then the
// perspective of an eye `eye` pixels in front (+z comes toward the eye: the deeper boxes, in front of their parents).
@(private = "file")
exploded_turn :: proc(yaw, pitch, k, eye: f32) -> draw.Mat4 {
	sy, cy := turn.sincos(yaw)
	sp, cp := turn.sincos(pitch)
	ry := draw.Mat4{cy, 0, -sy, 0, 0, 1, 0, 0, sy, 0, cy, 0, 0, 0, 0, 1}
	rx := draw.Mat4{1, 0, 0, 0, 0, cp, sp, 0, 0, -sp, cp, 0, 0, 0, 0, 1}
	fit := draw.Mat4{k, 0, 0, 0, 0, k, 0, 0, 0, 0, k, 0, 0, 0, 0, 1}
	persp := draw.MAT4_IDENTITY
	persp[11] = -1 / eye
	return draw.mat4_mul(persp, draw.mat4_mul(fit, draw.mat4_mul(rx, ry)))
}
