// The crash package: a report written and read back, and a real crash. The crashing program is this test program itself, started
// again with GT_CRASH_TEST_CHILD set: its @(init) does what the child must do (install, a session, a crash, a hang, a look at the
// last report) and ends before the test runner starts.
//   odin test tests/crash -vet
package crash_test

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import crash "../../src/crash"
import "../../src/testkit"
import toolbox "../../src/toolbox"

CHILD_ENV :: "GT_CRASH_TEST_CHILD"
DIR_ENV :: "GT_CRASH_TEST_DIR"
CHILD_PROGRAM :: "crash_test"
CHILD_VERSION :: "1.2.3"
CHILD_COMMIT :: "abc1234"
CHILD_LOG :: "line one\nline two\n"
CHILD_SETTINGS :: "theme = dark\n"
NO_REPORT :: "none"
CHILD_LIMIT :: 60 * time.Second

////////////////////////////////
// The child

@(init)
child :: proc "contextless" () {
	context = runtime.default_context()
	mode, is_child := os.lookup_env(CHILD_ENV, context.temp_allocator)
	if !is_child { return }
	dir, _ := os.lookup_env(DIR_ENV, context.temp_allocator)
	crash.install({
		program = CHILD_PROGRAM, version = CHILD_VERSION, commit = CHILD_COMMIT, report_dir = dir,
		log_tail = {child_log, nil}, settings = {child_settings, nil},
	})
	crash.begin_session()
	switch mode {
	case "crash":
		quiet_faults()
		parked: sync.Sema
		thread.run_with_poly_data(&parked, proc(s: ^sync.Sema) { sync.sema_wait(s) })   // a second thread, for its stack in the report
		intrinsics.volatile_store((^int)(uintptr(0)), 1)
	case "hang":
		forever: sync.Sema
		sync.sema_wait(&forever)
	case "last":
		path, ok := crash.last_report()
		fmt.print(ok ? path : NO_REPORT)
		crash.end_session()
	case "clean":
		crash.end_session()
	}
	os.exit(0)
}

// The child's Sources: constant text, as a program's snapshot would be.
child_log :: proc "contextless" (user: rawptr, buf: []u8) -> int { return copy(buf, CHILD_LOG) }
child_settings :: proc "contextless" (user: rawptr, buf: []u8) -> int { return copy(buf, CHILD_SETTINGS) }

// The child, its output and how it ended.
run_child :: proc(t: ^testing.T, mode, dir: string) -> (out: string, state: os.Process_State) {
	env := toolbox.env_with({CHILD_ENV, DIR_ENV}, fmt.tprintf("%s=%s", CHILD_ENV, mode), fmt.tprintf("%s=%s", DIR_ENV, dir))
	st, stdout, _, err := os.process_exec({command = {os.args[0]}, env = env}, context.temp_allocator)
	testing.expectf(t, err == nil, "the child (%s) runs: %v", mode, err)
	return string(stdout), st
}

// The reports of `prefix` in `dir`.
reports :: proc(dir, prefix: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for e in entries {
		n := e.name
		if strings.has_prefix(n, prefix) && len(n) > len(prefix) && n[len(prefix)] == '-' && strings.has_suffix(n, crash.REPORT_EXTENSION) { append(&out, e.fullpath) }
	}
	return out[:]
}

////////////////////////////////
// The format

sample :: proc() -> crash.Report {
	context.allocator = context.temp_allocator
	r := crash.Report{
		format = crash.FORMAT_VERSION, program = "fidget", version = "0.51.0", commit = "1a2b3c4", build = "9f86d081884c7d65",
		system = "linux amd64", date = "2026-11-13T17:03:00Z", pid = 4242, kind = crash.KIND_SIGNAL, code = "SIGSEGV",
		reason = "segmentation fault (an invalid memory access)", address = 0, pc = 0x55D0C0DE1234, thread = 4242, complete = true,
	}
	append(&r.extra, crash.Field{"channel", "dev"})
	main_frames := make([dynamic]crash.Frame, context.temp_allocator)
	append(&main_frames, crash.Frame{0x55D0C0DE1234, "fidget", 0x1234, ""}, crash.Frame{0x7F0012345678, "libc.so.6", 0x2A678, "abort+0x8F"})
	other := make([dynamic]crash.Frame, context.temp_allocator)
	append(&other, crash.Frame{0x7F0012340000, "libc.so.6", 0x25000, "futex_wait+0x10"})
	append(&r.threads, crash.Thread{id = 4242, name = "fidget", crashed = true, frames = main_frames}, crash.Thread{id = 4243, name = "store", frames = other})
	append(&r.modules, crash.Module{0x55D0C0DE0000, 0x5000, "fidget", "/home/me/fidget"}, crash.Module{0x7F0012300000, 0x200000, "libc.so.6", "/nix/store/x-glibc/lib/libc.so.6"})
	append(&r.log, "2026-11-13T17:02:59.120Z INFO  opened /home/me/a.txt", "[not a section] a line of the log")
	append(&r.settings, "theme = dark")
	return r
}

