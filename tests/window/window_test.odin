// Windows and their messages, without a person at the mouse: the window procedure is fed the messages the system would
// send (SendMessage / PostMessage), the results are read from the windows' event lists. Needs a desktop session (the
// repaint tests show a small window without activating it).
//   odin test tests/window -vet
package window_test

import "core:strings"
import "core:thread"
import "core:testing"
import "core:time"
import win "core:sys/windows"
import "../../base"
import "../../platform"
import "../../render"

// Long enough for a timer of a modal loop (16 ms) to fire, had it been set.
WINDOW_SIZE :: [2]int{320, 240}
CAPTURE_WAIT :: 60 * time.Second   // only ends a failing run: WARP on a CI runner takes its time
NO_TIMER_MS :: 100
MODAL_LOOP_MS :: 200
PUMP_WAIT_MS :: 2

xy :: proc(x, y: int) -> win.LPARAM { return win.LPARAM(uintptr(u32(u16(x)) | u32(u16(y)) << 16)) }

// The mouse stays captured until the last button is up, and a capture lost with a button down makes its release.
@(test)
capture_follows_the_buttons :: proc(t: ^testing.T) {
	w := platform.open_window("capture test", {200, 150})
	defer platform.destroy_window(w)
	h := w.hwnd
	win.SendMessageW(h, win.WM_LBUTTONDOWN, 0, xy(10, 10))
	win.SendMessageW(h, win.WM_RBUTTONDOWN, 0, xy(10, 10))
	win.SendMessageW(h, win.WM_RBUTTONUP, 0, xy(10, 10))
	testing.expect(t, win.GetCapture() == h, "the left button is still down: the capture stays")
	testing.expect_value(t, len(w.events), 3)
	// the capture goes elsewhere (Alt+Tab, a dialog): the release of the left button never comes to this window
	win.ReleaseCapture()
	testing.expect_value(t, len(w.events), 4)
	if len(w.events) == 4 {
		testing.expect(t, w.events[3].kind == .Mouse_Release && w.events[3].button == .Left, "the lost press is released")
	}
	// the usual way: press, release, capture given back, and nothing extra
	clear(&w.events)
	win.SendMessageW(h, win.WM_LBUTTONDOWN, 0, xy(10, 10))
	testing.expect(t, win.GetCapture() == h)
	win.SendMessageW(h, win.WM_LBUTTONUP, 0, xy(10, 10))
	testing.expect(t, win.GetCapture() != h)
	testing.expect_value(t, len(w.events), 2)
}

// Two windows of one thread: the poll of one takes the messages of both, and neither loses events it has not read.
@(test)
polls_keep_the_events_of_other_windows :: proc(t: ^testing.T) {
	a := platform.open_window("a", {200, 150})
	defer platform.destroy_window(a)
	b := platform.open_window("b", {200, 150})
	defer platform.destroy_window(b)
	win.PostMessageW(b.hwnd, win.WM_KEYDOWN, win.WPARAM('B'), 0)
	testing.expect_value(t, len(platform.poll_events(a, false)), 0)
	evs := platform.poll_events(b, false)
	testing.expect_value(t, count_key(evs, .B), 1)
	win.PostMessageW(b.hwnd, win.WM_KEYDOWN, win.WPARAM('C'), 0)
	testing.expect_value(t, len(platform.poll_events(a, false)), 0)
	evs = platform.poll_events(b, false)   // the first key was read: only the second is returned
	testing.expect_value(t, count_key(evs, .B), 0)
	testing.expect_value(t, count_key(evs, .C), 1)
	testing.expect_value(t, len(platform.poll_events(b, false)), 0)
}

count_key :: proc(evs: []platform.Event, k: platform.Key) -> (n: int) {
	for e in evs { if e.kind == .Key_Press && e.key == k { n += 1 } }
	return
}

// A Close event handed to inject_event ends a loop that tests is_closed, as the system's does.
@(test)
injected_close_closes_the_window :: proc(t: ^testing.T) {
	w := platform.open_window("inject", {200, 150})
	defer platform.destroy_window(w)
	testing.expect(t, !platform.is_closed(w))
	platform.inject_event(w, {kind = .Close})
	evs := platform.poll_events(w, false)
	testing.expect_value(t, len(evs), 1)
	testing.expect(t, platform.is_closed(w))
	testing.expect(t, len(evs) == 1 && evs[0].injected, "an injected event says so (the real pointer is elsewhere)")
}

// %APPDATA% longer than MAX_PATH (a roaming profile on a deep UNC path) is read whole, not sliced out of bounds.
@(test)
config_dir_with_a_long_path :: proc(t: ^testing.T) {
	name := win.utf8_to_wstring("APPDATA", context.temp_allocator)
	old: [win.MAX_PATH]u16
	n := win.GetEnvironmentVariableW(name, &old[0], len(old))
	defer if n > 0 && int(n) < len(old) { win.SetEnvironmentVariableW(name, win.wstring(&old[0])) }
	long := strings.concatenate({"C:\\", strings.repeat("a123456789\\", 30, context.temp_allocator)}, context.temp_allocator)   // 333 characters
	win.SetEnvironmentVariableW(name, win.utf8_to_wstring(long, context.temp_allocator))
	dir := platform.config_dir(context.temp_allocator)
	testing.expect_value(t, dir, long)
}

Frames :: struct { n: int }

on_frame :: proc(user: rawptr) { (^Frames)(user).n += 1 }

