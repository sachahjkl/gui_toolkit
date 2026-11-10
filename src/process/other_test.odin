package tk_process

import "core:testing"

@(test)
the_start_time_of_a_stat_line :: proc(t: ^testing.T) {
	// (a name with spaces and parentheses: the fields are counted after its last ')')
	line := "1234 (a (b) c) S 1 1234 1234 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 2 0 987654 12345678 300 18446744073709551615"
	start, ok := parse_start_time(line)
	testing.expect(t, ok)
	testing.expect_value(t, start, u64(987654))
	_, short := parse_start_time("1 (x) S 1 2 3")
	testing.expect(t, !short)
	_, none := parse_start_time("no name")
	testing.expect(t, !none)
}
