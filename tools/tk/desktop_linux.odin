#+build linux
package tk

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import toolbox "../../src/toolbox"

// desktop_tests [x11|randr|wayland]: the Linux backends against real servers, on a virtual desktop nobody sees (tests/linux_desktop):
// under Xvfb with a window manager (x11), under Xorg's dummy driver with two monitors of 60 and 144 Hz (randr), then under a
// headless Wayland compositor (wayland). Never on a person's desktop: DISPLAY and WAYLAND_DISPLAY are the command's own, and so are
// XDG_RUNTIME_DIR, the session bus (none) and xdg-open (tests/linux_desktop/xdg_open). Needs Xvfb, openbox, xdotool, xclip, xprop,
// xwininfo, xrandr, Xorg with its dummy driver, sway, wl-clipboard, wtype, and the libraries of the Linux backend.
// XORG: how to start Xorg (default Xorg); XORG_MODULES: more module folders for it. GUI_TEST_NAMES: only these tests.
//
// Every program started here (a server, the test program) runs in a process group of its own (setsid), and is stopped with
// all of that group: a server may be a wrapper (NixOS's sway is dbus-run-session, which starts sway and a session bus
// beside it), and a signal to the wrapper alone leaves the compositor and the bus running. What they print goes to files in
// <out>, never to tk's own output: a process left behind would hold it open. The test program's log is printed when it ends.
// A signal that ends tk (timeout's SIGTERM, Ctrl+C, a closed terminal) stops the groups first (toolbox.guard_groups). The
// Wayland desktop is the toolbox's sway session (toolbox.sway_start), its socket and IPC given to the programs started here.

@(private = "file")
Desk :: struct {
	root, out: string,
	env:       [dynamic]string,   // KEY=VALUE: what every program started here gets
	servers:   [dynamic]os.Process,   // each the leader of its process group
}

// A program in a process group of its own (toolbox.start_group), its output in `out`.
@(private = "file")
start_group :: proc(d: ^Desk, out: ^os.File, command: ..string) -> (p: os.Process, err: os.Error) {
	return toolbox.start_group(command, d.env[:], out)
}

@(private = "file")
env_set :: proc(d: ^Desk, key, value: string) {
	env_unset(d, key)
	append(&d.env, fmt.tprintf("%s=%s", key, value))
}

@(private = "file")
env_unset :: proc(d: ^Desk, key: string) {
	for i := len(d.env) - 1; i >= 0; i -= 1 { if strings.has_prefix(d.env[i], fmt.tprintf("%s=", key)) { ordered_remove(&d.env, i) } }
}

// A program left running (a server, a window manager) in a group of its own, its output in <out>/<log>.
@(private = "file")
start :: proc(d: ^Desk, log: string, command: ..string) -> bool {
	f, err := os.create(join({d.out, log}))
	if err != nil { return false }
	p, perr := start_group(d, f, ..command)
	os.close(f)
	if perr != nil { fmt.printfln("desktop: %s does not start", command[0]); return false }
	append(&d.servers, p)
	return true
}

@(private = "file")
stop_all :: proc(d: ^Desk) {
	for p in d.servers { toolbox.stop_group(p) }
	clear(&d.servers)
}

// Runs a program to its end in a group of its own, at most `limit`, its output in <out>/<log>; then stops what it left
// running in its group (a test's own servers and peers).
@(private = "file")
run_env :: proc(d: ^Desk, limit: time.Duration, log: string, command: ..string) -> bool {
	f, ferr := os.create(join({d.out, log}))
	if ferr != nil { return false }
	p, err := start_group(d, f, ..command)
	os.close(f)
	if err != nil { return false }
	st, werr := os.process_wait(p, limit)
	if werr == nil { toolbox.group_ended(p) } else { toolbox.stop_group(p) }
	if werr != nil { fmt.printfln("desktop: %s took more than %v", command[0], limit); return false }
	return st.exited && st.exit_code == 0
}

// Waits until `command` succeeds (a server answers), at most `tries` times 100 ms.
@(private = "file")
until :: proc(d: ^Desk, tries: int, command: ..string) -> bool {
	for _ in 0 ..< tries {
		st, _, _, err := os.process_exec({command = command, env = d.env[:]}, context.temp_allocator)
		if err == nil && st.exited && st.exit_code == 0 { return true }
		time.sleep(100 * time.Millisecond)
	}
	return false
}

@(private = "file")
desktop_run :: proc(d: ^Desk, name: string, limit: time.Duration) -> bool {
	log := fmt.tprintf("desktop_test_%s.log", name)
	ok := run_env(d, limit, log, join({d.out, "desktop_test"}))
	if data, err := os.read_entire_file(join({d.out, log}), context.temp_allocator); err == nil { fmt.print(string(data)) }
	fmt.printfln("desktop %s %s", ok ? "ok  " : "FAIL", name)
	return ok
}

