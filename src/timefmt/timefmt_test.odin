package timefmt

import "core:testing"
import "core:thread"
import "core:time"

DAY_MS :: f64(SECS_PER_DAY * MS_PER_S)

// A span to the second, in its two largest units; days from the limit on.
@(test)
a_span_reads_in_two_units :: proc(t: ^testing.T) {
	testing.expect_value(t, duration(0), "0s")
	testing.expect_value(t, duration(-5_000), "0s")
	testing.expect_value(t, duration(45_900), "45s")
	testing.expect_value(t, duration(252_000), "4m 12s")
	testing.expect_value(t, duration(60_000), "1m 00s")
	testing.expect_value(t, duration(3_780_000), "1h 03m")
	testing.expect_value(t, duration(47 * 3_600_000), "47h 00m")
	testing.expect_value(t, duration(53 * 3_600_000), "2d 05h")
	testing.expect_value(t, duration(25 * 3_600_000, days_after_hours = 24), "1d 01h")
}

// An age in its largest whole unit, "now" under a minute (and for a time a little in the future).
@(test)
an_age_reads_in_one_unit :: proc(t: ^testing.T) {
	testing.expect_value(t, age(-1_000), "now")
	testing.expect_value(t, age(59_000), "now")
	testing.expect_value(t, age(3 * 60_000), "3m")
	testing.expect_value(t, age(2 * 3_600_000 + 1), "2h")
	testing.expect_value(t, age(5 * DAY_MS), "5d")
	testing.expect_value(t, age(15 * DAY_MS), "2w")
}

// The local clock: the offset added, past midnight either way; 24 or 12 hours, seconds when asked.
@(test)
a_clock_reads_on_the_local_time :: proc(t: ^testing.T) {
	at := 20_000 * DAY_MS + 14 * 3_600_000 + 32 * 60_000 + 5_000   // (14:32:05 UTC)
	testing.expect_value(t, clock(at, 0), "14:32")
	testing.expect_value(t, clock(at, 60, {seconds = true}), "15:32:05")
	testing.expect_value(t, clock(at, 0, {hours12 = true}), "2:32 pm")
	testing.expect_value(t, clock(at, 0, {hours12 = true, seconds = true}), "2:32:05 pm")
	testing.expect_value(t, clock(at, 10 * 60), "00:32")   // (the next day)
	testing.expect_value(t, clock(at, -15 * 60), "23:32")  // (the day before)
	testing.expect_value(t, clock(at, 10 * 60, {hours12 = true}), "12:32 am")
	testing.expect_value(t, clock(at - 2 * 3_600_000, 0, {hours12 = true}), "12:32 pm")
}

// A date on the local clock, and the local day that says whether two times share one.
@(test)
a_date_and_its_day_follow_the_offset :: proc(t: ^testing.T) {
	at := 1794309600000.0   // (2026-11-10 11:20 UTC)
	testing.expect_value(t, date(at, 0), "Nov 10")
	testing.expect_value(t, date(at, 13 * 60), "Nov 11")
	testing.expect_value(t, date(at, -12 * 60), "Nov 9")
	testing.expect_value(t, local_day(at, 0), local_day(at + 12 * 3_600_000, 0))
	testing.expect(t, local_day(at, 0) != local_day(at + 13 * 3_600_000, 0), "past midnight UTC")
	testing.expect_value(t, local_day(at, 13 * 60), local_day(at, 0) + 1)
}

// A moment as a list says it: today and yesterday by their names, then the date, the year when it is not this one's.
@(test)
a_moment_reads_from_now :: proc(t: ^testing.T) {
	now := 1794309600000.0   // (2026-11-10 11:20 UTC)
	testing.expect_value(t, moment(now - 3_600_000, now, 0), "today 10:20")
	testing.expect_value(t, moment(now - 3_600_000, now, 0, short = true), "10:20")
	testing.expect_value(t, moment(now - DAY_MS, now, 0), "yesterday 11:20")
	testing.expect_value(t, moment(now - DAY_MS, now, 0, short = true), "yesterday")
	testing.expect_value(t, moment(now - 3 * DAY_MS, now, 0), "Nov 7, 11:20")
	testing.expect_value(t, moment(now - 3 * DAY_MS, now, 0, short = true), "Nov 7")
	testing.expect_value(t, moment(now - 365 * DAY_MS, now, 0, short = true), "Nov 10 2025")
	testing.expect_value(t, moment(now, 0, 0), "Nov 10, 11:20")
	// (yesterday on the local clock, though less than a day ago)
	testing.expect_value(t, moment(now - 12 * 3_600_000, now, 0, short = true), "yesterday")
}

// The bound of the wait for the watch's first reading, and the widest offset of a zone (UTC+14, UTC-12).
@(private = "file") OFFSET_WAIT :: 10 * time.Second
@(private = "file") OFFSET_MOST_MINUTES :: 14 * MINUTES_PER_HOUR

// The watch reads the machine's offset on its own thread: once it has, the value is the system's, within a zone's
// reach. A second call starts nothing more.
@(test)
the_watch_reads_the_machines_offset :: proc(t: ^testing.T) {
	local_offset_watch()
	local_offset_watch()
	end := time.tick_add(time.tick_now(), OFFSET_WAIT)
	for !local_offset_read_once() {
		if time.tick_diff(time.tick_now(), end) <= 0 { break }
		thread.yield()
	}
	if !testing.expect(t, local_offset_read_once(), "the watch read the offset within its bound") { return }
	got := local_offset_minutes()
	testing.expect_value(t, got, local_offset_read())
	testing.expectf(t, abs(got) <= OFFSET_MOST_MINUTES, "an offset of %d minutes", got)
}

@(test)
a_size_reads_in_powers_of_1024 :: proc(t: ^testing.T) {
	testing.expect_value(t, size(512), "512 B")
	// (a no-break space between the number and its unit)
	testing.expect_value(t, size(7 * 1024), "7.0 KB")
	testing.expect_value(t, size(12 * 1024 * 1024), "12 MB")
	testing.expect_value(t, size(1288490188), "1.2 GB")
}
