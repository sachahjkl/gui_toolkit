package host_test

// host.program_start: a program's log and crash reports in one call. The program is this test program, started again
// with GT_PROGRAM_TEST_CHILD set: its @(init) starts, logs a line, prints the last session's report and ends cleanly or
// not, before the test runner starts (a crash handler is never installed in the runner itself). Its folders are a
// temporary folder's (Program_Start_Options.dir).

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import host "gt:host"
import tk_log "gt:log"
import "gt:testkit"

@(private = "file") PROGRAM_CHILD_ENV :: "GT_PROGRAM_TEST_CHILD"
@(private = "file") PROGRAM_DIR_ENV :: "GT_PROGRAM_TEST_DIR"
@(private = "file") PROGRAM_NAME :: "program_test"
@(private = "file") PROGRAM_LINE :: "the child started"
@(private = "file") NO_CRASH :: "none"
@(private = "file") RESTARTED_ARG :: "--gt-restarted"
@(private = "file") RESTARTED_FILE :: "restarted.txt"
@(private = "file") RESTART_BOUND :: 60 * time.Second

// What the test's launch was given (restart_after_exit's in-process test).
@(private = "file") launched: [dynamic]string

// The child: "end" ends cleanly, "killed" ends with its session open (as a kill would leave it), "restart" asks to
// start again at its end. Started again (RESTARTED_ARG), it writes what it found in RESTARTED_FILE and ends.
@(init)
@(private = "file")
program_child :: proc "contextless" () {
	context = runtime.default_context()
	mode, is_child := os.lookup_env(PROGRAM_CHILD_ENV, context.temp_allocator)
	if !is_child { return }
	dir, _ := os.lookup_env(PROGRAM_DIR_ENV, context.temp_allocator)
	p := host.program_start({name = PROGRAM_NAME, folder = PROGRAM_NAME, version = "1.2.3", dir = dir, quiet = true})
	context.logger = p.logger
	if len(os.args) > 1 && os.args[1] == RESTARTED_ARG {
		found := fmt.tprintf("%s\n%s", p.last_crash != "" ? p.last_crash : NO_CRASH, p.executable)
		file, _ := filepath.join({dir, RESTARTED_FILE}, context.temp_allocator)
		_ = os.write_entire_file(file, transmute([]u8)found)
		context.logger = {}
		host.program_end(&p)
		os.exit(0)
	}
	log.info(PROGRAM_LINE)
	fmt.print(p.last_crash != "" ? p.last_crash : NO_CRASH)
	if mode == "restart" { host.restart_after_exit(&p, {RESTARTED_ARG}) }
	if mode == "end" || mode == "restart" {
		context.logger = {}
		host.program_end(&p)
	} else {
		tk_log.flush(p.logger)
	}
	os.exit(0)
}

@(private = "file")
program_run :: proc(t: ^testing.T, mode, dir: string) -> string {
	parent, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, context.temp_allocator)
	for e in parent {
		if !strings.has_prefix(e, PROGRAM_CHILD_ENV + "=") && !strings.has_prefix(e, PROGRAM_DIR_ENV + "=") { append(&env, e) }
	}
	append(&env, fmt.tprintf("%s=%s", PROGRAM_CHILD_ENV, mode), fmt.tprintf("%s=%s", PROGRAM_DIR_ENV, dir))
	_, stdout, _, err := os.process_exec({command = {os.args[0]}, env = env[:]}, context.temp_allocator)
	testing.expectf(t, err == nil, "the child (%s) runs: %v", mode, err)
	return string(stdout)
}

