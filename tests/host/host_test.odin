// host: a window as an object. The first window is offscreen, on the software renderer (no window of the system); a second
// one is a real window, hidden, on the runner's own desktop. The clock is the state's own (ui.set_clock): nothing waits.
package host_test

import "core:testing"
import win "core:sys/windows"
import "../../host"
import "../../platform"
import "../../render"
import "../../ui"

@(private = "file") SIZE :: [2]int{320, 200}
@(private = "file") FRAME_MS :: 16
@(private = "file") HOLD_MS :: 40
@(private = "file") WAKE_A_MS :: 300
@(private = "file") WAKE_B_MS :: 120
@(private = "file") B_CLOCK_AHEAD_MS :: 100000

@(private = "file")
Probe :: struct {
	clock:  f64,
	seen:   [dynamic]string,
	builds: int,
	hold:   int,
	hwnd_in_poll: win.HWND,   // what the renderer held while the input was read
}

@(private = "file")
note :: proc(h: ^host.Host, what: string) { append(&(^Probe)(h.user).seen, what) }

@(private = "file")
probe_build :: proc(h: ^host.Host, size: host.Vec2) {
	(^Probe)(h.user).builds += 1
	ui.label("probe###probe")
}

@(private = "file")
open_main :: proc(t: ^testing.T, sh: ^host.Shared, h: ^host.Host, p: ^Probe) -> bool {
	if !host.host_open(h, sh, {title = "host test", size = SIZE, headless = true}, probe_build, p) {
		testing.fail_now(t, "no renderer (WARP)")
	}
	ui.set_clock(&h.state, &p.clock)
	return true
}

@(private = "file")
step :: proc(h: ^host.Host) {
	(^Probe)(h.user).clock += FRAME_MS
	host.host_frame(h)
}

// The parts of a frame come in the order the real loops came to: input read before the interface sees it, every build, then the
// picture.
@(test)
a_frame_goes_in_its_order :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &p)
	defer host.host_close(h)
	h.before_input = proc(h: ^host.Host) { note(h, "before_input") }
	h.dragging = proc(h: ^host.Host) -> bool { note(h, "dragging"); return false }
	h.input = proc(h: ^host.Host, e: []platform.Event) -> []platform.Event { note(h, "input"); return e }
	h.params = proc(h: ^host.Host, bp: ^ui.Build_Params) { note(h, "params") }
	h.after_build = proc(h: ^host.Host) { note(h, "after_build") }
	h.hold = proc(h: ^host.Host, size: host.Vec2) -> int { note(h, "hold"); return 0 }
	step(h)
	want := []string{"dragging", "before_input", "input", "params", "after_build", "hold"}
	testing.expect_value(t, len(p.seen), len(want))
	for w, i in want {
		if i < len(p.seen) { testing.expectf(t, p.seen[i] == w, "%d: %s, want %s", i, p.seen[i], w) }
	}
	testing.expect_value(t, h.shown, SIZE)
	testing.expect(t, ui.building() == false, "no build left open")
}

// A frame may build as many times as it needs: the builds after the first take no input.
@(test)
several_builds_in_a_frame :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &p)
	defer host.host_close(h)
	h.builds = proc(h: ^host.Host, size: host.Vec2, events: []platform.Event, dt: f32) {
		host.host_build(h, size, events, dt)
		host.host_build(h, size, nil, 0)
		host.host_build(h, size, nil, 0)
	}
	step(h)
	testing.expect_value(t, p.builds, 3)
}

// A frame held back shows nothing and asks to be woken within the time it said; the next one shows.
@(test)
a_held_frame_shows_nothing_and_comes_back :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &p)
	defer host.host_close(h)
	h.hold = proc(h: ^host.Host, size: host.Vec2) -> int { return (^Probe)(h.user).hold }
	p.hold = HOLD_MS
	step(h)
	testing.expect_value(t, h.shown, [2]int{})
	testing.expect_value(t, ui.wake_ms(&h.state), HOLD_MS)
	now, wake := host.hosts_due({h})
	testing.expect(t, !now, "nothing else is due")
	testing.expect_value(t, wake, HOLD_MS)
	p.hold = 0
	step(h)
	testing.expect_value(t, h.shown, SIZE)
}

