package render

import "core:testing"

// A partial frame of nothing is not presented, unless a capture waits for it (its copy needs the frame's texture).
@(test)
a_frame_a_capture_waits_for_is_not_skipped :: proc(t: ^testing.T) {
	r: Renderer
	testing.expect(t, damage_skips_present(&r, true), "a region of nothing: skipped")
	testing.expect(t, !damage_skips_present(&r, false), "a whole frame: presented")
	r.damage.count = 1
	testing.expect(t, !damage_skips_present(&r, true), "a region: presented")
	r.damage.count = 0
	r.capture.requested = true
	testing.expect(t, !damage_skips_present(&r, true), "a capture waits for it: presented")
}
