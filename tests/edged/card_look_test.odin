package edged_test

// A card with its own look (ui.Card_Options): a program's permission card is a ui.card, in every finish.

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") TOP    :: ui.Color{0.9, 0.1, 0.1, 1}
@(private = "file") BOTTOM :: ui.Color{0.1, 0.1, 0.9, 1}
@(private = "file") EDGE   :: ui.Color{0.1, 0.9, 0.1, 1}

// Its face goes from its top colour to its bottom one (the flat forms: their mean, the same at the top and the bottom),
// its edge is its own colour, its id is the one given. A card without a look keeps the theme's.
@(test)
a_card_with_its_own_look :: proc(t: ^testing.T) {
	for finish in ([]ui.Finish{.Machined, .Edged, .Flat}) {
		p := ui.palette_of("Kernel")
		p.finish = finish
		s := session.start(t, {size = {240, 320}, palette = p, build = proc(s: ^session.Session) {
			ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(240), height = ui.px(320), axis = .Y})
			if ui.column(id = "###page") {
				ui.spacer(ui.px(20))
				if ui.card("", id = "###warm", o = {radius = 4, look = {top = TOP, bottom = BOTTOM, border = EDGE, shadow = 0}}) {
					ui.spacer(ui.px(120))
				}
				ui.spacer(ui.px(20))
				if ui.card("Plain") { ui.spacer(ui.px(20)) }
			}
		}})
		session.frames(s, 2)
		card := session.find(s, "warm")
		if !testing.expectf(t, card != nil, "%v: the card has its id", finish) { continue }
		testing.expect(t, session.find(s, "card_Plain").plate == nil)
		r := card.rect
		img := session.capture(s)
		cx, cy := int((r.min.x + r.max.x) * 0.5), int((r.min.y + r.max.y) * 0.5)
		top, bottom := session.pixel(img, cx, int(r.min.y) + 6), session.pixel(img, cx, int(r.max.y) - 6)
		edge := session.pixel(img, int(r.min.x), cy)
		if finish == .Flat {
			testing.expectf(t, session.near(top, bottom, 3), "%v: one face, %v at the top, %v at the bottom", finish, top, bottom)
			testing.expectf(t, int(top.r) > int(top.g) + 40 && int(top.b) > int(top.g) + 40, "%v: the mean of its colours, %v", finish, top)
		} else {
			testing.expectf(t, int(top.r) > int(top.b) + 80, "%v: its top colour at the top, %v", finish, top)
			testing.expectf(t, int(bottom.b) > int(bottom.r) + 80, "%v: its bottom colour at the bottom, %v", finish, bottom)
		}
		testing.expectf(t, int(edge.g) > int(edge.r) + 60 && int(edge.g) > int(edge.b) + 60, "%v: its edge, %v", finish, edge)
	}
}
