package host_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "gt:devtools"
import host "gt:host"
import "gt:ui"

// Frames a command may take to be answered: the wait's builds and the click's rest, with room.
@(private = "file") ANSWER_FRAMES :: 50
@(private = "file") ANSWER_LIMIT :: 10 * time.Second

// A window served over the devtools protocol, as a program's loop serves it (Host.before_input), whose frames stalled
// past a wait's time: the deadline is over before the wait first looks. The wait is still judged on the builds that follow,
// not on the tree from before: what is on the screen is found, clicked, and the window is idle.
@(test)
a_wait_after_a_stall_is_judged_on_a_fresh_tree :: proc(t: ^testing.T) {
	p: Probe
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &p)
	defer host.host_close(h)
	srv := devtools.start_local(h.win, "host test")
	defer devtools.stop(srv, &h.state)
	h.before_input = proc(h: ^host.Host) { devtools.service((^Server_Of)(h.user).srv, &h.state, &h.shared.r) }
	of := Server_Of{probe = p, srv = srv}
	h.user = &of
	ui.set_clock(&h.state, &of.probe.clock)
	c := devtools.local_connect(srv)
	defer devtools.local_close(c)
	step(h)
	step(h)
	// ("timeout": 0: the time is over at once, as after a stall longer than the wait)
	found := answer(t, h, c, 1, "Toolkit.waitFor", `{"text":"probe","timeout":0}`)
	testing.expectf(t, strings.contains(found, `"text":"probe"`), "waitFor finds what is on the screen: %s", found)
	clicked := answer(t, h, c, 2, "Toolkit.click", `{"text":"probe","timeout":0}`)
	testing.expectf(t, strings.contains(clicked, `"result":{"x"`), "click clicks what is on the screen: %s", clicked)
	idle := answer(t, h, c, 3, "Toolkit.waitIdle", `{"timeout":0}`)
	testing.expectf(t, strings.contains(idle, `"idle":true`), "waitIdle sees the window at rest: %s", idle)
}

// The probe first (step advances its clock), then the server the frames serve.
@(private = "file")
Server_Of :: struct {
	probe: Probe,
	srv:   ^devtools.Server,
}

// The answer to a command, frame after frame (each one a wake of the loop), within a bound.
@(private = "file")
answer :: proc(t: ^testing.T, h: ^host.Host, c: devtools.Local_Client, id: int, method, params: string) -> string {
	devtools.local_send(c, fmt.tprintf(`{{"id":%d,"method":%q,"params":%s}}`, id, method, params))
	end := time.tick_add(time.tick_now(), ANSWER_LIMIT)
	for _ in 0 ..< ANSWER_FRAMES {
		step(h)
		for m in devtools.local_take(c, context.temp_allocator) {
			if strings.contains(m, fmt.tprintf(`"id":%d,`, id)) { return m }
		}
		if time.tick_diff(time.tick_now(), end) <= 0 { break }
	}
	testing.expectf(t, false, "%s: no answer in %d frames", method, ANSWER_FRAMES)
	return ""
}
