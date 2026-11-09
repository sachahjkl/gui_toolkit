package prefs_page_test

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
