# timefmt: times as people read them

`import "gt:timefmt"` (or the relative path of the submodule). Pure Odin, any target.

A time is milliseconds since 1970 (UTC), as servers and JavaScript give them. The local clock is UTC plus
`offset_minutes`. Reading the machine's offset is a system call (on Linux it can read the zone's file): read it on a
worker, keep the last value, and pass it. No procedure of this package makes a system call. Each result is in temp memory
unless `allocator` says otherwise.

| Procedure | Result |
|---|---|
| `duration(ms, days_after_hours = 48)` | a span to the second, in its two largest units: "45s", "4m 12s", "1h 03m", from `days_after_hours` hours on "2d 05h"; a negative span is "0s" |
| `size(bytes)` | a size as file managers say it, in powers of 1024: "512 B", "7.0 KB", "12 MB", "1.2 GB" (one decimal under 10) |
| `age(ms)` | how old something is, in its largest whole unit: "now" under a minute (or in the future), "3m", "2h", "5d", "1w" |
| `clock(ms, offset_minutes, Clock_Options{hours12, seconds})` | the local time: "14:32"; `hours12`: "2:32 pm", "12:05 am"; `seconds`: "14:32:05" |
| `date(ms, offset_minutes)` | the local date: "Nov 10" |
| `moment(ms, now_ms, offset_minutes, Clock_Options, short)` | when it was, seen from now: "today 14:32", "yesterday 14:32", "Nov 10, 14:32", its year when not this one's ("Nov 10 2024, 14:32"); `short` (a line among others): "14:32", "yesterday", "Nov 10"; `now_ms` 0: date and time |
| `local_day(ms, offset_minutes)` | days since 1970-01-01 on the local clock: two times are on the same day when their days are equal |

The constants `MS_PER_S`, `SECS_PER_MINUTE`, `SECS_PER_HOUR`, `SECS_PER_DAY`, `SECS_PER_WEEK`, `MINUTES_PER_HOUR` and
`MINUTES_PER_DAY` are exported for the arithmetic around them.

```odin
offset := local_offset_minutes()   // (the program's: read on a worker)
started := timefmt.clock(task.started_ms, offset, {seconds = true})
if timefmt.local_day(task.started_ms, offset) != timefmt.local_day(now, offset) {
	started = fmt.tprintf("%s, %s", timefmt.date(task.started_ms, offset), started)
}
label := fmt.tprintf("started %s, %s ago", started, timefmt.duration(now - task.started_ms))
```

`odin run tools/run_tests -- timefmt` tests it.
