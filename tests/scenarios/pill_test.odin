package scenarios_test

// A pill (ui.pill): as wide as its icon and its words, rounded at its ends, a wash and a line of its colour, its words
// lighter; a screen reader reads its words once.

import "core:testing"
import "gt:lucide"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(test)
a_pill_is_as_wide_as_its_words :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {400, 80}, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 10, fixed_y = 10, height = ui.px(40), axis = .X, cross = .Center})
		if ui.row(.Center, {}, "###pills") {
			ui.pill("added", "Added", lucide.SPARKLES, ui.hue(.Green))
			ui.pill("long", "A longer label", "", ui.hue(.Blue))
		}
	}})
	session.frames(s, 2)
	added, long := session.get(s, "added"), session.get(s, "long")
	w, h := added.rect.max.x - added.rect.min.x, added.rect.max.y - added.rect.min.y
	testing.expectf(t, w > h && w < 160, "as wide as its icon and its words: %v", added.rect)
	testing.expect(t, long.rect.max.x - long.rect.min.x > w, "longer words, a wider pill")
	testing.expectf(t, abs(added.radius - h * 0.5) < 0.5, "rounded at its ends: %v of %v", added.radius, h)
	testing.expect(t, session.find(s, "icon", within = added) != nil && session.find(s, "icon", within = long) == nil, "an icon when given")
	green := ui.hue(.Green)
	testing.expect(t, added.bg.a > 0 && added.bg.a < 0.5 && added.bg.g == green.g, "a wash of its colour")
	text := session.find(s, "text", within = added)
	if !testing.expect(t, text != nil, "its words") { return }
	testing.expect(t, text.text_color.r > green.r, "its words lighter than its colour")
}) }
