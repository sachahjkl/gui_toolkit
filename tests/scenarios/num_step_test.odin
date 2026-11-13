package scenarios_test

// Numbers stepped in a text (ui.num_step_text, ui.field_num_step): each modifier on values of several shapes, the number at the
// caret (or the next one) moved with its unit and the text around it kept, words and hex colours left alone; in a field, the
// keys and the wheel while it has the keyboard, the number selected after.

import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(test)
numbers_step_by_each_modifier :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Case :: struct { key: platform.Key, mods: platform.Modifiers, delta: f64 }
	cases := [?]Case{
		{.Up, {}, 1}, {.Down, {}, -1}, {.Up, {.Shift}, 10}, {.Down, {.Shift}, -10}, {.Up, {.Alt}, 0.1}, {.Down, {.Alt}, -0.1},
		{.Up, {.Ctrl}, 100}, {.Up, {.Ctrl, .Shift}, 100}, {.Page_Up, {}, 10}, {.Page_Down, {}, -10}, {.Page_Up, {.Shift}, 100},
	}
	for c in cases {
		d, ok := ui.num_step_delta(c.key, c.mods)
		testing.expectf(t, ok && abs(d - c.delta) < 1e-9, "%v %v steps by %v: %v", c.key, c.mods, c.delta, d)
	}
	_, ok := ui.num_step_delta(.Left, {})
	testing.expect(t, !ok, "Left does not step")
}) }

@(test)
the_number_at_the_caret_steps_with_its_unit :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Case :: struct { text: string, caret: int, delta: f64, want: string, number: string }
	cases := [?]Case{
		{"10px", 2, 1, "11px", "11"},
		{"10px", 4, 10, "20px", "20"},
		{"10px", 0, 0.1, "10.1px", "10.1"},
		{"10px", 1, 100, "110px", "110"},
		{"10px 5px", 6, 1, "10px 6px", "6"},          // the caret on the second
		{"10px 5px", 4, -1, "9px 5px", "9"},          // at the end of the first's unit: the first
		{"rgba(10, 20, 30, 0.5)", 18, 0.1, "rgba(10, 20, 30, 0.6)", "0.6"},
		{"rgba(10, 20, 30, 0.5)", 0, 1, "rgba(11, 20, 30, 0.5)", "11"},   // in the function's name: the next number
		{"calc(100% - 12px)", 13, 1, "calc(100% - 13px)", "13"},
		{"-5px", 1, 10, "5px", "5"},
		{"0.2", 3, 0.1, "0.3", "0.3"},                // no noise of floating point
		{"1.5em", 0, -1, "0.5em", "0.5"},
		{"translate3d(1px, 2px, 3px)", 0, 1, "translate3d(2px, 2px, 3px)", "2"},   // the 3 of the name is not a number
		{"margin: 0 auto", 14, 1, "margin: 1 auto", "1"},                         // after the caret none: the last before it
	}
	for c in cases {
		out, lo, hi, ok := ui.num_step_text(c.text, c.caret, c.delta)
		testing.expectf(t, ok && out == c.want && out[lo:hi] == c.number, "%q at %d by %v: %q [%d, %d) (want %q)", c.text, c.caret, c.delta, out, lo, hi, c.want)
	}
	for text in ([?]string{"#10f", "h1", "auto", ""}) {
		_, _, _, ok := ui.num_step_text(text, 0, 1)
		testing.expectf(t, !ok, "%q has no number", text)
	}
}) }

@(test)
a_field_steps_its_number_by_keys_and_wheel :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { f: ui.Text_Field, changed: int }
	r: Run
	defer ui.field_destroy(&r.f)
	ui.field_set(&r.f, "margin: 10px 5px")
	s := session.start(t, {user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(300)})
		res := ui.line_edit("###f", &r.f)
		if ui.field_num_step(&r.f, res.box) { r.changed += 1 }
	}})
	session.key(s, .Up)
	testing.expect_value(t, ui.field_string(&r.f), "margin: 10px 5px")   // not focused: nothing
	session.click(s, "f")
	session.key(s, .Home)
	session.key(s, .Right, repeat = len("margin: 1"))
	session.key(s, .Up, {.Shift})
	testing.expect_value(t, ui.field_string(&r.f), "margin: 20px 5px")
	testing.expect_value(t, ui.field_selection(&r.f), "20")
	session.key(s, .Down, {.Alt})
	testing.expect_value(t, ui.field_string(&r.f), "margin: 19.9px 5px")
	session.wheel(s, session.center(session.get(s, "f")), {0, -1})
	testing.expect_value(t, ui.field_string(&r.f), "margin: 20.9px 5px")
	session.wheel(s, session.center(session.get(s, "f")), {0, 1}, {.Shift})
	testing.expect_value(t, ui.field_string(&r.f), "margin: 10.9px 5px")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.field_string(&r.f), "margin: 20.9px 5px")   // a step is an edit of the field's history
	testing.expect(t, r.changed == 4, "each step says it changed")
}) }
