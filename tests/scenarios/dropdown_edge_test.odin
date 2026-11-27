package scenarios_test

// A dropdown at the right of a card row, near the window's right edge (socle's settings, 1400 x 820 at 120 dpi): its
// list, wider than its button, moves left to show every row whole, inside the window; at the left edge, right.

import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file", rodata)
EDGE_ITEMS := [?]string{"English (United States)", "English (United Kingdom)", "Français (France)", "Deutsch (Deutschland)", "Português (Brasil)"}

@(private = "file")
Edge_Run :: struct { sel: int, left: bool }

@(private = "file")
edge_build :: proc(s: ^session.Session) {
	r := (^Edge_Run)(s.user)
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.parent(ui.build_box({}, "###page")) {
		ui.spacer(ui.px(em * 2))
		// a card: a row, its label at the left, the dropdown at its right, the card's own clip
		ui.next({width = ui.fill(), height = ui.px(em * 3), axis = .X, cross = .Center})
		if ui.parent(ui.build_box({.Clip}, "###card")) {
			ui.spacer(ui.px(em))
			if !r.left {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label("Language###language_label")
			}
			ui.next({width = ui.px(em * 7)})
			ui.dropdown("###language", EDGE_ITEMS[:], &r.sel)
			if r.left { ui.spacer(ui.fill()) }
			ui.spacer(ui.px(em * 0.5))
		}
	}
}

@(private = "file")
expect_whole_list :: proc(t: ^testing.T, s: ^session.Session, loc := #caller_location) {
	panel_r, _, ok := ui.menu_rect(0)
	if !testing.expect(t, ok, "the list is open", loc = loc) { return }
	w := f32(s.win.size.x)
	testing.expectf(t, panel_r.min.x >= -0.5 && panel_r.max.x <= w + 0.5, "the list inside the window: %v in %v", panel_r, w, loc = loc)
	for item in EDGE_ITEMS {
		// (the list's row, not the button's words)
		b: ^ui.Box
		for k in 0 ..< 3 {
			c := session.find_text(s, item, k)
			if c != nil && c.rect.min.y >= panel_r.min.y { b = c; break }
		}
		if !testing.expectf(t, b != nil, "%q listed", item, loc = loc) { continue }
		testing.expectf(t, b.rect.max.x - b.rect.min.x >= b.text_dim.x + 2 * b.text_pad - 0.5, "%q whole: %v for %v", item, b.rect, b.text_dim.x, loc = loc)
		testing.expectf(t, b.rect.max.x <= panel_r.max.x + 0.5, "%q inside the list: %v in %v", item, b.rect, panel_r, loc = loc)
	}
}

@(test)
a_dropdown_at_the_window_s_edge_shows_its_rows_whole :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Edge_Run
	s := session.start(t, {size = {1750, 1025}, dpi_scale = 1.25, user = &r, build = edge_build})
	session.wait_idle(s)
	session.click(s, "language")
	session.wait_text(s, "Português (Brasil)")
	session.wait_idle(s)
	session.save_png(s, "right_edge.png")
	expect_whole_list(t, s)
	session.key(s, .Escape)
	session.wait_idle(s)
	r.left = true
	session.wait_idle(s)
	session.click(s, "language")
	session.wait_text(s, "Português (Brasil)")
	session.wait_idle(s)
	session.save_png(s, "left_edge.png")
	expect_whole_list(t, s)
}) }
