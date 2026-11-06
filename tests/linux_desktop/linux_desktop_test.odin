#+build linux
// The Linux backends against real servers, on a virtual desktop that tools/linux_desktop.sh starts: X11 under Xvfb and a
// window manager (openbox), Wayland under a headless compositor (sway). The input comes from the servers' own test
// devices (xdotool's XTEST, swaymsg's seat cursor, wtype), the other programs on the clipboard are xclip and wl-clipboard.
// One test at a time: the tests share the process's connection to the server.
//   tools/linux_desktop.sh [odin]
//   GUI_TEST_DESKTOP=x11|wayland, set by the script; without it every test passes without doing anything: nothing here
//   may ever reach a person's desktop.
package linux_desktop_test

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "../../platform"

@(private = "file") desktop :: proc() -> string {
	v := posix.getenv("GUI_TEST_DESKTOP")
	return v != nil ? string(v) : ""
}

@(private = "file") x11 :: proc() -> bool { return desktop() == "x11" }
@(private = "file") wayland :: proc() -> bool { return desktop() == "wayland" }

// Runs a shell command; a trailing & leaves it running while the test pumps its window.
@(private = "file")
sh :: proc(args: ..any) -> int {
	cmd := fmt.tprint(..args, sep = "")
	return int(libc.system(strings.clone_to_cstring(cmd, context.temp_allocator)))
}

@(private = "file")
open :: proc(title: string, size := [2]int{300, 200}) -> ^platform.Window {
	w := platform.open_window(title, size)
	if w == nil { return nil }
	platform.show_window(w)
	platform.test_show_plain(w)
	if x11() {
		// managed by the window manager, its frame placed: until then a press may land anywhere
		sh("for i in $(seq 100); do xprop -id ", window_id(w), " WM_STATE 2>/dev/null | grep -q Normal && break; sleep 0.05; done; xdotool windowactivate --sync ", window_id(w), " 2>/dev/null")
	}
	pump_for(w, 150)
	// the size of its tile now, on Wayland: a smaller picture would sit in the middle of the tile, away from the pointer
	if wayland() {
		for i := 0; i < 100 && w.size == size; i += 1 { pump_for(w, 10) }   // (a compositor still closing other windows answers late)
		platform.test_show_plain(w)
		pump_for(w, 150)
	}
	return w
}

@(private = "file") window_id :: proc(w: ^platform.Window) -> u64 { return platform.native_surface_handles(w).window }

// The events of a pumped window, kept: each poll hands out a slice valid until the next.
// How long a pump waits for the server each time round.
@(private = "file") PUMP_WAIT_MS :: 5
@(private = "file") SERVER_SENDS_CLICK :: 200 * time.Millisecond

@(private = "file")
Seen :: struct { events: [dynamic]platform.Event }

@(private = "file")
pump_for :: proc(w: ^platform.Window, ms: int, seen: ^Seen = nil) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) {
		for e in platform.poll_events(w, true, PUMP_WAIT_MS) { if seen != nil { append(&seen.events, e) } }
	}
}

// Pumps until `done` says so; false after `ms`.
@(private = "file")
pump_until :: proc(w: ^platform.Window, ms: int, seen: ^Seen, data: rawptr, done: proc(s: ^Seen, data: rawptr) -> bool) -> bool {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) {
		for e in platform.poll_events(w, true, PUMP_WAIT_MS) { if seen != nil { append(&seen.events, e) } }
		if done(seen, data) { return true }
	}
	return false
}

@(private = "file")
has_kind :: proc(s: ^Seen, data: rawptr) -> bool {
	k := (^platform.Event_Kind)(data)^
	for e in s.events { if e.kind == k { return true } }
	return false
}

@(private = "file")
wait_kind :: proc(w: ^platform.Window, s: ^Seen, kind: platform.Event_Kind, ms := 5000) -> bool {
	kind := kind
	return pump_until(w, ms, s, &kind, has_kind)
}

// Waits for the file a background command writes, pumping the window (it may have to serve the command).
@(private = "file")
wait_file :: proc(w: ^platform.Window, path: string, ms := 8000) -> (string, bool) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) {
		platform.poll_events(w, true, PUMP_WAIT_MS)
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil { return string(data), true }
	}
	return "", false
}

@(private = "file")
reset_files :: proc() { sh("rm -f /tmp/gt_out /tmp/gt_out.tmp") }

// Writes to the file whole, for wait_file: the output of `cmd`.
@(private = "file")
capture_in_background :: proc(cmd: string) { sh("(", cmd, " > /tmp/gt_out.tmp; mv /tmp/gt_out.tmp /tmp/gt_out) &") }

////////////////////////////////
// a window, its input

@(test)
keys_and_pointer_reach_the_window :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("input")
	testing.expect(t, w != nil, "the window opens")
	if w == nil { return }
	defer platform.destroy_window(w)
	seen: Seen
	defer delete(seen.events)
	if x11() {
		id := window_id(w)
		sh("xdotool windowactivate --sync ", id, " mousemove --window ", id, " 50 40 click 1 key a")
	} else {
		// the window fills the tile; the seat's cursor moves on the output, the keyboard is a virtual one
		sh("swaymsg -q seat seat0 cursor set 60 60; sleep 0.5; swaymsg -q seat seat0 cursor press button1; sleep 0.1; swaymsg -q seat seat0 cursor release button1; sleep 0.2; wtype a")
	}
	testing.expect(t, wait_kind(w, &seen, .Mouse_Release), "press and release arrive with poll_events(w, false) only")
	testing.expect(t, wait_kind(w, &seen, .Text), "typed text arrives")
	for e in seen.events {
		if e.kind == .Mouse_Press && x11() { testing.expect_value(t, e.pos, [2]f32{50, 40}) }
		if e.kind == .Mouse_Press { testing.expect_value(t, e.button, platform.Mouse_Button.Left) }
		if e.kind == .Key_Press { testing.expect_value(t, e.key, platform.Key.A) }
		if e.kind == .Text { testing.expect_value(t, e.text, 'a') }
	}
}

