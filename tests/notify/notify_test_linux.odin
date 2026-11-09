package notify_test

// Linux, end to end: a bus of the test's own (dbus-daemon with no service directory: nothing on it starts by itself, so
// no real notification server is ever reached), a fake org.freedesktop.Notifications on its own thread that records
// the Notify calls and sends ActionInvoked / NotificationClosed / ActivationToken when told, and offscreen windows (no
// display) that receive the events.

import "core:c/libc"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "../../src/dbus"
import "../../src/platform"
import "../../src/png"

@(private = "file") SERVICE :: "org.freedesktop.Notifications"
@(private = "file") PATH :: "/org/freedesktop/Notifications"
@(private = "file") WAIT :: 3 * time.Second

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

// A signal the fake sends, from its thread (a connection is driven by one thread).
@(private = "file")
Command :: struct {
	member: string,
	id:     u32,
	text:   string,
	code:   u32,
}

@(private = "file")
Fake :: struct {
	address:  string,
	mutex:    sync.Mutex,
	arena:    virtual.Arena,   // what the fake keeps (its thread writes, under the mutex)
	calls:    [dynamic]Notify_Call,
	commands: [dynamic]Command,
	next_id:  u32,
	ready:    bool,   // (atomic)
	stop:     bool,   // (atomic)
	failed:   bool,
}

@(private = "file")
fake_run :: proc(f: ^Fake) {
	c := dbus.connect_bus_address(f.address)
	if c == nil || !dbus.request_name(c, SERVICE) {
		f.failed = true
		sync.atomic_store(&f.ready, true)
		return
	}
	defer dbus.conn_close(c)
	dbus.export_object(c, PATH, fake_handler, f)
	sync.atomic_store(&f.ready, true)
	for !sync.atomic_load(&f.stop) {
		pfd := posix.pollfd{fd = posix.FD(dbus.conn_fd(c)), events = {.IN}}
		posix.poll(&pfd, 1, 10)
		dbus.dispatch(c)
		sync.mutex_lock(&f.mutex)
		commands := f.commands[:]
		for cmd in commands { fake_emit(c, cmd) }
		clear(&f.commands)
		sync.mutex_unlock(&f.mutex)
	}
}

@(private = "file")
fake_emit :: proc(c: ^dbus.Conn, cmd: Command) {
	w := dbus.body_writer()
	dbus.w_u32(&w, cmd.id)
	switch cmd.member {
	case "ActionInvoked", "ActivationToken":
		dbus.w_string(&w, cmd.text)
		dbus.emit_signal(c, PATH, SERVICE, cmd.member, "us", w.buf[:])
	case "NotificationClosed":
		dbus.w_u32(&w, cmd.code)
		dbus.emit_signal(c, PATH, SERVICE, cmd.member, "uu", w.buf[:])
	}
}

@(private = "file")
fake_handler :: proc(user: rawptr, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	f := (^Fake)(user)
	switch msg.member {
	case "GetCapabilities":
		w := dbus.body_writer()
		l, at := dbus.w_array_begin(&w, 4)
		for cap in ([]string{"actions", "body", "body-markup", "persistence"}) { dbus.w_string(&w, cap) }
		dbus.w_array_end(&w, l, at)
		dbus.reply_return(c, msg, "as", w.buf[:])
		return true
	case "Notify":
		sync.mutex_lock(&f.mutex)
		call := parse_notify(msg.body_bytes, msg.big, virtual.arena_allocator(&f.arena))
		append(&f.calls, call)
		id := call.replaces
		if id == 0 { f.next_id += 1; id = f.next_id }
		sync.mutex_unlock(&f.mutex)
		w := dbus.body_writer()
		dbus.w_u32(&w, id)
		dbus.reply_return(c, msg, "u", w.buf[:])
		return true
	case "CloseNotification":
		r := dbus.msg_reader(msg)
		id := dbus.r_u32(&r)
		dbus.reply_return(c, msg, "", nil)
		fake_emit(c, {member = "NotificationClosed", id = id, code = 3})
		return true
	}
	return false
}

@(private = "file")
fake_send :: proc(f: ^Fake, cmd: Command) {
	sync.mutex_lock(&f.mutex)
	append(&f.commands, cmd)
	sync.mutex_unlock(&f.mutex)
}

@(private = "file")
last_call :: proc(f: ^Fake) -> (c: Notify_Call, n: int) {
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	n = len(f.calls)
	if n > 0 { c = f.calls[n - 1] }
	return
}

// Pumps the windows until `w` received an event of `kind` (true), or for WAIT. Every event of `w` is kept in `seen`.
@(private = "file")
wait_for :: proc(w: ^platform.Window, kind: platform.Event_Kind, seen: ^[dynamic]platform.Event, limit := WAIT) -> (platform.Event, bool) {
	start := time.tick_now()
	for time.tick_since(start) < limit {
		for e in platform.poll_events(w, true, 20) {
			if e.kind < .Notification_Click { continue }
			append(seen, e)
			if e.kind == kind { return e, true }
		}
	}
	return {}, false
}

@(private = "file")
Bus :: struct {
	dir, address: string,
	pid: posix.pid_t,
}

