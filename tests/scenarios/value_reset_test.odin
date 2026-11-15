package scenarios_test

// A value comes back to its default (src/md/features/widget-table.md, G2): a double click on a slider's track, and the
// menu of a number's field ("Reset to 10"), set the default given; with no default, a double click is a press.

import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Reset_Run :: struct { level: f32, count: int, plain: f32, from, to: f32 }

@(private = "file")
reset_build :: proc(s: ^session.Session) {
	r := (^Reset_Run)(s.user)
	ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(300), height = ui.px(30)})
	ui.slider("###level", &r.level, 0, 100, 1, "%.0f", default = 50)
	ui.next({fixed_x = 10, fixed_y = 60, height = ui.px(30)})
	ui.number("###count", &r.count, lo = 0, hi = 99, default = 10)
	ui.next({fixed_x = 10, fixed_y = 110, width = ui.px(300), height = ui.px(30)})
	ui.slider("###plain", &r.plain, 0, 100, 1, "%.0f")
	ui.next({fixed_x = 10, fixed_y = 160, width = ui.px(300), height = ui.px(30)})
	ui.range_slider("###range", &r.from, &r.to, 0, 100, 1, "%.0f", default = [2]f32{20, 80})
}

@(test)
a_value_comes_back_to_its_default :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Reset_Run{level = 80, count = 42, plain = 80, from = 40, to = 60}
	s := session.start(t, {size = {400, 210}, user = &r, build = reset_build})
	session.frames(s, 2)
	level := session.get(s, "level")
	session.click_at(s, {level.rect.min.x + 20, session.center(level).y}, count = 2)
	session.frames(s, 2)
	testing.expect_value(t, r.level, 50)
	// the number's field: its menu
	session.click(s, "value", .Right)
	session.frames(s, 2)
	item, ok := ui.menu_item_rect(0, 0)
	if !testing.expect(t, ok, "the field's menu") { return }
	session.click_at(s, (item.min + item.max) * 0.5)
	session.frames(s, 2)
	testing.expect_value(t, r.count, 10)
	// no default: a double click is a press where it lands
	plain := session.get(s, "plain")
	session.click_at(s, {plain.rect.min.x + 20, session.center(plain).y}, count = 2)
	session.frames(s, 2)
	testing.expectf(t, r.plain < 50, "no default: the knob where it was pressed (%v)", r.plain)
	// a range: both ends back
	rng := session.get(s, "range")
	session.click_at(s, {rng.rect.min.x + 15, session.center(rng).y}, count = 2)
	session.frames(s, 2)
	testing.expectf(t, r.from == 20 && r.to == 80, "the range back to 20-80 (%v-%v)", r.from, r.to)
}) }
