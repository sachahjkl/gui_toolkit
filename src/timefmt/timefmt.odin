package timefmt

// Times as a person reads them in an interface: a span ("4m 12s"), a stopwatch ("1:02:03"), an age ("3m", "2h"), a clock
// ("14:32", "2:32 pm"), a date ("Nov 10", "Monday", "2026-11-10"); and the sizes and rates beside them ("1.2 MB/s"). Times are milliseconds since 1970 (UTC), as servers and JavaScript give them. The local clock is UTC plus
// `offset_minutes`, which the caller passes: local_offset_minutes() (local_offset.odin) is the machine's, read by a thread
// of its own (ui.init starts it), so these procedures stay pure: no system call, and a test gives any offset. Their words
// and units are in the language in use (gt:i18n).

import "core:fmt"
import "core:math"
import "core:strings"
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

// The local date of `ms`, its month in three letters: "Nov 10"; `year`, with its year: "Nov 10 2026".
date :: proc(ms: f64, offset_minutes: int, year := false, allocator := context.temp_allocator) -> string {
	y, month, d := time.date(local_time(ms, offset_minutes))
	months := [12]string{
		i18n.tr("month", "Jan"), i18n.tr("month", "Feb"), i18n.tr("month", "Mar"), i18n.tr("month", "Apr"), i18n.tr("month", "May"), i18n.tr("month", "Jun"),
		i18n.tr("month", "Jul"), i18n.tr("month", "Aug"), i18n.tr("month", "Sep"), i18n.tr("month", "Oct"), i18n.tr("month", "Nov"), i18n.tr("month", "Dec"),
	}
	// (the order is the language's: "Nov 10", "10 nov.")
	if !year { return fmt.aprintf(i18n.tr("date", "%s %d"), months[int(month) - 1], d, allocator = allocator) }
	day_month := fmt.tprintf(i18n.tr("date", "%s %d"), months[int(month) - 1], d)
	return fmt.aprintf(i18n.tr("date and year", "%s %d"), day_month, y, allocator = allocator)
}

// How far back moment names the weekday (its `weekdays`): from 2 days, as 1 is "yesterday", to 6, as 7 days back
// the weekday is today's again.
MOMENT_WEEKDAYS_MOST :: 6

// When `ms` was, seen at `now_ms`, on the local clock: "today 14:32", "yesterday 14:32", "Nov 10, 14:32", and its year
// when it is not this one's ("Nov 10 2024, 14:32"). `short` (a line among others): "14:32" today, "yesterday", "Nov 10",
// "Nov 10 2024". `weekdays`: from 2 to MOMENT_WEEKDAYS_MOST days back, the weekday's name ("Monday 14:32"; short:
// "Monday"). `now_ms` 0 (not known): its date and its time. In the language in use.
moment :: proc(ms, now_ms: f64, offset_minutes: int, o := Clock_Options{}, short := false, weekdays := false, allocator := context.temp_allocator) -> string {
	at := clock(ms, offset_minutes, o, context.temp_allocator)
	if now_ms > 0 {
		switch local_day(now_ms, offset_minutes) - local_day(ms, offset_minutes) {
		case 0: return short ? fmt.aprint(at, allocator = allocator) : fmt.aprintf(i18n.tr("today %s"), at, allocator = allocator)
		case 1: return short ? fmt.aprint(i18n.tr("yesterday"), allocator = allocator) : fmt.aprintf(i18n.tr("yesterday %s"), at, allocator = allocator)
		case 2 ..= MOMENT_WEEKDAYS_MOST:
			if !weekdays { break }
			name := weekday(ms, offset_minutes)
			return short ? fmt.aprint(name, allocator = allocator) : fmt.aprintf(i18n.tr("weekday and clock", "%s %s"), name, at, allocator = allocator)
		}
	}
	d := date(ms, offset_minutes, year = now_ms > 0 && local_year(ms, offset_minutes) != local_year(now_ms, offset_minutes), allocator = context.temp_allocator)
	return short ? fmt.aprint(d, allocator = allocator) : fmt.aprintf(i18n.tr("%s, %s"), d, at, allocator = allocator)
}

// The local day of `ms`: days since 1970-01-01 on the local clock. Two times are on the same day when their days are equal.
local_day :: proc(ms: f64, offset_minutes: int) -> int {
	return int(math.floor((ms / (SECS_PER_MINUTE * MS_PER_S) + f64(offset_minutes)) / MINUTES_PER_DAY))
}

// The day of the week of `ms` on the local clock, its whole name in the language in use: "Monday".
weekday :: proc(ms: f64, offset_minutes: int) -> string {
	names := [time.Weekday]string{
		.Sunday = i18n.tr("weekday", "Sunday"), .Monday = i18n.tr("weekday", "Monday"), .Tuesday = i18n.tr("weekday", "Tuesday"),
		.Wednesday = i18n.tr("weekday", "Wednesday"), .Thursday = i18n.tr("weekday", "Thursday"), .Friday = i18n.tr("weekday", "Friday"),
		.Saturday = i18n.tr("weekday", "Saturday"),
	}
	return names[time.weekday(local_time(ms, offset_minutes))]
}

// The local date of `ms` as ISO 8601 writes it, the same in every language: "2026-11-10"; `with_clock`, its time on 24
// hours after a space: "2026-11-10 14:32" (a column that sorts as it reads).
iso_date :: proc(ms: f64, offset_minutes: int, with_clock := false, allocator := context.temp_allocator) -> string {
	y, m, d := time.date(local_time(ms, offset_minutes))
	if !with_clock { return fmt.aprintf("%04d-%02d-%02d", y, int(m), d, allocator = allocator) }
	return fmt.aprintf("%04d-%02d-%02d %s", y, int(m), d, clock(ms, offset_minutes, {}, context.temp_allocator), allocator = allocator)
}

