package draw

import "core:math"
import "../render"

// Partial redraw from the drawing layer. An application that knows which boxes of its UI changed between two frames
// (a caret, a hovered control, a progress bar, a video, a local animation) marks them here, in the context's drawing
// coordinates (screen pixels; the transform / alpha stacks do not apply: damage is about the final frame). The
// renderer then rasterizes only the batches that touch them and presents only those rectangles (render/damage.odin).
//
// Usage, each frame between begin_frame and end_frame:
//   draw.damage_begin(c)                 (once, right after begin_frame, when the app tracks damage)
//   draw.damage(c, some_rect)            as many changed boxes as needed
//   draw.damage_scrolled(c, rect, d)     content of `rect` moved by `d` since the last frame (a scrolled view)
//   ... normal drawing ...
//   end_frame(c)
// A frame that begins damage and marks nothing redraws and presents nothing. Not calling damage_begin means the whole
// frame is damaged, exactly as before (lossless default). Turn the whole feature on with set_partial_redraw.

// Turns partial redraw on or off for the context's renderer (render.set_partial_redraw). Off: every frame is drawn and
// presented whole (the behaviour before this feature). On: a region marked with damage_begin / damage is the only part
// redrawn. Backends that cannot present partially right now fall back to a whole frame on their own.
set_partial_redraw :: proc(c: ^Context, on: bool) { render.set_partial_redraw(c.renderer, on) }
partial_redraw :: proc(c: ^Context) -> bool { return render.partial_redraw(c.renderer) }

// Renders every frame both partially and in full and compares them (render.damage.verify): the first differing pixel
// is reported. For development; it costs a full extra frame.
set_damage_verify :: proc(c: ^Context, on: bool) { render.set_damage_verify(c.renderer, on) }

// Begins the damage region for this frame. Call once after begin_frame when the application tracks damage.
damage_begin :: proc(c: ^Context) { render.damage_begin(c.renderer) }

// Marks `r` (context coordinates, screen pixels) as changed this frame. Clamped to the frame; near rectangles are
// merged so the region stays bounded.
damage :: proc(c: ^Context, r: Rect) {
	render.damage_add(c.renderer, rect_to_damage(r))
}

// Marks the bounding box of `boxes` grown by `pad` pixels (a drop shadow, a glow, a focus ring whose paint reaches
// past the element). A convenience over damage: the renderer reads nothing outside the region, so effects that bleed
// must widen it.
damage_padded :: proc(c: ^Context, r: Rect, pad: f32) {
	render.damage_add(c.renderer, rect_to_damage(rect_pad(r, pad)))
}

// The content of `rect` moved by `delta` screen pixels since the last frame (a scrolled view): presented as a block
// copy where the backend can, so the moved pixels are not repainted. The newly exposed band must still be marked with
// damage. One scroll per frame.
damage_scrolled :: proc(c: ^Context, rect: Rect, delta: Vec2) {
	render.damage_scroll(c.renderer, rect_to_damage(rect), i32(delta.x), i32(delta.y))
}

// This frame's damage: rectangles added (before fusion) and kept (after), the pixels the region covers and the pixels
// of the whole frame, and whether a region is in effect. For diagnostics / stats.
damage_stats :: proc(c: ^Context) -> (added, kept, px_region, px_frame: int, active: bool) {
	return render.damage_stats(c.renderer)
}

@(private)
rect_to_damage :: proc(r: Rect) -> render.Damage_Rect {
	// round outward so a sub-pixel edge is fully covered (a partial rectangle must never clip antialiased fringes)
	return {
		x0 = i32(math.floor(r.min.x)), y0 = i32(math.floor(r.min.y)),
		x1 = i32(math.ceil(r.max.x)),  y1 = i32(math.ceil(r.max.y)),
	}
}