@(test)
a_report_reads_back_as_it_was_written :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator   // (what the reports and the children's output hold: freed with the test)
	r := sample()
	text := crash.report_text(r, context.temp_allocator)
	got, ok := crash.report_parse(text, context.temp_allocator)
	testing.expect(t, ok, text)
	testing.expect_value(t, got.format, r.format)
	testing.expect_value(t, got.program, r.program)
	testing.expect_value(t, got.version, r.version)
	testing.expect_value(t, got.commit, r.commit)
	testing.expect_value(t, got.build, r.build)
	testing.expect_value(t, got.system, r.system)
	testing.expect_value(t, got.date, r.date)
	testing.expect_value(t, got.pid, r.pid)
	testing.expect_value(t, got.kind, r.kind)
	testing.expect_value(t, got.code, r.code)
	testing.expect_value(t, got.reason, r.reason)
	testing.expect_value(t, got.address, r.address)
	testing.expect_value(t, got.pc, r.pc)
	testing.expect_value(t, got.thread, r.thread)
	testing.expect_value(t, got.complete, true)
	testing.expect_value(t, len(got.extra), 1)
	if len(got.extra) == 1 { testing.expect_value(t, got.extra[0], r.extra[0]) }
	testing.expect_value(t, len(got.threads), len(r.threads))
	for i in 0 ..< min(len(got.threads), len(r.threads)) {
		a, b := got.threads[i], r.threads[i]
		testing.expect_value(t, a.id, b.id)
		testing.expect_value(t, a.name, b.name)
		testing.expect_value(t, a.crashed, b.crashed)
		testing.expect_value(t, len(a.frames), len(b.frames))
		for k in 0 ..< min(len(a.frames), len(b.frames)) { testing.expect_value(t, a.frames[k], b.frames[k]) }
	}
	testing.expect(t, slice_equal(got.modules[:], r.modules[:]), "the modules")
	testing.expect(t, slice_equal(got.log[:], r.log[:]), "the log, a line like a section's head too")
	testing.expect(t, slice_equal(got.settings[:], r.settings[:]), "the settings")
	// written again, the same text
	testing.expect_value(t, crash.report_text(got, context.temp_allocator), text)
}

// A report parsed into the heap is freed whole (the test's allocator says a leak), and the default folder is the program's state.
@(test)
a_report_is_freed_and_has_a_default_folder :: proc(t: ^testing.T) {
	text := crash.report_text(sample(), context.temp_allocator)
	r, ok := crash.report_parse(text)
	testing.expect(t, ok)
	crash.report_destroy(&r)
	testing.expect_value(t, len(r.threads), 0)
	dir := crash.default_report_dir("gt_crash_test", context.temp_allocator)
	testing.expect(t, dir == "" || (strings.has_suffix(dir, "/crashes") && strings.contains(dir, "gt_crash_test")), dir)
}

slice_equal :: proc(a, b: []$T) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) { if a[i] != b[i] { return false } }
	return true
}

// What the handler writes after the stack: the names the system found go to the frames of their address that had none; a report
// cut short says so; a newer format keeps the keys it does not know; a text that is no report is refused.
@(test)
a_report_as_the_handler_writes_it :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator   // (what the reports and the children's output hold: freed with the test)
	text := "gt-crash-report: 2\nprogram: p\nnew-key: value\n\n[thread 7]\n  crashed: yes\n  #00\t0x1000\tp\t0x0\t?\n  #01\t0x2000\tlibc.so.6\t0x10\t?\n[symbols]\n  0x2000\tabort+0x10\n"
	r, ok := crash.report_parse(text, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, r.format, 2)
	testing.expect_value(t, r.program, "p")
	testing.expect(t, len(r.extra) == 1 && r.extra[0].key == "new-key" && r.extra[0].value == "value")
	testing.expect(t, !r.complete, "no [end]: cut short")
	if testing.expect_value(t, len(r.threads), 1) && testing.expect_value(t, len(r.threads[0].frames), 2) {
		testing.expect_value(t, r.threads[0].frames[0].symbol, "")
		testing.expect_value(t, r.threads[0].frames[1].symbol, "abort+0x10")
	}
	_, is_report := crash.report_parse("program: p\n", context.temp_allocator)
	testing.expect(t, !is_report)
}

////////////////////////////////
// Real crashes