// The path of a real window's frames, on its real swap chain: a composition one, with its surface of the monitor's size, a resize, what the frame is read back as.
@(test)
a_real_window_shows_its_frames :: proc(t: ^testing.T) {
	w := platform.open_window("frames", WINDOW_SIZE, transparent = true)
	defer platform.destroy_window(w)
	r := new(render.Renderer)
	defer free(r)
	if !testing.expect(t, render.init_window(r, w, w.size, transparent = true), "a renderer on the window") { return }
	defer render.destroy(r)
	testing.expect(t, !render.is_offscreen(r), "a swap chain")
	testing.expect(t, render.is_transparent(r), "a composition one")
	testing.expect_value(t, render.backend_name(), render.RENDER_BACKEND)
	testing.expect(t, render.renderer_id(r) != 0, "an id")
	render.set_fixed_surface(r, platform.monitor_size(w))
	win.ShowWindow(w.hwnd, win.SW_SHOWNOACTIVATE)
	settle(w)
	read :: proc(t: ^testing.T, r: ^render.Renderer) -> (px: []u8, size: [2]int) {
		testing.expect(t, render.capture_request(r), "a capture")
		render.frame_begin(r, {1, 0, 0, 1})
		render.frame_end(r, false)
		last := render.Capture_Status.None
		start := time.tick_now()
		for time.tick_since(start) < CAPTURE_WAIT {
			got, sz, st := render.capture_poll(r, context.temp_allocator)
			last = st
			if st == .Ready { return got, sz }
			if st != .Pending { break }
			thread.yield()
		}
		testing.expectf(t, false, "the capture came back (status %v, %s)", last, render.backend_name())
		return
	}
	px, size := read(t, r)
	testing.expect_value(t, size, w.size)
	if len(px) >= 4 { testing.expect_value(t, [4]u8{px[0], px[1], px[2], px[3]}, [4]u8{255, 0, 0, 255}) }
	// a resize: the frame is the window's new size, cut, never stretched
	platform.set_size(w, WINDOW_SIZE * 2)
	settle(w)
	render.resize(r, w.size)
	testing.expect_value(t, r.size, w.size)
	_, size = read(t, r)
	testing.expect_value(t, size, w.size)
}

// Every message there is has been handled (a repaint is one, as soon as nothing else is queued).
settle :: proc(w: ^platform.Window) {
	for {
		platform.poll_events(w, false)
		if win.HIWORD(win.GetQueueStatus(win.QS_ALLINPUT)) == 0 { return }
	}
}

// This long of the real clock, messages handled: for what must come by a timer, and for what must not come at all.
pump :: proc(w: ^platform.Window, ms: int) {
	until := time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
	for time.tick_diff(time.tick_now(), until) > 0 {
		platform.poll_events(w, true, PUMP_WAIT_MS)
	}
}

// A window that nobody polls is repainted by the poll of another window of the thread: its frame must not run inside
// that poll (the app's own frame is being built there). It asks for the frame (take_paint_request) like a polled window.
@(test)
repaint_of_an_unpolled_window_waits_for_its_owner :: proc(t: ^testing.T) {
	fr: Frames
	a := platform.open_window("a", {200, 150})
	defer platform.destroy_window(a)
	x := platform.open_window("x", {200, 150}, &fr, on_frame)
	defer platform.destroy_window(x)
	win.ShowWindow(x.hwnd, win.SW_SHOWNOACTIVATE)
	settle(a)   // the first repaints
	platform.take_paint_request(x)
	fr.n = 0
	win.InvalidateRect(x.hwnd, nil, false)
	settle(a)
	testing.expect_value(t, fr.n, 0)
	testing.expect(t, platform.take_paint_request(x), "the repaint is asked for")
}

// WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE that do not come from a loop of the system (AltSnap posts them around the moves it
// makes from its own process) open no modal mode: no timer, no frame from the window procedure. The decision itself is
// tested in tests/size_move; a real loop needs the mouse.
@(test)
size_move_messages_from_outside_are_ignored :: proc(t: ^testing.T) {
	fr: Frames
	a := platform.open_window("a", {200, 150})
	defer platform.destroy_window(a)
	x := platform.open_window("x", {200, 150}, &fr, on_frame)
	defer platform.destroy_window(x)
	win.ShowWindow(x.hwnd, win.SW_SHOWNOACTIVATE)
	settle(a)
	platform.take_paint_request(x)
	fr.n = 0
	win.PostMessageW(x.hwnd, win.WM_ENTERSIZEMOVE, 0, 0)
	win.SendMessageW(x.hwnd, win.WM_ENTERSIZEMOVE, 0, 0)
	pump(a, NO_TIMER_MS)
	testing.expect_value(t, fr.n, 0)
	win.PostMessageW(x.hwnd, win.WM_EXITSIZEMOVE, 0, 0)
	settle(a)
	stats := platform.pump_stats(x)
	testing.expect_value(t, stats.modal_loops, 0)
	testing.expect_value(t, stats.ignored_size_moves, 3)
}

// A menu (the system's modal loop) makes no repaint of its own on a compositor: a timer keeps the frames coming.
@(test)
frames_come_during_a_modal_loop :: proc(t: ^testing.T) {
	fr: Frames
	a := platform.open_window("a", {200, 150})
	defer platform.destroy_window(a)
	x := platform.open_window("x", {200, 150}, &fr, on_frame)
	defer platform.destroy_window(x)
	win.ShowWindow(x.hwnd, win.SW_SHOWNOACTIVATE)
	settle(a)
	platform.take_paint_request(x)
	fr.n = 0
	win.SendMessageW(x.hwnd, win.WM_ENTERMENULOOP, 0, 0)
	pump(a, MODAL_LOOP_MS)
	if !base.perf_skip("frames in a modal loop") { testing.expectf(t, fr.n >= 3, "%d frames in 200 ms of a modal loop", fr.n) }
	win.SendMessageW(x.hwnd, win.WM_EXITMENULOOP, 0, 0)
	n := fr.n
	pump(a, NO_TIMER_MS)
	testing.expect_value(t, fr.n, n)
}
