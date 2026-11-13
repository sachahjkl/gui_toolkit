package scenarios_test

// ui.Feel: a tooltip's delay set longer is waited for by the session's clock; a slider's arrow key with Shift moves
// Feel.step_shift steps. (The undo limit: text_edit_test.odin; a scroll bar arrow's repeat: scrollbar_test.odin.)

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

// A delay well past the default (500 ms), and how far from it each look is.
@(private = "file") TIP_DELAY_MS :: 2000
@(private = "file") TIP_MARGIN_MS :: 500
@(private = "file") SLIDER_WIDTH :: 300
@(private = "file") SLIDER_START :: 50

@(private = "file")
Tip :: struct { shown: bool }

@(private = "file")
tip_build :: proc(s: ^session.Session) {
	tp := (^Tip)(s.user)
	sig := ui.button("btn", "Hover me")
	tp.shown = ui.hovered_for(sig)
	if tp.shown {
		if ui.tooltip() { ui.tooltip_text("A tip") }
	}
}

@(test)
a_longer_tooltip_delay_is_waited_for :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	tp := Tip{}
	s := session.start(t, {build = tip_build, user = &tp, no_renderer = true})
	f := ui.feel(s.state)
	f.tooltip_delay_ms = TIP_DELAY_MS
	ui.set_feel(s.state, f)
	testing.expect_value(t, ui.feel(s.state).tooltip_delay_ms, TIP_DELAY_MS)
	session.hover(s, "btn")
	session.advance(s, TIP_DELAY_MS - TIP_MARGIN_MS)
	testing.expect(t, !tp.shown, "not yet: past the default delay, short of the one set")
	session.advance(s, 2 * TIP_MARGIN_MS)
	testing.expect(t, tp.shown, "past the delay set: the tooltip shows")
	session.leave(s)
	testing.expect(t, !tp.shown, "gone with the pointer")
}) }

@(private = "file")
Slid :: struct { value: f32 }

@(private = "file")
slider_build :: proc(s: ^session.Session) {
	sl := (^Slid)(s.user)
	ui.next({width = ui.px(SLIDER_WIDTH)})
	ui.slider("###slider", &sl.value, 0, 100, 1)
}

@(test)
a_slider_s_arrow_key_with_shift_moves_ten_steps :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sl := Slid{}
	s := session.start(t, {build = slider_build, user = &sl, no_renderer = true})
	session.click(s, "slider")   // (the keyboard: the press also moves the value, set again below)
	sl.value = SLIDER_START
	session.frames(s, 2)
	session.key(s, .Right, {.Shift})
	testing.expect_value(t, sl.value, SLIDER_START + 10)
	session.key(s, .Left)
	testing.expect_value(t, sl.value, SLIDER_START + 9)
	session.key(s, .Down, {.Shift})
	testing.expect_value(t, sl.value, SLIDER_START - 1)

	f := ui.feel(s.state)
	f.step_shift = 5
	ui.set_feel(s.state, f)
	session.key(s, .Up, {.Shift})
	testing.expect_value(t, sl.value, SLIDER_START + 4)
}) }

@(private = "file")
Motion :: struct { on: bool }

// The user's word on motion goes over the system's (Build_Params.animations, the session's `animations`): Off stills a
// window whose system animates, On animates one whose system asks for less motion; System follows it again.
@(test)
the_animations_setting_goes_over_the_system :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	m := Motion{}
	s := session.start(t, {build = proc(s: ^session.Session) { (^Motion)(s.user).on = ui.animations_on() }, user = &m, no_renderer = true, animations = true})
	testing.expect(t, m.on, "the system's word: it animates")
	ui.set_animations(s.state, .Off)
	session.frame(s)
	testing.expect_value(t, ui.animations(s.state), ui.Animations.Off)
	testing.expect(t, !m.on, "Off: still")
	ui.set_animations(s.state, .System)
	session.frame(s)
	testing.expect(t, m.on, "System: as the system says again")
})}
