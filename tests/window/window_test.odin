// Windows and their messages, without a person at the mouse: the window procedure is fed the messages the system would
// send (SendMessage / PostMessage), the results are read from the windows' event lists. Needs a desktop session (the
// repaint tests show a small window without activating it).
//   odin test tests/window -vet
package window_test

import "core:os"
import "core:thread"
import "core:testing"
import "core:time"
import win "core:sys/windows"
import "../../src/base"
import "../../src/platform"
import "../../src/render"

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
		testing.expect(t, w.events[3].lost, "and says it is no real release")
	}
	// the usual way: press, release, capture given back, and nothing extra
	clear(&w.events)
	win.SendMessageW(h, win.WM_LBUTTONDOWN, 0, xy(10, 10))
	testing.expect(t, win.GetCapture() == h)
	win.SendMessageW(h, win.WM_LBUTTONUP, 0, xy(10, 10))
	testing.expect(t, win.GetCapture() != h)
	testing.expect_value(t, len(w.events), 2)
}

// A press outside the client area says so. (HTNOWHERE: on the caption the system would start moving the window, and wait.)
@(test)
a_press_on_the_frame_is_told :: proc(t: ^testing.T) {
	HTNOWHERE :: 0
	w := platform.open_window("frame press test", {200, 150})
	defer platform.destroy_window(w)
	clear(&w.events)
	for msg in ([?]u32{win.WM_NCLBUTTONDOWN, win.WM_NCRBUTTONDOWN, win.WM_NCMBUTTONDOWN}) {
		win.SendMessageW(w.hwnd, msg, HTNOWHERE, xy(10, 10))
	}
	n := 0
	for e in w.events { if e.kind == .Frame_Press { n += 1 } }
	testing.expect_value(t, n, 3)
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

// A release of a button pressed elsewhere says nothing, nor one that comes after a lost capture made it.
@(test)
a_release_comes_once_and_only_of_a_press :: proc(t: ^testing.T) {
	w := platform.open_window("release", {200, 150})
	defer platform.destroy_window(w)
	h := w.hwnd
	win.SendMessageW(h, win.WM_LBUTTONUP, 0, xy(10, 10))
	testing.expect_value(t, len(w.events), 0)
	win.SendMessageW(h, win.WM_LBUTTONDOWN, 0, xy(10, 10))
	win.ReleaseCapture()
	win.SendMessageW(h, win.WM_LBUTTONUP, 0, xy(10, 10))
	testing.expect_value(t, len(w.events), 2)
}

// What the pump left for the loop ends the wait: a wait does not sleep over a repaint asked for, nor over events kept.
@(test)
a_wait_does_not_sleep_over_what_is_left :: proc(t: ^testing.T) {
	w := platform.open_window("wait", {200, 150})
	defer platform.destroy_window(w)
	for len(platform.poll_events(w, false)) > 0 {}
	drain :: proc(w: ^platform.Window) {
		msg: win.MSG
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) { win.DispatchMessageW(&msg) }
	}
	drain(w)
	w.paint_requested = true
	start := time.tick_now()
	platform.wait_event(w, WAIT_THAT_ENDS_A_FAILING_RUN_MS)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < WAIT_THAT_ENDS_A_FAILING_RUN_MS / 2, "a repaint asked for")
	platform.take_paint_request(w)
	drain(w)
	win.SendMessageW(w.hwnd, win.WM_KEYDOWN, win.WPARAM('A'), 0)   // (queued by the window procedure, no message left)
	start = time.tick_now()
	platform.wait_event(w, WAIT_THAT_ENDS_A_FAILING_RUN_MS)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < WAIT_THAT_ENDS_A_FAILING_RUN_MS / 2, "an event not handed out")
}

WAIT_THAT_ENDS_A_FAILING_RUN_MS :: 2000

// A batch stays whole while the app reads it, whatever comes meanwhile: a drag or a paste run from an event pump the system.
@(test)
a_batch_outlives_what_comes_while_it_is_read :: proc(t: ^testing.T) {
	w := platform.open_window_offscreen("batch", {16, 16})
	defer platform.destroy_window(w)
	platform.inject_event(w, {kind = .Key_Press, key = .A})
	evs := platform.poll_events(w, false)
	testing.expect_value(t, len(evs), 1)
	for _ in 0 ..< 1000 { append(&w.events, platform.Event{kind = .Mouse_Move}) }   // (as a window procedure does)
	testing.expect_value(t, evs[0].key, platform.Key.A)
	testing.expect(t, raw_data(evs) != raw_data(w.events[:]), "the batch is not the queue the system appends to")
}

