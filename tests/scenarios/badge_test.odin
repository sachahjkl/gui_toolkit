package scenarios_test

// A count on a button's corner: its digits in a pill at the top right, "99+" past 99, nothing at 0; the button keeps its click.

import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Badged :: struct { count, clicks: int }

@(private = "file")
badged_build :: proc(s: ^session.Session) {
	r := (^Badged)(s.user)
	ui.next({fixed_x = 100, fixed_y = 100, width = ui.px(40), height = ui.px(40)})
	sig := ui.button("bell", icon = ui.ICON_UP)
	if sig.clicked { r.clicks += 1 }
	ui.badge(sig.box, r.count)
}

@(test)
a_badge_shows_its_count_on_the_corner :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Badged{count = 3}
	s := session.start(t, {size = {400, 300}, user = &r, no_renderer = true, build = badged_build})
	pill := session.get(s, "badge_count")
	testing.expect_value(t, ui.box_text(pill), "3")
	button := session.get(s, "bell")
	testing.expect(t, abs(pill.rect.max.x - button.rect.max.x) < 0.5 && abs(pill.rect.min.y - button.rect.min.y) < 0.5, "at the top right corner")
	testing.expect(t, pill.rect.max.x - pill.rect.min.x < button.rect.max.x - button.rect.min.x, "smaller than the button")
	session.click_at(s, {pill.rect.min.x + 2, pill.rect.min.y + 2})
	testing.expect_value(t, r.clicks, 1)

	r.count = 120
	session.frames(s, 2)
	testing.expect_value(t, ui.box_text(session.get(s, "badge_count")), "99+")

	r.count = 0
	session.frames(s, 2)
	testing.expect(t, session.find(s, "badge_count") == nil, "no badge at 0")
	testing.expect(t, session.find(s, "badge") == nil)
}) }

// On a button sized by its words, the count is at that button's corner, not at a distant ancestor's: the layout sizes the
// badge's floating box from the button once the button's words are measured.
@(test)
a_badge_on_words_sits_on_their_button :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {400, 300}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 100, fixed_y = 100})
		sig := ui.button("inbox", "Inbox")
		ui.badge(sig.box, 5)
	}})
	session.frames(s, 2)
	button := session.get(s, "inbox")
	pill := session.get(s, "badge_count")
	// (inside its border)
	testing.expectf(t, pill.rect.max.x <= button.rect.max.x && button.rect.max.x - pill.rect.max.x <= 3 && pill.rect.min.y >= button.rect.min.y && pill.rect.min.y - button.rect.min.y <= 3, "at the button's top right corner: %v in %v", pill.rect, button.rect)
}) }
