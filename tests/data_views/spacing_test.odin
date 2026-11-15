package data_views_test

// The spacing scale's blocks (src/md/features/spacing.md): a card's content sits the same inset from its four edges and
// nothing follows the card; a list card's first row sits as far from its edges as any card's content, and its rows are
// split by a hairline; a well's inset is the same on its four sides, and a well without an edge draws none.

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
spacing_build :: proc(s: ^session.Session) {
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(500), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###page") {
		if ui.card("") {
			ui.next({width = ui.fill(), height = ui.px(30)})
			ui.build_box({}, "###inner")
		}
		ui.next({width = ui.fill(), height = ui.px(10)})
		ui.build_box({}, "###after")
		if ui.list_card("###list") {
			for id in ([]string{"###r1", "###r2", "###r3"}) {
				if ui.card_row(id) {
					ui.next({width = ui.fill(), height = ui.px(20)})
					ui.build_box({}, "###cell")
				}
			}
		}
		ui.next({width = ui.px(200), height = ui.px(100)})
		if ui.well("###w", pad = ui.INNER_PAD, edge = false) {
			ui.next({width = ui.fill(), height = ui.fill()})
			ui.build_box({}, "###wi")
		}
	}
}

@(test)
the_blocks_keep_to_the_scale :: proc(t: ^testing.T) {
	s := session.start(t, {size = {500, 600}, no_renderer = true, build = spacing_build})
	session.frames(s, 3)

	card, inner, after := session.get(s, "card_"), session.get(s, "inner"), session.get(s, "after")
	left, top := inner.rect.min.x - card.rect.min.x, inner.rect.min.y - card.rect.min.y
	right, bottom := card.rect.max.x - inner.rect.max.x, card.rect.max.y - inner.rect.max.y
	testing.expectf(t, left > 0 && left == top && top == right && right == bottom, "a card's inset, its four sides: %v %v %v %v", left, top, right, bottom)
	testing.expect_value(t, after.rect.min.y, card.rect.max.y)   // (nothing after the card)

	list, r1, r2 := session.get(s, "list"), session.get(s, "r1_content"), session.get(s, "r2")
	testing.expect_value(t, r1.rect.min.y - list.rect.min.y, left)   // (the first row as far from the top as any content)
	testing.expect_value(t, r1.rect.min.x - list.rect.min.x, left)
	first := session.get(s, "r1")
	testing.expectf(t, r2.rect.min.y > first.rect.max.y, "a hairline between two rows: %v, %v", first.rect, r2.rect)

	w, wi := session.get(s, "w"), session.get(s, "wi")
	wl, wt := wi.rect.min.x - w.rect.min.x, wi.rect.min.y - w.rect.min.y
	wr, wb := w.rect.max.x - wi.rect.max.x, w.rect.max.y - wi.rect.max.y
	testing.expectf(t, wl > 0 && wl == wt && wt == wr && wr == wb, "a well's inset, its four sides: %v %v %v %v", wl, wt, wr, wb)
	testing.expect(t, .Draw_Border not_in w.flags, "a well without an edge draws none")
}
