package timefmt

// Times as a person reads them in an interface: a span ("4m 12s"), an age ("3m", "2h"), a clock ("14:32", "2:32 pm") and a
// date ("Nov 10"). Times are milliseconds since 1970 (UTC), as servers and JavaScript give them. The local clock is UTC plus
// `offset_minutes`: reading the machine's offset is a system call (on Linux it may read the zone's file), so a program reads
// it off the interface thread and passes it; these procedures do no system call. Pure Odin, any target.

import "core:fmt"
import "core:math"
import "core:time"

MS_PER_S         :: 1000
SECS_PER_MINUTE  :: 60
SECS_PER_HOUR    :: 3600
SECS_PER_DAY     :: 86400
SECS_PER_WEEK    :: 86400 * 7
MINUTES_PER_HOUR :: 60
MINUTES_PER_DAY  :: 24 * 60
HOURS_HALF_DAY   :: 12
DAYS_AFTER_HOURS :: 48   // duration: from this many hours on, a span is told in days

// A span of `ms` milliseconds, to the second: "45s", "4m 12s", "1h 03m", from `days_after_hours` hours on "2d 05h".
// A negative span is 0s.
duration :: proc(ms: f64, days_after_hours := DAYS_AFTER_HOURS, allocator := context.temp_allocator) -> string {
	s := int(max(ms, 0) / MS_PER_S)
	switch {
	case s < SECS_PER_MINUTE: return fmt.aprintf("%ds", s, allocator = allocator)
	case s < SECS_PER_HOUR:   return fmt.aprintf("%dm %02ds", s / SECS_PER_MINUTE, s % SECS_PER_MINUTE, allocator = allocator)
	}
	if s < days_after_hours * SECS_PER_HOUR {
		return fmt.aprintf("%dh %02dm", s / SECS_PER_HOUR, (s / SECS_PER_MINUTE) % MINUTES_PER_HOUR, allocator = allocator)
	}
	return fmt.aprintf("%dd %02dh", s / SECS_PER_DAY, (s / SECS_PER_HOUR) % 24, allocator = allocator)
}

// How old something is, in its largest whole unit: "now" under a minute, then "3m", "2h", "5d", "1w".
age :: proc(ms: f64, allocator := context.temp_allocator) -> string {
	d := ms / MS_PER_S
	switch {
	case d < SECS_PER_MINUTE: return "now"
	case d < SECS_PER_HOUR:   return fmt.aprintf("%dm", int(d / SECS_PER_MINUTE), allocator = allocator)
	case d < SECS_PER_DAY:    return fmt.aprintf("%dh", int(d / SECS_PER_HOUR), allocator = allocator)
	case d < SECS_PER_WEEK:   return fmt.aprintf("%dd", int(d / SECS_PER_DAY), allocator = allocator)
	}
	return fmt.aprintf("%dw", int(d / SECS_PER_WEEK), allocator = allocator)
}

Clock_Options :: struct {
	hours12: bool,   // "2:32 pm", "12:05 am" instead of "14:32", "00:05"
	seconds: bool,   // "14:32:05"
}

// The local time of `ms` (since 1970, UTC): "14:32"; Clock_Options adds the seconds or reads it on 12 hours.
clock :: proc(ms: f64, offset_minutes: int, o := Clock_Options{}, allocator := context.temp_allocator) -> string {
	secs := floor_mod(int(math.floor(ms / MS_PER_S)) + offset_minutes * SECS_PER_MINUTE, SECS_PER_DAY)
	total := secs / SECS_PER_MINUTE   // (minutes since the local midnight)
	ss := o.seconds ? fmt.tprintf(":%02d", secs % SECS_PER_MINUTE) : ""
	if o.hours12 {
		hh := (total / MINUTES_PER_HOUR) % HOURS_HALF_DAY
		return fmt.aprintf("%d:%02d%s %s", hh == 0 ? HOURS_HALF_DAY : hh, total % MINUTES_PER_HOUR, ss, total / MINUTES_PER_HOUR < HOURS_HALF_DAY ? "am" : "pm", allocator = allocator)
	}
	return fmt.aprintf("%02d:%02d%s", total / MINUTES_PER_HOUR, total % MINUTES_PER_HOUR, ss, allocator = allocator)
}

// The local date of `ms`, its month in three letters: "Nov 10".
date :: proc(ms: f64, offset_minutes: int, allocator := context.temp_allocator) -> string {
	t := time.unix(0, i64((ms + f64(offset_minutes) * SECS_PER_MINUTE * MS_PER_S) * 1e6))
	_, month, d := time.date(t)
	months := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return fmt.aprintf("%s %d", months[int(month) - 1], d, allocator = allocator)
}

// The local day of `ms`: days since 1970-01-01 on the local clock. Two times are on the same day when their days are equal.
local_day :: proc(ms: f64, offset_minutes: int) -> int {
	return int(math.floor((ms / (SECS_PER_MINUTE * MS_PER_S) + f64(offset_minutes)) / MINUTES_PER_DAY))
}

@(private = "file")
floor_mod :: proc(a, b: int) -> int { return ((a % b) + b) % b }
