#+build linux
package platform

import "core:time"

foreign import libc_timer "system:c"

@(private = "file") CLOCK_MONOTONIC :: 1
@(private = "file") TFD_FLAGS :: 0o2004000   // TFD_CLOEXEC | TFD_NONBLOCK
@(private = "file") NS_PER_S :: 1_000_000_000

@(private = "file")
Itimerspec :: struct { interval_s, interval_ns, value_s, value_ns: i64 }

@(default_calling_convention = "c", private = "file")
foreign libc_timer {
	timerfd_create  :: proc(clock, flags: i32) -> i32 ---
	timerfd_settime :: proc(fd, flags: i32, new, old: ^Itimerspec) -> i32 ---
}

// A wait under the system's tick (nanosleep is precise here). Nothing is read meanwhile: with a window, wait_slot.
precise_sleep :: proc(d: time.Duration) { time.sleep(d) }

// The wait of a frame's slot (see the declaration of the same name in sleep_other.odin for what it does).
wait_slot :: proc(w: ^Window, d: time.Duration) {
	if d <= 0 || (w != nil && w.offscreen) { return }
	if w == nil || w.in_poll { precise_sleep(d); return }
	@(thread_local) timer: i32   // the descriptor + 1 (0: none yet)
	if timer == 0 { timer = timerfd_create(CLOCK_MONOTONIC, TFD_FLAGS) + 1 }
	if timer <= 0 { timer = 0; precise_sleep(d); return }
	spec := Itimerspec{value_s = i64(d) / NS_PER_S, value_ns = i64(d) % NS_PER_S}
	if timerfd_settime(timer - 1, 0, &spec, nil) != 0 { precise_sleep(d); return }   // (arming it again forgets the last expiry)
	wait_handle(w, rawptr(uintptr(timer - 1)), int(time.duration_milliseconds(d)) + WAIT_SLOT_MARGIN_MS, until_press = true)
}