// The window is shown; a click before any motion, at a scale: the position on entering. (Scale 2 only on a scaled output.)
@(test)
wake_ends_a_waiting_poll :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("wake")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	pump_for(w, 200)
	platform.wake(w)
	start := time.tick_now()
	platform.poll_events(w, true, 5000)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 2000, "wake ends the wait")
	// and it is consumed: the next wait takes its whole time
	start = time.tick_now()
	platform.poll_events(w, true, 300)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) >= 250, "a wake counts once")
}

// An event read from the socket behind a reply is queued inside xcb: poll(2) does not see it, a wait must not sleep over it.
@(test)
a_wait_does_not_sleep_over_what_xcb_read :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("queued")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	pump_for(w, 200)
	id := window_id(w)
	sh("xdotool windowactivate --sync ", id, " mousemove --window ", id, " 20 20 click 1")
	time.sleep(SERVER_SENDS_CLICK)   // (real time: the click is on its way to the socket, and reading it is what this test is about)
	platform.display_invalidate(w)
	platform.display_info(w)   // (requests and replies: the click is read with them, and stays in xcb's queue)
	start := time.tick_now()
	evs := platform.poll_events(w, true, 3000)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 1000, "the wait ends at once")
	testing.expect(t, len(evs) > 0)
}

@(test)
the_refresh_rate_is_the_servers :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("rate")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	d := platform.display_info(w)
	fmt.println("display:", d.hz, d.max_hz, d.source, d.numerator, d.denominator)
	testing.expect(t, d.hz > 0)
	testing.expect(t, d.max_hz >= d.hz)
	testing.expect(t, wayland() ? d.source == .Mode : d.source == .Default, "a virtual screen without a timing: the fallback, on Xvfb")
}

// Two monitors of a server with real modes (Xorg's dummy driver: the script sets GUI_TEST_RANDR): each window has the rate
// of the monitor it is on, and follows it.
@(test)
each_monitor_has_its_rate :: proc(t: ^testing.T) {
	if posix.getenv("GUI_TEST_RANDR") == nil { return }
	context.allocator = runtime.heap_allocator()
	w := platform.open_window("monitors", {200, 150})
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	platform.show_window(w)
	platform.move_window(w, 100, 100)
	pump_for(w, 300)
	left := platform.display_info(w)
	testing.expect_value(t, left.source, platform.Display_Source.Display_Config)
	testing.expect(t, abs(left.hz - 60) < 0.01, fmt.tprint("the left monitor:", left.hz))
	testing.expect(t, abs(left.max_hz - 144) < 0.01, fmt.tprint("its modes at this size go to:", left.max_hz))
	testing.expect_value(t, f64(left.numerator) / f64(left.denominator), left.hz)
	platform.move_window(w, 1400, 100)
	pump_for(w, 300)
	right := platform.display_info(w)
	testing.expect(t, abs(right.hz - 144) < 0.01, fmt.tprint("the right monitor:", right.hz))
	testing.expect(t, right.serial != left.serial, "the rate changed: the serial says so")
	// the mode changes under the window: the server's notice reads it again
	sh("xrandr --output DUMMY1 --mode m60")
	pump_for(w, 300)
	testing.expect(t, abs(platform.display_info(w).hz - 60) < 0.01, "the new mode of its monitor")
}

@(test)
a_modes_timing_gives_its_rate :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, dot: u32, h, v: u16, flags: u32, want: f64) {
		n, d, ok := platform.randr_mode_rate(dot, h, v, flags)
		testing.expect(t, ok)
		testing.expect(t, abs(f64(n) / f64(d) - want) < 0.01, fmt.tprint(n, "/", d))
	}
	check(t, 148_500_000, 2200, 1125, 0, 60)
	check(t, 148_500_000, 2200, 1125, 1 << 4, 120)    // interlaced: two fields per frame's time
	check(t, 148_500_000, 2200, 1125, 1 << 5, 30)     // double scan
	check(t, 593_406_592, 4400, 2250, 0, 59.94)
	_, _, ok := platform.randr_mode_rate(0, 0, 0, 0)   // a virtual screen says nothing
	testing.expect(t, !ok)
}

@(test)
the_monitor_under_a_point :: proc(t: ^testing.T) {
	rects := [][4]int{{0, 0, 1920, 1080}, {1920, 0, 2560, 1440}, {-1280, 200, 1280, 720}}
	testing.expect_value(t, platform.randr_monitor_at(rects, {100, 100}), 0)
	testing.expect_value(t, platform.randr_monitor_at(rects, {1920, 0}), 1)
	testing.expect_value(t, platform.randr_monitor_at(rects, {-1, 300}), 2)
	testing.expect_value(t, platform.randr_monitor_at(rects, {100, 5000}), -1)
}

////////////////////////////////
// the state the window manager decides

@(test)
the_window_managers_state_is_followed :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("state")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	id := window_id(w)
	sh("xdotool windowminimize --sync ", id)
	pump_for(w, 300)
	testing.expect(t, platform.is_minimized(w), "minimized by someone else")
	testing.expect(t, !platform.is_window_visible(w))
	sh("xdotool windowactivate --sync ", id)
	pump_for(w, 300)
	testing.expect(t, !platform.is_minimized(w), "restored by someone else")
	testing.expect(t, platform.is_window_visible(w))
	platform.toggle_maximize(w)
	pump_for(w, 300)
	testing.expect(t, platform.is_maximized(w))
	platform.toggle_maximize(w)
	pump_for(w, 300)
	testing.expect(t, !platform.is_maximized(w))
}

// A window under a frame, saved and restored: it stays. (The corner read is the frame's, the corner a move sets.)
@(test)
a_saved_placement_does_not_move_the_window :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()
	w := open("placement")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	platform.move_window(w, 200, 150)
	pump_for(w, 300)
	p := platform.get_placement(w)
	testing.expect_value(t, p.rect[0], 200)
	testing.expect_value(t, p.rect[1], 150)
	o := platform.client_origin(w)
	testing.expect(t, o.x >= 200 && o.y > 150, "the client area is inside the frame")
	for _ in 0 ..< 3 {
		platform.set_placement(w, p)
		pump_for(w, 200)
		testing.expect_value(t, platform.get_placement(w).rect, p.rect)
		testing.expect_value(t, platform.client_origin(w), o)
	}
}

