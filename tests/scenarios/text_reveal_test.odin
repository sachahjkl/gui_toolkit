package scenarios_test

// A cut text shows itself whole (src/md/features/text-reveal.md): the ellipsis of a cut title in a clickable row opens
// its whole text in a bubble that stays; the rest of the row still acts; Escape closes the bubble and only the bubble;
// Copy and Ctrl+C copy the whole text.

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") REVEAL_TEXT :: "/home/someone/Projects/kernel-devlog/2026-11-15_drawing_module/compare_all.png"

@(private = "file")
Reveal_Run :: struct { row_clicks, escapes: int }

@(test)
a_cut_text_s_ellipsis_shows_it_whole :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Reveal_Run
	s := session.start(t, {size = {600, 400}, user = &r, build = proc(s: ^session.Session) {
		r := (^Reveal_Run)(s.user)
		ui.spacer(ui.px(40))
		// (a row that acts, its title cut by its width)
		ui.next({width = ui.px(240), height = ui.px(32), axis = .X, cross = .Center})
		row := ui.build_box({.Clickable, .Draw_Background}, "###row")
		if ui.signal(row).clicked { r.row_clicks += 1 }
		if ui.parent(row) {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(REVEAL_TEXT + "###title")
		}
		// (the program's own Escape: the bubble's must not reach it)
		if ui.key_press(.Escape) { r.escapes += 1 }
	}})
	session.frames(s, 3)
	title := session.get(s, "title")
	if !testing.expect(t, title.ellipsis != {}, "the title is cut: its ellipsis is a target") { return }
	ell := (title.ellipsis.min + title.ellipsis.max) * 0.5

	// the ellipsis opens the whole text; the row does not act
	session.click_at(s, ell)
	session.frames(s, 2)
	text, open := ui.text_reveal_shown()
	testing.expect(t, open, "the bubble is open")
	testing.expect_value(t, text, REVEAL_TEXT)
	testing.expect_value(t, r.row_clicks, 0)
	testing.expect(t, session.find(s, "reveal_text") != nil, "the whole text in it")

	// Copy copies it all, and the bubble stays
	session.click(s, "reveal_copy")
	session.frames(s, 2)
	testing.expect_value(t, session.clipboard(s), REVEAL_TEXT)
	_, open = ui.text_reveal_shown()
	testing.expect(t, open, "it stays after Copy")

	// Escape closes it, and only it
	session.key(s, .Escape)
	session.frames(s, 2)
	_, open = ui.text_reveal_shown()
	testing.expect(t, !open, "Escape closed it")
	testing.expect_value(t, r.escapes, 0)

	// the rest of the row acts as before; a press outside the bubble closes it
	session.click_at(s, ell)
	session.frames(s, 2)
	_, open = ui.text_reveal_shown()
	testing.expect(t, open, "open again")
	session.click_at(s, {title.rect.min.x + 10, (title.rect.min.y + title.rect.max.y) * 0.5})
	session.frames(s, 2)
	_, open = ui.text_reveal_shown()
	testing.expect(t, !open, "a press outside closed it")
	testing.expect_value(t, r.row_clicks, 1)

	// its cross closes it
	session.click_at(s, ell)
	session.frames(s, 2)
	session.click(s, "reveal_close")
	session.frames(s, 2)
	_, open = ui.text_reveal_shown()
	testing.expect(t, !open, "the cross closed it")
}) }
