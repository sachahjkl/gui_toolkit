package file_request_test

// The portal's backend end to end: a bus of the test's own (dbus-daemon with no service directory), the server on a
// thread, a shell command in place of gt-file-picker --json, and the test as the portal's frontend: OpenFile answered
// with the command's paths as URIs; Close on the call's Request ends its process and the call says cancelled.

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "gt:dbus"
import req "gt:file_request"

@(private = "file") WAIT :: 10 * time.Second
@(private = "file") CALL_MS :: 10_000

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

@(private = "file")
bus_start :: proc(t: ^testing.T, name: string) -> (b: Bus, ok: bool) {
	// (a folder per test: the tests of a package run side by side)
	b.dir = fmt.aprintf("/tmp/gt-portal-test-%d-%s", posix.getpid(), name, allocator = context.temp_allocator)
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

@(private = "file")
Served :: struct {
	server: req.Portal_Server,
	worker: ^thread.Thread,
}

@(private = "file")
serve :: proc(t: ^testing.T, b: Bus, child: []string) -> ^Served {
	sv := new(Served)
	why := req.portal_open(&sv.server, child, b.address)
	if !testing.expect_value(t, why, "") { free(sv); return nil }
	sv.worker = thread.create_and_start_with_data(sv, proc(d: rawptr) { req.portal_run(&(^Served)(d).server) })
	return sv
}

@(private = "file")
serve_end :: proc(sv: ^Served) {
	if sv == nil { return }
	req.portal_stop(&sv.server)
	thread.join(sv.worker)
	thread.destroy(sv.worker)
	req.portal_close(&sv.server)
	free(sv)
}

HANDLE :: "/org/freedesktop/portal/desktop/request/1_7/gt"

// An OpenFile call's body, as the frontend writes it.
@(private = "file")
open_body :: proc() -> []u8 {
	w := dbus.body_writer()
	dbus.w_string(&w, HANDLE)
	dbus.w_string(&w, "org.example.App")
	dbus.w_string(&w, "")
	dbus.w_string(&w, "Open")
	l, c := dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "multiple"); dbus.arg_variant_bool(&w, true)
	dbus.arg_dict_end(&w, l, c)
	return w.buf[:]
}

// The reply's response and its URIs.
@(private = "file")
reply_of :: proc(m: ^dbus.Message) -> (response: u32, uris: [dynamic]string) {
	r := dbus.msg_reader(m)
	response = dbus.r_u32(&r)
	uris = make([dynamic]string, context.temp_allocator)
	end := dbus.r_array_begin(&r, "{sv}")
	for r.pos < end && !r.err {
		dbus.r_align_entry(&r)
		key := dbus.r_string(&r)
		sig := dbus.r_variant_sig(&r)
		if key != "uris" { dbus.r_skip(&r, sig); continue }
		uend := dbus.r_array_begin(&r, "s")
		for r.pos < uend && !r.err { append(&uris, strings.clone(dbus.r_string(&r), context.temp_allocator)) }
	}
	return
}

@(test)
the_portal_answers_with_the_pickers_paths :: proc(t: ^testing.T) {
	b, ok := bus_start(t, "paths")
	if !testing.expect(t, ok, "a bus of the test's own") { return }
	defer bus_stop(b)
	child := []string{"/bin/sh", "-c", `cat > /dev/null; printf '{"status":"chosen","paths":["/tmp/one.txt","/tmp/two words.txt"],"filter":0}'`}
	sv := serve(t, b, child)
	defer serve_end(sv)
	if sv == nil { return }
	c := dbus.connect_bus_address(b.address)
	if !testing.expect(t, c != nil) { return }
	defer dbus.conn_close(c)
	m, called := dbus.call(c, req.PORTAL_BUS_NAME, req.PORTAL_OBJECT, req.PORTAL_INTERFACE, "OpenFile", "osssa{sv}", open_body(), CALL_MS)
	if !testing.expect(t, called, "the backend replied") { return }
	response, uris := reply_of(&m)
	testing.expect_value(t, response, u32(req.PORTAL_RESPONSE_SUCCESS))
	if testing.expect_value(t, len(uris), 2) {
		testing.expect_value(t, uris[0], "file:///tmp/one.txt")
		testing.expect_value(t, uris[1], "file:///tmp/two%20words.txt")
	}
}

@(private = "file")
Heard :: struct {
	done:     bool,
	response: u32,
}

@(test)
close_ends_the_pickers_process :: proc(t: ^testing.T) {
	b, ok := bus_start(t, "close")
	if !testing.expect(t, ok, "a bus of the test's own") { return }
	defer bus_stop(b)
	// (a picker that never answers: only Close ends it)
	child := []string{"/bin/sh", "-c", "cat > /dev/null; exec sleep 60"}
	sv := serve(t, b, child)
	defer serve_end(sv)
	if sv == nil { return }
	c := dbus.connect_bus_address(b.address)
	if !testing.expect(t, c != nil) { return }
	defer dbus.conn_close(c)
	heard: Heard
	sent := dbus.call_async(c, req.PORTAL_BUS_NAME, req.PORTAL_OBJECT, req.PORTAL_INTERFACE, "OpenFile", "osssa{sv}", open_body(), proc(user: rawptr, status: dbus.Call_Status, msg: ^dbus.Message) {
		h := (^Heard)(user)
		if msg != nil { h.response, _ = reply_of(msg) } else { h.response = 99 }
		h.done = true
	}, &heard, CALL_MS)
	testing.expect(t, sent)
	// (the call reaches the server, then its Request object exists: Close is answered by it)
	closed := false
	for start := time.tick_now(); !closed && time.tick_since(start) < WAIT; {
		_, closed = dbus.call(c, req.PORTAL_BUS_NAME, HANDLE, req.PORTAL_REQUEST_INTERFACE, "Close", "", nil, CALL_MS)
	}
	testing.expect(t, closed, "Close was answered")
	for start := time.tick_now(); !heard.done && time.tick_since(start) < WAIT; {
		fds := [1]linux.Poll_Fd{{fd = linux.Fd(dbus.conn_fd(c)), events = {.IN}}}
		_, _ = linux.poll(fds[:], 100)
		dbus.dispatch(c)
	}
	testing.expect(t, heard.done, "the call was answered")
	testing.expect_value(t, heard.response, u32(req.PORTAL_RESPONSE_CANCELLED))
}

_ :: sync
