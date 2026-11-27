package gt_base

import "core:sys/linux"

// /proc/self/stat counts its start time in clock ticks of USER_HZ, 100 a second on every Linux architecture.
@(private = "file") USER_HZ :: 100
@(private = "file") STAT_BYTES :: 1024
// The start time is the 22nd field; the fields after the name's ")" start at the 3rd.
@(private = "file") STARTTIME_AFTER_NAME :: 22 - 3

// How long ago the process started, in nanoseconds (0: unknown). The start time and CLOCK_BOOTTIME count from the boot.
@(private)
process_age_ns :: proc "contextless" () -> i64 {
	fd, err := linux.open("/proc/self/stat", {})
	if err != .NONE { return 0 }
	buf: [STAT_BYTES]u8
	n, rerr := linux.read(fd, buf[:])
	linux.close(fd)
	if rerr != .NONE || n <= 0 { return 0 }
	text := buf[:n]
	// (the name is in parentheses and may hold spaces and parentheses: the fields start after the last ")")
	at := -1
	for c, i in text { if c == ')' { at = i } }
	if at < 0 { return 0 }
	field := 0
	ticks: i64 = 0
	in_field := false
	for c in text[at + 1:] {
		if c == ' ' { in_field = false; continue }
		if !in_field { in_field = true; field += 1 }
		if field == STARTTIME_AFTER_NAME + 1 {
			if c < '0' || c > '9' { return 0 }
			ticks = ticks * 10 + i64(c - '0')
		} else if field > STARTTIME_AFTER_NAME + 1 {
			break
		}
	}
	now, terr := linux.clock_gettime(.BOOTTIME)
	if terr != .NONE || ticks == 0 { return 0 }
	age := i64(now.time_sec) * 1_000_000_000 + i64(now.time_nsec) - ticks * (1_000_000_000 / USER_HZ)
	return max(age, 0)
}
