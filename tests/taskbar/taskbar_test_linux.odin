package taskbar_test

// Linux, end to end: a bus of the test's own (dbus-daemon with no service directory), a dock that listens to the launcher
// entry's Update signal on it, and an offscreen window (no display) that asked for its taskbar calls to go out as that
// signal (taskbar_offscreen_entry).

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "gt:dbus"
import "gt:platform"

@(private = "file") WAIT :: 3 * time.Second
@(private = "file") APP_ID :: "gt-taskbar-test"

@(private = "file")
BUS_CONFIG :: `<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=%s</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
`

@(private = "file")
Bus :: struct {
	dir, address: string,
	pid: posix.pid_t,
}

// A dbus-daemon of the test's own, with no service directory.
@(private = "file")
bus_start :: proc(t: ^testing.T) -> (b: Bus, ok: bool) {
	b.dir = fmt.aprintf("/tmp/gt-taskbar-test-%d", posix.getpid(), allocator = context.temp_allocator)
	os.make_directory(b.dir)
	socket := fmt.tprintf("%s/bus", b.dir)
	os.remove(socket)
	config := fmt.tprintf("%s/bus.conf", b.dir)
	if os.write_entire_file(config, fmt.tprintf(BUS_CONFIG, socket)) != nil { return }
	pidfile := fmt.tprintf("%s/pid", b.dir)
	cmd := fmt.tprintf("dbus-daemon --config-file=%s --fork --print-pid > %s", config, pidfile)
	if libc.system(strings.clone_to_cstring(cmd, context.temp_allocator)) != 0 {
		testing.fail_now(t, "dbus-daemon did not start (nix develop has it)")
	}
	text, err := os.read_entire_file(pidfile, context.temp_allocator)
	if err != nil { return }
	pid, parsed := strconv.parse_int(strings.trim_space(string(text)))
	if !parsed { return }
	b.pid = posix.pid_t(pid)
	b.address = fmt.tprintf("unix:path=%s", socket)
	return b, true
}

@(private = "file")
bus_stop :: proc(b: Bus) {
	if b.pid > 0 { posix.kill(b.pid, .SIGTERM) }
	os.remove_all(b.dir)
}

// What the dock heard: each Update, read as a dock reads it, with the path it came from.
@(private = "file")
Dock :: struct {
	heard: [dynamic]Entry,
	paths: [dynamic]string,
}

@(private = "file")
dock_heard :: proc(user: rawptr, msg: ^dbus.Message) {
	d := (^Dock)(user)
	e := read_entry(msg.body_bytes)
	e.uri = strings.clone(e.uri)
	append(&d.heard, e)
	append(&d.paths, strings.clone(msg.path))
}

// Pumps the dock's connection until it heard `n` signals in all, or for `limit`.
@(private = "file")
dock_wait :: proc(c: ^dbus.Conn, d: ^Dock, n: int, limit := WAIT) -> bool {
	start := time.tick_now()
	for len(d.heard) < n && time.tick_since(start) < limit {
		pfd := posix.pollfd{fd = posix.FD(dbus.conn_fd(c)), events = {.IN}}
		posix.poll(&pfd, 1, 10)
		dbus.dispatch(c)
	}
	return len(d.heard) >= n
}

