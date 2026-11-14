package prefs_page_test

import "core:fmt"
import "core:testing"
import prefs_page "../../src/prefs_page"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
Cards :: struct { current: string, picked: int }

// A click on a theme's card picks it; the one shown is not picked again.
@(test)
a_card_click_picks_its_theme :: proc(t: ^testing.T) {
	c := Cards{current = ui.THEMES[0].name, picked = -1}
	s := session.start(t, {size = {900, 600}, user = &c, build = proc(s: ^session.Session) {
		c := (^Cards)(s.user)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###cards") {
			if at := prefs_page.theme_cards(ui.THEMES[:6], c.current, false, ui.font_size()); at >= 0 { c.picked = at }
		}
	}})
	session.click_text(s, ui.THEMES[1].name)
	testing.expect_value(t, c.picked, 1)
	c.picked = -1
	session.click(s, "th2")
	testing.expect_value(t, c.picked, 2)
}

@(private = "file")
Grid :: struct { count, columns: int }

// The cards of a last row that is not full have the width of the full rows' cards, at their columns, and what is in
// a card stays in it: at 3 columns and at 2, with one card left over.
@(test)
a_short_last_row_keeps_the_column_width_at_3 :: proc(t: ^testing.T) {
	g := Grid{7, 3}   // (a last row of one card)
	expect_even_grid(t, &g)
}

@(test)
a_last_row_of_two_keeps_the_column_width_at_3 :: proc(t: ^testing.T) {
	g := Grid{8, 3}
	expect_even_grid(t, &g)
}

@(test)
a_short_last_row_keeps_the_column_width_at_2 :: proc(t: ^testing.T) {
	g := Grid{5, 2}
	expect_even_grid(t, &g)
}

@(private = "file")
expect_even_grid :: proc(t: ^testing.T, g: ^Grid, loc := #caller_location) {
	s := session.start(t, {size = {900, 600}, user = g, build = proc(s: ^session.Session) {
		g := (^Grid)(s.user)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###cards") {
			prefs_page.theme_cards(ui.THEMES[:g.count], ui.THEMES[0].name, false, ui.font_size(), g.columns)
		}
	}}, loc)
	first := session.get(s, "th0")
	w := first.rect.max.x - first.rect.min.x
	testing.expectf(t, w > 100, "%v: a card is %v px wide", g^, w, loc = loc)
	for i in 0 ..< g.count {
		card := session.get(s, fmt.tprintf("th%d", i))
		cw := card.rect.max.x - card.rect.min.x
		testing.expectf(t, abs(cw - w) <= 1, "%v: card %d is %v px wide, card 0 %v", g^, i, cw, w, loc = loc)
		// (at its column: the card above it starts where it does)
		if i >= g.columns {
			above := session.get(s, fmt.tprintf("th%d", i - g.columns))
			testing.expectf(t, abs(card.rect.min.x - above.rect.min.x) <= 1, "%v: card %d starts at %v, the one above at %v", g^, i, card.rect.min.x, above.rect.min.x, loc = loc)
		}
		name := session.get(s, "t", within = card)
		testing.expectf(t, name.rect.min.x >= card.rect.min.x && name.rect.max.x <= card.rect.max.x, "%v: card %d's name %v passes its card %v", g^, i, name.rect, card.rect, loc = loc)
	}
}