// A start after a session that ended with no report (a kill) says it: the session begins before the last report is read.
// A start after a clean end says nothing.
@(test)
a_start_says_the_last_session_that_did_not_end_cleanly :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "program")
	testing.expect_value(t, program_run(t, "killed", dir), NO_CRASH)   // (the first start: nothing before it)
	report := program_run(t, "end", dir)
	crashes, _ := filepath.join({dir, "crashes"}, context.temp_allocator)
	testing.expectf(t, report != NO_CRASH && strings.has_prefix(report, crashes), "the killed session's report, in %s: %s", crashes, report)
	testing.expect_value(t, program_run(t, "end", dir), NO_CRASH)      // (the last one ended cleanly)
	log_file, _ := filepath.join({dir, "logs", PROGRAM_NAME + ".log"}, context.temp_allocator)
	text, read := os.read_entire_file_from_path(log_file, context.temp_allocator)
	testing.expect(t, read == nil, "the log is in its folder")
	testing.expect(t, strings.contains(string(text), PROGRAM_LINE), "with the child's line")
}

// restart_after_exit: program_end starts the executable read at the start, with the last args asked, and only when
// asked. The launch is the test's (Program_Start_Options.launch).
@(test)
the_end_starts_the_program_again_when_asked :: proc(t: ^testing.T) {
	defer { for s in launched { delete(s) }; delete(launched); launched = nil }
	record := proc(exe: string, args: []string) -> bool {
		append(&launched, strings.clone(exe))
		for a in args { append(&launched, strings.clone(a)) }
		return true
	}
	p := host.Program_Start{executable = strings.clone("/opt/app/app"), launch = record, allocator = context.allocator}
	host.program_end(&p)
	testing.expect_value(t, len(launched), 0)   // (not asked: nothing starts)

	p = host.Program_Start{executable = strings.clone("/opt/app/app"), launch = record, allocator = context.allocator}
	host.restart_after_exit(&p, {"--hidden"})
	host.restart_after_exit(&p, {"--a", "--b"})   // (the last asked wins)
	testing.expect_value(t, len(launched), 0)     // (nothing before the end)
	host.program_end(&p)
	if testing.expect_value(t, len(launched), 3) {
		testing.expect_value(t, launched[0], "/opt/app/app")
		testing.expect_value(t, launched[1], "--a")
		testing.expect_value(t, launched[2], "--b")
	}
	testing.expect_value(t, p.executable, "")   // (program_end freed it)
}

// The real sequence: a program asks to start again and ends; the new process starts from the path the first one
// started from, after the first one's session ended (it says no crash).
@(test)
a_restart_starts_the_program_after_its_session_ended :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, RESTART_BOUND)
	dir := testkit.temp_folder(t, "restart")
	testing.expect_value(t, program_run(t, "restart", dir), NO_CRASH)
	file, _ := filepath.join({dir, RESTARTED_FILE}, context.temp_allocator)
	begun := time.tick_now()
	text: []u8
	for {
		data, err := os.read_entire_file_from_path(file, context.temp_allocator)
		if err == nil && len(data) > 0 { text = data; break }
		if time.tick_since(begun) > RESTART_BOUND { break }
		time.sleep(20 * time.Millisecond)
	}
	if !testing.expect(t, text != nil, "the program started again") { return }
	parts := strings.split(string(text), "\n", context.temp_allocator)
	testing.expect_value(t, parts[0], NO_CRASH)
	exe, _ := os.get_executable_path(context.temp_allocator)
	testing.expect_value(t, len(parts) > 1 ? parts[1] : "", exe)
}

// A window owes AFTER_INPUT frames after an event unless the program set its own count; host_settle owes them too.
@(test)
a_window_settles_after_a_change :: proc(t: ^testing.T) {
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	if !host.host_open(h, &sh, {title = "host test", size = SIZE, headless = true}, probe_build, nil) {
		testing.fail_now(t, "no renderer (WARP)")
	}
	defer host.host_close(h)
	testing.expect_value(t, h.after_input, host.AFTER_INPUT)
	h.settle = 0
	host.host_settle(h)
	testing.expect_value(t, h.settle, host.AFTER_INPUT)

	other := new(host.Host)
	defer free(other)
	other.after_input = 5   // (a program's own count, set before the open)
	if !host.host_open(other, &sh, {title = "host test 2", size = SIZE, headless = true}, probe_build, nil) {
		testing.fail_now(t, "no second window")
	}
	defer host.host_close(other)
	testing.expect_value(t, other.after_input, 5)
}
