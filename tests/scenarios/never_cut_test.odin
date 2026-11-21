package scenarios_test

// Words a person must read are never cut nor past an edge: a button grows to its words, or wraps them; a dialog grows to its
// title and its buttons, then wraps them; a tool bar folds its groups into its "…" menu; a popover grows to what is in it.

import "core:fmt"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") NARROW :: 170   // a column narrower than a button's words, wider than its longest word
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
	// wrapped buttons keep vertical breathing room above and below their lines (never flush with the pill edges)
	wt := session.get(s, "t", within = wraps)
	testing.expectf(t, wraps.size.y > wt.text_dim.y + 4, "vertical breathing room around wrapped lines: button %v vs lines %v", wraps.size.y, wt.text_dim.y)
}) }

// A .Row button (sidebar nav item, list row) stays one sleek line and truncates with "…" when narrower than its label,
// instead of wrapping onto two cramped lines.
@(test)
a_row_button_stays_one_line_and_truncates :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {400, 200}, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(110), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###side") {
			ui.button("nav_long", "Numbers and ranges", "", {face = .Row, width = ui.fill(), left = true})
			ui.button("nav_short", "Menus", "", {face = .Row, width = ui.fill(), left = true})
		}
	}})
	session.frames(s, 2)
	long_b := session.get(s, "nav_long")
	short_b := session.get(s, "nav_short")
	testing.expectf(t, abs(long_b.size.y - short_b.size.y) <= 1, "one line tall as a short row: %v vs %v", long_b.size.y, short_b.size.y)
	lbl := session.get(s, "t", within = long_b)
	testing.expect(t, lbl.ellipsis != {}, "truncated with an ellipsis")
}) }

// Every choice control with a next and previous value (dropdown, segmented pills and text) steps on the wheel: on hover
// outside a scrolling view, and only once focused inside one.
@(test)
the_wheel_steps_dropdown_and_segmented :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { dd, seg, seg_txt, in_scroll: int }
	r := Run{dd = 1, seg = 1, seg_txt = 1, in_scroll = 1}
	s := session.start(t, {size = {500, 320}, no_renderer = true, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		items := []string{"One", "Two", "Three"}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.column(id = "###root") {
			ui.dropdown("dd", items, &r.dd)
			ui.segmented("seg", items, &r.seg)
			ui.segmented("seg_txt", items, &r.seg_txt, look = .Text)
			ui.next({width = ui.px(300), height = ui.px(120)})
			if ui.scroll_y("###sc") {
				ui.dropdown("dd_sc", items, &r.in_scroll)
				ui.spacer(ui.px(300))
			}
		}
	}})
	session.frames(s, 2)
	// outside a scroll view: hover + wheel steps immediately (down = next, up = previous)
	session.wheel(s, session.center(session.get(s, "dd")), {0, 1})
	testing.expect_value(t, r.dd, 2)
	session.wheel(s, session.center(session.get(s, "dd")), {0, -1})
	testing.expect_value(t, r.dd, 1)
	session.wheel(s, session.center(session.get(s, "seg")), {0, 1})
	testing.expect_value(t, r.seg, 2)
	session.wheel(s, session.center(session.get(s, "seg")), {0, -1})
	testing.expect_value(t, r.seg, 1)
	session.wheel(s, session.center(session.get(s, "seg_txt")), {0, 1})
	testing.expect_value(t, r.seg_txt, 2)
	// inside a scroll view: unfocused wheel scrolls the view (up at top keeps dd_sc in view), never changes the dropdown
	session.wheel(s, session.center(session.get(s, "dd_sc")), {0, -1})
	testing.expect_value(t, r.in_scroll, 1)
	// focused inside a scroll view: wheel steps the dropdown
	ui.use(s.state)
	ui.set_focus(session.get(s, "dd_sc").key)
	session.frame(s)
	dd_sc := session.get(s, "dd_sc")
	session.wheel(s, session.center(dd_sc), {0, 1})
	testing.expectf(t, r.in_scroll == 2, "expected 2, got %d (sc.rect=%v dd.rect=%v)", r.in_scroll, session.get(s, "sc").rect, dd_sc.rect)
}) }

