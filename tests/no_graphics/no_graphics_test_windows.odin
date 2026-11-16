#+build windows
// A machine with no graphics driver, on Windows (src/md/infrastructure/no-graphics.md), forced with render's faults:
//   - a window whose hardware Direct3D 11 device is refused draws with WARP;
//   - a program with no device at all says why: a message box when standard error goes nowhere (a program built with
//     -subsystem:windows, started from the desktop), none when it has one (a console, a test runner).
// The program of the second test is this test program, started again with GT_NO_GRAPHICS_WINDOWS_CHILD set.
//   odin run tools/run_tests -- no_graphics
package no_graphics_test

@(require) import "base:runtime"
@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:strings"
@(require) import win "core:sys/windows"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import host "gt:host"
@(require) import "gt:platform"
@(require) import "gt:render"

when render.RENDER_FAULTS && !render.USE_WGPU {

WINDOWS_CHILD_ENV :: "GT_NO_GRAPHICS_WINDOWS_CHILD"
BOX_TITLE :: "no graphics box"
WINDOWS_CHILD_LIMIT :: 60 * time.Second
WINDOWS_EXIT_NO_WINDOW :: 1
WINDOWS_EXIT_OPENED :: 3

// The child: both devices refused (the hardware's, then WARP's), then what a program's main does.
@(init)
windows_child :: proc "contextless" () {
	context = runtime.default_context()
	if _, is_child := os.lookup_env(WINDOWS_CHILD_ENV, context.temp_allocator); !is_child { return }
	render.fault_arm(.D3D_Device, 0, 2)
	sh: host.Shared
	h: host.Host
	if host.host_open(&h, &sh, {title = BOX_TITLE, size = {320, 200}}, proc(h: ^host.Host, size: host.Vec2) {}) {
		host.host_close(&h)
		os.exit(WINDOWS_EXIT_OPENED)
	}
	fmt.printfln("open_error: %s", host.open_error(&h))
	os.exit(WINDOWS_EXIT_NO_WINDOW)
}

// No hardware device: the window's renderer falls back to WARP, and draws.
@(test)
no_hardware_device_draws_with_warp :: proc(t: ^testing.T) {
	w := platform.open_window("no hardware device", {200, 150})
	if !testing.expect(t, w != nil, "the window opens") { return }
	defer platform.destroy_window(w)
	r: render.Renderer
	render.fault_arm(.D3D_Device)
	ok := render.init_window(&r, w, w.size)
	fired := render.fault_fired(.D3D_Device)
	render.fault_arm(.D3D_Device, 0, 0)
	if !testing.expect(t, ok, "the renderer starts") { return }
	defer render.destroy(&r)
	testing.expect_value(t, fired, 1)
	testing.expect(t, render.adapter_info(&r).software, "on WARP")
	render.frame_begin(&r, {1, 0, 0, 1})
	render.frame_end(&r)
}

// No device at all, standard error to a file: the sentence is written there, no box holds the program, and it ends
// with its own code.
@(test)
no_device_with_standard_error_shows_no_box :: proc(t: ^testing.T) {
	// (the pipe is read once the child has ended or been stopped, so a child held by a box holds no read; what it writes,
	// two short lines, fits in the pipe's buffer without blocking it)
	r, w, perr := os.pipe()
	if !testing.expect(t, perr == nil, "a pipe") { return }
	env := make([dynamic]string, context.temp_allocator)
	if all, err := os.environ(context.temp_allocator); err == nil { append(&env, ..all) }
	append(&env, fmt.tprintf("%s=1", WINDOWS_CHILD_ENV))
	p, err := os.process_start({command = {os.args[0]}, env = env[:], stdout = w, stderr = w})
	os.close(w)
	if !testing.expect(t, err == nil, "the child starts") { os.close(r); return }
	state, werr := os.process_wait(p, WINDOWS_CHILD_LIMIT)
	if werr != nil { _ = os.process_kill(p) }
	out, _ := os.read_entire_file(r, context.temp_allocator)
	os.close(r)
	testing.expectf(t, werr == nil && state.exited && state.exit_code == WINDOWS_EXIT_NO_WINDOW, "the child ends with %d, no box held it: %v\n%s", WINDOWS_EXIT_NO_WINDOW, state, string(out))
	testing.expectf(t, strings.contains(string(out), "Direct3D 11 gives no device"), "the sentence on standard error:\n%s", string(out))
}

// No device at all, no standard error (a -subsystem:windows program from the desktop): a message box says why; closed,
// the program ends with its own code.
@(test)
no_device_without_standard_error_shows_a_box :: proc(t: ^testing.T) {
	// (the environment block of CreateProcessW: this process's, with the child's mark)
	env := strings.builder_make(context.temp_allocator)
	if all, err := os.environ(context.temp_allocator); err == nil {
		for e in all { strings.write_string(&env, e); strings.write_byte(&env, 0) }
	}
	strings.write_string(&env, WINDOWS_CHILD_ENV + "=1")
	strings.write_byte(&env, 0)
	strings.write_byte(&env, 0)
	block := win.utf8_to_utf16(strings.to_string(env), context.temp_allocator)
	cmd := win.utf8_to_wstring(fmt.tprintf("\"%s\"", os.args[0]), context.temp_allocator)
	// (no console and no standard handles: GetStdHandle gives the child nothing, as to a -subsystem:windows program)
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESTDHANDLES}
	pi: win.PROCESS_INFORMATION
	if !testing.expect(t, bool(win.CreateProcessW(nil, cmd, nil, nil, false, win.DETACHED_PROCESS | win.CREATE_UNICODE_ENVIRONMENT, raw_data(block), nil, &si, &pi)), "the child starts") { return }
	defer win.CloseHandle(pi.hProcess)
	defer win.CloseHandle(pi.hThread)
	box := find_box(pi.dwProcessId, WINDOWS_CHILD_LIMIT)
	testing.expect(t, box != nil, "a message box says why")
	if box != nil { win.PostMessageW(box, win.WM_CLOSE, 0, 0) }
	if win.WaitForSingleObject(pi.hProcess, u32(time.duration_milliseconds(WINDOWS_CHILD_LIMIT))) != win.WAIT_OBJECT_0 {
		win.TerminateProcess(pi.hProcess, 99)
		testing.expect(t, false, "the child ends once its box is closed")
		return
	}
	code: win.DWORD
	win.GetExitCodeProcess(pi.hProcess, &code)
	testing.expect_value(t, int(code), WINDOWS_EXIT_NO_WINDOW)
}

// A dialog box (class #32770) of process `pid`, waited for until `limit`.
@(private = "file")
find_box :: proc(pid: win.DWORD, limit: time.Duration) -> win.HWND {
	Search :: struct { pid: win.DWORD, found: win.HWND }
	start := time.tick_now()
	for time.tick_since(start) < limit {
		s := Search{pid = pid}
		win.EnumWindows(proc "system" (hwnd: win.HWND, data: win.LPARAM) -> win.BOOL {
			s := (^Search)(rawptr(uintptr(data)))
			owner: win.DWORD
			win.GetWindowThreadProcessId(hwnd, &owner)
			if owner != s.pid { return true }
			class: [16]u16
			n := win.GetClassNameW(hwnd, &class[0], len(class))
			if n == 6 && class[0] == '#' && class[1] == '3' && class[2] == '2' && class[3] == '7' && class[4] == '7' && class[5] == '0' {
				s.found = hwnd
				return false
			}
			return true
		}, win.LPARAM(uintptr(&s)))
		if s.found != nil { return s.found }
		// (a bounded wait for a condition: the box shows once the child failed its devices)
		time.sleep(50 * time.Millisecond)
	}
	return nil
}

}   // when render.RENDER_FAULTS && !render.USE_WGPU
