package tk_session

// Partial redraw under test: every partial frame drawn whole on the side and compared (draw.set_damage_verify), frames
// until nothing moves, what the last frame's region covered. The tests of partial redraw (tests/partial_redraw,
// tests/partial_redraw_layers) and a program's own share them.

import "core:testing"
import "../../draw"
import "../../render"
import "../../ui"

// Frames in a row that redraw nothing: at rest (longer than a gap inside an animation; a caret's blink is half a second).
DAMAGE_QUIET_FRAMES :: 12
// What damage_settle runs at most by default.
DAMAGE_SETTLE_FRAMES :: 90
// How far a value of the last frame may be from [0, 1] and from opaque (a half's rounding of a blend).
OPAQUE_MARGIN :: 1e-3

// Partial redraw on, each partial frame checked against the whole one (damage_expect_exact reads the result).
damage_verify :: proc(s: ^Session) {
	ui.set_partial_redraw(s.state, true)
	draw.set_damage_verify(draw_context(s), true)
}

// The pixels the last frame's region covered, and whether the frame had a region.
damage_px :: proc(s: ^Session) -> (px: int, active: bool) {
	_, _, px, _, active = draw.damage_stats(draw_context(s))
	return
}

// Frames until nothing moves (DAMAGE_QUIET_FRAMES in a row redraw nothing), `frames` at most; the largest region on the
// way. (A fixed count ran every scene its whole bound: on WebGPU's WARP, where the verify draws each frame twice, a
// package of such scenes passed its time.)
damage_settle :: proc(s: ^Session, frames := DAMAGE_SETTLE_FRAMES) -> (most: int) {
	quiet := 0
	for _ in 0 ..< frames {
		frame(s)
		px, active := damage_px(s)
		most = max(most, px)
		quiet = active && px == 0 ? quiet + 1 : 0
		if quiet >= DAMAGE_QUIET_FRAMES { break }
	}
	return
}

// Every partial frame was the whole frame to the bit (in the frame's format), and the last frame is opaque
// (expect_opaque).
damage_expect_exact :: proc(t: ^testing.T, s: ^Session, what: string, loc := #caller_location) {
	format := render.frame_is_half(s.renderer) ? "half floats" : "8 bits"
	n := render.damage_verify_differences(s.renderer)
	testing.expectf(t, n == 0, "%s (%s): %d partial frames differ from the whole frame", what, format, n, loc = loc)
	expect_opaque(t, s, what, loc)
}

// The last frame's values: finite, in [0, 1], alpha 1 (each within OPAQUE_MARGIN): a window shows nothing behind it.
expect_opaque :: proc(t: ^testing.T, s: ^Session, what: string, loc := #caller_location) {
	format := render.frame_is_half(s.renderer) ? "half floats" : "8 bits"
	n, at, v := out_of_range(capture_float(s), least_alpha = 1 - OPAQUE_MARGIN, margin = OPAQUE_MARGIN)
	testing.expectf(t, n == 0, "%s (%s): %d pixels out of [0, 1] or not opaque, the first at %v: %v", what, format, n, at, v, loc = loc)
}
