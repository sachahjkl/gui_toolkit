package scenarios_test

// Buttons and small widgets: a button's text alignment from its style or `next` (centred when nothing says), an
// icon_button's tooltip and the name a screen reader reads, a toggled button held down, a lit one, a label that shows its
// whole text when cut, and a spinner that asks for frames only while it is shown.

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{500, 300}
@(private = "file") BUTTON_WIDTH :: 200
@(private = "file") BUTTON_HEIGHT :: 30
@(private = "file") CUT_WIDTH :: 60

@(test)
a_button_keeps_the_text_align_it_is_given :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT), text_align = .Left})
		ui.button("Left###left")
		ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT)})
		ui.button("Centre###centre")
		if ui.style({text_align = .Right}) {
			ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT)})
			ui.button("Right###right")
		}
		ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT), text_align = .Left})
		ui.icon_button("glyph", ui.ICON_UP)
	}})
	testing.expect_value(t, session.get(s, "left").text_align, ui.Text_Align.Left)
	testing.expect_value(t, session.get(s, "centre").text_align, ui.Text_Align.Center)
	testing.expect_value(t, session.get(s, "right").text_align, ui.Text_Align.Right)
	testing.expect_value(t, session.get(s, "glyph").text_align, ui.Text_Align.Left)
}) }

@(private = "file")
Tips :: struct { clicks: int, on: bool }

// The tooltip shows once the pointer has rested on the button; its words name the glyph for a screen reader. Disabled, it
// takes no click.
@(test)
an_icon_button_shows_its_tip_and_is_named_by_it :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Tips{}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Tips)(s.user)
		ui.next({width = ui.px(BUTTON_HEIGHT), height = ui.px(BUTTON_HEIGHT)})
		if ui.icon_button("bell", ui.ICON_UP, tip = "Notifications", intent = .Primary, disabled = r.on).clicked { r.clicks += 1 }
	}})
	ui.a11y_capture(s.state, true)
	session.hover(s, "bell")
	testing.expect(t, session.find_text(s, "Notifications") == nil, "no tooltip at once")
	session.wait_text(s, "Notifications")
	bell := session.get(s, "bell")
	testing.expect(t, bell.a11y != nil && bell.a11y.name == "Notifications", "its tip names it")
	session.click(s, "bell")
	testing.expect_value(t, r.clicks, 1)
	r.on = true
	session.frames(s, 2)
	session.click(s, "bell")
	testing.expect_value(t, r.clicks, 1)
}) }

// A Toggled face is held down, a lit button drawn as under the pointer.
@(test)
a_toggled_button_is_held_and_a_lit_one_hot :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.button("Bold###bold", face = .Toggled)
		ui.button_icon("menu", "", "Menu", lit = true)
		ui.button_icon("plain", "", "Plain", quiet = true)
	}})
	bold := session.get(s, "bold")
	testing.expect(t, .Held in bold.flags, "held down")
	testing.expect_value(t, ui.box_held(bold), 1)
	testing.expect_value(t, ui.box_hot(session.get(s, "menu")), 1)
	testing.expect_value(t, ui.box_hot(session.get(s, "plain")), 0)
}) }

@(private = "file")
Spin :: struct { shown: bool }

// A spinner asks for the next frames while it is shown, and for none once it is gone.
@(test)
a_spinner_asks_for_frames_only_while_shown :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Spin{shown = true}
	s := session.start(t, {size = WINDOW, user = &r, animations = true, build = proc(s: ^session.Session) {
		r := (^Spin)(s.user)
		if r.shown { ui.spinner("###busy") }
	}})
	session.frames(s, 3)
	testing.expect(t, ui.needs_frame(s.state), "it turns")
	r.shown = false
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.needs_frame(s.state) }, "no frame asked")
	session.frames(s, 3)
	testing.expect(t, !ui.needs_frame(s.state), "still none")
}) }

// A label cut by its box shows its whole text in a tooltip once the pointer rests on it; one that fits shows none.
@(test)
a_cut_label_shows_its_whole_text :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(CUT_WIDTH), height = ui.px(BUTTON_HEIGHT)})
		ui.label_tip("A name far too long for its box###long")
		ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT)})
		ui.label_tip("Short###short")
	}})
	session.hover(s, "short")
	session.advance(s, f64(ui.feel(s.state).tooltip_delay_ms) * 2)
	testing.expect(t, session.find(s, "tooltip_text") == nil, "a label that fits has no tooltip")
	session.hover(s, "long")
	box := session.wait_box(s, "tooltip_text")
	testing.expect_value(t, ui.box_text(box), "A name far too long for its box")
}) }
