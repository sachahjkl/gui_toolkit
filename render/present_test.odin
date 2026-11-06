package render

import "core:testing"

// What a Present is asked for (present_call), as data: no swap chain, no window.

@(test)
present_call_vsync_waits_its_interval :: proc(t: ^testing.T) {
	testing.expect_value(t, present_call(.Vsync, true, 1, true), Present_Call{sync = 1, mode = .Vsync})
	testing.expect_value(t, present_call(.Vsync, false, 2, true), Present_Call{sync = 2, mode = .Vsync})
	testing.expect_value(t, present_call(.Vsync, false, 0, true).sync, 1)                                    // not set: every refresh
	testing.expect_value(t, present_call(.Vsync, false, SYNC_INTERVAL_MAX + 3, true).sync, SYNC_INTERVAL_MAX)   // DXGI's limit
}

@(test)
present_call_tears_only_where_allowed :: proc(t: ^testing.T) {
	testing.expect_value(t, present_call(.Tearing, true, 2, true), Present_Call{sync = 0, allow_tearing = true, mode = .Tearing})
	// no support (a composition swap chain, an old system, a surface without Immediate): vsync, never the flag
	testing.expect_value(t, present_call(.Tearing, false, 2, true), Present_Call{sync = 2, mode = .Vsync})
	testing.expect_value(t, present_call(.Tearing, false, 1, false), Present_Call{sync = 0, mode = .Vsync})
}

// frame_end(vsync = false) presents at once whatever the mode; with tearing support the flag goes with it (the flag never goes with a wait).
@(test)
present_call_without_vsync_is_at_once :: proc(t: ^testing.T) {
	testing.expect_value(t, present_call(.Vsync, true, 3, false), Present_Call{sync = 0, allow_tearing = true, mode = .Vsync})
	testing.expect_value(t, present_call(.Vsync, false, 3, false), Present_Call{sync = 0, mode = .Vsync})
	for asked in Present_Mode {
		for ok in ([]bool{false, true}) {
			for interval in u32(0) ..= SYNC_INTERVAL_MAX + 1 {
				for vsync in ([]bool{false, true}) {
					c := present_call(asked, ok, interval, vsync)
					testing.expectf(t, !(c.allow_tearing && c.sync != 0), "%v %v %v %v: tearing with a wait", asked, ok, interval, vsync)
					testing.expectf(t, !(c.allow_tearing && !ok), "%v %v %v %v: tearing without support", asked, ok, interval, vsync)
				}
			}
		}
	}
}
// A surface in Fifo waits for the vblank even when frame_end asked for no wait: only a surface in Immediate is at once.
@(test)
wgpu_present_sync_follows_the_surface :: proc(t: ^testing.T) {
	testing.expect_value(t, wgpu_present_sync(0, .Fifo), 1)
	testing.expect_value(t, wgpu_present_sync(0, .Immediate), 0)
	testing.expect_value(t, wgpu_present_sync(2, .Fifo), 2)
}