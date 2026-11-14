// host: a window as an object. The first window is offscreen, on the software renderer (no window of the system); a second
// one is a real window, hidden, on the runner's own desktop (Windows only: host_test_windows.odin). The clock is the state's
// own (ui.set_clock): nothing waits.
package host_test

import "core:testing"
import "../../src/draw"
import "../../src/font"
import host "../../src/host"
import "../../src/platform"
import "../../src/render"
import "../../src/ui"

@(private) SIZE :: [2]int{320, 200}
@(private = "file") FRAME_MS :: 16
@(private = "file") HOLD_MS :: 40
@(private) WAKE_A_MS :: 300
@(private) WAKE_B_MS :: 120
@(private) B_CLOCK_AHEAD_MS :: 100000

@(private)
Probe :: struct {
	clock:  f64,
	seen:   [dynamic]string,
	builds: int,
	hold:   int,
	hwnd_in_poll: rawptr,   // what the renderer held while the input was read (Windows)
}

@(private)
note :: proc(h: ^host.Host, what: string) { append(&(^Probe)(h.user).seen, what) }

@(private)
probe_build :: proc(h: ^host.Host, size: host.Vec2) {
	(^Probe)(h.user).builds += 1
	ui.label("probe###probe")
}

@(private)
open_main :: proc(t: ^testing.T, sh: ^host.Shared, h: ^host.Host, p: ^Probe) -> bool {
	if !host.host_open(h, sh, {title = "host test", size = SIZE, headless = true}, probe_build, p) {
		testing.fail_now(t, "no renderer (WARP)")
	}
	ui.set_clock(&h.state, &p.clock)
	return true
}

@(private)
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
	h.still = proc(h: ^host.Host, e: []platform.Event) -> bool { note(h, "still"); return false }
	h.after_frame = proc(h: ^host.Host) { note(h, "after_frame") }
	step(h)
	want := []string{"dragging", "before_input", "still", "input", "params", "after_build", "hold", "after_frame"}
	testing.expect_value(t, len(p.seen), len(want))
	for w, i in want {
		if i < len(p.seen) { testing.expectf(t, p.seen[i] == w, "%d: %s, want %s", i, p.seen[i], w) }
	}
	testing.expect_value(t, h.shown, SIZE)
	testing.expect(t, ui.building() == false, "no build left open")
}

// A window that says nothing it shows changed is not built, and its last picture stays.
@(test)
a_still_window_builds_nothing :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &p)
	defer host.host_close(h)
	step(h)
	built := p.builds
	h.still = proc(h: ^host.Host, e: []platform.Event) -> bool { return true }
	step(h)
	step(h)
	testing.expect_value(t, p.builds, built)
}

// A window and a renderer the application made itself: the host takes them, and its frames go as an opened one's.
@(test)
an_adopted_window_has_its_frames :: proc(t: ^testing.T) {
	p: Probe
	sh: host.Shared
	w := platform.open_window_offscreen("adopted", SIZE)
	if !testing.expect(t, w != nil) { return }
	if !testing.expect(t, render.init_offscreen(&sh.r, w.size, warp = true), "no renderer (WARP)") { platform.destroy_window(w); return }
	font.init(&sh.fonts)   // (what is shared, made by the application: its fonts, its drawing, its theme)
	sh.font, _, _ = font.load_system_or_embedded(&sh.fonts, "", font.FALLBACK_UI_DATA)
	draw.init(&sh.dc, &sh.r, &sh.fonts)
	ui.apply_palette(&sh.theme, ui.palette_of("Midnight"))
	h := new(host.Host)
	defer free(h)
	host.host_adopt(h, &sh, w, probe_build, &p)
	testing.expect(t, sh.main == h && h.paced, "the first one adopted is the main one, paced")
	ui.init(&h.state, &sh.fonts, &sh.theme)
	ui.set_clock(&h.state, &p.clock)
	testing.expect(t, w.on_frame != nil && w.user == h)
	step(h)
	testing.expect_value(t, p.builds, 1)
	testing.expect_value(t, h.shown, SIZE)
	ui.destroy(&h.state)
	ui.theme_destroy(&sh.theme)
	draw.destroy(&sh.dc)
	render.destroy(&sh.r)
	font.destroy(&sh.fonts)
	platform.destroy_window(w)
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

// A size no picture is drawn at (the picture held) leaves the renderer as it was: it takes the window's size with the
// next picture drawn.
@(test)
a_size_with_no_picture_leaves_the_renderer :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &p)
	defer host.host_close(h)
	step(h)
	testing.expect_value(t, sh.r.size, SIZE)
	h.hold = proc(h: ^host.Host, size: host.Vec2) -> int { return (^Probe)(h.user).hold }
	p.hold = HOLD_MS
	h.win.size = {SIZE.x + 40, SIZE.y}
	step(h)
	h.win.size = {SIZE.x + 80, SIZE.y}
	step(h)
	testing.expect_value(t, sh.r.size, SIZE)
	p.hold = 0
	step(h)
	testing.expect_value(t, sh.r.size, [2]int{SIZE.x + 80, SIZE.y})
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