// The loop sleeps until the soonest of what the windows asked for, and not at all while one still moves or settles.
@(test)
the_wait_is_the_soonest_of_all :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	a, b := new(host.Host), new(host.Host)
	defer { free(a); free(b) }
	open_main(t, &sh, a, &p)
	defer host.host_close(a)
	if !host.host_open(b, &sh, {title = "host test b", size = SIZE}, probe_build, &p) { testing.fail_now(t, "no second window") }
	defer host.host_close(b)
	ui.set_clock(&b.state, &p.clock)
	step(a)
	step(b)
	a.state.wake_ms, b.state.wake_ms = WAKE_A_MS, WAKE_B_MS
	now, wake := host.hosts_due({a, b})
	testing.expect(t, !now, "nothing is due")
	testing.expect_value(t, wake, WAKE_B_MS)
	b.state.anim_busy = true
	now, _ = host.hosts_due({a, b})
	testing.expect(t, now, "one window moves: no sleep")
	b.state.anim_busy = false
	a.settle = 1
	now, _ = host.hosts_due({a, b})
	testing.expect(t, now, "a change settles: no sleep")
	step(a)
	testing.expect_value(t, a.settle, 0)
}

// The second window: its frame draws on its own surface, and reads its input with the renderer given back (a loop of the system
// begun there would find the other windows' frames as a frame leaves them).
@(test)
a_second_window_reads_its_input_with_the_renderer_given_back :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	a, b := new(host.Host), new(host.Host)
	defer { free(a); free(b) }
	open_main(t, &sh, a, &p)
	defer host.host_close(a)
	if !host.host_open(b, &sh, {title = "host test b", size = SIZE}, probe_build, &p) { testing.fail_now(t, "no second window") }
	defer host.host_close(b)
	b_clock := p.clock + B_CLOCK_AHEAD_MS   // (its own clock: which interface is current shows in ui.now_ms)
	ui.set_clock(&b.state, &b_clock)
	testing.expect(t, !b.paced, "only the first window is paced")
	main_hwnd := sh.r.hwnd
	b.paced = true   // (so that the pacing, done on its surface, is seen too)
	b.dragging = proc(h: ^host.Host) -> bool {
		note(h, h.shared.r.hwnd == win.HWND(h.win.hwnd) ? "paced on its surface" : "paced elsewhere")
		return false
	}
	b.before_input = proc(h: ^host.Host) { (^Probe)(h.user).hwnd_in_poll = h.shared.r.hwnd }
	b.input = proc(h: ^host.Host, e: []platform.Event) -> []platform.Event {
		note(h, h.shared.r.hwnd == win.HWND(h.win.hwnd) ? "built on its surface" : "built elsewhere")
		return e
	}
	step(b)
	testing.expect_value(t, len(p.seen), 2)
	if len(p.seen) == 2 {
		testing.expect_value(t, p.seen[0], "paced on its surface")
		testing.expect_value(t, p.seen[1], "built on its surface")
	}
	testing.expect_value(t, p.hwnd_in_poll, main_hwnd)
	testing.expect_value(t, sh.r.hwnd, main_hwnd)   // (and after the frame)
	testing.expect_value(t, b.shown, b.win.size)
	testing.expect_value(t, ui.now_ms(), p.clock)   // (between frames, the first window's interface is the current one)
}

// From the system's loop: a step of a resize is this window's alone; with no step to show, the program's whole frame.
@(test)
a_resize_step_is_the_window_s_own :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &p)
	defer host.host_close(h)
	h.rest_frame = proc(h: ^host.Host) { note(h, "rest") }
	step(h)
	h.win.on_frame(h.win.user)
	testing.expect_value(t, len(p.seen), 1)
	h.win.size = {SIZE.x + 40, SIZE.y}
	built := p.builds
	h.win.on_frame(h.win.user)
	testing.expect_value(t, len(p.seen), 1)   // (no rest frame)
	testing.expect_value(t, p.builds, built + 1)
	testing.expect_value(t, h.shown, h.win.size)
}

_ :: render