// A high surrogate pairs with the low one right after it, or with nothing: not with one that comes later.
@(test)
a_lone_surrogate_pairs_with_nothing :: proc(t: ^testing.T) {
	w := platform.open_window("surrogate", {200, 150})
	defer platform.destroy_window(w)
	h := w.hwnd
	win.SendMessageW(h, win.WM_CHAR, 0xD83D, 0)
	win.SendMessageW(h, win.WM_CHAR, win.WPARAM('a'), 0)
	win.SendMessageW(h, win.WM_CHAR, 0xDE00, 0)
	testing.expect_value(t, len(w.events), 1)
	if len(w.events) == 1 { testing.expect_value(t, w.events[0].text, 'a') }
	clear(&w.events)
	win.SendMessageW(h, win.WM_CHAR, 0xD83D, 0)
	win.SendMessageW(h, win.WM_CHAR, 0xDE00, 0)
	testing.expect_value(t, len(w.events), 1)
	if len(w.events) == 1 { testing.expect_value(t, w.events[0].text, '\U0001F600') }
}

// The focus goes with a key held: its release goes elsewhere, it is made here. And a window not shown has no focus.
@(test)
a_key_held_when_the_focus_goes_is_released :: proc(t: ^testing.T) {
	w := platform.open_window("keys", {200, 150})
	defer platform.destroy_window(w)
	testing.expect(t, !w.focused && !w.active, "nothing gave it the focus")
	h := w.hwnd
	win.SendMessageW(h, win.WM_KEYDOWN, win.WPARAM('A'), 0)
	win.SendMessageW(h, win.WM_KILLFOCUS, 0, 0)
	testing.expect_value(t, len(w.events), 2)
	if len(w.events) == 2 { testing.expect(t, w.events[1].kind == .Key_Release && w.events[1].key == .A, "the release") }
	win.SendMessageW(h, win.WM_KEYUP, win.WPARAM('A'), 0)
	testing.expect_value(t, len(w.events), 2)
}

// An emulated window keeps a state a full screen left alone; a placement restores a maximized one.
@(test)
an_offscreen_state_is_left_as_it_is :: proc(t: ^testing.T) {
	w := platform.open_window_offscreen("state", {16, 16})
	defer platform.destroy_window(w)
	platform.toggle_maximize(w)
	platform.set_fullscreen(w, false)
	testing.expect(t, platform.is_maximized(w), "it was not full screen: nothing to leave")
	p := platform.get_placement(w)
	p.maximized = false
	platform.set_placement(w, p)
	testing.expect(t, !platform.is_maximized(w))
}

// A placement on a window on the screen applies at once: nothing else will read it.
@(test)
a_placement_reaches_a_shown_window :: proc(t: ^testing.T) {
	w := platform.open_window("placement", {200, 150})
	defer platform.destroy_window(w)
	platform.show_window(w)
	p := platform.get_placement(w)
	p.maximized = true
	platform.set_placement(w, p)
	testing.expect(t, platform.is_maximized(w))
	p.maximized = false
	platform.set_placement(w, p)
	testing.expect(t, !platform.is_maximized(w))
}

// With an offscreen window open, a real window's clipboard_changed goes on reading the system's clipboard.
@(test)
a_real_window_reads_the_clipboard_of_the_system :: proc(t: ^testing.T) {
	w := platform.open_window("real", {200, 150})
	defer platform.destroy_window(w)
	o := platform.open_window_offscreen("other", {16, 16})
	defer platform.destroy_window(o)
	platform.clipboard_changed(w)
	platform.set_clipboard(w, "from the real window")   // (the system's)
	testing.expect(t, platform.clipboard_changed(w), "the system's clipboard changed")
}

// A Close is the app's to answer: taken back, the window is open.
@(test)
a_close_can_be_taken_back :: proc(t: ^testing.T) {
	w := platform.open_window_offscreen("veto", {16, 16})
	defer platform.destroy_window(w)
	platform.request_close(w)
	platform.poll_events(w, false)
	testing.expect(t, platform.is_closed(w))
	platform.cancel_close(w)
	testing.expect(t, !platform.is_closed(w))
}

// A program's folders on Windows: the configuration in %APPDATA%, the rest in %LOCALAPPDATA%, the state and the cache each in a
// folder of their own there; a variable that is not an absolute path is not taken (the known folder is).
@(test)
a_program_s_folders_on_windows :: proc(t: ^testing.T) {
	old_roaming, had_roaming := os.lookup_env("APPDATA", context.temp_allocator)
	old_local, had_local := os.lookup_env("LOCALAPPDATA", context.temp_allocator)
	defer {
		if had_roaming { os.set_env("APPDATA", old_roaming) }
		if had_local { os.set_env("LOCALAPPDATA", old_local) }
	}
	os.set_env("APPDATA", "C:\\roaming")
	os.set_env("LOCALAPPDATA", "C:\\local")
	testing.expect_value(t, platform.user_dir(.Config, "prog", context.temp_allocator), "C:\\roaming\\prog")
	testing.expect_value(t, platform.user_dir(.Data, "prog", context.temp_allocator), "C:\\local\\prog")
	testing.expect_value(t, platform.user_dir(.State, "prog", context.temp_allocator), "C:\\local\\prog\\state")
	testing.expect_value(t, platform.user_dir(.Cache, "prog", context.temp_allocator), "C:\\local\\prog\\cache")
	os.set_env("APPDATA", "relative")
	known := platform.user_dir(.Config, "", context.temp_allocator)
	testing.expect(t, known != "" && known != "relative", "the known folder")
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
