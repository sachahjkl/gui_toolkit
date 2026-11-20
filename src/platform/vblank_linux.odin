#+build linux
package platform

import "core:sys/posix"

// The clock of a display server's timestamps, moved to core:time's (CLOCK_MONOTONIC_RAW on Linux), which the pacer and the
// frame statistics use. Wayland's presentation answers are on the clock the compositor announces (CLOCK_MONOTONIC on
// sway, KWin, Mutter), X11's Present answers on CLOCK_MONOTONIC.

// (Linux's clock ids, as the protocols pass them: clock_gettime's)
@(private) CLOCK_ID_MONOTONIC :: 1
@(private) CLOCK_ID_MONOTONIC_RAW :: 4

// `t_ns` on the clock `clock_id`, on core:time's tick clock. 0: a clock cannot be read.
@(private)
clock_to_tick_ns :: proc(t_ns: i64, clock_id: u32) -> i64 {
	if clock_id == CLOCK_ID_MONOTONIC_RAW { return t_ns }
	// (moved by the distance of the two clocks now; they drift by parts per million (NTP's slew), nothing over the frames
	// that use it. libc's clock_gettime is the vDSO's: no call into the kernel)
	read :: proc(id: u32) -> (i64, bool) {
		ts: posix.timespec
		if posix.clock_gettime(posix.Clock(id), &ts) != .OK { return 0, false }
		return i64(ts.tv_sec) * 1e9 + i64(ts.tv_nsec), true
	}
	theirs, ok1 := read(clock_id)
	ours, ok2 := read(CLOCK_ID_MONOTONIC_RAW)
	if !ok1 || !ok2 { return 0 }
	return t_ns - theirs + ours
}
