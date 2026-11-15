package ui

import "core:fmt"
import "core:math"
import "../draw"
import "../platform"

// The exploded view (src/md/features/exploded-view.md): instead of the page, one plane per depth of the box tree, each
// box drawn without its children, each parent behind its children, the whole turned with the mouse. The nesting of a
// page and its overlays reads at a glance.
//
//   ui.set_exploded(s, true)               a program's own switch
//   Ctrl+Alt+Shift+E                       in a build with the devtools (TOOLKIT_DEVTOOLS), any window
//   drag: turn; wheel: spread; Escape: off

// How the boxes go to planes (Tab: the next one).
//   Layers   a plane for each box that paints a surface (a background, a panel, a drawing of its own); what it holds
//            without one (text, icons, controls drawn as text) stays on its panel's plane: the real content, in a few
//            planes, as a browser's view of its layers
//   Depths   a plane for each depth of the tree, every box on its own depth's
//   Outlines the depths' planes, each box only its outline in its plane's colour
Exploded_Mode :: enum u8 { Layers, Depths, Outlines }

// What the view keeps between frames. `yaw` and `pitch` in degrees; `spread` in logical pixels between two planes.
Exploded_View :: struct {
	on:       bool,
	mode:     Exploded_Mode,
	yaw:      f32,
	pitch:    f32,
	spread:   f32,
	dragging: bool,   // the left button went down while the view was on: moves turn it
	at:       Vec2,   // where the drag was at its last move
}

set_exploded :: proc(s: ^State, on: bool) {
	v := &s.exploded
	if v.on == on { return }
	v.on = on
	v.dragging = false
	if on && v.spread == 0 { v.yaw, v.pitch, v.spread = EXPLODED_YAW, EXPLODED_PITCH, EXPLODED_SPREAD }
	if on {
		// (the page takes no input meanwhile: nothing stays hot or held under the pointer)
		s.mouse_valid = false
		s.active_key = {}
	}
	// (what partial redraw remembers is of the other picture)
	draw.damage_memory_reset(&s.damage)
	s.anim_busy = true
}

exploded :: proc(s: ^State) -> bool { return s.exploded.on }

// The view's first angles and spread, and their bounds.
@(private = "file") EXPLODED_YAW :: -30
@(private = "file") EXPLODED_PITCH :: 20
@(private = "file") EXPLODED_SPREAD :: 40
@(private = "file") EXPLODED_SPREAD_MIN :: 4
@(private = "file") EXPLODED_SPREAD_MAX :: 400
@(private = "file") EXPLODED_PITCH_MAX :: 85
// Degrees per pixel of a drag; the factor of the spread per wheel notch.
@(private = "file") EXPLODED_TURN_PER_PX :: 0.4
@(private = "file") EXPLODED_SPREAD_STEP :: 1.15
// The stack is shrunk to this share of the window, so that turned it stays in view; the eye is this many window sizes
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
// A plane's colour: its hue turns by this many degrees from one plane to the next (a golden angle: neighbours differ).
@(private = "file") EXPLODED_HUE_STEP :: 137.5
@(private = "file") EXPLODED_TINT :: 0.10      // how much of its colour a plane's boxes wear (Depths)
@(private = "file") EXPLODED_EDGE :: 0.9       // the outline's opacity
@(private = "file") EXPLODED_HUD :: Color{1, 1, 1, 0.75}

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