////////////////////////////////
// the clipboard, with another program

@(private = "file") other_copy :: proc(mime, text: string) {
	if x11() {
		sh("printf '%s' '", text, "' | xclip -i -selection clipboard -t ", mime, " >/dev/null 2>&1")
	} else {
		sh("(printf '%s' '", text, "' | wl-copy -t ", mime, ") >/dev/null 2>&1")
	}
}

@(test)
our_clipboard_reaches_another_program :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("clip out")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	pump_for(w, 200)
	if wayland() { sh("swaymsg -q seat seat0 cursor set 60 60; wtype x"); pump_for(w, 300) }   // (a selection needs a serial)
	platform.set_clipboard(w, "from the toolkit")
	pump_for(w, 200)
	reset_files()
	capture_in_background(x11() ? "xclip -o -selection clipboard -t UTF8_STRING" : "wl-paste -n -t text/plain")
	got, ok := wait_file(w, "/tmp/gt_out")
	testing.expect(t, ok, "the other program answered")
	testing.expect_value(t, got, "from the toolkit")
	testing.expect_value(t, platform.get_clipboard(w, context.temp_allocator), "from the toolkit")

	// through the rich store too, with file names that need encoding
	platform.clipboard_set(w, {html = "<b>x</b>", files = {"/tmp/a b#c.txt"}})
	pump_for(w, 200)
	reset_files()
	capture_in_background(x11() ? "xclip -o -selection clipboard -t text/uri-list" : "wl-paste -n -t text/uri-list")
	uris, ok2 := wait_file(w, "/tmp/gt_out")
	testing.expect(t, ok2)
	testing.expect_value(t, strings.trim_space(uris), "file:///tmp/a%20b%23c.txt")
}

@(test)
a_large_clipboard_goes_out_whole :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("clip large")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	pump_for(w, 200)
	if wayland() { sh("swaymsg -q seat seat0 cursor set 60 60; wtype x"); pump_for(w, 300) }
	big := strings.repeat("0123456789abcdef", 64 * 1024, context.temp_allocator)   // 1 MiB: INCR on X11
	platform.set_clipboard(w, big)
	pump_for(w, 200)
	reset_files()
	capture_in_background(x11() ? "xclip -o -selection clipboard -t UTF8_STRING | wc -c" : "wl-paste -n -t text/plain | wc -c")
	got, ok := wait_file(w, "/tmp/gt_out", 20000)
	testing.expect(t, ok)
	testing.expect_value(t, strings.trim_space(got), fmt.tprint(len(big)))
}

@(test)
another_programs_clipboard_is_read_and_seen :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("clip in")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	pump_for(w, 300)
	platform.clipboard_changed(w)
	testing.expect(t, !platform.clipboard_changed(w))
	other_copy("text/html", "<i>y</i>")
	pump_for(w, 500)
	testing.expect(t, platform.clipboard_changed(w), "another program took the clipboard")
	testing.expect(t, !platform.clipboard_changed(w), "told once")
	testing.expect(t, .Html in platform.clipboard_formats(), "what the other program offers")
	html, _, ok := platform.clipboard_get_html(w, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, html, "<i>y</i>")

	other_copy("text/plain", "plain text")
	pump_for(w, 500)
	testing.expect(t, platform.clipboard_changed(w), "from one program to another: seen too")
	testing.expect(t, .Text in platform.clipboard_formats())
	testing.expect_value(t, platform.get_clipboard(w, context.temp_allocator), "plain text")
}

@(test)
a_large_clipboard_comes_in_whole :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("clip in large")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	pump_for(w, 200)
	if x11() {
		sh("head -c 3000000 /dev/zero | tr '\\0' x | xclip -i -selection clipboard -t UTF8_STRING >/dev/null 2>&1")
	} else {
		sh("(head -c 3000000 /dev/zero | tr '\\0' x | wl-copy -t text/plain) >/dev/null 2>&1")
	}
	pump_for(w, 500)
	got := platform.get_clipboard(w, context.temp_allocator)
	testing.expect_value(t, len(got), 3000000)
}

////////////////////////////////
// a drag between two windows of one program

@(private = "file")
Drag_Result :: struct { effect: Maybe(platform.Drop_Effect), ok: bool }

@(private = "file")
drag_between :: proc(t: ^testing.T, a, b: ^platform.Window, data: platform.Drag_Data, image: Maybe(platform.Drag_Image), press, drop: string) -> Drag_Result {
	// the press is made first and seen by the window (a drag starts from a press); the move and the release come while
	// drag_start blocks
	seen: Seen
	defer delete(seen.events)
	sh(press)
	testing.expect(t, wait_kind(a, &seen, .Mouse_Press), "the press that starts the drag")
	sh("(sleep 0.4; ", drop, ") >/dev/null 2>&1 &")
	r: Drag_Result
	r.effect, r.ok = platform.drag_start(a, data, {.Copy, .Move}, image)
	return r
}

@(private = "file")
x11_place_side_by_side :: proc(a, b: ^platform.Window) {
	sh("xdotool windowmove --sync ", window_id(a), " 40 60 windowmove --sync ", window_id(b), " 500 60")
	pump_for(a, 200)
	pump_for(b, 200)
}

@(private = "file")
two_windows :: proc() -> (a, b: ^platform.Window) {
	a = open("drag a")
	b = open("drag b")
	platform.drop_target_enable(b, true)
	if x11() { x11_place_side_by_side(a, b) } else {
		pump_for(a, 300); pump_for(b, 300)
		platform.test_show_plain(a); platform.test_show_plain(b)   // (their tiles now: a smaller picture would sit in the middle of its tile)
		pump_for(a, 100); pump_for(b, 100)
	}
	return
}

