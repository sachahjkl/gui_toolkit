package timefmt

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

// (core:sys/windows declares the struct, not the call)
@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	GetTimeZoneInformation :: proc(tzi: ^win.TIME_ZONE_INFORMATION) -> u32 ---
}

@(private = "file") TIME_ZONE_ID_DAYLIGHT :: 2

// Minutes to add to UTC for the machine's local time now (daylight saving included). A system call: only the watch's
// thread calls it (local_offset_watch).
@(private)
local_offset_read :: proc() -> int {
	tzi: win.TIME_ZONE_INFORMATION
	r := GetTimeZoneInformation(&tzi)
	bias := int(tzi.Bias) + (r == TIME_ZONE_ID_DAYLIGHT ? int(tzi.DaylightBias) : int(tzi.StandardBias))
	return -bias
}
