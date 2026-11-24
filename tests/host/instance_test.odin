#+build linux, windows
package host_test

// host.instance_serve: a second start's launch, a PING and a QUIT reach the window's thread through the instance's own
// thread; a launch is a launch only when it decodes; a post that fails at the window's end loses nothing and leaks
// nothing; a call posted before the stop does nothing after it. (Other systems have no hand-over: instance_other.odin.)

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import host "gt:host"
import instance "gt:instance"
import "gt:ui"

@(private = "file") SEND_WAIT_MS :: 2000

@(private = "file")
Served :: struct {
	probe:    Probe,              // (first: h.user is this struct)
	launches: [dynamic]string,    // "token|arg|arg"
	quits:    int,
	raise:    bool,
}

@(private = "file")
served_launch :: proc(h: ^host.Host, l: instance.Launch) -> bool {
	s := (^Served)(h.user)
	b := strings.builder_make()
	strings.write_string(&b, l.token)
	for a in l.args { strings.write_byte(&b, '|'); strings.write_string(&b, a) }
	append(&s.launches, strings.to_string(b))
	return s.raise
}

@(private = "file")
served_quit :: proc(h: ^host.Host) { (^Served)(h.user).quits += 1 }

@(private = "file")
served_free :: proc(s: ^Served) {
	for l in s.launches { delete(l) }
	delete(s.launches)
	delete(s.probe.seen)
}

@(private = "file") name_counter: u64

// (in the caller's allocator, not the temporary one: host_frame frees that, and the options outlive the frames)
@(private = "file")
unique_name :: proc() -> string {
	n := sync.atomic_add(&name_counter, 1)
	return fmt.aprintf("tk.host.serve.%d.%d", time.to_unix_nanoseconds(time.now()), n)
}

@(test)
a_second_start_reaches_the_window_s_thread :: proc(t: ^testing.T) {
	served: Served
	defer served_free(&served)
	served.raise = true
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &served.probe)
	defer host.host_close(h)
	o := instance.Instance_Options{name = unique_name(), wait_ms = SEND_WAIT_MS}
	defer delete(o.name)
	outcome, owner := instance.acquire(o, nil)
	testing.expect_value(t, outcome, instance.Outcome.First)
	svc: host.Instance_Service
	testing.expect(t, host.instance_serve(&svc, h, owner, served_launch, served_quit), "served")
	defer host.instance_serve_stop(&svc)

	testing.expect(t, instance.running(o), "a PING is answered")
	m := instance.launch_encode({token = "tok", args = {"/a b/c.txt", "two\nlines", "Été"}})
	testing.expect_value(t, instance.send(o, m), instance.Outcome.Forwarded)
	testing.expect_value(t, instance.send(o, transmute([]byte)string("no launch")), instance.Outcome.Forwarded)
	testing.expect_value(t, len(served.launches), 0)   // (on the instance's thread: nothing ran on the window's yet)
	step(h)
	if testing.expect_value(t, len(served.launches), 1) {
		testing.expect_value(t, served.launches[0], "tok|/a b/c.txt|two\nlines|Été")
	}
	testing.expect_value(t, served.quits, 0)

	testing.expect(t, instance.quit(o), "a QUIT is taken")
	step(h)
	testing.expect_value(t, served.quits, 1)
	testing.expect_value(t, len(served.launches), 1)
}

@(test)
a_failed_post_and_a_late_call_lose_nothing :: proc(t: ^testing.T) {
	served: Served
	defer served_free(&served)
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &served.probe)
	defer host.host_close(h)
	o := instance.Instance_Options{name = unique_name(), wait_ms = SEND_WAIT_MS}
	defer delete(o.name)
	outcome, owner := instance.acquire(o, nil)
	testing.expect_value(t, outcome, instance.Outcome.First)
	svc: host.Instance_Service
	testing.expect(t, host.instance_serve(&svc, h, owner, served_launch), "served")

	// a call posted, the service stopped before the window's next frame: the call finds it stopped
	testing.expect_value(t, instance.send(o, instance.launch_encode({args = {"/x"}})), instance.Outcome.Forwarded)
	host.instance_serve_stop(&svc)
	step(h)
	testing.expect_value(t, len(served.launches), 0)

	// served again, the window's queue closed (its end): the launch waits in the service, the stop frees it
	again, owner2 := instance.acquire(o, nil)
	testing.expect_value(t, again, instance.Outcome.First)
	testing.expect(t, host.instance_serve(&svc, h, owner2, served_launch), "served again")
	ui.post_close(&h.state)
	testing.expect_value(t, instance.send(o, instance.launch_encode({args = {"/y"}})), instance.Outcome.Forwarded)
	host.instance_serve_stop(&svc)
	testing.expect_value(t, len(served.launches), 0)
	// the name is free once stopped
	last, owner3 := instance.acquire(o, nil)
	testing.expect_value(t, last, instance.Outcome.First)
	instance.owner_stop(&owner3)
}