@(test)
the_launcher_entry_reaches_a_dock_on_a_private_bus :: proc(t: ^testing.T) {
	b, ok := bus_start(t)
	if !testing.expect(t, ok, "a bus of the test's own") { return }
	defer bus_stop(b)
	// (before the first use of the session bus on this thread: the platform connects to this one)
	posix.setenv("DBUS_SESSION_BUS_ADDRESS", strings.clone_to_cstring(b.address, context.temp_allocator), true)
	defer posix.unsetenv("DBUS_SESSION_BUS_ADDRESS")
	platform.set_app_id(APP_ID)
	defer platform.set_app_id("")

	dock := dbus.connect_bus_address(b.address)
	if !testing.expect(t, dock != nil, "the dock's connection") { return }
	defer dbus.conn_close(dock)
	d: Dock
	defer {
		for e in d.heard { delete(e.uri) }
		for p in d.paths { delete(p) }
		delete(d.heard)
		delete(d.paths)
	}
	testing.expect(t, dbus.subscribe(dock, "", "", platform.LAUNCHER_ENTRY_INTERFACE, "Update", dock_heard, &d) != 0)
	// (a call answered after AddMatch: the bus handled the match before anything the window sends)
	_, pinged := dbus.call(dock, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId", "", nil, 2000)
	testing.expect(t, pinged)

	// an offscreen window that did not ask sends nothing: a program's tests stay out of the person's dock. (Signals of one
	// connection arrive in order: the first one heard is the next window's.)
	quiet := platform.open_window_offscreen("quiet", {200, 100})
	if !testing.expect(t, quiet != nil) { return }
	testing.expect(t, platform.taskbar_badge(quiet, 9), "the state is kept")
	testing.expect_value(t, platform.taskbar_state(quiet).count, 9)
	platform.destroy_window(quiet)

	w := platform.open_window_offscreen("taskbar", {200, 100})
	if !testing.expect(t, w != nil) { return }
	platform.taskbar_offscreen_entry(w, true)
	uri := platform.launcher_entry_uri(APP_ID)

	// a count: the dock reads it from the program's entry, at libunity's path
	testing.expect(t, platform.taskbar_badge(w, 3, "3 sessions are waiting for you"))
	if !testing.expect(t, dock_wait(dock, &d, 1), "the count's Update") { return }
	e := d.heard[0]
	testing.expect(t, e.ok)
	testing.expect_value(t, e.uri, uri)
	testing.expect_value(t, d.paths[0], platform.launcher_entry_path(uri))
	testing.expect(t, e.count == 3 && e.count_visible && !e.progress_visible && !e.urgent, "the quiet window's 9 never came")

	// the same count again sends nothing: the next signal heard is the progress's
	testing.expect(t, !platform.taskbar_badge(w, 3, "3 sessions are waiting for you"))
	testing.expect(t, platform.taskbar_progress(w, .Paused, 0.25))
	if !testing.expect(t, dock_wait(dock, &d, 2), "the progress's Update") { return }
	e = d.heard[1]
	testing.expect(t, e.count == 3 && e.count_visible, "the whole state in each signal")
	testing.expect(t, e.progress_visible && e.progress == 0.25)

	testing.expect(t, platform.taskbar_progress(w, .Indeterminate))
	if !testing.expect(t, dock_wait(dock, &d, 3)) { return }
	testing.expect(t, !d.heard[2].progress_visible, "no bar for a progress with no fraction")

	// attention: refused while the person is in the window; urgent once they left; over when they come back
	testing.expect(t, !platform.taskbar_attention(w, true), "an active window asks nothing")
	platform.set_offscreen_active(w, false)
	testing.expect(t, platform.taskbar_attention(w, true))
	if !testing.expect(t, dock_wait(dock, &d, 4)) { return }
	testing.expect(t, d.heard[3].urgent)
	platform.set_offscreen_active(w, true)
	if !testing.expect(t, dock_wait(dock, &d, 5), "the end of the attention") { return }
	testing.expect(t, !d.heard[4].urgent)
	testing.expect(t, !platform.taskbar_state(w).attention)

	// the theme's count: the dock draws its own, the count is what it reads
	badge_in_the_theme_s_accent(t, w, 5)
	if !testing.expect(t, dock_wait(dock, &d, 6)) { return }
	testing.expect(t, d.heard[5].count == 5 && d.heard[5].count_visible)

	// the window that decided the entry goes: the dock is told to show nothing
	platform.destroy_window(w)
	if !testing.expect(t, dock_wait(dock, &d, 7), "the cleared entry") { return }
	e = d.heard[6]
	testing.expect(t, e.ok && e.uri == uri && !e.count_visible && !e.progress_visible && !e.urgent)
}
