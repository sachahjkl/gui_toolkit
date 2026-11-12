package timefmt

import "core:testing"

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
