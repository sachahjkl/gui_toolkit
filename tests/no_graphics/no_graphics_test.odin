#+build linux
// A machine with no graphics driver (src/md/infrastructure/no-graphics.md): a program that opens its window there says why
// and ends with its own exit code; it does not abort, and gt:crash records no crash. The program is this test program
// itself, started again with GT_NO_GRAPHICS_CHILD set, in a headless sway session (a real Wayland window) whose Vulkan
// loader is pointed at a driver list that does not exist: the state of a machine without Vulkan, whatever this one has.
//   odin run tools/run_tests -- no_graphics
package no_graphics_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import crash "gt:crash"
import host "gt:host"
import toolbox "gt:toolbox"

CHILD_ENV :: "GT_NO_GRAPHICS_CHILD"
DIR_ENV :: "GT_NO_GRAPHICS_DIR"
CHILD_LIMIT :: 60 * time.Second
// (the loader's two names for its driver list: VK_DRIVER_FILES now, VK_ICD_FILENAMES before 1.3.207)
NO_DRIVER :: "/nonexistent/no_graphics_test/icd.json"
EXIT_NO_WINDOW :: 1
EXIT_OPENED :: 3

////////////////////////////////
// The child: what a program's main does, with crash reports on.

@(init)
child :: proc "contextless" () {
	context = runtime.default_context()
	if _, is_child := os.lookup_env(CHILD_ENV, context.temp_allocator); !is_child { return }
	dir, _ := os.lookup_env(DIR_ENV, context.temp_allocator)
	crash.install({program = "no_graphics_test", report_dir = dir})
	crash.begin_session()
	sh: host.Shared
	h: host.Host
	opened := host.host_open(&h, &sh, {title = "no graphics", size = {320, 200}}, proc(h: ^host.Host, size: host.Vec2) {})
	if opened {
		host.host_close(&h)
		crash.end_session()
		os.exit(EXIT_OPENED)
	}
	fmt.printfln("open_error: %s", host.open_error(&h))
	crash.end_session()
	os.exit(EXIT_NO_WINDOW)
}

////////////////////////////////
// The test

@(test)
no_driver_ends_with_a_sentence_not_a_crash :: proc(t: ^testing.T) {
	state, out, ok := run_child(t, "none", {"VK_DRIVER_FILES=" + NO_DRIVER, "VK_ICD_FILENAMES=" + NO_DRIVER, "VK_ADD_DRIVER_FILES="})
	if !ok { return }
	// exited, with the program's code: not killed by SIGABRT (wgpu-native's panic at wgpuInstanceCreateSurface)
	testing.expectf(t, state.exited && state.exit_code == EXIT_NO_WINDOW, "the child exits with %d: %v\n%s", EXIT_NO_WINDOW, state, out)
	testing.expectf(t, !strings.contains(out, "panicked"), "no panic:\n%s", out)
	// the sentence, on standard error (as "<program>: ...") and from open_error, with the driver's words and what to do
	sentence := "no graphics device this program can draw with (Vulkan): vulkan drivers/libraries could not be loaded. Install your system's Vulkan driver"
	testing.expectf(t, strings.contains(out, fmt.tprintf("open_error: %s", sentence)), "open_error says why:\n%s", out)
	testing.expectf(t, strings.count(out, sentence) == 2, "standard error says it once too:\n%s", out)
}

// The other side of the order the fix changed (the adapter before the surface): with its driver, the same program opens
// its window.
@(test)
a_driver_opens_the_window :: proc(t: ^testing.T) {
	state, out, ok := run_child(t, "with", nil)
	if !ok { return }
	testing.expectf(t, state.exited && state.exit_code == EXIT_OPENED, "the child opens its window (exit %d): %v\n%s", EXIT_OPENED, state, out)
}

// The child in a sway session of its own, with `env` over the session's. Also checks the end was clean for gt:crash: the
// session file became clean-end.txt, and no report (crash, unclean) was written. ok: the child ran.
@(private = "file")
run_child :: proc(t: ^testing.T, what: string, env: []string) -> (state: os.Process_State, out: string, ok: bool) {
	// (short: sway's sockets are in it, and a socket's path holds 107 bytes)
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.tprintf("%s/gt-gfx-%s-%d", tmp, what, os.get_pid())
	defer os.remove_all(dir)
	reports := fmt.tprintf("%s/reports", dir)
	testing.expect(t, os.make_directory_all(reports) == nil)
	s: toolbox.Sway
	defer toolbox.sway_stop(&s)
	// (expect and return, not fail_now: fail_now skips the deferred stop)
	if why := toolbox.sway_start(&s, fmt.tprintf("%s/s", dir)); why != "" { testing.expect(t, false, why); return }
	log := fmt.tprintf("%s/child.log", dir)
	all := make([dynamic]string, context.temp_allocator)
	append(&all, fmt.tprintf("%s=1", CHILD_ENV), fmt.tprintf("%s=%s", DIR_ENV, reports))
	append(&all, ..env)
	p, why := toolbox.sway_program(&s, {os.args[0]}, all[:], log)
	if why != "" { testing.expect(t, false, why); return }
	ended: bool
	state, ended = toolbox.sway_wait(&s, p, CHILD_LIMIT)
	testing.expect(t, ended, "the child ends")
	data, _ := os.read_entire_file(log, context.temp_allocator)
	out = string(data)
	entries, _ := os.read_all_directory_by_path(reports, context.temp_allocator)
	clean := false
	for e in entries {
		if e.name == "clean-end.txt" { clean = true; continue }
		testing.expectf(t, false, "no report: %s\n%s", e.name, out)
	}
	testing.expectf(t, clean, "the session ended cleanly\n%s", out)
	return state, out, true
}