// A dbus-daemon of the test's own, with no service directory.
@(private = "file")
bus_start :: proc(t: ^testing.T) -> (b: Bus, ok: bool) {
	b.dir = fmt.aprintf("/tmp/gt-notify-test-%d", posix.getpid(), allocator = context.temp_allocator)
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

@(test)
a_notification_round_trip_on_a_private_bus :: proc(t: ^testing.T) {
	b, ok := bus_start(t)
	if !testing.expect(t, ok, "a bus of the test's own") { return }
	defer bus_stop(b)
	// (before the first use of the session bus on this thread: the platform connects to this one)
	posix.setenv("DBUS_SESSION_BUS_ADDRESS", strings.clone_to_cstring(b.address, context.temp_allocator), true)
	defer posix.unsetenv("DBUS_SESSION_BUS_ADDRESS")
	platform.set_app_id("gt-notify-test")
	platform.notify_set_app({name = "Notify Test"})

	w := platform.open_window_offscreen("notify", {200, 100})
	if !testing.expect(t, w != nil) { return }
	defer platform.destroy_window(w)
	other := platform.open_window_offscreen("other", {200, 100})
	defer platform.destroy_window(other)

	testing.expect(t, !platform.notify_supported(), "no server on the bus: no notifications")
	_, shown := platform.notify(w, {title = "nobody hears"})
	testing.expect(t, !shown)

	f := new(Fake)
	defer { virtual.arena_destroy(&f.arena); free(f) }
	f.address = b.address
	runner := thread.create_and_start_with_poly_data(f, fake_run)
	defer {
		sync.atomic_store(&f.stop, true)
		thread.join(runner)
		thread.destroy(runner)
		delete(f.calls)
		delete(f.commands)
	}
	for !sync.atomic_load(&f.ready) { time.sleep(time.Millisecond) }
	if !testing.expect(t, !f.failed, "the fake server owns its name") { return }
	testing.expect(t, platform.notify_supported())

	// the call: the app's name and .desktop file, the escaped body (the server reads markup), the buttons, the hints
	icon := png.encode([]u8{1, 2, 3, 255, 4, 5, 6, 255}, 2, 1, allocator = context.temp_allocator)
	id, sent := platform.notify(w, {title = "Build <done>", body = "a & b", icon_png = icon, urgency = .Critical,
		silent = true, actions = {{7, "Open"}, {9, "Later"}}})
	if !testing.expect(t, sent && id != 0) { return }
	call, calls := last_call(f)
	testing.expect_value(t, calls, 1)
	testing.expect(t, call.ok)
	testing.expect_value(t, call.app_name, "Notify Test")
	testing.expect_value(t, call.desktop_entry, "gt-notify-test")
	testing.expect_value(t, call.summary, "Build <done>")
	testing.expect_value(t, call.body, "a &amp; b")
	testing.expect_value(t, strings.join(call.actions[:], "|", context.temp_allocator), "default||7|Open|9|Later")
	testing.expect_value(t, call.urgency, 2)
	testing.expect(t, call.silent)
	testing.expect_value(t, call.image, [3]i32{2, 1, 8})

	seen: [dynamic]platform.Event
	defer delete(seen)

	// a click on the body, with the activation token the server got for it (it comes first)
	fake_send(f, {member = "ActivationToken", id = u32(id), text = "token-1"})
	fake_send(f, {member = "ActionInvoked", id = u32(id), text = "default"})
	e, heard := wait_for(w, .Notification_Click, &seen)
	testing.expect(t, heard, "the click")
	testing.expect_value(t, e.notification.id, id)
	testing.expect_value(t, platform.notify_activation_token(w), "token-1")

	// a button; then signals of a notification the window did not show (another program's) change nothing
	fake_send(f, {member = "ActionInvoked", id = 999, text = "default"})
	fake_send(f, {member = "ActionInvoked", id = u32(id), text = "9"})
	e, heard = wait_for(w, .Notification_Action, &seen)
	testing.expect(t, heard, "the button")
	testing.expect_value(t, e.notification.action, 9)
	testing.expect_value(t, e.notification.id, id)

	// the user closes it: Closed, Dismissed; it is gone: what the server says of it after goes nowhere
	fake_send(f, {member = "NotificationClosed", id = u32(id), code = 2})
	e, heard = wait_for(w, .Notification_Closed, &seen)
	testing.expect(t, heard, "closed")
	testing.expect_value(t, e.notification.reason, platform.Notification_Reason.Dismissed)
	clear(&seen)
	fake_send(f, {member = "ActionInvoked", id = u32(id), text = "default"})
	_, heard = wait_for(w, .Notification_Click, &seen, 200 * time.Millisecond)
	testing.expect(t, !heard, "nothing of a notification that closed")

	// replace in place, then close from the program: the server's NotificationClosed (3) is Closed
	first, _ := platform.notify(w, {title = "1 of 2"})
	second, again := platform.notify(w, {title = "2 of 2", replace = first})
	testing.expect(t, again)
	call, _ = last_call(f)
	testing.expect_value(t, call.replaces, u32(first))
	testing.expect_value(t, second, first)
	platform.notify_close(w, second)
	e, heard = wait_for(w, .Notification_Closed, &seen)
	testing.expect(t, heard, "closed by the program")
	testing.expect_value(t, e.notification.id, second)
	testing.expect_value(t, e.notification.reason, platform.Notification_Reason.Closed)

	// the other window heard none of it
	others: [dynamic]platform.Event
	defer delete(others)
	_, heard = wait_for(other, .Notification_Click, &others, 100 * time.Millisecond)
	testing.expect_value(t, len(others), 0)
}