// The single test of the design: a process that crashes leaves a report a program reads, with each thread's stack, the modules, the
// log and the settings; the next start learns of it once, and a clean end after that forgets it.
@(test)
a_crash_leaves_a_report :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "crash")
	context.allocator = context.temp_allocator   // (what the reports and the children's output hold: freed with the test)
	_, state := run_child(t, "crash", dir)
	testing.expect(t, !toolbox.succeeded(state), "the child died of its crash")
	found := reports(dir, crash.CRASH_PREFIX)
	if !testing.expectf(t, len(found) == 1, "one report in %s", dir) { return }
	data, _ := os.read_entire_file(found[0], context.temp_allocator)
	r, ok := crash.report_parse(string(data), context.temp_allocator)
	testing.expect(t, ok, string(data))
	testing.expect_value(t, r.program, CHILD_PROGRAM)
	testing.expect_value(t, r.version, CHILD_VERSION)
	testing.expect_value(t, r.commit, CHILD_COMMIT)
	testing.expect_value(t, r.kind, ODIN_OS == .Windows ? crash.KIND_EXCEPTION : crash.KIND_SIGNAL)
	testing.expect_value(t, r.code, ODIN_OS == .Windows ? "0xC0000005" : "SIGSEGV")
	testing.expect(t, r.complete, "written to its end")
	testing.expect(t, len(r.threads) >= 2, "the faulting thread and the parked one")
	exe := filepath.base(os.args[0])
	if len(r.threads) > 0 {
		testing.expect(t, r.threads[0].crashed && r.threads[0].id == r.thread, "the faulting thread first")
		testing.expect(t, len(r.threads[0].frames) > 0 && r.threads[0].frames[0].module == exe, "its stack starts in the program")
	}
	for th, i in r.threads { if i > 0 { testing.expectf(t, len(th.frames) > 0, "thread %d said its stack", th.id) } }
	has_exe := false
	for m in r.modules { if m.name == exe && m.base != 0 { has_exe = true } }
	testing.expect(t, has_exe, "the program among the modules")
	testing.expect(t, slice_equal(r.log[:], []string{"line one", "line two"}), "the log's last lines")
	testing.expect(t, slice_equal(r.settings[:], []string{"theme = dark"}), "the settings")
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", dir, crash.SESSION_FILE)), "the report closed the session")

	// the next start learns of it; once it ended cleanly, the next one does not
	out, _ := run_child(t, "last", dir)
	testing.expect_value(t, filepath.base(out), filepath.base(found[0]))
	out, _ = run_child(t, "last", dir)
	testing.expect_value(t, out, NO_REPORT)
}

// A session killed from outside leaves no report of its own: the next start writes one, "unclean", and gives it.
@(test)
a_killed_session_is_found_at_the_next_start :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "unclean")
	context.allocator = context.temp_allocator   // (what the reports and the children's output hold: freed with the test)
	env := toolbox.env_with({CHILD_ENV, DIR_ENV}, fmt.tprintf("%s=hang", CHILD_ENV), fmt.tprintf("%s=%s", DIR_ENV, dir))
	p, err := os.process_start({command = {os.args[0]}, env = env})
	if !testing.expect(t, err == nil) { return }
	session := fmt.tprintf("%s/%s", dir, crash.SESSION_FILE)
	testing.expect(t, testkit.await(&session, proc(s: ^string) -> bool { return os.exists(s^) }), "the session began")
	testing.expect(t, os.process_kill(p) == nil)
	_, _ = os.process_wait(p, CHILD_LIMIT)

	out, _ := run_child(t, "last", dir)
	found := reports(dir, crash.UNCLEAN_PREFIX)
	if !testing.expect_value(t, len(found), 1) { return }
	testing.expect_value(t, filepath.base(out), filepath.base(found[0]))
	data, _ := os.read_entire_file(found[0], context.temp_allocator)
	r, ok := crash.report_parse(string(data), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, r.kind, crash.KIND_UNCLEAN)
	testing.expect_value(t, r.program, CHILD_PROGRAM)
	testing.expect_value(t, r.pid, u64(p.pid))
}

// A session that ends cleanly leaves nothing to report.
@(test)
a_clean_session_leaves_no_report :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "clean")
	context.allocator = context.temp_allocator   // (what the reports and the children's output hold: freed with the test)
	_, state := run_child(t, "clean", dir)
	testing.expect(t, toolbox.succeeded(state))
	out, _ := run_child(t, "last", dir)
	testing.expect_value(t, out, NO_REPORT)
	testing.expect_value(t, len(reports(dir, crash.CRASH_PREFIX)) + len(reports(dir, crash.UNCLEAN_PREFIX)), 0)
}