// The screen's point in a window's area, on either desktop (sway tiles two windows left and right on its 1280 wide output).
@(private = "file") press_in_a :: proc(a: ^platform.Window) -> string {
	if x11() { return fmt.tprint("xdotool mousemove --window ", window_id(a), " 30 30 mousedown 1") }
	return "swaymsg -q seat seat0 cursor set 100 100; sleep 0.5; swaymsg -q seat seat0 cursor press button1"
}
@(private = "file") drop_in_b :: proc(b: ^platform.Window) -> string {
	if x11() { return fmt.tprint("xdotool mousemove --window ", window_id(b), " 70 90; sleep 0.2; xdotool mousemove --window ", window_id(b), " 80 95; sleep 0.3; xdotool mouseup 1") }
	return "swaymsg -q seat seat0 cursor set 900 200; sleep 0.2; swaymsg -q seat seat0 cursor set 910 210; sleep 0.3; swaymsg -q seat seat0 cursor release button1"
}

@(test)
a_drag_goes_from_one_window_to_another :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a, b := two_windows()
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil { return }
	defer { platform.destroy_window(a); platform.destroy_window(b) }

	data: platform.Drag_Data
	data.text = "dragged"
	data.html = "<b>dragged</b>"
	append(&data.custom, platform.Drag_Entry{"application/x-gui-toolkit-test", "own format"})
	defer delete(data.custom)
	pixels := make([]u8, 16 * 16 * 4)
	defer delete(pixels)
	for i in 0 ..< len(pixels) { pixels[i] = 200 }
	// on X11 the picture is a window of ours, and it must be on the screen under the drag
	sh("rm -f /tmp/gt_tree; (sleep 0.8; xwininfo -root -tree > /tmp/gt_tree.tmp 2>/dev/null; mv /tmp/gt_tree.tmp /tmp/gt_tree) >/dev/null 2>&1 &")
	r := drag_between(t, a, b, data, platform.Drag_Image{pixels, {16, 16}, {4, 4}}, press_in_a(a), drop_in_b(b))
	if x11() {
		tree, got := wait_file(a, "/tmp/gt_tree")
		testing.expect(t, got && strings.contains(tree, "16x16+"), "the picture's window was on the screen")
	}
	testing.expect(t, r.ok, "the drag ran")
	testing.expect_value(t, r.effect, Maybe(platform.Drop_Effect)(.Copy))

	seen: Seen
	defer delete(seen.events)
	pump_for(b, 300, &seen)
	enters, overs, drops := 0, 0, 0
	drop_pos: [2]f32
	for e in seen.events {
		#partial switch e.kind {
		case .Drop_Enter: enters += 1
		case .Drop_Over: overs += 1
		case .Drop: drops += 1; drop_pos = e.pos
		}
	}
	testing.expect_value(t, enters, 1)
	testing.expect(t, overs >= 1)
	testing.expect_value(t, drops, 1)
	if x11() { testing.expect_value(t, drop_pos, [2]f32{80, 95}) }   // client pixels of the target, under a frame
	d := platform.drop_data(b)
	testing.expect(t, d != nil)
	if d != nil {
		testing.expect_value(t, d.text, "dragged")
		testing.expect_value(t, d.html, "<b>dragged</b>")
		testing.expect_value(t, len(d.custom), 1)
		if len(d.custom) == 1 {
			testing.expect_value(t, d.custom[0].mime, "application/x-gui-toolkit-test")
			testing.expect_value(t, d.custom[0].data, "own format")
		}
	}

	// the press does not stay pressed
	seen_a: Seen
	defer delete(seen_a.events)
	pump_for(a, 300, &seen_a)
	testing.expect_value(t, a.buttons_down, platform.Mouse_Buttons{})
	size, offset, held := platform.drag_image_held(a)
	testing.expect(t, held, "the source shows its picture")
	testing.expect_value(t, size, [2]int{16, 16})
	testing.expect_value(t, offset, [2]int{4, 4})
	platform.drop_data_release(b)
}

// A drop on the window it started from: this thread both serves the data and reads it.
@(test)
a_drag_comes_back_to_its_window :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a := open("drag self")
	testing.expect(t, a != nil)
	if a == nil { return }
	defer platform.destroy_window(a)
	platform.drop_target_enable(a, true)
	pump_for(a, 300)
	data := platform.Drag_Data{text = "to myself"}
	back := x11() ? fmt.tprint("xdotool mousemove --window ", window_id(a), " 60 60; sleep 0.2; xdotool mousemove --window ", window_id(a), " 70 70; sleep 0.3; xdotool mouseup 1") : "swaymsg -q seat seat0 cursor set 120 120; sleep 0.2; swaymsg -q seat seat0 cursor set 130 130; sleep 0.3; swaymsg -q seat seat0 cursor release button1"
	r := drag_between(t, a, a, data, nil, press_in_a(a), back)
	testing.expect(t, r.ok)
	seen: Seen
	defer delete(seen.events)
	testing.expect(t, wait_kind(a, &seen, .Drop), "the drop came")
	if d := platform.drop_data(a); d != nil { testing.expect_value(t, d.text, "to myself") }
	platform.drop_data_release(a)
}

// A drag released over nothing, then: no effect of an earlier one.
@(test)
a_drag_released_over_nothing_has_no_effect :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a := open("drag nowhere")
	testing.expect(t, a != nil)
	if a == nil { return }
	defer platform.destroy_window(a)
	pump_for(a, 300)
	nowhere := x11() ? "xdotool mousemove 1200 900; sleep 0.2; xdotool mouseup 1" : "sleep 0.2; swaymsg -q seat seat0 cursor release button1"
	r := drag_between(t, a, a, platform.Drag_Data{text = "lost"}, nil, press_in_a(a), nowhere)
	testing.expect(t, r.ok)
	testing.expect_value(t, r.effect, Maybe(platform.Drop_Effect)(nil))
}

