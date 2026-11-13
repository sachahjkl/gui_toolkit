// What a user does to an interface, through testkit/session: no window of the system, input through the event path, the real renderer's pixels, the session's clock.
// One file per subject.
//   odin test tests/scenarios -vet -define:ODIN_TEST_THREADS=1
package scenarios_test

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file")
Form :: struct {
	name, mail:  ui.Text_Field,
	agree:       bool,
	saves:       int,
	show_mail:   bool,
	modal:       bool,
	disabled:    bool,
}

@(private = "file")
form_build :: proc(s: ^session.Session) {
	f := (^Form)(s.user)
	ui.next({width = ui.px(200)})
	ui.line_edit("###name", &f.name)
	if f.show_mail {
		ui.next({width = ui.px(200)})
		ui.line_edit("###mail", &f.mail)
	}
	ui.next({width = ui.px(200)})
	ui.checkbox("###agree", "Agree", &f.agree)
	if ui.disabled(f.disabled) {
		ui.next({width = ui.px(100)})
		if ui.button("save", "Save").clicked { f.saves += 1 }
	}
	if ui.modal("dialog", 300, &f.modal) {
		ui.next({width = ui.px(100)})
		ui.button("m_one", "One")
		ui.next({width = ui.px(100)})
		ui.button("m_two", "Two")
	}
}

@(private = "file")
form_start :: proc(t: ^testing.T, loc := #caller_location) -> (^session.Session, ^Form) {
	f := new(Form)   // (a cleanup runs after the test's procedure has returned)
	f.show_mail = true
	testing.cleanup(t, proc(p: rawptr) {
		f := (^Form)(p)
		ui.field_destroy(&f.name)
		ui.field_destroy(&f.mail)
		free(f)
	}, f)
	return session.start(t, {build = form_build, user = f, no_renderer = true}, loc), f
}

@(test)
tab_goes_through_the_stops_in_order_and_round :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, _ := form_start(t)
	testing.expect_value(t, session.focused_name(s), "")
	order := []string{"name", "mail", "agree", "save", "name"}
	for want in order {
		session.key(s, .Tab)
		testing.expect_value(t, session.focused_name(s), want)
	}
	session.key(s, .Tab, {.Shift})
	testing.expect_value(t, session.focused_name(s), "save")
	session.key(s, .Tab, {.Shift})
	testing.expect_value(t, session.focused_name(s), "agree")
	testing.expect(t, s.state.focus_visible, "the focus came from the keyboard: its ring shows")
}) }

@(test)
a_click_takes_the_focus_and_shows_no_ring :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, _ := form_start(t)
	session.click(s, "mail")
	testing.expect_value(t, session.focused_name(s), "mail")
	testing.expect(t, !s.state.focus_visible, "the focus came from the mouse: no ring on what is not a field")
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "agree")
}) }

@(test)
a_disabled_button_is_no_stop_and_no_target :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, f := form_start(t)
	f.disabled = true
	session.frame(s)
	for want in ([]string{"name", "mail", "agree", "name"}) {
		session.key(s, .Tab)
		testing.expect_value(t, session.focused_name(s), want)
	}
	session.click(s, "save")
	testing.expect_value(t, f.saves, 0)
}) }

@(test)
space_and_enter_press_what_has_the_focus :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, f := form_start(t)
	session.key(s, .Tab, repeat = 3)
	testing.expect_value(t, session.focused_name(s), "agree")
	session.key(s, .Space)
	testing.expect(t, f.agree, "Space on a checkbox")
	session.key(s, .Tab)
	session.key(s, .Return)
	testing.expect_value(t, f.saves, 1)
	session.key(s, .Space)
	testing.expect_value(t, f.saves, 2)
}) }

// A field that goes takes the focus with it: Tab starts over, nothing is typed anywhere.
@(test)
the_focus_goes_with_its_box :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, f := form_start(t)
	session.click(s, "mail")
	session.type_text(s, "a")
	f.show_mail = false
	session.frames(s, 2)
	testing.expect_value(t, session.focused_name(s), "")
	session.type_text(s, "b")
	testing.expect_value(t, ui.field_string(&f.mail), "a")
	testing.expect_value(t, ui.field_string(&f.name), "")
}) }

// In a modal, Tab stays inside; Esc closes it; the page's stops come back.
@(test)
a_modal_keeps_tab_inside :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, f := form_start(t)
	session.click(s, "name")
	f.modal = true
	session.frames(s, 2)
	seen: [2]string
	session.key(s, .Tab)
	seen[0] = session.focused_name(s)
	session.key(s, .Tab)
	seen[1] = session.focused_name(s)
	testing.expect(t, seen[0] != seen[1], "Tab moves")
	for n in seen { testing.expectf(t, n == "m_one" || n == "m_two", "inside the dialog, got %q", n) }
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), seen[0])
	// the page under it takes no click
	session.click(s, "agree")
	testing.expect(t, !f.agree, "the page is behind the dialog")
	session.key(s, .Escape)
	testing.expect(t, !f.modal, "Esc closes it")
}) }

// Arrows move the focus through space between the widgets that do not use them.
@(test)
arrows_move_the_focus_through_space :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, _ := form_start(t)
	session.key(s, .Tab, repeat = 3)
	testing.expect_value(t, session.focused_name(s), "agree")
	session.key(s, .Down)
	testing.expect_value(t, session.focused_name(s), "save")
	session.key(s, .Up)
	testing.expect_value(t, session.focused_name(s), "agree")
}) }
