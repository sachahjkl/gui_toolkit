// The test session itself (testkit/session): an application with no window of the system, its input through the toolkit's own path, its
// time a clock of its own, its pixels the real renderer's.
//   odin test tests/session -vet -define:ODIN_TEST_THREADS=1
package session_test

import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") App :: struct { clicks: int, field: ui.Line_Edit, typed: string }

@(private = "file")
counter_app :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	if ui.button("add", "Add").clicked { app.clicks += 1 }
	ui.line_edit("###field", &app.field)
}

@(test)
a_click_goes_through_the_event_path :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := session.start(t, {build = counter_app, user = &app})
	session.click(s, "add")
	testing.expect_value(t, app.clicks, 1)
	session.click_text(s, "Add")
	testing.expect_value(t, app.clicks, 2)
	testing.expect(t, ui.build_events(s.state) != nil || s.frames > 0)
}

@(test)
keys_and_text_reach_the_focused_field :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := session.start(t, {build = counter_app, user = &app})
	session.click(s, "field")
	testing.expect_value(t, session.focused_name(s), "field")
	session.type_text(s, "hello")
	testing.expect_value(t, ui.line_edit_string(&app.field), "hello")
	session.key(s, .Backspace, repeat = 2)
	testing.expect_value(t, ui.line_edit_string(&app.field), "hel")
	session.key(s, .A, {.Ctrl})
	session.key(s, .C, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), "hel")
}

@(test)
the_clipboard_is_the_process_s_own :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := session.start(t, {build = counter_app, user = &app})
	session.set_clipboard(s, "from the test")
	session.click(s, "field")
	session.key(s, .V, {.Ctrl})
	testing.expect_value(t, ui.line_edit_string(&app.field), "from the test")
	testing.expect(t, .Text in platform.clipboard_formats())
}

@(test)
pixels_are_the_real_frame :: proc(t: ^testing.T) {
	s := session.start(t, {build = proc(s: ^session.Session) {
		ui.next({fixed_x = 10, fixed_y = 20, width = ui.px(30), height = ui.px(40), bg = {1, 0, 0, 1}})
		ui.build_box({.Draw_Background}, "###red")
	}})
	img := session.capture(s)
	testing.expect_value(t, img.width, session.DEFAULT_SIZE.x)
	testing.expect(t, session.near(session.pixel(img, 25, 40), {255, 0, 0, 255}), "the box is red")
	testing.expect(t, !session.near(session.pixel(img, 45, 40), {255, 0, 0, 255}), "right of it is not")
	testing.expect_value(t, session.count_color(img, {0, 0}, session.DEFAULT_SIZE, {255, 0, 0, 255}), 30 * 40)
}

@(test)
the_clock_is_moved_not_waited_for :: proc(t: ^testing.T) {
	Timers :: struct { fired: bool }
	state: Timers
	s := session.start(t, {user = &state, build = proc(s: ^session.Session) {
		key := ui.Key(0x71)
		st := (^Timers)(s.user)
		if s.frames == 1 { ui.timer_set(key, 500) }
		if ui.timer_due(key) { st.fired = true }
	}})
	session.frames(s, 3)
	testing.expect(t, !state.fired, "not yet: 3 frames are 50 ms")
	session.advance(s, 600)
	testing.expect(t, state.fired, "600 ms of the session's clock later")
}

@(test)
a_second_window_on_the_same_screen :: proc(t: ^testing.T) {
	a_app, b_app: App
	defer { ui.line_edit_destroy(&a_app.field); ui.line_edit_destroy(&b_app.field) }
	a := session.start(t, {build = counter_app, user = &a_app, size = {300, 200}})
	b := session.start(t, {build = counter_app, user = &b_app, size = {400, 300}})
	session.click(b, "add")
	session.click(a, "add")
	session.click(a, "add")
	testing.expect_value(t, a_app.clicks, 2)
	testing.expect_value(t, b_app.clicks, 1)
	session.activate(a, false)
	testing.expect(t, !a.win.active)
	testing.expect(t, b.win.active)
	testing.expect_value(t, session.capture(b).width, 400)
	testing.expect_value(t, session.capture(a).width, 300)
}

@(test)
the_virtual_screen_answers_for_the_machine :: proc(t: ^testing.T) {
	s := session.start(t, {no_renderer = true})
	before := platform.display_info(s.win)
	testing.expect_value(t, platform.monitor_size(s.win), platform.VIRTUAL_SCREEN_DEFAULT.size)
	testing.expect_value(t, before.hz, platform.VIRTUAL_SCREEN_DEFAULT.hz)
	platform.virtual_screen_set({size = {2560, 1440}, hz = 144})
	defer platform.virtual_screen_set(platform.VIRTUAL_SCREEN_DEFAULT)
	after := platform.display_info(s.win)
	testing.expect_value(t, platform.monitor_size(s.win), [2]int{2560, 1440})
	testing.expect_value(t, after.hz, 144.0)
	testing.expect(t, after.serial != before.serial, "the serial tells the change")
}

@(test)
the_pointer_comes_and_leaves :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := session.start(t, {build = counter_app, user = &app, no_renderer = true})
	session.hover(s, "add")
	testing.expect_value(t, session.hot_name(s), "add")
	session.leave(s)
	testing.expect_value(t, session.hot_name(s), "")
}

// A frame against a reference image: what it is compared with is a file; a frame that differs fails (here: in its count of pixels).
@(test)
a_frame_looks_like_its_reference :: proc(t: ^testing.T) {
	Run :: struct { other: bool }
	r: Run
	s := session.start(t, {user = &r, size = {100, 100}, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(50), height = ui.px(50), bg = r.other ? ui.Color{0, 1, 0, 1} : ui.Color{1, 0, 0, 1}})
		ui.build_box({.Draw_Background}, "###box")
	}})
	session.save_png(s, "ref.png")
	path := session.out_path(s, "ref.png")
	session.expect_like(s, path)
	want, ok := session.load_png(s, path)
	testing.expect(t, ok && want.width == 100, "it reads back")
	r.other = true
	session.frames(s, 2)
	testing.expect_value(t, session.count_different(session.capture(s), want), 50 * 50)
}

@(test)
a_wait_ends_when_the_state_holds :: proc(t: ^testing.T) {
	Later :: struct { show: bool }
	st: Later
	s := session.start(t, {user = &st, no_renderer = true, build = proc(s: ^session.Session) {
		st := (^Later)(s.user)
		if s.frames > 5 { st.show = true }
		if st.show { ui.label("Shown###late") }
	}})
	testing.expect(t, session.find(s, "late") == nil)
	session.wait_box(s, "late")
	session.wait_text(s, "shown")
	testing.expect(t, s.frames <= 7, "as soon as it holds")
}
