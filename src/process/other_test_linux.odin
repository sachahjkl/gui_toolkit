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

// The test's own child, a sleep: its processors read, narrowed to the first one, read again; a wrong start time is
// refused.
@(test)
an_affinity_reaches_every_thread_of_the_process :: proc(t: ^testing.T) {
	child, err := os.process_start({command = {"sleep", "30"}})
	testing.expect(t, err == nil, "sleep starts")
	if err != nil { return }
	defer { _ = os.process_kill(child); _, _ = os.process_wait(child, TEST_WAIT) }
	pid := i32(child.pid)
	start, _ := process_start_time(pid)
	cpus, r, _ := affinity(pid, start)
	testing.expect_value(t, r, Act_Result.Done)
	testing.expect(t, cpu_set_count(cpus) >= 1, "it may run somewhere")
	first := -1
	for i in 0 ..< CPU_SET_MAX { if cpu_set_has(cpus, i) { first = i; break } }
	one: Cpu_Set
	cpu_set_put(&one, first)
	r, _ = set_affinity(pid, start, one)
	testing.expect_value(t, r, Act_Result.Done)
	again, r2, _ := affinity(pid, start)
	testing.expect_value(t, r2, Act_Result.Done)
	testing.expect(t, cpu_set_count(again) == 1 && cpu_set_has(again, first), "one processor now")
	r, _ = set_affinity(pid, start + 1, cpus)
	testing.expect_value(t, r, Act_Result.Gone)
	r, _ = set_affinity(pid, start, {})
	testing.expect_value(t, r, Act_Result.Failed)
}

@(private = "file")
int_text :: proc(n: int) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), context.temp_allocator)
}

// The test's own children, sleeps: each signal of a program's menu ends one by its own number (a sleep takes none).
@(test)
each_signal_is_its_own :: proc(t: ^testing.T) {
	SIGNALS :: [?]struct { sig: Signal, number: int }{{.Hangup, 1}, {.Interrupt, 2}, {.Quit, 3}, {.User1, 10}, {.User2, 12}}
	for s in SIGNALS {
		child, err := os.process_start({command = {"sleep", "30"}})
		if !testing.expect(t, err == nil, "sleep starts") { return }
		pid := i32(child.pid)
		start, _ := process_start_time(pid)
		r, _ := signal_process(pid, start, s.sig)
		testing.expect_value(t, r, Act_Result.Done)
		state, werr := os.process_wait(child, TEST_WAIT)
		testing.expectf(t, werr == nil && state.exit_code == s.number, "%v ends it by signal %d (%v)", s.sig, s.number, state)
	}
}
