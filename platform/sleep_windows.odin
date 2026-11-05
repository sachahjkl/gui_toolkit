#+build windows
package platform

import win "core:sys/windows"
import "core:time"

// A wait to the millisecond and under: Sleep rounds up to the system's tick (15.6 ms), a whole frame three times over.
precise_sleep :: proc(d: time.Duration) {
	if d <= 0 { return }
	CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: 0x2
	@(thread_local) timer: win.HANDLE
	if timer == nil { timer = win.CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS) }
	if timer == nil { time.sleep(d); return }
	due := win.LARGE_INTEGER(-(i64(d) / 100))   // relative, in 100 ns units
	if !win.SetWaitableTimerEx(timer, &due, 0, nil, nil, nil, 0) { time.sleep(d); return }
	win.WaitForSingleObject(timer, win.INFINITE)
}
