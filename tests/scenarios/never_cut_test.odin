package scenarios_test

// Words a person must read are never cut nor past an edge: a button grows to its words, or wraps them; a dialog grows to its
// title and its buttons, then wraps them; a tool bar folds its groups into its "…" panel; a popover grows to what is in it.

import "core:fmt"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") NARROW :: 90   // a column narrower than a button's words
@(private = "file") SMALL :: 40    // a width in pixels smaller than a button's words
@(private = "file") LONG_TITLE :: "Fermer l'éditeur et abandonner les modifications ?"
@(private = "file") LONG_ACT :: "Abandonner les modifications"

// The rect of `b` holds the rect of `inner` (a pixel of rounding aside).
@(private = "file")
holds :: proc(b, inner: ^ui.Box) -> bool {
	return inner.rect.min.x >= b.rect.min.x - 1 && inner.rect.max.x <= b.rect.max.x + 1
}

// A width in pixels is a least: the button is as wide as its words. In a column narrower than its words, they wrap and the
// button is taller, within the column.
@(test)
a_button_grows_to_its_words_or_wraps_them :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {500, 400}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(SMALL)})
		ui.button("small", "Enregistrer sous")
		ui.next({width = ui.px(NARROW), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###narrow") { ui.button("wraps", "Abandonner les modifications") }
		ui.button("plain", "Save")
	}})
	session.frames(s, 2)
	small := session.get(s, "small")
	words := session.get(s, "t", within = small)
	testing.expectf(t, words.size.x >= words.text_dim.x, "its words whole: %v of %v", words.size.x, words.text_dim.x)
	testing.expect(t, holds(small, words), "its words inside it")
	col := session.get(s, "narrow")
	wraps := session.get(s, "wraps")
	testing.expectf(t, wraps.size.x <= col.size.x + 1, "within the column: %v in %v", wraps.size.x, col.size.x)
	testing.expectf(t, wraps.size.y > session.get(s, "plain").size.y, "taller: its words on more lines (%v)", wraps.size.y)
	testing.expect(t, holds(wraps, session.get(s, "t", within = wraps)), "its words inside it")
}) }

// A confirmation grows to its title and its buttons; in a narrow window its title and its buttons wrap, all of them
// inside it. Its Cancel is a plain button.
@(test)
a_dialog_holds_its_title_and_buttons :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { open: bool }
	r := Run{open = true}
	s := session.start(t, {size = {1300, 700}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		_ = ui.confirm("ask", &r.open, {title = LONG_TITLE, note = "Les annotations de cette image sont perdues.", act = LONG_ACT})
	}})
	session.frames(s, 3)
	check :: proc(t: ^testing.T, s: ^session.Session, wrapped: bool) {
		panel := session.get(s, "modal_ask")
		title := session.get(s, "confirm_title_title")
		testing.expect(t, holds(panel, title), "the title inside the dialog")
		if !wrapped { testing.expectf(t, title.size.x >= title.text_dim.x, "the title on one line, whole: %v of %v", title.size.x, title.text_dim.x) }
		for name in ([]string{"confirm_cancel", "confirm_act"}) {
			b := session.get(s, name)
			testing.expectf(t, holds(panel, b), "%s inside the dialog: %v in %v", name, b.rect, panel.rect)
			testing.expect(t, holds(b, session.get(s, "t", within = b)), "its words inside it")
		}
	}
	check(t, s, false)
	cancel := session.get(s, "confirm_cancel")
	testing.expect(t, ui.box_text(session.get(s, "t", within = cancel)) != "", "Cancel has words")
	session.resize(s, {360, 700})
	session.frames(s, 3)
	check(t, s, true)
}) }

// A tool bar too narrow for its groups folds the lowest priority first; its pinned group stays in the bar; the "…" button
// opens a panel where the folded group is built and works.
@(test)
a_toolbar_folds_what_does_not_fit :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { clicks: int }
	r := Run{}
	s := session.start(t, {size = {900, 300}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("bar") {
			if ui.toolbar_group("first", {priority = 2}) {
				for i in 0 ..< 4 { ui.button(fmt.tprintf("a%d", i), "Outil") }
			}
			if ui.toolbar_group("middle", {separator = true}) {
				if ui.button("mid", "Propriétés de la forme").clicked { r.clicks += 1 }
			}
			ui.spacer(ui.fill())
			if ui.toolbar_group("end", {pinned = true}) {
				ui.button("cancel", "Annuler")
				ui.button("done", "Terminé")
			}
		}
	}})
	session.frames(s, 3)
	testing.expect(t, session.find(s, "mid") != nil, "room for all: nothing folds")
	testing.expect(t, session.find(s, "toolbar_more") == nil, "no \"…\"")
	session.resize(s, {420, 300})
	session.frames(s, 3)
	bar := session.get(s, "bar")
	testing.expect(t, session.find(s, "mid") == nil, "the lowest priority folded")
	testing.expect(t, session.find(s, "toolbar_more") != nil, "its \"…\" button")
	testing.expect(t, holds(bar, session.get(s, "done")), "the pinned group stays in the bar")
	session.click(s, "toolbar_more")
	mid := session.wait_box(s, "mid")
	testing.expect(t, !holds(bar, mid) || mid.rect.min.y >= bar.rect.max.y, "built in the panel, under the bar")
	session.click(s, "mid")
	testing.expect_value(t, r.clicks, 1)
	testing.expect(t, ui.toolbar_menu_open("bar"), "a click in the panel keeps it open")
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect(t, !ui.toolbar_menu_open("bar"), "Escape closes it")
}) }

// A popover narrower than what is in it grows to it.
@(test)
a_popover_grows_to_what_is_in_it :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {600, 300}, no_renderer = true, build = proc(s: ^session.Session) {
		if ui.popover("###chip", {{100, 200}, {101, 201}}, 40, .Above, align_right = false) {
			ui.next({width = ui.fill(), height = ui.px(30), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###r") {
				ui.button("quote", "Citer", o = {face = .Ghost, width = ui.fill()})
				ui.button("comment", "Commenter", o = {face = .Ghost, width = ui.fill()})
			}
		}
	}})
	session.frames(s, 3)
	chip := session.get(s, "chip")
	for name in ([]string{"quote", "comment"}) {
		b := session.get(s, name)
		testing.expectf(t, holds(chip, b), "%s inside the popover", name)
		w := session.get(s, "t", within = b)
		testing.expectf(t, w.size.x >= w.text_dim.x, "%s: its words whole", name)
	}
}) }
