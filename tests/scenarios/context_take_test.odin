package scenarios_test

// ui.context_take: a block that is no button (a message, a card) takes a right press for its menu. The innermost that
// asks keeps it, one box a build; a field that opened its own menu on that press keeps it; a left press is nobody's.

import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Ctx_Run :: struct { inner, outer: int, field: ui.Line_Edit }

@(private = "file")
ctx_build :: proc(s: ^session.Session) {
	r := (^Ctx_Run)(s.user)
	ui.next({width = ui.px(400), height = ui.px(300), axis = .Y})
	outer := ui.build_box({.Draw_Background}, "###outer")
	if ui.parent(outer) {
		ui.next({width = ui.px(200), height = ui.px(100)})
		inner := ui.build_box({.Draw_Background}, "###inner")
		ui.next({width = ui.px(200), height = ui.px(30)})
		ui.line_edit("###field", &r.field)
		// (each after what is in it: the inner first)
		if ui.context_take(inner) { r.inner += 1 }
	}
	if ui.context_take(outer) { r.outer += 1 }
}

@(test)
the_innermost_block_takes_the_right_press :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Ctx_Run
	defer ui.line_edit_destroy(&r.field)
	s := session.start(t, {size = {600, 400}, user = &r, build = ctx_build, no_renderer = true})
	session.wait_idle(s)
	session.click_at(s, session.center(session.get(s, "inner")), .Right)
	session.wait_idle(s)
	testing.expect_value(t, r.inner, 1)
	testing.expect_value(t, r.outer, 0)   // (one box a build: the inner kept it)
	o := session.get(s, "outer")
	session.click_at(s, {o.rect.min.x + 300, o.rect.min.y + 250}, .Right)   // (outside the inner block)
	session.wait_idle(s)
	testing.expect_value(t, r.outer, 1)
	session.click_at(s, {o.rect.min.x + 300, o.rect.min.y + 250})   // (a left press: nobody's)
	session.wait_idle(s)
	testing.expect_value(t, r.outer, 1)
	session.click_at(s, session.center(session.get(s, "field")), .Right)   // (the field's own menu keeps it)
	session.wait_idle(s)
	testing.expect_value(t, r.outer, 1)
	testing.expect_value(t, r.inner, 1)
}) }
