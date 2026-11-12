package capture

import "core:math"

// Where the pointer is: `at` logical, on the desktop, and the id of the output it is on. ok is false when the system
// does not say: a Wayland compositor without ext_image_copy_capture's cursor sessions, or one that has said nothing yet
// (the pointer on no output), the portal backend. Blocks for at most one round trip to the compositor: call it on the
// worker that holds the session.
//
// Wayland tells a client where the pointer is only over its own surfaces; a cursor session per output
// (ext_image_copy_capture_cursor_session_v1) is the way to know it elsewhere. The sessions are made at the first call
// and kept with the outputs.
pointer :: proc(s: ^Session) -> (at: [2]i32, output: u64, ok: bool) {
	if s == nil { return }
	return platform_pointer(s)
}

// A point of a buffer (physical pixels, `size` its width and height before the turn) shown turned as `turn` says, on
// an output placed at `place` (logical, on the desktop): the point on the desktop, logical. The buffer once upright
// covers `place` exactly, whatever the output's scale. The point may be outside the buffer: it is then outside `place`.
pointer_from_buffer :: proc(pos, size: [2]i32, turn: Turn, place: Rect) -> [2]i32 {
	width, height := size.x, size.y
	ow, oh := turned_size(width, height, turn)
	if ow <= 0 || oh <= 0 { return {place.x, place.y} }
	// The inverse of frame_from_buffer_into's mapping (upright to buffer): the buffer's point turned upright, then
	// mirrored.
	ux, uy: i32
	switch u8(turn) & 3 {
	case 0: ux, uy = pos.x, pos.y
	case 1: ux, uy = height - 1 - pos.y, pos.x
	case 2: ux, uy = width - 1 - pos.x, height - 1 - pos.y
	case 3: ux, uy = pos.y, width - 1 - pos.x
	}
	if turn >= .Flipped { ux = ow - 1 - ux }
	return {
		place.x + i32(math.floor(f64(ux) * f64(place.w) / f64(ow))),
		place.y + i32(math.floor(f64(uy) * f64(place.h) / f64(oh))),
	}
}