// While the view is on: the pointer, the wheel and the keys of the frame are the view's, the rest goes to the page
// (a resize, a close, the window's activation, a pointer that leaves). Off: the events untouched.
@(private)
exploded_events :: proc(s: ^State, events: []platform.Event) -> []platform.Event {
	v := &s.exploded
	if !v.on { return events }
	kept := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	off := false
	for e in events {
		#partial switch e.kind {
		case .Mouse_Press:
			if e.button == .Left { v.dragging, v.at = true, e.pos }
		case .Mouse_Move:
			if v.dragging {
				d := e.pos - v.at
				v.yaw += d.x * EXPLODED_TURN_PER_PX
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
			when EXPLODED_KEY { if e.key == .E && e.mods == {.Ctrl, .Alt, .Shift} { off = true } }
		case .Key_Release, .Text, .Pointer_Down, .Pointer_Move, .Pointer_Up:
		case:
			append(&kept, e)
		}
	}
	s.mouse_valid = false
	if off { set_exploded(s, false) }
	return kept[:]
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
	mode := s.exploded.mode
	exploded_ground(dc, win)

	levels := make([dynamic][dynamic]Exploded_Entry, 0, 16, context.temp_allocator)
	// (`plane`: the box's plane; Layers: its parent's, one further when it paints a surface of its own)
	walk :: proc(s: ^State, b: ^Box, plane: int, mode: Exploded_Mode, clip: Rect, clipped: bool, levels: ^[dynamic][dynamic]Exploded_Entry) {
		if !box_current(s, b) { return }
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
			if mode == .Layers && !paints_a_surface(c) { next = plane }
			walk(s, c, next, mode, inner, inner_clipped, levels)
		}
	}
	walk(s, s.root, 0, mode, {}, false, &levels)
	n := len(levels)
	if n == 0 { return }

	size := Vec2{win.max.x - win.min.x, win.max.y - win.min.y}
	mid := (win.min + win.max) * 0.5
	eye := EXPLODED_EYE * max(size.x, size.y)
	// (the stack's half depth, shrunk by the fit, stays in front of the eye)
	spread := min(s.exploded.spread * s.scale, EXPLODED_DEPTH_SHARE * 2 * eye / (f32(n) * EXPLODED_FIT))
	turn := exploded_turn(s.exploded.yaw, s.exploded.pitch, eye)
	line := max(1, math.round(s.scale))

	items := make([]draw.Plane_Item, n, context.temp_allocator)
	for level, d in levels {
		hue := draw.hsv(f32(d) * EXPLODED_HUE_STEP / 360, 0.65, 1, EXPLODED_EDGE)
		draw.push_plane(dc, win, 1, {mips = true})
		// (the root's plane is the page's ground: the theme's background under its boxes)
		if d == 0 && mode != .Outlines { draw.rect(dc, win, s.backdrop) }
		for e in level {
			r := e.b.rect
			has_area := r.max.x > r.min.x && r.max.y > r.min.y
			if e.clipped { draw.push_clip(dc, e.clip) }
			if mode != .Outlines { draw_box(s, dc, e.b, s.scale, children = false) }
			if mode == .Depths && has_area && .Gap not_in e.b.flags {
				tint := hue
				tint.a = EXPLODED_TINT
				draw.rect(dc, r, tint)
			}
			// (Layers: a plane's own surfaces outlined, not each word on it)
			outline := has_area && .Gap not_in e.b.flags && (mode != .Layers || paints_a_surface(e.b) || d == 0)
			if outline { draw.rect(dc, r, hue, 0, line) }
			if e.clipped { draw.pop_clip(dc) }
		}
		layer := draw.pop_plane(dc)
		z := (f32(d) - f32(n - 1) * 0.5) * spread
		at := draw.Mat4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -mid.x, -mid.y, z, 1}
		back := draw.Mat4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, mid.x, mid.y, 0, 1}
		items[d] = draw.plane_item(layer, draw.mat4_mul(back, draw.mat4_mul(turn, at)))
	}
	draw.draw_planes(dc, items)
	exploded_hud(s, dc, win, n)
}

// Whether a box paints a surface of its own (Layers: it starts a plane): a background, a drawing, an image.
@(private = "file")
paints_a_surface :: proc(b: ^Box) -> bool {
	return .Draw_Background in b.flags || b.custom != nil
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

// The keys and the mode, at the window's top left.
@(private = "file")
exploded_hud :: proc(s: ^State, dc: ^draw.Context, win: Rect, planes: int) {
	MODE_WORDS := [Exploded_Mode]string{.Layers = "layers", .Depths = "depths", .Outlines = "outlines"}
	size := math.round(12 * s.scale)
	words := fmt.tprintf("%s · %d planes   drag: turn   wheel: spread   Tab: mode   Esc: close", MODE_WORDS[s.exploded.mode], planes)
	draw.text(dc, s.root.font, size, win.min + {size, size}, EXPLODED_HUD, words)
}

// The turn of the stack about its middle: yaw about y, then pitch about x, shrunk to fit, then the perspective of an eye
// `eye` pixels in front (+z comes toward the eye: the deeper boxes, in front of their parents).
@(private = "file")
exploded_turn :: proc(yaw, pitch, eye: f32) -> draw.Mat4 {
	ya, pa := yaw * math.PI / 180, pitch * math.PI / 180
	cy, sy := math.cos(ya), math.sin(ya)
	cp, sp := math.cos(pa), math.sin(pa)
	ry := draw.Mat4{cy, 0, -sy, 0, 0, 1, 0, 0, sy, 0, cy, 0, 0, 0, 0, 1}
	rx := draw.Mat4{1, 0, 0, 0, 0, cp, sp, 0, 0, -sp, cp, 0, 0, 0, 0, 1}
	k := f32(EXPLODED_FIT)
	fit := draw.Mat4{k, 0, 0, 0, 0, k, 0, 0, 0, 0, k, 0, 0, 0, 0, 1}
	persp := draw.MAT4_IDENTITY
	persp[11] = -1 / eye
	return draw.mat4_mul(persp, draw.mat4_mul(fit, draw.mat4_mul(rx, ry)))
}