// XdndProxy: a window that is not aware itself but names one that is; the messages go through it and name the target.
@(test)
a_drag_follows_xdnd_proxy :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a, b := two_windows()
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil { return }
	defer { platform.destroy_window(a); platform.destroy_window(b) }
	platform.drop_target_enable(b, false)
	c := open("drag proxy")
	testing.expect(t, c != nil)
	if c == nil { return }
	defer platform.destroy_window(c)
	sh("xdotool windowmove --sync ", window_id(c), " 40 400")
	platform.drop_target_enable(c, true)
	pump_for(c, 200)
	sh("xprop -id ", window_id(b), " -f XdndProxy 32x -set XdndProxy ", window_id(c), " ; xprop -id ", window_id(c), " -f XdndProxy 32x -set XdndProxy ", window_id(c))
	data := platform.Drag_Data{text = "through a proxy"}
	r := drag_between(t, a, b, data, nil, press_in_a(a), drop_in_b(b))
	testing.expect(t, r.ok)
	testing.expect_value(t, r.effect, Maybe(platform.Drop_Effect)(.Copy))
	seen: Seen
	defer delete(seen.events)
	pump_for(b, 200, &seen)
	testing.expect(t, has_kind_of(&seen, .Drop), "the event names the target, not the proxy")
	if d := platform.drop_data(b); d != nil { testing.expect_value(t, d.text, "through a proxy") }
	platform.drop_data_release(b)
}

@(private = "file")
has_kind_of :: proc(s: ^Seen, k: platform.Event_Kind) -> bool {
	for e in s.events { if e.kind == k { return true } }
	return false
}

////////////////////////////////
// Wayland: what the client must do by itself

@(test)
a_held_key_repeats_on_wayland :: proc(t: ^testing.T) {
	if !wayland() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("repeat")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	pump_for(w, 300)
	sh("wtype -P b -s 1200 -p b >/dev/null 2>&1 &")   // (one process: its keyboard going away releases the key)
	seen: Seen
	defer delete(seen.events)
	pump_for(w, 1500, &seen)
	repeats, texts, releases := 0, 0, 0
	for e in seen.events {
		if e.kind == .Key_Press && e.key == .B && e.repeat { repeats += 1 }
		if e.kind == .Text && e.text == 'b' { texts += 1 }
		if e.kind == .Key_Release && e.key == .B { releases += 1 }
	}
	testing.expect(t, repeats >= 3, fmt.tprint("repeats:", repeats))
	testing.expect_value(t, texts, repeats + 1)
	testing.expect(t, releases >= 1)
}

////////////////////////////////
// spawning

// A program handed to the system leaves no zombie (GUI_TEST_XDG_OPEN_LOG: the fake xdg-open of the script writes here).
@(test)
open_url_leaves_no_zombie :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	sh("rm -f /tmp/gt_opened")
	testing.expect(t, platform.open_url("https://example.org/a b"))
	st: i32
	testing.expect(t, posix.waitpid(-1, &st, {.NOHANG}) == -1, "no child is left to reap")
	start := time.tick_now()
	got := ""
	for time.duration_milliseconds(time.tick_since(start)) < 3000 {
		if data, err := os.read_entire_file("/tmp/gt_opened", context.temp_allocator); err == nil && len(data) > 0 { got = string(data); break }
		thread.yield()
	}
	testing.expect_value(t, strings.trim_space(got), "https://example.org/a b")
}

// A cursor reaches the server: each shows another image over the window, the theme's or the cursor font's, and a custom one.
@(test)
cursors_change_on_x11 :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("cursors")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	id := window_id(w)
	sh("xdotool windowactivate --sync ", id, " mousemove --window ", id, " 50 40")
	pump_for(w, 150)
	shown :: proc(t: ^testing.T, w: ^platform.Window) -> u64 {
		pump_for(w, 100)
		s, ok := platform.cursor_on_screen(w)
		testing.expect(t, ok, "the server says what it shows (XFIXES)")
		return s
	}
	platform.set_cursor(w, .Hand)
	hand := shown(t, w)
	platform.set_cursor(w, .Text)
	text := shown(t, w)
	platform.set_cursor(w, .None)
	none := shown(t, w)
	testing.expect(t, hand != text, "a hand is not a text cursor")
	testing.expect(t, none != text && none != hand, "hidden is another image")
	platform.set_cursor(w, .Hand)
	testing.expect_value(t, shown(t, w), hand)   // made once
	pixels := make([]u8, 16 * 16 * 4)
	defer delete(pixels)
	for i := 0; i < len(pixels); i += 4 { pixels[i], pixels[i + 3] = 255, 255 }
	cc, err := platform.custom_cursor_create(w, pixels, {16, 16}, {8, 8})
	testing.expect_value(t, err, platform.Custom_Cursor_Error.None)
	platform.set_cursor_custom(w, cc, .Arrow)
	custom := shown(t, w)
	testing.expect(t, custom != hand && custom != text && custom != none, "a custom cursor is its own image")
	platform.custom_cursor_release(w, cc)
}

// A scale of 1.5: the surface asks for it (the wl_output integer would say 2), the buffer has that many pixels, and the
// pointer lands at it.
@(test)
a_fractional_scale_on_wayland :: proc(t: ^testing.T) {
	if !wayland() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("fractional")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	sh("swaymsg -q 'output * scale 1.5'")
	defer sh("swaymsg -q 'output * scale 1'")
	for i := 0; i < 200 && w.dpi_scale != 1.5; i += 1 { pump_for(w, 10) }
	testing.expect_value(t, w.dpi_scale, f32(1.5))
	platform.test_show_plain(w)
	pump_for(w, 200)
	seen: Seen
	defer delete(seen.events)
	sh("swaymsg -q seat seat0 cursor set 60 60; sleep 0.5; swaymsg -q seat seat0 cursor press button1; sleep 0.1; swaymsg -q seat seat0 cursor release button1")
	testing.expect(t, wait_kind(w, &seen, .Mouse_Press), "the press arrives")
	for e in seen.events {
		if e.kind == .Mouse_Press { testing.expectf(t, abs(e.pos.x - 90) <= 3 && abs(e.pos.y - 90) <= 3, "at the buffer's pixels: %v", e.pos) }
	}
}


////////////////////////////////
// how a drag ends

