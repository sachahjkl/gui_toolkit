# timefmt: times as people read them

`import "gt:timefmt"` (or the relative path of the submodule). Any target.

A time is milliseconds since 1970 (UTC), as servers and JavaScript give them. The local clock is UTC plus
`offset_minutes`, which the caller passes. The procedures that format make no system call. Each result is in temp memory
unless `allocator` says otherwise.

## The machine's offset

| Procedure | Result |
|---|---|
| `local_offset_watch()` | starts the watch: one thread reads the machine's offset at once, then every `LOCAL_OFFSET_EVERY` (a minute), and stores it atomically. The first call starts it; a later one does nothing. `ui.init` calls it: a program of the toolkit never does |
| `local_offset_minutes()` | the last reading, in minutes to add to UTC (daylight saving included); 0 until the first one. An atomic load: any thread, any build |
| `local_offset_read_once()` | whether the first reading is stored (a test waits for it) |

Reading the offset is a system call (Linux: libc's `localtime_r`, which can read the zone's file; Windows:
`GetTimeZoneInformation`; other systems: 0, UTC). It never runs on the caller's thread. Every widget and every program
reads the same value: a change of zone or of daylight saving shows everywhere within a minute.

## Formatting

| Procedure | Result |
|---|---|
| `duration(ms, days_after_hours = 48)` | a span to the second, in its two largest units: "45s", "4m 12s", "1h 03m", from `days_after_hours` hours on "2d 05h"; a negative span is "0s" |
| `stopwatch(ms, Stopwatch_Options{padded, days})` | a span as a stopwatch shows it: "0:07", "12:34", "1:02:03"; `padded`: "00:07" (the width stays while it runs); `days`: "3:04:12:09" (an uptime); the same in every language |
| `size(bytes, Size_Options{decimal})` | a size as file managers say it, in powers of 1024: "512 B", "7.0 KB", "12 MB", "1.2 GB" (one decimal under 10); `decimal`: powers of 1000 and "kB", as browsers count network bytes |
| `rate(bytes_per_s, Size_Options)` | a size per second: "340 KB/s", "0 B/s" when nothing moves (a column that wants an empty cell tests the rate first) |
| `write_size(buf, bytes, Size_Options)`, `write_rate(buf, bytes_per_s, Size_Options)` | the same, written into `buf` (`SIZE_TEXT_MOST` bytes), and the part written: no allocation, for a column that writes one per row per frame |
| `age(ms)` | how old something is, in its largest whole unit: "now" under a minute (or in the future), "3m", "2h", "5d", "1w" |
| `clock(ms, offset_minutes, Clock_Options{hours12, seconds})` | the local time: "14:32"; `hours12`: "2:32 pm", "12:05 am"; `seconds`: "14:32:05" |
| `date(ms, offset_minutes, year = false)` | the local date: "Nov 10"; `year`: "Nov 10 2026" |
| `weekday(ms, offset_minutes)` | the local day of the week, its whole name: "Monday" (static text: no allocation) |
| `iso_date(ms, offset_minutes, with_clock = false)` | the local date as ISO 8601 writes it, in every language: "2026-11-10"; `with_clock`: "2026-11-10 14:32" |
| `moment(ms, now_ms, offset_minutes, Clock_Options, short, weekdays)` | when it was, seen from now: "today 14:32", "yesterday 14:32", "Nov 10, 14:32", its year when not this one's ("Nov 10 2024, 14:32"); `short` (a line among others): "14:32", "yesterday", "Nov 10"; `weekdays`: from 2 to `MOMENT_WEEKDAYS_MOST` (6) days back, "Monday 14:32" (short: "Monday"); `now_ms` 0: date and time |
| `local_day(ms, offset_minutes)` | days since 1970-01-01 on the local clock: two times are on the same day when their days are equal |

The constants `MS_PER_S`, `SECS_PER_MINUTE`, `SECS_PER_HOUR`, `SECS_PER_DAY`, `SECS_PER_WEEK`, `MINUTES_PER_HOUR` and
`MINUTES_PER_DAY` are exported for the arithmetic around them.

```odin
offset := timefmt.local_offset_minutes()   // (the watch's last reading: no system call here)
started := timefmt.clock(task.started_ms, offset, {seconds = true})
if timefmt.local_day(task.started_ms, offset) != timefmt.local_day(now, offset) {
	started = fmt.tprintf("%s, %s", timefmt.date(task.started_ms, offset), started)
}
label := fmt.tprintf("started %s, %s ago", started, timefmt.duration(now - task.started_ms))
```

`odin run tools/run_tests -- timefmt` tests it.
