package scenarios_test

// A check box's long label with `wrap`: on the next lines, within its column, the row as tall as they are; without it, one line.

import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
LONG :: "Contrat entre unités - Format d'unité, description des fonctions, convention d'appel, chargeur"

@(private = "file")
Marks :: struct { a, b: bool }

@(test)
a_long_check_box_label_wraps_in_its_column :: proc(t: ^testing.T) {
	m: Marks
	s := session.start(t, {size = {400, 300}, user = &m, build = proc(s: ^session.Session) {
		m := (^Marks)(s.user)
		ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(200), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			ui.next({width = ui.fill()})
			ui.checkbox("###wrapped", LONG, &m.a, wrap = true)
			ui.next({width = ui.fill()})
			ui.checkbox("###one", LONG, &m.b)
		}
	}})
	session.frames(s, 2)
	col, wrapped, one := session.get(s, "col"), session.get(s, "wrapped"), session.get(s, "one")
	em := ui.font_size()
	wh := wrapped.rect.max.y - wrapped.rect.min.y
	oh := one.rect.max.y - one.rect.min.y
	testing.expectf(t, oh <= 2 * em + 0.5, "one line: as tall as a row (%v, em %v)", oh, em)
	testing.expectf(t, wh > 1.5 * oh, "several lines: %v high against one line's %v", wh, oh)
	testing.expectf(t, wrapped.rect.max.x <= col.rect.max.x + 0.5, "within its column: %v past %v", wrapped.rect.max.x, col.rect.max.x)
	label := wrapped.last
	testing.expect(t, label != nil && label.rect.max.x <= col.rect.max.x + 0.5, "its label too")
	// its mark stands on the first line: centered in it, as the one-line row's is in its row
	mark, one_mark := session.find(s, "mark", 0), session.find(s, "mark", 1)
	line := one.rect.max.y - one.rect.min.y
	mc := (mark.rect.min.y + mark.rect.max.y) * 0.5
	testing.expectf(t, abs(mc - (wrapped.rect.min.y + line * 0.5)) <= 1, "the mark on the first line: its centre %v, the line's %v", mc, wrapped.rect.min.y + line * 0.5)
	testing.expectf(t, abs((mark.rect.min.y - wrapped.rect.min.y) - (one_mark.rect.min.y - one.rect.min.y)) <= 1, "as the one-line row's: %v against %v", mark.rect.min.y - wrapped.rect.min.y, one_mark.rect.min.y - one.rect.min.y)
	session.click_at(s, session.center(wrapped))
	session.frames(s, 1)
	testing.expect(t, m.a, "a click on it checks it")
}
