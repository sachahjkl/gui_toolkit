package scenarios_test

// ui.check_mark: a check box's mark alone, its box the mark, placed by its caller (here at a row's end); a click and
// Space toggle it, a screen reader reads a check box.

import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Marked :: struct { on: bool, changes: int }

@(test)
a_check_mark_is_its_mark_where_it_is_put :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	m: Marked
	s := session.start(t, {size = {400, 200}, no_renderer = true, user = &m, build = proc(s: ^session.Session) {
		m := (^Marked)(s.user)
		ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(300), height = ui.px(40), axis = .X, cross = .Center})
		if ui.row(id = "###line") {
			ui.spacer(ui.fill())
			if ui.check_mark("###mark", &m.on) { m.changes += 1 }
		}
	}})
	session.frames(s, 2)
	line, mark := session.get(s, "line"), session.get(s, "mark")
	w, h := mark.rect.max.x - mark.rect.min.x, mark.rect.max.y - mark.rect.min.y
	testing.expectf(t, abs(w - h) < 0.5 && w < ui.font_size() * 2, "a mark's square, no room for words: %v x %v", w, h)
	testing.expectf(t, abs(mark.rect.max.x - line.rect.max.x) < 0.5, "at the row's end: %v, the row's %v", mark.rect.max.x, line.rect.max.x)
	testing.expect(t, mark.a11y != nil && mark.a11y.role == .Check_Box, "a check box to a screen reader")
	session.click(s, "mark")
	testing.expect(t, m.on, "a click ticks it")
	testing.expect_value(t, m.changes, 1)
	session.key(s, .Space)
	testing.expect(t, !m.on, "Space unticks it")
	testing.expect_value(t, m.changes, 2)
}) }