// The time of `ms` on the local clock (a time.Time whose UTC fields read as the local ones).
@(private = "file")
local_time :: proc(ms: f64, offset_minutes: int) -> time.Time {
	return time.unix(0, i64((ms + f64(offset_minutes) * SECS_PER_MINUTE * MS_PER_S) * 1e6))
}

@(private = "file")
local_year :: proc(ms: f64, offset_minutes: int) -> int {
	y, _, _ := time.date(local_time(ms, offset_minutes))
	return y
}

@(private = "file")
floor_mod :: proc(a, b: int) -> int { return ((a % b) + b) % b }

Stopwatch_Options :: struct {
	padded: bool,   // "00:07": the minutes on two digits under an hour (a clock that keeps its width while it runs)
	days:   bool,   // "0:04:12:09": days, hours, minutes and seconds, always (an uptime, as Task Manager shows it)
}

// A span of `ms` milliseconds as a stopwatch shows it, to the whole second: "0:07", "12:34", "1:02:03". The same in every
// language (digits and colons). A negative span is "0:00".
stopwatch :: proc(ms: f64, o := Stopwatch_Options{}, allocator := context.temp_allocator) -> string {
	s := i64(max(ms, 0) / MS_PER_S)
	if o.days { return fmt.aprintf("%d:%02d:%02d:%02d", s / SECS_PER_DAY, (s / SECS_PER_HOUR) % 24, (s / SECS_PER_MINUTE) % MINUTES_PER_HOUR, s % SECS_PER_MINUTE, allocator = allocator) }
	if s >= SECS_PER_HOUR { return fmt.aprintf("%d:%02d:%02d", s / SECS_PER_HOUR, (s / SECS_PER_MINUTE) % MINUTES_PER_HOUR, s % SECS_PER_MINUTE, allocator = allocator) }
	return fmt.aprintf(o.padded ? "%02d:%02d" : "%d:%02d", s / SECS_PER_MINUTE, s % SECS_PER_MINUTE, allocator = allocator)
}

Size_Options :: struct {
	// Powers of 1000 and "kB" (a network panel, a download's rate, as browsers count) instead of powers of 1024 and "KB"
	// (a file's size, as the systems' file managers count).
	decimal: bool,
}

// The bytes a size or a rate takes at most once written (the longest unit name of a language included).
SIZE_TEXT_MOST :: 48

// A size in bytes as the systems' file managers say it, in powers of 1024: "512 B", "7.0 KB", "12 MB", "1.2 GB" (one
// decimal under 10, none above), the decimal mark and the units of the language in use ("7,8 Go" in French). A negative
// size is 0 B.
size :: proc(bytes: i64, o := Size_Options{}, allocator := context.temp_allocator) -> string {
	buf: [SIZE_TEXT_MOST]u8
	return strings.clone(write_size(buf[:], bytes, o), allocator)
}

// `size` written into `buf` (SIZE_TEXT_MOST bytes are enough), and the part of it written: no allocation, for a column
// that writes a size in every row of every frame.
write_size :: proc(buf: []u8, bytes: i64, o := Size_Options{}) -> string {
	b := strings.builder_from_bytes(buf)
	size_to(&b, bytes, o)
	return strings.to_string(b)
}

// A rate in bytes per second, as `size` says the bytes: "340 KB/s", "1.2 MB/s" ("0 B/s" when nothing moves).
rate :: proc(bytes_per_s: f64, o := Size_Options{}, allocator := context.temp_allocator) -> string {
	buf: [SIZE_TEXT_MOST]u8
	return strings.clone(write_rate(buf[:], bytes_per_s, o), allocator)
}

// `rate` written into `buf`, as write_size.
write_rate :: proc(buf: []u8, bytes_per_s: f64, o := Size_Options{}) -> string {
	b := strings.builder_from_bytes(buf)
	size_to(&b, i64(max(bytes_per_s, 0)), o)
	strings.write_string(&b, i18n.tr("per second", "/s"))
	return strings.to_string(b)
}

@(private = "file")
size_to :: proc(b: ^strings.Builder, bytes: i64, o: Size_Options) {
	base: f64 = o.decimal ? 1000 : 1024
	if f64(bytes) < base {
		fmt.sbprintf(b, i18n.tr("%d B"), max(bytes, 0))
		return
	}
	units := [?]string{o.decimal ? i18n.tr("kB") : i18n.tr("KB"), i18n.tr("MB"), i18n.tr("GB"), i18n.tr("TB"), i18n.tr("PB")}
	v := f64(bytes) / base
	u := 0
	for v >= base && u < len(units) - 1 {
		v /= base
		u += 1
	}
	// (rounded, 1023.7 KB reads "1024 KB": it is the next unit's 1.0)
	if v >= base - 0.5 && u < len(units) - 1 {
		v /= base
		u += 1
	}
	start := len(b.buf)
	if v < 9.95 { fmt.sbprintf(b, "%.1f", v) } else { fmt.sbprintf(b, "%.0f", v) }
	// (the language's decimal mark, in place: i18n.decimal would allocate)
	if mark := i18n.decimal_mark(); mark != '.' {
		for &c in b.buf[start:] { if c == '.' { c = mark } }
	}
	// (a no-break space: the number and its unit stay on one line)
	strings.write_string(b, " ")
	strings.write_string(b, units[u])
}
