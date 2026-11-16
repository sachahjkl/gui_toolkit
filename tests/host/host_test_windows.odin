package host_test

// What the host does with a real window of the system and the Direct3D renderer's own window handle.

import "core:testing"
import win "core:sys/windows"
import host "gt:host"
import "gt:platform"
import "gt:render"
import "gt:ui"

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

// The first window (a real one) closes while a second is open: the renderer draws on the second's window as its own
// (first-window.md), and its frame is the second's, read back; the second's close then ends what is shared.
@(test)
the_first_window_closes_and_the_renderer_stays :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	a, b := new(host.Host), new(host.Host)
	defer { free(a); free(b) }
	if !host.host_open(a, &sh, {title = "host test first", size = SIZE}, probe_build, &p) { testing.fail_now(t, "no first window") }
	if !host.host_open(b, &sh, {title = "host test second", size = SIZE}, probe_build, &p) { host.host_close(a); testing.fail_now(t, "no second window") }
	ui.set_clock(&a.state, &p.clock)
	ui.set_clock(&b.state, &p.clock)
	b.background = {1, 0, 0, 1}
	step(a)
	step(b)
	host.host_close(a)
	testing.expect(t, sh.main == b, "the second window is the first now")
	testing.expect(t, b.paced, "and it is paced")
	testing.expect_value(t, sh.r.hwnd, win.HWND(b.win.hwnd))
	testing.expect(t, render.capture_request(&sh.r), "a capture of its next frame")
	pixels: []u8
	status := render.Capture_Status.Pending
	// (a bounded wait for the copy: one frame, then polls, never a fixed delay)
	for i := 0; i < 100 && status == .Pending; i += 1 {
		b.settle = max(b.settle, 1)
		step(b)
		pixels, _, status = render.capture_poll(&sh.r)
	}
	testing.expect_value(t, status, render.Capture_Status.Ready)
	if len(pixels) >= 4 { testing.expectf(t, pixels[0] > 200 && pixels[1] < 50 && pixels[2] < 50, "the second window's red clear: %v", pixels[:4]) }
	delete(pixels)
	host.host_close(b)
	testing.expect(t, sh.main == nil, "the last close ends what is shared")
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
	b.before_input = proc(h: ^host.Host) { (^Probe)(h.user).hwnd_in_poll = rawptr(h.shared.r.hwnd) }
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
	testing.expect_value(t, p.hwnd_in_poll, rawptr(main_hwnd))
	testing.expect_value(t, sh.r.hwnd, main_hwnd)   // (and after the frame)
	testing.expect_value(t, b.shown, b.win.size)
	testing.expect_value(t, ui.now_ms(), p.clock)   // (between frames, the first window's interface is the current one)
}
