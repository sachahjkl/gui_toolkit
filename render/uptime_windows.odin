#+build windows
package render

import win "core:sys/windows"

// Milliseconds since this process started (render trace, first-present timing). Windows reads the process creation time.
@(private)
process_uptime_ms :: proc() -> f64 {
	created, exited, kernel, user: win.FILETIME
	now: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &created, &exited, &kernel, &user)
	win.GetSystemTimeAsFileTime(&now)
	ft :: proc(f: win.FILETIME) -> u64 { return u64(f.dwHighDateTime) << 32 | u64(f.dwLowDateTime) }
	return f64(ft(now) - ft(created)) / 1e4
}
