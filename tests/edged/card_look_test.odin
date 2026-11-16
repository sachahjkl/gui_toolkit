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

@(private = "file") FACE :: ui.Color{0.5, 0.5, 0.5, 1}

// A card's edge: nil is the finish's, a colour of alpha 0 is none, Color{} included (a zero colour once meant the
// finish's, and a card could not ask for no edge with it).
@(test)
a_card_without_an_edge :: proc(t: ^testing.T) {
	for finish in ([]ui.Finish{.Machined, .Edged, .Flat}) {
		p := ui.palette_of("Kernel")
		p.finish = finish
		s := session.start(t, {size = {240, 320}, palette = p, build = proc(s: ^session.Session) {
			ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(240), height = ui.px(320), axis = .Y})
			if ui.column(id = "###page") {
				ui.spacer(ui.px(20))
				if ui.card("", id = "###edged", o = {radius = 4, look = {top = FACE, bottom = FACE, rim = 0, shadow = 0}}) {
					ui.spacer(ui.px(80))
				}
				ui.spacer(ui.px(20))
				if ui.card("", id = "###zero", o = {radius = 4, look = {top = FACE, bottom = FACE, border = ui.Color{}, rim = 0, shadow = 0}}) {
					ui.spacer(ui.px(80))
				}
				ui.spacer(ui.px(20))
				// (a theme's colour made transparent, as a program writes it)
				if ui.card("", id = "###clear", o = {radius = 4, look = {top = FACE, bottom = FACE, border = ui.with_alpha(EDGE, 0), rim = 0, shadow = 0}}) {
					ui.spacer(ui.px(80))
				}
			}
		}})
		session.frames(s, 2)
		img := session.capture(s)
		// (its outermost column at mid height against its face a few pixels in: the rim and the edged lines are along
		// its top and bottom, never there)
		edge_and_face :: proc(s: ^session.Session, img: session.Image, id: string) -> (edge, face: session.Color) {
			r := session.get(s, id).rect
			cy := int((r.min.y + r.max.y) * 0.5)
			return session.pixel(img, int(r.min.x), cy), session.pixel(img, int(r.min.x) + 4, cy)
		}
		e, f := edge_and_face(s, img, "edged")
		testing.expectf(t, !session.near(e, f, 6), "%v: nil, the finish's edge: %v on a face of %v", finish, e, f)
		for id in ([]string{"zero", "clear"}) {
			e, f = edge_and_face(s, img, id)
			testing.expectf(t, session.near(e, f, 3), "%v: %s, no edge: %v on a face of %v", finish, id, e, f)
		}
	}
}
