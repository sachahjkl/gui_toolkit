#+build windows
package platform

import win "core:sys/windows"
import "core:time"

// A timer of the thread, to the millisecond and under: Sleep rounds up to the system's tick (15.6 ms), a whole frame three times over.
@(private = "file")
thread_timer :: proc() -> win.HANDLE {
	CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: 0x2
	@(thread_local) timer: win.HANDLE
	if timer == nil { timer = win.CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS) }
	return timer
}

@(private = "file")
timer_arm :: proc(d: time.Duration) -> (win.HANDLE, bool) {
	timer := thread_timer()
	if timer == nil { return nil, false }
	due := win.LARGE_INTEGER(-(i64(d) / 100))   // relative, in 100 ns units
	return timer, bool(win.SetWaitableTimerEx(timer, &due, 0, nil, nil, nil, 0))
}

// A wait under the system's tick. Nothing is read meanwhile: with a window, wait_slot.
precise_sleep :: proc(d: time.Duration) {
	if d <= 0 { return }
	timer, armed := timer_arm(d)
	if !armed { time.sleep(d); return }
	win.WaitForSingleObject(timer, win.INFINITE)
}

// The wait of a frame's slot (see the declaration of the same name in sleep_other.odin for what it does).
wait_slot :: proc(w: ^Window, d: time.Duration) {
	if d <= 0 || (w != nil && w.offscreen) { return }
	if w == nil || w.in_poll { precise_sleep(d); return }
	timer, armed := timer_arm(d)
	if !armed { precise_sleep(d); return }
	wait_handle(w, rawptr(timer), int(time.duration_milliseconds(d)) + WAIT_SLOT_MARGIN_MS, until_press = true)
}
