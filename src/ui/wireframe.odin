package ui

import "core:fmt"
import "core:math"
import "../draw"

// The wireframe (src/md/features/spacing.md, "The wireframe"): every box of the window drawn as its outline, over the
// page; each gap (a spacer) filled with the colour of its step of the spacing scale, a gap off the scale in red; the
// innermost box under the pointer named. One sees how a page is built and where it leaves the scale.
//
//   ui.set_wireframe(s, true)              a program's own switch
//   Ctrl+Alt+Shift+W                       in a build with the devtools (TOOLKIT_DEVTOOLS), any window
//   Overlay.setShowDebugBorders            Chrome DevTools' Rendering panel, "Layer borders" (gt:devtools)

set_wireframe :: proc(s: ^State, on: bool) {
	if s.wireframe == on { return }
	s.wireframe = on
	s.anim_busy = true   // (a frame shows it, even a window at rest)
}

// The key, read at the start of a build in a build with the devtools: what is for a program's author, not its users.
@(private)
WIREFRAME_KEY :: #config(TOOLKIT_DEVTOOLS, ODIN_DEBUG || ODIN_TEST)

@(private)
wireframe_keys :: proc(s: ^State) {
	when WIREFRAME_KEY {
		if key_press_any(.W, {.Ctrl, .Alt, .Shift}) { set_wireframe(s, !s.wireframe) }
	}
}

// The colours of the steps, in order (SPACE_1 to SPACE_6), and of a gap off the scale; a box's outline.
@(private = "file") WIRE_STEPS :: [5]Color{{0.35, 0.75, 1, 0.30}, {0.35, 1, 0.6, 0.30}, {1, 0.85, 0.3, 0.30}, {1, 0.55, 0.25, 0.30}, {0.8, 0.45, 1, 0.30}}
@(private = "file") WIRE_OFF_SCALE :: Color{1, 0.2, 0.2, 0.45}
@(private = "file") WIRE_OUTLINE   :: Color{0.55, 0.8, 1, 0.45}
@(private = "file") WIRE_HOT       :: Color{1, 1, 1, 0.9}
@(private = "file") WIRE_LABEL_BG  :: Color{0, 0, 0, 0.8}

@(private)
wireframe_draw :: proc(s: ^State, dc: ^draw.Context) {
	if s.root == nil { return }
	line := max(1, math.round(s.scale))
	hot: ^Box
	walk :: proc(s: ^State, dc: ^draw.Context, b: ^Box, line: f32, hot: ^^Box) {
		if !box_current(s, b) { return }
		r := b.rect
		if .Gap in b.flags {
			// (a gap has no size across its parent's axis: it is drawn across the whole parent, as the room it makes)
			if p := b.parent; p != nil {
				if p.layout_axis == .Y { r.min.x, r.max.x = p.rect.min.x, p.rect.max.x } else { r.min.y, r.max.y = p.rect.min.y, p.rect.max.y }
			}
			if r.max.x > r.min.x && r.max.y > r.min.y { draw.rect(dc, r, gap_color(b.gap_step)) }
		} else {
			draw.rect(dc, r, WIRE_OUTLINE, 0, line)
			if s.mouse.x >= r.min.x && s.mouse.x < r.max.x && s.mouse.y >= r.min.y && s.mouse.y < r.max.y { hot^ = b }
		}
		if .Clip in b.flags { draw.push_clip(dc, r) }
		for c := b.first; c != nil; c = c.next { walk(s, dc, c, line, hot) }
		if .Clip in b.flags { draw.pop_clip(dc) }
	}
	walk(s, dc, s.root, line, &hot)
	if hot == nil || hot == s.root { return }
	draw.rect(dc, hot.rect, WIRE_HOT, 0, line)
	// its name and its size, at its top left (inside the window)
	f := s.root.font
	size := math.round(12 * s.scale)
	words := fmt.tprintf("%s  %.0f×%.0f", hot.name != "" ? hot.name : "(no id)", hot.rect.max.x - hot.rect.min.x, hot.rect.max.y - hot.rect.min.y)
	w := text_width(f, size, words)
	at := Vec2{hot.rect.min.x, max(s.root.rect.min.y, hot.rect.min.y - size * 1.5)}
	at.x = min(at.x, s.root.rect.max.x - w - size)
	draw.rect(dc, {at, at + {w + size * 0.6, size * 1.4}}, WIRE_LABEL_BG, size * 0.25)
	draw.text(dc, f, size, at + {size * 0.3, size * 0.2}, WIRE_HOT, words)
}

// A gap's colour: its step's, red when it is none of the scale's.
@(private = "file")
gap_color :: proc(step: f32) -> Color {
	switch step {
	case SPACE_1: return WIRE_STEPS[0]
	case SPACE_2: return WIRE_STEPS[1]
	case SPACE_3: return WIRE_STEPS[2]
	case SPACE_4: return WIRE_STEPS[3]
	case SPACE_6: return WIRE_STEPS[4]
	}
	return WIRE_OFF_SCALE
}