XORG_DUMMY_CONF :: `Section "ServerFlags"
  Option "AutoAddDevices" "false"
  Option "AutoEnableDevices" "false"
EndSection
Section "Device"
  Identifier "dummy"
  Driver "dummy"
  VideoRam 128000
EndSection
Section "Monitor"
  Identifier "mon"
  HorizSync 5-1000
  VertRefresh 20-400
  Modeline "m60"  74.25 1280 1390 1430 1650 720 725 730 750
  Modeline "m144" 178.2 1280 1390 1430 1650 720 725 730 750
EndSection
Section "Screen"
  Identifier "s"
  Device "dummy"
  Monitor "mon"
  DefaultDepth 24
  SubSection "Display"
    Depth 24
    Virtual 2560 720
    Modes "m60"
  EndSubSection
EndSection
`

// (what sway_start's config does not say: the output's mode is its Sway_Options.output)
SWAY_CONF :: "focus_on_window_activation focus\ndefault_border none\n"

run_desktop_tests :: proc(args: []string) -> string {
	only := len(toolbox.plain_args(args)) > 0 ? toolbox.plain_args(args)[0] : ""
	if only != "" && only != "x11" && only != "randr" && only != "wayland" { return "x11, randr or wayland" }
	toolbox.guard_groups()
	d := Desk{root = toolkit_root()}
	d.out = fmt.tprintf("%s/gt_desktop_%d", os.get_env("TMPDIR", context.temp_allocator) != "" ? os.get_env("TMPDIR", context.temp_allocator) : "/tmp", os.get_pid())
	bin, run_dir := join({d.out, "bin"}), join({d.out, "run"})
	if os.make_directory_all(bin) != nil || os.make_directory_all(run_dir) != nil { return fmt.tprintf("%s cannot be made", d.out) }
	defer os.remove_all(d.out)
	_ = os.chmod(run_dir, {.Read_User, .Write_User, .Execute_User})
	environ, _ := os.environ(context.temp_allocator)
	d.env = make([dynamic]string, context.temp_allocator)
	append(&d.env, ..environ)
	env_set(&d, "PATH", fmt.tprintf("%s:%s", bin, os.get_env("PATH", context.temp_allocator)))
	env_unset(&d, "DBUS_SESSION_BUS_ADDRESS")   // (no session bus of a person: open_url must come to the xdg-open here)
	env_set(&d, "XDG_RUNTIME_DIR", run_dir)
	sway: toolbox.Sway
	defer toolbox.sway_stop(&sway)   // (deferred before stop_all: it runs after it, the programs in the session stopped first)
	defer stop_all(&d)

	tests := join({d.root, "tests", "linux_desktop"})
	if !toolbox.run({"odin", "build", join({tests, "virtual_pointer"}), "-vet", fmt.tprintf("-out:%s", join({bin, "virtual_pointer"}))}) { return "building virtual_pointer failed" }
	if !toolbox.run({"odin", "build", join({tests, "drag_peer"}), "-vet", fmt.tprintf("-out:%s", join({bin, "drag_peer"}))}) { return "building drag_peer failed" }
	if !toolbox.run({"odin", "build", join({tests, "xdg_open"}), "-vet", fmt.tprintf("-out:%s", join({bin, "xdg-open"}))}) { return "building xdg_open failed" }
	// (a host with its renderer is tested too: the native text library, linked as the examples are)
	if why := build_rust_lib(d.root, TEXT_LIB, false); why != "" { return why }
	test_cmd := make([dynamic]string, context.temp_allocator)
	append(&test_cmd, "odin", "build", tests, "-build-mode:test", "-vet", "-define:ODIN_TEST_THREADS=1", "-debug", fmt.tprintf("-out:%s", join({d.out, "desktop_test"})))
	append(&test_cmd, toolbox.LINUX_LINK_FLAG)
	if names := os.get_env("GUI_TEST_NAMES", context.temp_allocator); names != "" { append(&test_cmd, fmt.tprintf("-define:ODIN_TEST_NAMES=%s", names)) }
	if !toolbox.run(test_cmd[:]) { return "building tests/linux_desktop failed" }

	failed := make([dynamic]string, context.temp_allocator)
	if only == "" || only == "x11" {
		// X11: a server with RandR and XFIXES, a window manager (frames, minimize, _NET_WM_STATE)
		env_unset(&d, "WAYLAND_DISPLAY")
		env_set(&d, "DISPLAY", ":97")
		ok := start(&d, "xvfb.log", "Xvfb", ":97", "-screen", "0", "1280x1024x24", "+extension", "RANDR", "+extension", "XFIXES", "-nolisten", "tcp")
		ok = ok && until(&d, 50, "xprop", "-root")
		ok = ok && start(&d, "openbox.log", "openbox")
		for _ in 0 ..< 100 {   // (the window manager is there when the root says which window it checks with)
			st, out, _, err := os.process_exec({command = {"xprop", "-root", "_NET_SUPPORTING_WM_CHECK"}, env = d.env[:]}, context.temp_allocator)
			if err == nil && st.exit_code == 0 && strings.contains(string(out), "window id") { break }
			time.sleep(100 * time.Millisecond)
		}
		env_set(&d, "GUI_TEST_DESKTOP", "x11")
		if !ok || !desktop_run(&d, "x11", 240 * time.Second) { append(&failed, "x11") }
		stop_all(&d)
	}
	if only == "" || only == "randr" {
		// RandR: Xvfb's only mode has no timing. Xorg's dummy driver has outputs and modelines: two monitors, 60 and 144 Hz
		env_unset(&d, "WAYLAND_DISPLAY")
		env_set(&d, "DISPLAY", ":96")
		conf := join({d.out, "xorg.conf"})
		if os.write_entire_file(conf, XORG_DUMMY_CONF) != nil { return "xorg.conf cannot be written" }
		xorg := os.get_env("XORG", context.temp_allocator)
		cmd := make([dynamic]string, context.temp_allocator)
		// (XORG may be a command line: "sudo /usr/lib/xorg/Xorg")
		append(&cmd, ..strings.fields(xorg != "" ? xorg : "Xorg", context.temp_allocator))
		append(&cmd, ":96", "-config", conf)
		if m := os.get_env("XORG_MODULES", context.temp_allocator); m != "" { append(&cmd, "-modulepath", m) }
		append(&cmd, "-ac", "-noreset", "-logfile", join({d.out, "xorg.log"}), "-nolisten", "tcp")
		ok := start(&d, "xorg.out", ..cmd[:]) && until(&d, 100, "xprop", "-root")
		ok = ok && run_env(&d, 10 * time.Second, "xrandr.log", "xrandr", "--addmode", "DUMMY1", "m60")
		ok = ok && run_env(&d, 10 * time.Second, "xrandr.log", "xrandr", "--addmode", "DUMMY1", "m144")
		ok = ok && run_env(&d, 10 * time.Second, "xrandr.log", "xrandr", "--output", "DUMMY0", "--mode", "m60", "--pos", "0x0", "--output", "DUMMY1", "--mode", "m144", "--pos", "1280x0")
		env_set(&d, "GUI_TEST_RANDR", "1")
		env_set(&d, "GUI_TEST_DESKTOP", "")
		if !ok || !desktop_run(&d, "randr", 60 * time.Second) {
			append(&failed, "randr")
			if log, err := os.read_entire_file(join({d.out, "xorg.log"}), context.temp_allocator); err == nil { fmt.println(last_lines(string(log), 5)) }
		}
		env_unset(&d, "GUI_TEST_RANDR")
		stop_all(&d)
		if xorg != "" { _ = toolbox.run({"sudo", "-n", "pkill", "-f", "Xorg :96"}) }   // (an Xorg started through sudo is not this one's to stop)
	}
	if only == "" || only == "wayland" {
		// Wayland: sway on no hardware (the toolbox's session). Its virtual output and seat take the test's cursor; wtype is a
		// virtual keyboard
		env_unset(&d, "DISPLAY")
		why := toolbox.sway_start(&sway, join({d.out, "sway"}), {output = "1280x1024@60Hz", config = SWAY_CONF})
		if why != "" { fmt.printfln("desktop: %s", why) }
		ok := why == ""
		env_set(&d, "XDG_RUNTIME_DIR", sway.runtime)
		env_set(&d, "WAYLAND_DISPLAY", sway.display)
		env_set(&d, "SWAYSOCK", sway.ipc)
		// the seat's devices: a pointer the tests move with swaymsg, a keyboard (wtype sleeping); a device stays while its client
		// does (a test takes the pointer away and makes it again: the file says which one to stop)
		pid_file := join({d.out, "pointer.pid"})
		env_set(&d, "GUI_TEST_POINTER_PID", pid_file)
		pointer_ok := start(&d, "pointer.log", join({bin, "virtual_pointer"}))
		if pointer_ok { _ = os.write_entire_file(pid_file, fmt.tprint(d.servers[len(d.servers) - 1].pid)) }
		ok = ok && pointer_ok && start(&d, "wtype.log", "wtype", "-s", "3600000")
		time.sleep(500 * time.Millisecond)
		env_set(&d, "GUI_TEST_DESKTOP", "wayland")
		if !ok || !desktop_run(&d, "wayland", 240 * time.Second) {
			append(&failed, "wayland")
			if log, err := os.read_entire_file(join({d.out, "sway", "sway.log"}), context.temp_allocator); err == nil { fmt.println(last_lines(string(log), 20)) }
		}
		// (a test may have stopped the pointer and made another: the file names the one that runs)
		if data, err := os.read_entire_file(pid_file, context.temp_allocator); err == nil {
			_ = toolbox.run({"kill", strings.trim_space(string(data))})
		}
	}
	if len(failed) > 0 { return fmt.tprintf("failed: %s", strings.join(failed[:], ", ", context.temp_allocator)) }
	return ""
}

@(private = "file")
last_lines :: proc(text: string, n: int) -> string {
	lines := strings.split_lines(strings.trim_right(text, "\n"), context.temp_allocator)
	return strings.join(lines[max(0, len(lines) - n):], "\n", context.temp_allocator)
}
