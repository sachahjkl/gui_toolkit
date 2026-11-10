#+build linux
package tk_process

import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// The nice value the test's child is given (a user may lower a priority: 0 -> 7).
@(private = "file") TEST_NICE :: 7
@(private = "file") TEST_WAIT :: 5 * time.Second

// The test's own child, a sleep: a priority set on all its threads, a signal refused for a wrong start time, then sent.
@(test)
a_signal_reaches_only_the_process_that_started_then :: proc(t: ^testing.T) {
	child, err := os.process_start({command = {"sleep", "30"}})
	testing.expect(t, err == nil, "sleep starts")
	if err != nil { return }
	pid := i32(child.pid)
	start, ok := process_start_time(pid)
	testing.expect(t, ok && start > 0)

	r, _ := signal_process(pid, start + 1, .Terminate)
	testing.expect_value(t, r, Act_Result.Gone)

	r, _ = set_priority(pid, start, TEST_NICE)
	testing.expect_value(t, r, Act_Result.Done)
	stat, rerr := os.read_entire_file(strings.concatenate({"/proc/", int_text(int(pid)), "/stat"}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, rerr == nil)
	close := strings.last_index_byte(string(stat), ')')
	fields := strings.fields(string(stat)[close + 1:], context.temp_allocator)
	testing.expect_value(t, fields[19 - 3], int_text(TEST_NICE))   // (field 19: the nice value)

	r, _ = signal_process(pid, start, .Terminate)
	testing.expect_value(t, r, Act_Result.Done)
	state, werr := os.process_wait(child, TEST_WAIT)
	testing.expect(t, werr == nil && state.exited)

	// the pid is free now: nothing to signal
	r, _ = signal_process(pid, start, .Kill)
	testing.expect_value(t, r, Act_Result.Gone)
	_, gone := process_start_time(pid)
	testing.expect(t, !gone)
}

@(private = "file")
int_text :: proc(n: int) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), context.temp_allocator)
}