// Screen points in the second window, one after the other: a drag that goes on moving.
@(private = "file") moves_in_b :: proc(b: ^platform.Window, steps: int, pause: string) -> string {
	s := strings.builder_make(context.temp_allocator)
	for i in 0 ..< steps {
		if x11() {
			fmt.sbprint(&s, "xdotool mousemove --window ", window_id(b), " ", 60 + i * 2, " 90; sleep ", pause, "; ")
		} else {
			fmt.sbprint(&s, "swaymsg -q seat seat0 cursor set ", 900 + i * 2, " 200; sleep ", pause, "; ")
		}
	}
	return strings.to_string(s)
}
@(private = "file") release_drag :: proc() -> string { return x11() ? "xdotool mouseup 1" : "swaymsg -q seat seat0 cursor release button1" }

@(private = "file")
kinds :: proc(w: ^platform.Window, ms: int) -> (enters, leaves, drops: int, drop_pos: [2]f32, allowed: platform.Drop_Effects) {
	seen: Seen
	defer delete(seen.events)
	pump_for(w, ms, &seen)
	for e in seen.events {
		#partial switch e.kind {
		case .Drop_Enter: enters += 1; allowed = e.drop_allowed
		case .Drop_Leave: leaves += 1
		case .Drop: drops += 1; drop_pos = e.pos; allowed = e.drop_allowed
		}
	}
	return
}

// A drag is not given up while the pointer moves, however long it lasts: the limit is of silence.
@(test)
a_long_drag_goes_on :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a, b := two_windows()
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil { return }
	defer { platform.destroy_window(a); platform.destroy_window(b) }
	platform.drag_silence_limit(a, 500)
	r := drag_between(t, a, b, {text = "long"}, nil, press_in_a(a), fmt.tprint(moves_in_b(b, 12, "0.1"), release_drag()))
	testing.expect(t, r.ok)
	testing.expect_value(t, r.effect, Maybe(platform.Drop_Effect)(.Copy))
	platform.drop_data_release(b)
}

// A click of another button in the middle of a drag is not its release.
@(test)
only_the_button_of_the_drag_ends_it_on_x11 :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a, b := two_windows()
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil { return }
	defer { platform.destroy_window(a); platform.destroy_window(b) }
	script := fmt.tprint("xdotool mousemove --window ", window_id(b), " 70 90; sleep 0.2; xdotool mousemove --window ", window_id(b), " 72 90; sleep 0.2; xdotool click 3; sleep 0.2; ",
		"xdotool mousemove --window ", window_id(b), " 80 95; sleep 0.3; xdotool mouseup 1")
	r := drag_between(t, a, b, {text = "left"}, nil, press_in_a(a), script)
	testing.expect_value(t, r.effect, Maybe(platform.Drop_Effect)(.Copy))
	_, _, drops, pos, _ := kinds(b, 200)
	testing.expect_value(t, drops, 1)
	testing.expect_value(t, pos, [2]f32{80, 95})
	platform.drop_data_release(b)
}

// Escape gives the drag up: no effect, the target told so.
@(test)
escape_gives_a_drag_up_on_x11 :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a, b := two_windows()
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil { return }
	defer { platform.destroy_window(a); platform.destroy_window(b) }
	script := fmt.tprint(moves_in_b(b, 3, "0.1"), "xdotool key Escape; sleep 0.2; xdotool mouseup 1")
	r := drag_between(t, a, b, {text = "no"}, nil, press_in_a(a), script)
	testing.expect(t, r.ok)
	testing.expect_value(t, r.effect, Maybe(platform.Drop_Effect)(nil))
	enters, leaves, drops, _, _ := kinds(b, 200)
	testing.expect_value(t, enters, 1)
	testing.expect_value(t, leaves, 1)
	testing.expect_value(t, drops, 0)
}

// The target hears what the source allows, and a Move is a Move.
@(test)
a_target_hears_what_the_source_allows :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a, b := two_windows()
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil { return }
	defer { platform.destroy_window(a); platform.destroy_window(b) }
	seen: Seen
	defer delete(seen.events)
	sh(press_in_a(a))
	testing.expect(t, wait_kind(a, &seen, .Mouse_Press), "the press that starts the drag")
	sh("(sleep 0.4; ", drop_in_b(b), ") >/dev/null 2>&1 &")
	effect, ok := platform.drag_start(a, {text = "moved"}, {.Move})
	testing.expect(t, ok)
	testing.expect_value(t, effect, Maybe(platform.Drop_Effect)(.Move))
	_, _, drops, _, allowed := kinds(b, 200)
	testing.expect_value(t, drops, 1)
	testing.expect_value(t, allowed, platform.Drop_Effects{.Move})
	platform.drop_data_release(b)
}

// A target that stops taking drops under a drag says the drag left.
@(test)
a_target_disabled_under_a_drag_says_it_left :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a := open("drag off")
	testing.expect(t, a != nil)
	if a == nil { return }
	defer platform.destroy_window(a)
	platform.drop_target_enable(a, true)
	pump_for(a, 300)
	Told :: struct { leaves: int }
	told: Told
	platform.drop_sync_set(a, proc(user: rawptr, w: ^platform.Window, e: platform.Event) -> Maybe(platform.Drop_Effect) {
		if e.kind == .Drop_Over && platform.drop_target_enabled(w) { platform.drop_target_enable(w, false) }
		if e.kind == .Drop_Leave { (^Told)(user).leaves += 1 }
		return .Copy
	}, &told)
	back := x11() ? fmt.tprint("xdotool mousemove --window ", window_id(a), " 60 60; sleep 0.2; xdotool mousemove --window ", window_id(a), " 70 70; sleep 0.3; xdotool mouseup 1") : "swaymsg -q seat seat0 cursor set 120 120; sleep 0.2; swaymsg -q seat seat0 cursor set 130 130; sleep 0.3; swaymsg -q seat seat0 cursor release button1"
	drag_between(t, a, a, {text = "off"}, nil, press_in_a(a), back)
	testing.expect_value(t, told.leaves, 1)
	testing.expect(t, !platform.drop_active(a))
}

