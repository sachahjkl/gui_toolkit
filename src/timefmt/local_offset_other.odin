#+build !linux
#+build !windows
package timefmt

// Other systems: no reading of the zone, the local clock is UTC.
@(private)
local_offset_read :: proc() -> int { return 0 }