// An icon-only .Row button (a collapsed sidebar rail item) shows its tooltip on hover with zero delay, because the
// tooltip is its only label.
@(test)
a_collapsed_rail_button_shows_its_tooltip_immediately :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {300, 120}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(32), height = ui.px(32)})
		ui.button("rail_item", "", "*", {face = .Row, width = ui.px(32), height = 32, tip = "Numbers and ranges"})
	}})
	session.frames(s, 2)
	session.move(s, session.center(session.get(s, "rail_item")))
	// zero extra time waited: tooltip is already visible on the hover frame
	testing.expect(t, session.find_text(s, "Numbers and ranges") != nil, "rail tooltip shown immediately with no delay")
}) }

// A word wider than the room is never split ("Vérifie / r / maint / enant"): the button grows past the column, its lines
// break only between words, each line a whole word.
@(test)
a_word_is_never_split :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {500, 400}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(SMALL), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###tiny") { ui.button("check", "Vérifier maintenant") }
	}})
	session.frames(s, 2)
	b := session.get(s, "check")
	words := session.get(s, "t", within = b)
	text := ui.box_text(words)
	lines := ui.wrap_lines_cached(words.font, words.font_size, text, words.size.x - 2 * words.text_pad)
	testing.expectf(t, len(lines) >= 1 && len(lines) <= 2, "one line or two: %d", len(lines))
	for l in lines {
		line := text[l[0]:l[1]]
		testing.expectf(t, line == "Vérifier" || line == "maintenant" || line == text, "a whole word a line: %q", line)
	}
	testing.expect(t, holds(b, words), "its words inside it")
}) }

// A confirmation grows to its title and its buttons; in a narrow window its title and its buttons wrap, all of them
// inside it. Its Cancel is a plain button.
@(test)
a_dialog_holds_its_title_and_buttons :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { open: bool }
	r := Run{open = true}
	s := session.start(t, {size = {1300, 700}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.open {
			r.open = false
			ui.confirm_open("ask", {title = LONG_TITLE, note = "Les annotations de cette image sont perdues.", act = LONG_ACT})
		}
	}})
	session.frames(s, 3)
	check :: proc(t: ^testing.T, s: ^session.Session, wrapped: bool) {
		panel := session.get(s, "modal_view_ask")
		title := session.get(s, "view_header_title")
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

// A dropdown with no width given, in a row as wide as its children (a view's header tools): as wide as its widest item
// and its arrow, its item whole. (The style's width, a share of a row that has none to share, made it a sliver.)
@(test)
a_dropdown_without_a_width_holds_its_items :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { sel: int }
	r := Run{sel = 1}
	s := session.start(t, {size = {600, 200}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.children_sum(), height = ui.px(30), axis = .X})
		if ui.row(id = "###tools") {
			items := []string{"Top to bottom", "Left to right"}
			ui.dropdown("###dd", items, &r.sel)
		}
	}})
	session.frames(s, 3)
	dd := session.get(s, "dd")
	cur := session.get(s, "cur", within = dd)
	testing.expectf(t, cur.size.x >= cur.text_dim.x, "its item whole: %v of %v", cur.size.x, cur.text_dim.x)
	testing.expectf(t, dd.size.x > cur.text_dim.x + 20, "with its arrow: %v", dd.size.x)
}) }

