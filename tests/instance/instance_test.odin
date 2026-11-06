// Moved here with the single-instance mechanism it covers (was Wren's src/instance/instance_test.odin), adapted to the
// neutral API: a name built with `key`, an identity token, and an opaque message the test encodes and decodes itself.
//   odin test tests/instance -vet
package instance_test

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import inst "../../instance"
import "../../testkit"

@(private = "file") unique_counter: u64

// A name no other call of this process has made (the unit tests run on several threads: a bare clock is not unique).
@(private = "file")
unique :: proc() -> string {
	n := sync.atomic_add(&unique_counter, 1)
	return fmt.tprintf("tk_instance_test_%d_%d", time.to_unix_nanoseconds(time.now()), n)
}

// The opaque message the test application uses: "setup=<bool>:addr|addr". The package never looks inside it.
@(private = "file")
msg :: proc(setup: bool, addresses: []string) -> []byte {
	return transmute([]byte)fmt.tprintf("setup=%v:%s", setup, strings.join(addresses, "|", context.temp_allocator))
}

@(test)
instance_key_follows_prefix_and_path :: proc(t: ^testing.T) {
	a := inst.key("app.release", `C:\Users\me\AppData\Roaming\App`)
	testing.expect(t, strings.has_prefix(a, "app.release."), "prefix in the name")
	testing.expect_value(t, len(a), len("app.release.") + 16)
	for c in a { testing.expectf(t, (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.', "%q is fine in a kernel object name", c) }
	testing.expect(t, inst.key("app.dev", `C:\Users\me\AppData\Roaming\App`) != a, "another prefix, another name")
	testing.expect(t, inst.key("app.release", `C:\Users\me\AppData\Roaming\App2`) != a, "another path, another name")
	when ODIN_OS == .Windows {
		testing.expect_value(t, inst.key("app.release", `c:/users/ME/appdata/roaming/app/`), a)   // case, slash direction, trailing separator
	}
	testing.expect_value(t, inst.key("app.release", `C:\Users\me\AppData\Roaming\App`), a)   // (and always the same)
}

// How often an owner that pumps looks at its messages.
@(private = "file") OWNER_POLL :: 2 * time.Millisecond
// A few of the second start's attempts (instance: ACQUIRE_RETRY_MS).
@(private = "file") OWNER_STARTING_MS :: 150
@(private = "file") OWNER_GOES_AFTER :: 150 * time.Millisecond
// Pumps that cannot all have come before the message: it was there by the first whole one.
@(private = "file") PUMPS_TO_BE_SURE :: 2

////////////////////////////////
// The real exchange, in one process: a thread is the owner (it pumps its window), the test thread is the second start.

@(private = "file")
Owner_Thread :: struct {
	name, identity: string,
	ready:    sync.Sema,
	stop:     bool,
	closing:  bool,          // refuse messages from now on (as the owner does when it ends), keep pumping
	closing_seen: bool,      // atomic: it does
	wake:     sync.Sema,     // owner_end
	pump:     bool,          // atomic; false: do not pump (a busy owner)
	pumps:    int,           // atomic: how many times it did
	delay_ms: int,           // the window comes this long after the mutex (an owner that is starting)
	got:      [dynamic]string,
	mu:       sync.Mutex,
	started:  bool,
}

@(private = "file")
owner_handler :: proc(user: rawptr, message: []byte) {
	d := (^Owner_Thread)(user)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	// (the heap, not the thread's allocator: the test thread reads and frees this)
	text := strings.clone(string(message), runtime.heap_allocator())
	append(&d.got, text)
}

@(private = "file")
owner_ignores :: proc(user: rawptr, message: []byte) {}

@(private = "file")
owner_main :: proc(th: ^thread.Thread) {
	d := (^Owner_Thread)(th.data)
	outcome, owner := inst.acquire({name = d.name, identity = d.identity, wait_ms = 0}, nil)
	d.started = outcome == .First
	sync.sema_post(&d.ready)
	// (real time: the second start tries again by the system's clock, and nothing shows that it has tried)
	if d.delay_ms > 0 { time.sleep(time.Duration(d.delay_ms) * time.Millisecond) }
	if d.started { inst.owner_start(&owner, owner_handler, d) }
	for !d.stop {
		if d.closing && !sync.atomic_load(&d.closing_seen) {
			inst.owner_closing(&owner)
			sync.atomic_store(&d.closing_seen, true)
		}
		if sync.atomic_load(&d.pump) {
			inst.pump_messages()
			sync.atomic_add(&d.pumps, 1)
		}
		_ = sync.sema_wait_with_timeout(&d.wake, OWNER_POLL)
	}
	if d.started { inst.owner_stop(&owner) }
}

@(private = "file")
owner_begin :: proc(name, identity: string, pump := true, delay_ms := 0) -> (^Owner_Thread, ^thread.Thread) {
	d := new(Owner_Thread, runtime.heap_allocator())
	d.got.allocator = runtime.heap_allocator()
	d.name, d.identity, d.pump, d.delay_ms = name, identity, pump, delay_ms
	th := thread.create(owner_main)
	th.data = d
	thread.start(th)
	sync.sema_wait(&d.ready)
	return d, th
}

@(private = "file")
owner_end :: proc(d: ^Owner_Thread, th: ^thread.Thread) {
	d.stop = true
	sync.sema_post(&d.wake)
	thread.join(th)
	thread.destroy(th)
	for g in d.got { delete(g, runtime.heap_allocator()) }
	delete(d.got)
	free(d, runtime.heap_allocator())
}

@(test)
instance_second_start_hands_over_and_ends :: proc(t: ^testing.T) {
	name := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\%s", unique()))
	d, th := owner_begin(name, `C:\a\app.exe`)
	defer owner_end(d, th)
	testing.expect(t, d.started, "the first start owns the name")

	outcome, _ := inst.acquire({name = name, identity = `C:\a\app.exe`, wait_ms = 3000}, msg(false, {"https://example.org/", "file:///C:/x.html"}))
	testing.expect_value(t, outcome, inst.Outcome.Forwarded)
	outcome, _ = inst.acquire({name = name, identity = `C:\a\app.exe`, wait_ms = 3000}, msg(true, nil))
	testing.expect_value(t, outcome, inst.Outcome.Forwarded)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	testing.expect_value(t, len(d.got), 2)
	testing.expect(t, len(d.got) == 2 && d.got[0] == "setup=false:https://example.org/|file:///C:/x.html", "the message arrived whole")
	testing.expect(t, len(d.got) == 2 && d.got[1] == "setup=true:", "and the second")
}

@(test)
instance_a_different_identity_is_not_taken :: proc(t: ^testing.T) {
	name := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\%s", unique()))
	d, th := owner_begin(name, `C:\installed\app.exe`)
	defer owner_end(d, th)
	outcome, _ := inst.acquire({name = name, identity = `C:\download\app.exe`, wait_ms = 3000}, msg(false, {"about:config"}))
	testing.expect_value(t, outcome, inst.Outcome.Other_Instance)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	testing.expect_value(t, len(d.got), 0)
}

@(test)
instance_names_are_independent :: proc(t: ^testing.T) {
	id := unique()
	n1 := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\a%s", id))
	n2 := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\b%s", id))
	d, th := owner_begin(n1, `C:\a\app.exe`)
	defer owner_end(d, th)
	outcome, owner := inst.acquire({name = n2, identity = `C:\a\app.exe`, wait_ms = 500}, nil)
	testing.expect_value(t, outcome, inst.Outcome.First)   // another name: nothing to hand over to
	inst.owner_stop(&owner)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	testing.expect_value(t, len(d.got), 0)
}

@(test)
instance_a_silent_owner_does_not_hold_the_second_start :: proc(t: ^testing.T) {
	name := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\%s", unique()))
	d, th := owner_begin(name, `C:\a\app.exe`, pump = false)   // has the window, never answers
	defer owner_end(d, th)
	if !testing.expect(t, d.started, "the owner thread took the name before the second start is tried") { return }
	t0 := time.tick_now()
	outcome, _ := inst.acquire({name = name, identity = `C:\a\app.exe`, wait_ms = 700}, msg(false, {"about:config"}))
	testing.expect_value(t, outcome, inst.Outcome.Unresponsive)
	testing.expect(t, time.duration_milliseconds(time.tick_since(t0)) < 3000, "it gave up after about the timeout")
}

// The second start gave up and carries on alone: an owner that wakes later must not open what it asked as well.
@(test)
instance_a_message_given_up_is_not_handled :: proc(t: ^testing.T) {
	name := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\%s", unique()))
	d, th := owner_begin(name, `C:\a\app.exe`, pump = false)
	defer owner_end(d, th)
	outcome, _ := inst.acquire({name = name, identity = `C:\a\app.exe`, wait_ms = 0}, msg(false, {"about:config"}))
	testing.expect_value(t, outcome, inst.Outcome.Unresponsive)
	sync.atomic_store(&d.pump, true)
	testing.expect(t, testkit.await(d, proc(d: ^Owner_Thread) -> bool { return sync.atomic_load(&d.pumps) >= PUMPS_TO_BE_SURE }), "the owner wakes")
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	testing.expect_value(t, len(d.got), 0)
}

// More than the socket holds, to an owner that does not read: the wait is over at the timeout all the same.
@(test)
instance_a_large_message_does_not_hold_the_second_start :: proc(t: ^testing.T) {
	name := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\%s", unique()))
	d, th := owner_begin(name, `C:\a\app.exe`, pump = false)
	defer owner_end(d, th)
	large := make([]byte, inst.ENVELOPE_MAX / 2, context.temp_allocator)
	t0 := time.tick_now()
	outcome, _ := inst.acquire({name = name, identity = `C:\a\app.exe`, wait_ms = 0}, large)
	testing.expect_value(t, outcome, inst.Outcome.Unresponsive)
	testing.expect(t, time.duration_milliseconds(time.tick_since(t0)) < 3000, "it gave up after about the timeout")
}

// An Owner starts once: a second start, or a start after closing, opens nothing.
@(test)
instance_an_owner_starts_once :: proc(t: ^testing.T) {
	name := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\%s", unique()))
	outcome, owner := inst.acquire({name = name, identity = "", wait_ms = 0}, nil)
	testing.expect_value(t, outcome, inst.Outcome.First)
	testing.expect_value(t, owner.state, inst.Owner_State.Claimed)
	testing.expect(t, inst.owner_start(&owner, owner_ignores, nil))
	testing.expect_value(t, owner.state, inst.Owner_State.Serving)
	testing.expect(t, !inst.owner_start(&owner, owner_ignores, nil), "already started")
	inst.owner_closing(&owner)
	testing.expect_value(t, owner.state, inst.Owner_State.Closing)
	testing.expect(t, !inst.owner_start(&owner, owner_ignores, nil), "it is closing")
	inst.owner_stop(&owner)
	testing.expect_value(t, owner.state, inst.Owner_State.None)
	testing.expect(t, !inst.owner_start(&owner, owner_ignores, nil), "it is over")
	inst.owner_stop(&owner)   // (twice is nothing)
	none: inst.Owner
	testing.expect(t, !inst.owner_start(&none, owner_ignores, nil), "what acquire gives with no name")
	inst.owner_closing(&none)
	testing.expect_value(t, none.state, inst.Owner_State.None)
}

@(test)
instance_a_closing_owner_is_waited_for :: proc(t: ^testing.T) {
	name := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\%s", unique()))
	d, th := owner_begin(name, `C:\a\app.exe`)
	d.closing = true   // it refuses from now on
	testing.expect(t, testkit.await(d, proc(d: ^Owner_Thread) -> bool { return sync.atomic_load(&d.closing_seen) }), "the owner closes")
	// the owner goes away a moment later; the second start, which was refused meanwhile, becomes the owner
	// (real time: the second start tries again by the system's clock, and nothing shows that it has been refused)
	closer := thread.create_and_start_with_poly_data2(d, th, proc(d: ^Owner_Thread, th: ^thread.Thread) {
		time.sleep(OWNER_GOES_AFTER)
		owner_end(d, th)
	})
	outcome, owner := inst.acquire({name = name, identity = `C:\a\app.exe`, wait_ms = 5000}, msg(false, {"about:config"}))
	testing.expect_value(t, outcome, inst.Outcome.First)
	inst.owner_stop(&owner)
	thread.join(closer)
	thread.destroy(closer)
}

@(test)
instance_a_start_that_finds_no_window_yet_waits_for_it :: proc(t: ^testing.T) {
	name := inst.key("test", fmt.tprintf("C:\\tk_instance_test\\%s", unique()))
	// the owner holds the mutex (it is starting) and makes its window a moment later
	d, th := owner_begin(name, `C:\a\app.exe`, delay_ms = OWNER_STARTING_MS)
	defer owner_end(d, th)
	outcome, _ := inst.acquire({name = name, identity = `C:\a\app.exe`, wait_ms = 5000}, msg(false, {"https://example.org/"}))
	testing.expect_value(t, outcome, inst.Outcome.Forwarded)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	testing.expect_value(t, len(d.got), 1)
}
