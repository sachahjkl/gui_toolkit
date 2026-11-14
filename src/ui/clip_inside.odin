package ui

// What a frame holds, drawn inside it: clipped to its rounded corners, a line in from its edge (its rim, its border, stays
// over what it holds). A row's background that runs from side to side of a rounded frame then takes the frame's curve
// where it reaches a corner: square rows in a rounded frame, never a rounded row inside it.
//
//   clip_inside_open()        // first in the frame (the parent): a box whose draw starts the clip
//   ... the frame's content ...
//   clip_inside_close()       // last in it: a box whose draw ends it
//
// A box that draws its own frame (a custom draw) gives the frame its radius (`radius`, as its draw rounds it), so that
// the clip has the same corners.

import "core:math"
import "../draw"

// Clips what is drawn next to the inside of `frame`, until draw.pop_clip: the frame's rect a line in, its corners as drawn
// less that line (the two curves concentric).
clip_inside_push :: proc(dc: ^draw.Context, frame: ^Box) {
	line := max(math.round(scale()), 1)
	radius := max(box_drawn_radius(gs(), frame) - line, 0)
	draw.push_clip_rounded(dc, draw.rect_pad(frame.rect, -line), box_radii(radius, frame.square_corners))
}

// The start of the frame's clip, built first in it (its parent is the frame). The box floats over the frame and takes no
// room: only its draw counts, before what follows it.
clip_inside_open :: proc() {
	frame := parent_box()
	next({fixed_x = 0, fixed_y = 0, width = pct(1), height = pct(1)})
	b := build_box({}, "###clip_inside_open")
	b.custom, b.custom_user = proc(_: ^Box, user: rawptr, dc: ^draw.Context) { clip_inside_push(dc, (^Box)(user)) }, frame
}

// The end of the frame's clip, built last in it.
clip_inside_close :: proc() {
	next({fixed_x = 0, fixed_y = 0, width = pct(1), height = pct(1)})
	b := build_box({}, "###clip_inside_close")
	b.custom = proc(_: ^Box, _: rawptr, dc: ^draw.Context) { draw.pop_clip(dc) }
}
