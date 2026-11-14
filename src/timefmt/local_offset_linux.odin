package timefmt

import "core:c"

foreign import libc "system:c"

@(private = "file")
Tm :: struct {   // glibc's struct tm
	sec, min, hour, mday, mon, year, wday, yday, isdst: c.int,
	gmtoff: c.long,
	zone:   cstring,
}

@(default_calling_convention = "c", private = "file")
foreign libc {
	// (named apart: the package imports core:time as `time`)
	@(link_name = "time") libc_time :: proc(t: ^c.long) -> c.long ---
	localtime_r :: proc(t: ^c.long, out: ^Tm) -> ^Tm ---
}

// Minutes to add to UTC for the machine's local time now (daylight saving included). It may read the zone's file: only
// the watch's thread calls it (local_offset_watch).
@(private)
local_offset_read :: proc() -> int {
	now := libc_time(nil)
	tm: Tm
	if localtime_r(&now, &tm) == nil { return 0 }
	return int(tm.gmtoff) / SECS_PER_MINUTE
}