// A target that hangs after it took the drop: the source does not wait for it as long as for a user who keeps the button down.
@(test)
a_drop_on_a_hung_target_ends_soon_on_x11 :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a := open("to hung")
	testing.expect(t, a != nil)
	if a == nil { return }
	defer platform.destroy_window(a)
	sh("drag_peer target & echo $! > /tmp/gt_peer; sleep 1")
	defer sh("kill -CONT $(cat /tmp/gt_peer); kill -9 $(cat /tmp/gt_peer)")
	platform.drag_silence_limit(a, 20000)
	seen: Seen
	defer delete(seen.events)
	sh(press_in_a(a))
	testing.expect(t, wait_kind(a, &seen, .Mouse_Press), "the press that starts the drag")
	sh("(sleep 0.4; xdotool mousemove 800 600; sleep 0.2; xdotool mousemove 810 610; sleep 0.5; kill -STOP $(cat /tmp/gt_peer); xdotool mouseup 1) >/dev/null 2>&1 &")
	start := time.tick_now()
	effect, ok := platform.drag_start(a, {text = "to a program that hangs"}, {.Copy})
	testing.expect(t, ok)
	testing.expect_value(t, effect, Maybe(platform.Drop_Effect)(nil))
	testing.expect(t, time.duration_seconds(time.tick_since(start)) < 10, "given up well before the limit of a drag")
}

// A source that dies under the pointer never says it left: the next drag is a new one, the window not stuck under the old.
@(test)
a_source_that_dies_ends_its_drag_on_x11 :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("under a death")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	platform.drop_target_enable(w, true)
	platform.drop_set_effect(w, .Copy)
	sh("drag_peer source & echo $! > /tmp/gt_peer; sleep 1")
	defer sh("kill -9 $(cat /tmp/gt_peer) 2>/dev/null; xdotool mouseup 1")
	sh("xdotool mousemove 800 600 mousedown 1; sleep 0.3; xdotool mousemove 790 590; sleep 0.1; xdotool mousemove --window ", window_id(w), " 50 50; sleep 0.2")
	seen: Seen
	defer delete(seen.events)
	testing.expect(t, wait_kind(w, &seen, .Drop_Enter, 3000), "the drag came over the window")
	sh("xdotool mousemove --window ", window_id(w), " 60 60; sleep 0.1; xdotool mousemove --window ", window_id(w), " 70 70; sleep 0.1")
	pump_for(w, 200)
	sh("kill -9 $(cat /tmp/gt_peer)")
	testing.expect(t, wait_kind(w, &seen, .Drop_Leave, 3000), "the source's death ends the drag")
	testing.expect(t, !platform.drop_active(w))
}

// The window under a drag closes; the compositor's leave comes for a window that is gone.
@(test)
a_window_closed_under_a_drag_on_wayland :: proc(t: ^testing.T) {
	if !wayland() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("closes under a drag")
	testing.expect(t, w != nil)
	if w == nil { return }
	platform.drop_target_enable(w, true)
	platform.drop_set_effect(w, .Copy)
	sh("drag_peer source & echo $! > /tmp/gt_peer; sleep 1")
	defer sh("kill -9 $(cat /tmp/gt_peer) 2>/dev/null; swaymsg -q seat seat0 cursor release button1")
	keep := open("keeps the loop")
	testing.expect(t, keep != nil)
	if keep == nil { platform.destroy_window(w); return }
	defer platform.destroy_window(keep)
	pump_for(w, 300)
	// (sway splits the screen in the order of the windows: the peer is in the middle)
	sh("swaymsg -q seat seat0 cursor set 640 300; sleep 0.3; swaymsg -q seat seat0 cursor press button1; sleep 0.3; swaymsg -q seat seat0 cursor set 100 300; sleep 0.2; swaymsg -q seat seat0 cursor set 110 310; sleep 0.2")
	seen: Seen
	defer delete(seen.events)
	wait_kind(w, &seen, .Drop_Enter, 2000)
	platform.destroy_window(w)
	pump_for(keep, 500)   // (a read of what the window left would be here)
	sh("swaymsg -q seat seat0 cursor release button1")
	pump_for(keep, 300)
}

////////////////////////////////
// keys: what the modifiers do to them

@(private = "file")
texts :: proc(s: ^Seen) -> string {
	b := strings.builder_make(context.temp_allocator)
	for e in s.events { if e.kind == .Text { strings.write_rune(&b, e.text) } }
	return strings.to_string(b)
}

@(private = "file")
pressed :: proc(s: ^Seen, k: platform.Key) -> bool {
	for e in s.events { if e.kind == .Key_Press && e.key == k { return true } }
	return false
}

@(private = "file") wait_text :: proc(w: ^platform.Window, s: ^Seen, want: string, ms := 3000) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) && len(texts(s)) < len(want) {
		for e in platform.poll_events(w, true, PUMP_WAIT_MS) { append(&s.events, e) }
	}
}

// Shift and Caps Lock change what a key types; the key keeps its name whatever it types (Shift+1 is N1 that types !).
@(test)
modifiers_reach_the_typed_text_on_x11 :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("modifiers")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	seen: Seen
	defer delete(seen.events)
	sh("xdotool key --window 0 a shift+a shift+1 Caps_Lock a Caps_Lock a shift+Tab")
	wait_text(w, &seen, "aA!Aa")
	testing.expect_value(t, texts(&seen), "aA!Aa")
	testing.expect(t, pressed(&seen, .N1), "Shift+1 is the key 1")
	testing.expect(t, pressed(&seen, .Tab), "Shift+Tab is the key Tab")
}

// xdotool gives a spare keycode the symbol it types and takes it back: the keymap of the server changes under the window.
@(test)
a_new_keymap_is_followed_on_x11 :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("keymap")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	seen: Seen
	defer delete(seen.events)
	sh("xdotool key --delay 400 eacute &")
	wait_text(w, &seen, "\u00e9", 2500)
	testing.expect_value(t, texts(&seen), "\u00e9")
}

////////////////////////////////
// windows that end

// The server's notices for a window that is gone are for nobody: not for the window that polls.
@(test)
a_closed_window_leaves_the_others_alone :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a := open("goes")
	b := open("stays")
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil { return }
	defer platform.destroy_window(b)
	platform.destroy_window(a)
	pump_for(b, 300)
	testing.expect(t, !platform.is_minimized(b), "the other window is not minimized")
	testing.expect(t, platform.is_window_visible(b))
}

