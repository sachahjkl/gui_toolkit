// Windows and their messages, without a person at the mouse: the window procedure is fed the messages the system would
// send (SendMessage / PostMessage), the results are read from the windows' event lists. Needs a desktop session (the
// repaint tests show a small window without activating it).
//   odin test tests/window -vet
package window_test

import "core:testing"
import "core:time"
import win "core:sys/windows"
import "../../platform"

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

Frames :: struct { n: int }

on_frame :: proc(user: rawptr) { (^Frames)(user).n += 1 }

pump :: proc(w: ^platform.Window, ms: int) {
	until := time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
	for time.tick_diff(time.tick_now(), until) > 0 {
		platform.poll_events(w, false)
		time.sleep(2 * time.Millisecond)
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
	pump(a, 50)   // the first repaints
	platform.take_paint_request(x)
	fr.n = 0
	win.InvalidateRect(x.hwnd, nil, false)
	pump(a, 50)
	testing.expect_value(t, fr.n, 0)
	testing.expect(t, platform.take_paint_request(x), "the repaint is asked for")
}

// A move or a menu (the system's modal loop) makes no repaint of its own on a compositor: a timer keeps the frames coming.
@(test)
frames_come_during_a_modal_loop :: proc(t: ^testing.T) {
	fr: Frames
	a := platform.open_window("a", {200, 150})
	defer platform.destroy_window(a)
	x := platform.open_window("x", {200, 150}, &fr, on_frame)
	defer platform.destroy_window(x)
	win.ShowWindow(x.hwnd, win.SW_SHOWNOACTIVATE)
	pump(a, 50)
	platform.take_paint_request(x)
	fr.n = 0
	win.SendMessageW(x.hwnd, win.WM_ENTERSIZEMOVE, 0, 0)
	pump(a, 200)
	testing.expectf(t, fr.n >= 3, "%d frames in 200 ms of a modal loop", fr.n)
	win.SendMessageW(x.hwnd, win.WM_EXITSIZEMOVE, 0, 0)
	n := fr.n
	pump(a, 100)
	testing.expect_value(t, fr.n, n)
}