// A dialog's title of one long word, a path, wider than the dialog can be: it wraps between its characters, inside the
// dialog and before its close cross. (Its width never gave way: it ran under the cross and past the dialog's edge.)
@(test)
a_dialog_s_path_title_wraps_before_its_cross :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { open: bool }
	r := Run{open = true}
	s := session.start(t, {size = {700, 500}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.open {
			r.open = false
			ui.confirm_open("path", {title = "/home/someone/Projects/kernel-devlog/2026-11-15_drawing_module/compare_all_the_frames_of_the_run.png", act = "Open"})
		}
	}})
	session.frames(s, 3)
	panel := session.get(s, "modal_view_path")
	title := session.get(s, "view_header_title")
	cross := session.get(s, "dialog_close")
	testing.expectf(t, holds(panel, title), "the title inside the dialog: %v in %v", title.rect, panel.rect)
	testing.expectf(t, title.rect.max.x <= cross.rect.min.x + 0.5, "the title before the cross: %v, %v", title.rect, cross.rect)
	testing.expectf(t, title.rect.max.y - title.rect.min.y > title.text_dim.y * 0.5 + 1, "on more lines than one (%v)", title.rect)
}) }

// A tool bar too narrow for its groups folds the lowest priority first; its pinned group stays in the bar; the "…" button
// opens a menu where the folded tool is a row under its group's title, and a click on it runs it and closes the menu.
@(test)
a_toolbar_folds_what_does_not_fit :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { clicks: int }
	r := Run{}
	s := session.start(t, {size = {900, 300}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("bar", {overflow = .Fold}) {
			if ui.toolbar_group("first", {priority = 2}) {
				for i in 0 ..< 4 { _ = ui.toolbar_tool(fmt.tprintf("a%d", i), {label = "Outil", words = true}) }
			}
			if ui.toolbar_group("middle", {title = "Géométrie", separator = true}) {
				if ui.toolbar_tool("mid", {label = "Propriétés de la forme", words = true}) { r.clicks += 1 }
				_ = ui.toolbar_tool("outline", {label = "Contour", words = true})   // (two items: the menu shows its title)
			}
			if ui.toolbar_group("end", {pinned = true}) {
				_ = ui.toolbar_tool("cancel", {label = "Annuler", words = true})
				_ = ui.toolbar_tool("done", {label = "Terminé", words = true, intent = .Primary})
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
	row := session.wait_text(s, "Propriétés de la forme")
	testing.expect(t, row.rect.min.y >= bar.rect.max.y, "a row of the menu, under the bar")
	testing.expect(t, session.find_text(s, "Géométrie") != nil, "its section's title")
	testing.expect(t, ui.toolbar_menu_open("bar"), "the menu is open")
	session.click_text(s, "Propriétés de la forme")
	session.frames(s, 2)
	testing.expect_value(t, r.clicks, 1)
	testing.expect(t, !ui.toolbar_menu_open("bar"), "a tool chosen closes the menu")
	session.click(s, "toolbar_more")
	session.wait_text(s, "Propriétés de la forme")
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect(t, !ui.toolbar_menu_open("bar"), "Escape closes it")
}) }

// A group of items folds item by item, its last first: at a width where it fits but for its last items, only those fold,
// the others stay in the bar, and no room is left that the first folded item would fill. A folded item works in the menu.
@(test)
a_toolbar_folds_a_group_item_by_item :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	ITEMS :: 6
	Run :: struct { clicks: int }
	r := Run{}
	s := session.start(t, {size = {1200, 300}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("bar", {overflow = .Fold}) {
			if ui.toolbar_group("tools", {priority = 2}) {
				for i in 0 ..< 3 { _ = ui.toolbar_tool(fmt.tprintf("a%d", i), {label = "Outil", words = true}) }
			}
			if ui.toolbar_group("props", {separator = true}) {
				for i in 0 ..< ITEMS {
					if ui.toolbar_tool(fmt.tprintf("p%d", i), {label = fmt.tprintf("Propriété %d", i), words = true}) { r.clicks += 1 }
				}
			}
			if ui.toolbar_group("end", {pinned = true}) { _ = ui.toolbar_tool("done", {label = "Terminé", words = true}) }
		}
	}})
	session.frames(s, 3)
	for i in 0 ..< ITEMS { testing.expectf(t, session.find(s, fmt.tprintf("p%d", i)) != nil, "room for all: p%d in the bar", i) }
	testing.expect(t, session.find(s, "toolbar_more") == nil, "no \"…\"")
	// (narrower by the room left and a item and a half: the last items fold, not the group)
	last := session.get(s, fmt.tprintf("p%d", ITEMS - 1))
	slack := session.get(s, "done").rect.min.x - last.rect.max.x
	session.resize(s, {int(1200 - slack - 1.5 * last.size.x), 300})
	session.frames(s, 4)
	bar := session.get(s, "bar")
	testing.expect(t, session.find(s, "toolbar_more") != nil, "its \"…\" button")
	testing.expect(t, session.find(s, "a0") != nil && session.find(s, "p0") != nil, "the tools and the first items stay")
	testing.expect(t, session.find(s, fmt.tprintf("p%d", ITEMS - 1)) == nil, "the last item folded")
	shown := 0
	for i in 0 ..< ITEMS {
		if session.find(s, fmt.tprintf("p%d", i)) == nil { break }
		shown += 1
	}
	for i in shown ..< ITEMS { testing.expectf(t, session.find(s, fmt.tprintf("p%d", i)) == nil, "folded from the last: p%d too", i) }
	testing.expectf(t, shown >= ITEMS - 3, "only the last items fold: %d shown", shown)
	if shown == 0 { return }
	kept := session.get(s, fmt.tprintf("p%d", shown - 1))
	testing.expect(t, holds(bar, kept), "the items kept are in the bar")
	gap := session.get(s, "toolbar_more").rect.min.x - kept.rect.max.x
	testing.expectf(t, gap < last.size.x + 2 * kept.font_size, "no room left that an item would fill: %v px", gap)
	// (the folded items in the menu, working)
	session.click(s, "toolbar_more")
	folded := session.wait_text(s, fmt.tprintf("Propriété %d", ITEMS - 1))
	testing.expect(t, folded.rect.min.y >= bar.rect.max.y, "a row of the menu, under the bar")
	session.click_text(s, fmt.tprintf("Propriété %d", ITEMS - 1))
	session.frames(s, 2)
	testing.expect_value(t, r.clicks, 1)
}) }