////////////////////////////////
// the waits of a real window

@(test)
an_injected_event_ends_a_wait :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("inject")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	pump_for(w, 100)
	platform.inject_event(w, {kind = .Activate})
	start := time.tick_now()
	evs := platform.poll_events(w, true, 3000)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 1000, "the wait ends at once")
	testing.expect_value(t, len(evs), 1)
}

// A repaint asked for (the pump set the latch, nothing else is pending): wait_event does not sleep over it.
@(test)
a_repaint_asked_for_ends_a_wait :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("latch")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	pump_for(w, 100)
	w.paint_requested = true
	start := time.tick_now()
	platform.wait_event(w, 3000)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 1000, "the wait ends at once")
}

////////////////////////////////
// cursors

// A custom cursor gives way to the named one the window already had, and to it again when it is released.
@(test)
a_custom_cursor_gives_way :: proc(t: ^testing.T) {
	if desktop() == "" { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("custom")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	if x11() {
		sh("xdotool windowactivate --sync ", window_id(w), " mousemove --window ", window_id(w), " 50 40")
	} else {
		sh("swaymsg -q seat seat0 cursor set 60 60")
	}
	pump_for(w, 200)
	shown :: proc(t: ^testing.T, w: ^platform.Window) -> u64 {
		pump_for(w, 100)
		s, ok := platform.cursor_on_screen(w)
		testing.expect(t, ok)
		return s
	}
	pixels := make([]u8, 16 * 16 * 4)
	defer delete(pixels)
	for i := 0; i < len(pixels); i += 4 { pixels[i], pixels[i + 3] = 255, 255 }
	platform.set_cursor(w, .Hand)
	hand := shown(t, w)
	cc, err := platform.custom_cursor_create(w, pixels, {16, 16}, {8, 8})
	testing.expect_value(t, err, platform.Custom_Cursor_Error.None)
	platform.set_cursor_custom(w, cc, .Arrow)
	testing.expect(t, shown(t, w) != hand, "the custom cursor shows")
	platform.set_cursor(w, .Hand)
	testing.expect_value(t, shown(t, w), hand)
	platform.set_cursor_custom(w, cc, .Arrow)
	testing.expect(t, shown(t, w) != hand)
	platform.custom_cursor_release(w, cc)
	testing.expect_value(t, shown(t, w), hand)
}

// Only the window under the pointer sets what the pointer shows.
@(test)
a_window_without_the_pointer_leaves_it_alone_on_wayland :: proc(t: ^testing.T) {
	if !wayland() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	a, b := two_windows()
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil { return }
	defer { platform.destroy_window(a); platform.destroy_window(b) }
	sh("swaymsg -q seat seat0 cursor set 100 100")
	pump_for(a, 300)
	platform.set_cursor(a, .Hand)
	before, _ := platform.cursor_on_screen(a)
	platform.set_cursor(b, .Text)
	after, _ := platform.cursor_on_screen(a)
	testing.expect_value(t, after, before)
}

////////////////////////////////
// the press the compositor takes

// The seat loses its pointer under a held button: the pointer leaves, the release will not come here. Given back, it works.
@(test)
a_pointer_taken_with_a_button_held_releases_it_on_wayland :: proc(t: ^testing.T) {
	if !wayland() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("taken")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	seen: Seen
	defer delete(seen.events)
	sh("swaymsg -q seat seat0 cursor set 60 60; sleep 0.5; swaymsg -q seat seat0 cursor press button1")
	testing.expect(t, wait_kind(w, &seen, .Mouse_Press), "the press arrives")
	sh("swaymsg -q 'seat other attach \"*\"'")
	testing.expect(t, wait_kind(w, &seen, .Mouse_Release, 2000), "the release is made")
	testing.expect_value(t, w.buttons_down, platform.Mouse_Buttons{})
	sh("swaymsg -q seat seat0 cursor release button1; swaymsg -q 'seat seat0 attach \"*\"'; swaymsg -q seat seat0 cursor set 70 70")
	pump_for(w, 300)
	clear(&seen.events)
	sh("swaymsg -q seat seat0 cursor set 60 60; sleep 0.3; swaymsg -q seat seat0 cursor press button1; sleep 0.1; swaymsg -q seat seat0 cursor release button1")
	testing.expect(t, wait_kind(w, &seen, .Mouse_Press, 2000), "the pointer is back")
	sh("wtype a")
	testing.expect(t, wait_kind(w, &seen, .Text, 2000), "the keyboard is back")
}

// The window goes off the screen under a held button: the button's grab ends with it, the release goes elsewhere.
@(test)
a_window_unmapped_with_a_button_held_releases_it_on_x11 :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("grabbed")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	seen: Seen
	defer delete(seen.events)
	sh("xdotool mousemove --window ", window_id(w), " 50 50 mousedown 1")
	testing.expect(t, wait_kind(w, &seen, .Mouse_Press), "the press arrives")
	sh("xdotool windowminimize --sync ", window_id(w))
	defer sh("xdotool mouseup 1; xdotool windowactivate --sync ", window_id(w))
	testing.expect(t, wait_kind(w, &seen, .Mouse_Release, 2000), "the release is made")
	testing.expect_value(t, w.buttons_down, platform.Mouse_Buttons{})
}

// Under a press the pointer stays the window's, as under a capture on Windows: it left when the release says so.
@(test)
a_held_button_keeps_the_pointer_on_x11 :: proc(t: ^testing.T) {
	if !x11() { return }
	context.allocator = runtime.heap_allocator()   // (the connection's state outlives a test)
	w := open("held")
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	seen: Seen
	defer delete(seen.events)
	sh("xdotool mousemove --window ", window_id(w), " 50 50 mousedown 1")
	testing.expect(t, wait_kind(w, &seen, .Mouse_Press), "the press arrives")
	sh("xdotool mousemove 1200 900")
	pump_for(w, 200, &seen)
	testing.expect(t, !has_kind_of(&seen, .Mouse_Leave), "no leave under the press")
	sh("xdotool mouseup 1")
	testing.expect(t, wait_kind(w, &seen, .Mouse_Leave, 2000), "the leave comes with the release")
}