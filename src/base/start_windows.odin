package gt_base

import win "core:sys/windows"

// How long ago the process started, in nanoseconds: its creation time, against the system's time now.
@(private)
process_age_ns :: proc "contextless" () -> i64 {
	created, exited, kernel, user, now: win.FILETIME
	if !win.GetProcessTimes(win.GetCurrentProcess(), &created, &exited, &kernel, &user) { return 0 }
	win.GetSystemTimeAsFileTime(&now)
	ft :: proc "contextless" (f: win.FILETIME) -> i64 { return i64(f.dwHighDateTime) << 32 | i64(f.dwLowDateTime) }
	return max(ft(now) - ft(created), 0) * 100   // (a FILETIME counts 100 ns)
}