// An item's own priority places it among every group's parts: a rare tool of the group kept longest folds before the
// items of a group that folds first.
@(test)
a_toolbar_item_folds_by_its_own_priority :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {1200, 300}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("bar", {overflow = .Fold}) {
			if ui.toolbar_group("tools", {priority = 2}) {
				for i in 0 ..< 3 { _ = ui.toolbar_tool(fmt.tprintf("a%d", i), {label = "Outil", words = true}) }
				// (rare: it folds first)
				_ = ui.toolbar_tool("rare_tool", {label = "Un outil rarement utilisé", words = true, priority = -1})
			}
			if ui.toolbar_group("props", {separator = true}) {
				for i in 0 ..< 3 { _ = ui.toolbar_tool(fmt.tprintf("p%d", i), {label = fmt.tprintf("Propriété %d", i), words = true}) }
			}
			if ui.toolbar_group("end", {pinned = true}) { _ = ui.toolbar_tool("done", {label = "Terminé", words = true}) }
		}
	}})
	session.frames(s, 3)
	testing.expect(t, session.find(s, "rare_tool") != nil && session.find(s, "toolbar_more") == nil, "room for all: nothing folds")
	// (narrower by the room left and a quarter of the rare tool: it alone folds, with room for the "…" button)
	rare := session.get(s, "rare_tool")
	slack := session.get(s, "done").rect.min.x - session.get(s, "p2").rect.max.x
	session.resize(s, {int(1200 - slack - 0.25 * rare.size.x), 300})
	session.frames(s, 4)
	testing.expect(t, session.find(s, "toolbar_more") != nil, "its \"…\" button")
	testing.expect(t, session.find(s, "rare_tool") == nil, "the rare tool folded first")
	for i in 0 ..< 3 {
		testing.expectf(t, session.find(s, fmt.tprintf("p%d", i)) != nil, "the properties stay: p%d", i)
		testing.expectf(t, session.find(s, fmt.tprintf("a%d", i)) != nil, "the other tools stay: a%d", i)
	}
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
