package edged_test

import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

// A dialog's search strip (dialog_top_draw with no colour of its own: a palette's) is a field's background, as a menu's
// search band is (a box under the "input" tag): one look wherever one searches. It was the dialog's own background: it took
// the box's, which every box in a dialog has.
@(test)
a_search_strip_is_a_menus_search_band :: proc(t: ^testing.T) { strip_is_band(t, "OpenCode") }

@(test)
a_search_strip_is_a_menus_search_band_in_midnight :: proc(t: ^testing.T) { strip_is_band(t, "Midnight") }

@(private = "file")
strip_is_band :: proc(t: ^testing.T, name: string) {
	s := session.start(t, {size = {240, 120}, palette = ui.palette_of(name), build = proc(s: ^session.Session) {
		// (in a dialog's tags: every box there has the dialog's background, the strip too)
		ui.push_tags("floating")
		defer ui.pop_tags()
		ui.next({fixed_x = 20, fixed_y = 10, width = ui.px(200), height = ui.px(40)})
		strip := ui.build_box({}, "###strip")
		strip.custom = ui.dialog_top_draw
		ui.push_tags("input")
		ui.next({fixed_x = 20, fixed_y = 70, width = ui.px(200), height = ui.px(40)})
		ui.build_box({.Draw_Background}, "###band")
		ui.pop_tags()
	}})
	session.frames(s, 2)
	img := session.capture(s)
	strip, band := session.pixel(img, 120, 25), session.pixel(img, 120, 90)
	testing.expectf(t, session.near(strip, band, 2), "%s: the strip %v, the menu's band %v", name, strip, band)
}
