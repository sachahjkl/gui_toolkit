#+build linux
// A machine with no graphics driver (src/md/infrastructure/no-graphics.md): a program that opens its window there says why
// and ends with its own exit code; it does not abort, and gt:crash records no crash. The program is this test program
// itself, started again with GT_NO_GRAPHICS_CHILD set, in a headless sway session (a real Wayland window) whose Vulkan
// loader is pointed at a driver list that does not exist: the state of a machine without Vulkan, whatever this one has.
// Without Vulkan the window draws with OpenGL (the GL fallback); with libglvnd's EGL pointed at no vendor as well, it
// has no device at all.
//   odin run tools/run_tests -- no_graphics
package no_graphics_test

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import crash "gt:crash"
import host "gt:host"
import "gt:platform"
import "gt:render"
import toolbox "gt:toolbox"

CHILD_ENV :: "GT_NO_GRAPHICS_CHILD"
DIR_ENV :: "GT_NO_GRAPHICS_DIR"
CHILD_LIMIT :: 60 * time.Second
// (the loader's two names for its driver list: VK_DRIVER_FILES now, VK_ICD_FILENAMES before 1.3.207)
NO_DRIVER :: "/nonexistent/no_graphics_test/icd.json"
// (libglvnd's EGL then finds no vendor library: wgpu's GL backend has no display, the state of a machine without OpenGL)
NO_EGL :: "/nonexistent/no_graphics_test/egl_vendor.d"
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
		// what draws, and a frame of its own read back (on GL the surface cannot be copied from: the capture reads the
		// target the frame was composed into)
		fmt.printfln("api: %s", render.adapter_info(&sh.r).api)
		h.background = {1, 0, 0, 1}
		host.host_show(&h)
		_ = render.capture_request(&sh.r)
		status := render.Capture_Status.Pending
		pixels: []u8
		// (a bounded wait for the copy: frames, then polls, never a fixed delay)
		for i := 0; i < 200 && status == .Pending; i += 1 {
			h.settle = max(h.settle, 1)
			host.host_frame(&h)
			_ = platform.poll_events(h.win, true, 10)
			pixels, _, status = render.capture_poll(&sh.r)
		}
		red := len(pixels) >= 4 && pixels[0] > 200 && pixels[1] < 50 && pixels[2] < 50
		fmt.printfln("capture: %v, %s %v", status, red ? "red" : "not red", len(pixels) >= 4 ? pixels[:4] : nil)
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

// No Vulkan and no OpenGL (the GL fallback finds no EGL vendor either): the sentence names Vulkan, the driver to install.
@(test)
no_driver_ends_with_a_sentence_not_a_crash :: proc(t: ^testing.T) {
	env := [?]string{
		"VK_DRIVER_FILES=" + NO_DRIVER, "VK_ICD_FILENAMES=" + NO_DRIVER, "VK_ADD_DRIVER_FILES=",
		"__EGL_VENDOR_LIBRARY_FILENAMES=" + NO_EGL + "/none.json", "__EGL_VENDOR_LIBRARY_DIRS=" + NO_EGL,
	}
	state, out, ok := run_child(t, "none", env[:])
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
	// (never GL when Vulkan works)
	testing.expectf(t, !strings.contains(out, "api: OpenGL"), "Vulkan draws:\n%s", out)
}

// No Vulkan driver, OpenGL there (Mesa's EGL): the window opens on wgpu's GL backend, says so once on standard
// error, and draws a frame that a capture reads back. Where the system has no EGL, the log says the test drew nothing.
@(test)
no_vulkan_draws_with_opengl_es :: proc(t: ^testing.T) {
	env := [?]string{"VK_DRIVER_FILES=" + NO_DRIVER, "VK_ICD_FILENAMES=" + NO_DRIVER, "VK_ADD_DRIVER_FILES=", mesa_egl()}
	state, out, ok := run_child(t, "gl", env[:])
	if !ok { return }
	expect_gl_frame(t, state, out)
	testing.expectf(t, strings.contains(out, "drawing with OpenGL"), "standard error says what draws:\n%s", out)
}

// TOOLKIT_WGPU_BACKEND=gl: OpenGL though Vulkan is there.
@(test)
forced_gl_draws_with_opengl_es :: proc(t: ^testing.T) {
	env := [?]string{"TOOLKIT_WGPU_BACKEND=gl", mesa_egl()}
	state, out, ok := run_child(t, "forced", env[:])
	if !ok { return }
	expect_gl_frame(t, state, out)
}

// Mesa's EGL vendor alone for a GL child, where the dev shell names it (TOOLKIT_TEST_MESA_EGL, flake.nix): the fallback
// a machine without Vulkan takes runs on Mesa. (NVIDIA's EGL, glvnd's first choice on a machine with that card, gives wgpu
// a GLSL 330 context, which it refuses.) Without it, a variable nobody reads, and glvnd picks as it does.
@(private = "file")
mesa_egl :: proc() -> string {
	mesa := os.get_env("TOOLKIT_TEST_MESA_EGL", context.temp_allocator)
	if mesa == "" { return "GT_NO_MESA_EGL=1" }
	return fmt.tprintf("__EGL_VENDOR_LIBRARY_FILENAMES=%s", mesa)
}

// The child opened its window on OpenGL and captured its red frame; or the system has no EGL (logged, not a pass).
@(private = "file")
expect_gl_frame :: proc(t: ^testing.T, state: os.Process_State, out: string) {
	// (a GL adapter that exists and is refused, "OpenGL has ...", is a failure: only no EGL at all is a skip)
	if state.exited && state.exit_code == EXIT_NO_WINDOW && strings.contains(out, "no graphics device") && !strings.contains(out, "OpenGL has") {
		log.warnf("SKIPPED: no OpenGL on this system (EGL), the GL window was not drawn:\n%s", out)
		return
	}
	testing.expectf(t, state.exited && state.exit_code == EXIT_OPENED, "the child opens its window (exit %d): %v\n%s", EXIT_OPENED, state, out)
	testing.expectf(t, strings.contains(out, "api: OpenGL"), "on OpenGL:\n%s", out)
	testing.expectf(t, !strings.contains(out, "panicked"), "no panic:\n%s", out)
	testing.expectf(t, strings.contains(out, "capture: Ready, red"), "its red frame is presented and read back:\n%s", out)
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