// Another window's step of a resize is drawn in the paced window's frame, before that frame reads its input: it does not
// wait for the paced window's work (Wayland, where no loop of the system draws a window being sized). At rest, it is not.
@(test)
another_window_s_resize_step_comes_first :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	a, b := new(host.Host), new(host.Host)
	defer { free(a); free(b) }
	open_main(t, &sh, a, &p)
	defer host.host_close(a)
	w := platform.open_window_offscreen("host test step", SIZE)
	if !testing.expect(t, w != nil) { return }
	host.host_adopt(b, &sh, w, probe_build, &p)   // (offscreen: drawn on the first window's target, no window opens)
	ui.init(&b.state, &sh.fonts, &sh.theme)
	ui.use(&a.state)
	defer host.host_close(b)
	ui.set_clock(&b.state, &p.clock)
	testing.expect(t, !b.paced, "only the first window is paced")
	step(a)
	step(b)
	testing.expect_value(t, b.shown, SIZE)
	a.before_input = proc(h: ^host.Host) { note(h, "a reads") }
	b.after_build = proc(h: ^host.Host) { note(h, "b step") }
	step(a)
	testing.expect_value(t, len(p.seen), 1)   // (b at rest: not drawn)
	clear(&p.seen)
	b.win.size = {SIZE.x + 40, SIZE.y}
	step(a)
	testing.expect_value(t, len(p.seen), 2)
	if len(p.seen) == 2 {
		testing.expect_value(t, p.seen[0], "b step")
		testing.expect_value(t, p.seen[1], "a reads")
	}
	testing.expect_value(t, b.shown, b.win.size)
	testing.expect_value(t, ui.now_ms(), p.clock)   // (the first window's interface is current again)
}

_ :: render

// A close asked of a window whose program decides: the window stays open, its frames go on, the program is told once and
// the interface never sees the Close.
@(test)
a_close_asked_leaves_the_window_to_the_program :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	h := new(host.Host)
	defer free(h)
	open_main(t, &sh, h, &p)
	defer host.host_close(h)
	h.close_asked = proc(h: ^host.Host) { note(h, "close_asked") }
	h.input = proc(h: ^host.Host, e: []platform.Event) -> []platform.Event {
		for ev in e { if ev.kind == .Close { note(h, "close seen") } }
		return e
	}
	step(h)
	platform.inject_event(h.win, {kind = .Close})
	step(h)
	testing.expect(t, !platform.is_closed(h.win), "still open")
	asked, seen := 0, 0
	for s in p.seen { if s == "close_asked" { asked += 1 }; if s == "close seen" { seen += 1 } }
	testing.expect_value(t, asked, 1)
	testing.expect_value(t, seen, 0)
	built := p.builds
	step(h)
	testing.expect(t, p.builds > built, "its frames go on")
}

// The ring keeps the last FRAME_RING pictures and says their median and 95th percentile; the share of pixels drawn counts
// only the pictures drawn with partial redraw on.
@(test)
the_frame_ring_says_its_percentiles :: proc(t: ^testing.T) {
	ring: host.Frame_Ring
	testing.expect_value(t, host.frame_stats(&ring).frames, 0)
	for i in 0 ..< host.FRAME_RING + 28 {
		// (the first 28 are overwritten: their 1000 ms never shows)
		ms := f32(i < 28 ? 1000 : i - 28)
		ring.slots[ring.count % host.FRAME_RING] = {build_ms = ms, draw_ms = 1, px_drawn = 25, px_window = 100}
		ring.count += 1
	}
	s := host.frame_stats(&ring)
	testing.expect_value(t, s.frames, host.FRAME_RING)
	testing.expect_value(t, s.build_p50, f32(host.FRAME_RING / 2))
	testing.expect(t, s.build_p95 < 1000, "an overwritten picture still counts")
	testing.expect_value(t, s.draw_p95, f32(1))
	testing.expect_value(t, s.total_p50, f32(host.FRAME_RING / 2 + 1))
	testing.expect_value(t, s.drawn_share, f32(0.25))
}
