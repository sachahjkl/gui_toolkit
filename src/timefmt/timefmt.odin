package timefmt

// Times as a person reads them in an interface: a span ("4m 12s"), an age ("3m", "2h"), a clock ("14:32", "2:32 pm") and a
// date ("Nov 10"). Times are milliseconds since 1970 (UTC), as servers and JavaScript give them. The local clock is UTC plus
// `offset_minutes`: reading the machine's offset is a system call (on Linux it may read the zone's file), so a program reads
// it off the interface thread and passes it; these procedures do no system call. Pure Odin, any target. Their words and
// units are in the language in use (gt:i18n).

import "core:fmt"
import "core:math"
import "core:time"
import i18n "../i18n"

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
	case s < SECS_PER_MINUTE: return fmt.aprintf(i18n.tr("%ds"), s, allocator = allocator)
	case s < SECS_PER_HOUR:   return fmt.aprintf(i18n.tr("%dm %02ds"), s / SECS_PER_MINUTE, s % SECS_PER_MINUTE, allocator = allocator)
	}
	if s < days_after_hours * SECS_PER_HOUR {
		return fmt.aprintf(i18n.tr("%dh %02dm"), s / SECS_PER_HOUR, (s / SECS_PER_MINUTE) % MINUTES_PER_HOUR, allocator = allocator)
	}
	return fmt.aprintf(i18n.tr("%dd %02dh"), s / SECS_PER_DAY, (s / SECS_PER_HOUR) % 24, allocator = allocator)
}

// How old something is, in its largest whole unit: "now" under a minute, then "3m", "2h", "5d", "1w".
age :: proc(ms: f64, allocator := context.temp_allocator) -> string {
	d := ms / MS_PER_S
	switch {
	case d < SECS_PER_MINUTE: return i18n.tr("now")
	case d < SECS_PER_HOUR:   return fmt.aprintf(i18n.tr("%dm"), int(d / SECS_PER_MINUTE), allocator = allocator)
	case d < SECS_PER_DAY:    return fmt.aprintf(i18n.tr("%dh"), int(d / SECS_PER_HOUR), allocator = allocator)
	case d < SECS_PER_WEEK:   return fmt.aprintf(i18n.tr("%dd"), int(d / SECS_PER_DAY), allocator = allocator)
	}
	return fmt.aprintf(i18n.tr("%dw"), int(d / SECS_PER_WEEK), allocator = allocator)
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
		return fmt.aprintf("%d:%02d%s %s", hh == 0 ? HOURS_HALF_DAY : hh, total % MINUTES_PER_HOUR, ss, total / MINUTES_PER_HOUR < HOURS_HALF_DAY ? i18n.tr("am") : i18n.tr("pm"), allocator = allocator)
	}
	return fmt.aprintf("%02d:%02d%s", total / MINUTES_PER_HOUR, total % MINUTES_PER_HOUR, ss, allocator = allocator)
}

// The local date of `ms`, its month in three letters: "Nov 10".
date :: proc(ms: f64, offset_minutes: int, allocator := context.temp_allocator) -> string {
	t := time.unix(0, i64((ms + f64(offset_minutes) * SECS_PER_MINUTE * MS_PER_S) * 1e6))
	_, month, d := time.date(t)
	months := [12]string{
		i18n.tr("month", "Jan"), i18n.tr("month", "Feb"), i18n.tr("month", "Mar"), i18n.tr("month", "Apr"), i18n.tr("month", "May"), i18n.tr("month", "Jun"),
		i18n.tr("month", "Jul"), i18n.tr("month", "Aug"), i18n.tr("month", "Sep"), i18n.tr("month", "Oct"), i18n.tr("month", "Nov"), i18n.tr("month", "Dec"),
	}
	// (the order is the language's: "Nov 10", "10 nov.")
	return fmt.aprintf(i18n.tr("date", "%s %d"), months[int(month) - 1], d, allocator = allocator)
}

// The local day of `ms`: days since 1970-01-01 on the local clock. Two times are on the same day when their days are equal.
local_day :: proc(ms: f64, offset_minutes: int) -> int {
	return int(math.floor((ms / (SECS_PER_MINUTE * MS_PER_S) + f64(offset_minutes)) / MINUTES_PER_DAY))
}

@(private = "file")
floor_mod :: proc(a, b: int) -> int { return ((a % b) + b) % b }

// A size in bytes as the systems' file managers say it, in powers of 1024: "512 B", "7.0 KB", "12 MB", "1.2 GB" (one
// decimal under 10, none above).
size :: proc(bytes: i64, allocator := context.temp_allocator) -> string {
	units := [?]string{i18n.tr("KB"), i18n.tr("MB"), i18n.tr("GB"), i18n.tr("TB"), i18n.tr("PB")}
	if bytes < 1024 { return fmt.aprintf(i18n.tr("%d B"), bytes, allocator = allocator) }
	v := f64(bytes) / 1024
	u := 0
	for v >= 1024 && u < len(units) - 1 {
		v /= 1024
		u += 1
	}
	return v < 10 ? fmt.aprintf("%.1f %s", v, units[u], allocator = allocator) : fmt.aprintf("%.0f %s", v, units[u], allocator = allocator)
}
