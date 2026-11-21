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

// The wireframe reads what each gap is: one made by space knows its step, one made by hand is off the scale (step 0);
// set_wireframe turns it on and off. (Its drawing is kept in wireframe.png.)
@(test)
the_wireframe_knows_each_gap :: proc(t: ^testing.T) {
	s := session.start(t, {size = {500, 600}, build = proc(s: ^session.Session) {
		spacing_build(s)
		ui.next({fixed_x = 0, fixed_y = 560, width = ui.px(300), height = ui.px(20), axis = .X})
		if ui.row(id = "###gaps") {
			ui.space(ui.ITEM_GAP)
			ui.spacer(ui.px(7))
		}
	}})
	session.frames(s, 2)
	row := session.get(s, "gaps")
	testing.expect(t, row.first != nil && row.first.next != nil)
	if row.first == nil || row.first.next == nil { return }
	testing.expect(t, .Gap in row.first.flags && row.first.gap_step == ui.ITEM_GAP, "space knows its step")
	testing.expect(t, .Gap in row.first.next.flags && row.first.next.gap_step == 0, "a gap by hand is off the scale")
	ui.set_wireframe(s.state, true)
	session.frames(s, 2)
	testing.expect(t, s.state.wireframe)
	session.save_png(s, "wireframe.png")
	ui.set_wireframe(s.state, false)
	testing.expect(t, !s.state.wireframe)
}

@(private = "file") exploded_clicks: int

// The exploded view (src/md/features/exploded-view.md) eases in from the flat page, then takes the pointer: a drag on
// the planes turns it, a click on a button under it presses nothing, a slider of its panel sets its yaw; Escape eases
// it back, and once flat the page takes clicks again. (Its drawing is kept in exploded.png.)
@(test)
the_exploded_view_turns_and_takes_the_pointer :: proc(t: ^testing.T) {
	exploded_clicks = 0
	s := session.start(t, {size = {500, 600}, animations = true, build = proc(s: ^session.Session) {
		spacing_build(s)
		ui.next({fixed_x = 20, fixed_y = 540, width = ui.px(120), height = ui.px(40)})
		if ui.button("go", "Go").clicked { exploded_clicks += 1 }
	}})
	session.frames(s, 2)
	go := session.center(session.get(s, "go"))
	ui.set_exploded(s.state, true)
	session.frames(s, 2)
	testing.expect(t, ui.exploded(s.state))
	testing.expectf(t, s.state.exploded.t > 0 && s.state.exploded.t < 1, "it eases in: t %v", s.state.exploded.t)
	session.advance(s, 1000)
	testing.expect_value(t, s.state.exploded.t, 1)
	// (on the planes, left of the panel)
	yaw := s.state.exploded.yaw
	session.drag(s, {40, 300}, {140, 300})
	testing.expectf(t, s.state.exploded.yaw != yaw, "a drag across turns the view: yaw %v, then %v", yaw, s.state.exploded.yaw)
	session.click_at(s, go)
	testing.expect_value(t, exploded_clicks, 0)   // (the page takes no click under the view)
	// (the panel, a view, floats at the right at first; the yaw slider's left end: its least)
	slider := session.get(s, "exploded_yaw")
	testing.expectf(t, slider.rect.max.x > 400, "the panel floats at the right: its slider at %v", slider.rect)
	session.drag(s, session.center(slider), {slider.rect.min.x + 1, session.center(slider).y})
	testing.expect_value(t, s.state.exploded.yaw, -0.5)
	session.save_png(s, "exploded.png")
	session.key(s, .Escape)
	testing.expect(t, !ui.exploded(s.state), "Escape turns it off")
	session.click_at(s, go)
	testing.expect_value(t, exploded_clicks, 0)   // (on its way back, the view still takes the pointer)
	session.advance(s, 1000)
	testing.expect_value(t, s.state.exploded.t, 0)
	session.click_at(s, go)
	testing.expect_value(t, exploded_clicks, 1)
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

// What card_box answered at each place of the build: in a card, in a list card's row, in a card inside a card, after
// the inner card's end, outside every card.
@(private = "file") Card_Boxes :: struct { card, row, nested, after_nested, outside: ^ui.Box }
@(private = "file") card_boxes: Card_Boxes

// card_box is the innermost card's own box (its .Plate panel), from anywhere in its scope; none outside a card.
@(test)
a_card_gives_its_box :: proc(t: ^testing.T) {
	card_boxes = {}
	s := session.start(t, {size = {500, 600}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(500), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###page") {
			if ui.card("Outer") {
				card_boxes.card = ui.card_box()
				if ui.card("", id = "###inner_card") { card_boxes.nested = ui.card_box() }
				card_boxes.after_nested = ui.card_box()
			}
			if ui.list_card("###list") {
				if ui.card_row("###r1") { card_boxes.row = ui.card_box() }
			}
			card_boxes.outside = ui.card_box()
		}
	}})
	session.frames(s, 2)
	outer, inner, list := session.get(s, "card_Outer"), session.get(s, "inner_card"), session.get(s, "list")
	testing.expect(t, card_boxes.card == outer && .Plate in outer.flags, "in a card: its box")
	testing.expect(t, card_boxes.nested == inner, "in a card inside a card: the inner one")
	testing.expect(t, card_boxes.after_nested == outer, "after the inner card: the outer one again")
	testing.expect(t, card_boxes.row == list, "in a list card's row: the list card")
	testing.expect(t, card_boxes.outside == nil, "outside every card: none")
}
