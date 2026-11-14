package scenarios_test

// A tool bar's two answers to a narrow window (src/md/features/toolbar.md): .Wrap takes more lines, each group whole, the
// pinned group at the end of the last line; .Fold puts what does not fit in the "…" menu, as sections of menu rows.

import "core:fmt"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WRAP_GROUPS :: 4
@(private = "file") WRAP_TOOLS :: 2

// A .Wrap bar too narrow for one line wraps: a group's tools stay on one line together, every tool stays in the
// window, and the pinned group (Cancel, Done) is at the end of the last line.
@(test)
a_wrapping_toolbar_moves_groups_whole :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {1400, 400}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill()})
		if ui.toolbar("wbar", {overflow = .Wrap}) {
			for g in 0 ..< WRAP_GROUPS {
				if ui.toolbar_group(fmt.tprintf("g%d", g), {separator = g > 0}) {
					for i in 0 ..< WRAP_TOOLS { _ = ui.toolbar_tool(fmt.tprintf("g%d_%d", g, i), {label = "Outil", words = true}) }
				}
			}
			if ui.toolbar_group("end", {pinned = true}) {
				_ = ui.toolbar_tool("cancel", {label = "Annuler", words = true})
				_ = ui.toolbar_tool("done", {label = "Terminé", words = true, intent = .Primary})
			}
		}
	}})
	session.frames(s, 3)
	top := session.get(s, "g0_0").rect.min.y
	for g in 0 ..< WRAP_GROUPS {
		testing.expectf(t, session.get(s, fmt.tprintf("g%d_0", g)).rect.min.y == top, "room for all: g%d on the first line", g)
	}
	testing.expect(t, session.get(s, "done").rect.min.y == top, "room for all: Done on the first line")
	// (narrow: about two groups to a line beside the pinned group)
	g0 := session.get(s, "g0_0")
	group_w := 2 * WRAP_TOOLS * g0.size.x
	end_w := session.get(s, "done").rect.max.x - session.get(s, "cancel").rect.min.x
	width := int(end_w + 2 * group_w + 4 * g0.font_size)
	session.resize(s, {width, 400})
	session.frames(s, 4)
	lowest: f32
	for g in 0 ..< WRAP_GROUPS {
		first := session.get(s, fmt.tprintf("g%d_0", g))
		for i in 1 ..< WRAP_TOOLS {
			other := session.get(s, fmt.tprintf("g%d_%d", g, i))
			testing.expectf(t, other.rect.min.y == first.rect.min.y, "g%d whole on one line: tool %d at %v, its first at %v", g, i, other.rect.min.y, first.rect.min.y)
			testing.expectf(t, other.rect.max.x <= f32(width) + 1, "g%d_%d in the window", g, i)
		}
		lowest = max(lowest, first.rect.min.y)
	}
	testing.expect(t, lowest > top, "the bar took more lines")
	done, cancel := session.get(s, "done"), session.get(s, "cancel")
	bar := session.get(s, "wbar")
	testing.expectf(t, done.rect.max.x <= f32(width) + 1 && done.rect.max.x >= bar.rect.max.x - 2 * done.font_size, "Done at the bar's end: %v of %v", done.rect.max.x, bar.rect.max.x)
	testing.expect(t, cancel.rect.min.y == done.rect.min.y && cancel.rect.max.x <= done.rect.min.x, "Cancel just before Done, on its line")
	testing.expectf(t, done.rect.min.y >= lowest - 1, "the pinned group on the last line: %v, the last group at %v", done.rect.min.y, lowest)
}) }

@(private = "file")
Fold_Run :: struct {
	pen, bold, width, opacity: int,
	bar_w: f32,   // the bar's width (0: the window's)
}

// A .Fold bar's menu: a section per folded group, under its title, in the bar's order; a tool is a row that the keyboard
// reaches and runs; a control is a row whose widget works there and leaves the menu open, the widgets of two control rows
// in one column whatever their labels.
@(test)
a_folding_toolbar_shows_a_menu_of_sections :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Fold_Run{}
	s := session.start(t, {size = {1000, 400}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Fold_Run)(s.user)
		ui.next({width = r.bar_w > 0 ? ui.px(r.bar_w) : ui.fill(), height = ui.px(40)})
		if ui.toolbar("fbar", {overflow = .Fold}) {
			if ui.toolbar_group("draw", {title = "Dessin"}) {
				if ui.toolbar_tool("pen", {label = "Crayon", shortcut = "P", words = true}) { r.pen += 1 }
			}
			if ui.toolbar_group("style", {title = "Style", separator = true}) {
				if ui.toolbar_tool("bold", {label = "Gras", words = true, on = r.bold % 2 == 1}) { r.bold += 1 }
				if ui.toolbar_control("width", {label = "Épaisseur", labelled = true}) {
					if ui.button("w_plus", "Plus épais").clicked { r.width += 1 }
				}
				if ui.toolbar_control("opacity", {label = "Opacité du trait entier"}) {
					if ui.button("o_plus", "Plus opaque").clicked { r.opacity += 1 }
				}
			}
			if ui.toolbar_group("end", {pinned = true}) { _ = ui.toolbar_tool("done", {label = "Terminé", words = true}) }
		}
	}})
	session.frames(s, 3)
	testing.expect(t, session.find(s, "w_plus") != nil && session.find(s, "pen") != nil, "room for all: in the bar")
	testing.expect(t, session.find_text(s, "Épaisseur") != nil, "a control labelled in the bar shows its label")
	// (so narrow that both groups fold whole: first narrow enough for the "…" button to show, then as wide as Done, that
	// button and its gaps; the window keeps room for the menu)
	done := session.get(s, "done")
	r.bar_w = done.size.x * 3
	session.frames(s, 4)
	more := session.get(s, "toolbar_more")
	r.bar_w = done.size.x + more.size.x + more.font_size
	session.frames(s, 4)
	bar := session.get(s, "fbar")
	testing.expect(t, session.find(s, "pen") == nil && session.find(s, "w_plus") == nil, "both groups folded")
	session.click(s, "toolbar_more")
	session.wait_text(s, "Crayon")
	session.frames(s, 2)
	// (the sections, in the bar's order, each under its title)
	dessin, style := session.find_text(s, "Dessin"), session.find_text(s, "Style")
	testing.expect(t, dessin != nil && style != nil, "a title per section")
	if dessin == nil || style == nil { return }
	crayon, gras := session.find_text(s, "Crayon"), session.find_text(s, "Gras")
	testing.expect(t, crayon != nil && gras != nil, "a row per tool")
	if crayon == nil || gras == nil { return }
	testing.expect(t, dessin.rect.min.y >= bar.rect.max.y, "the menu under the bar")
	testing.expect(t, dessin.rect.max.y <= crayon.rect.min.y + 1 && crayon.rect.max.y <= style.rect.min.y + 1 && style.rect.max.y <= gras.rect.min.y + 1, "Dessin, Crayon, then Style, Gras")
	key := session.find(s, "key", within = crayon.parent)
	testing.expect(t, key != nil && ui.box_text(key) == "P", "the tool's shortcut in its row")
	// (a control row: its label at the left, its widget at the right, the widgets in one column)
	row := session.get(s, "mc_width")
	w_plus := session.get(s, "w_plus", within = row)
	o_plus := session.get(s, "o_plus")
	label := session.get(s, "lbl", within = row)
	testing.expect(t, label.rect.max.x <= w_plus.rect.min.x, "the label before the widget")
	testing.expectf(t, abs(w_plus.rect.min.x - o_plus.rect.min.x) <= 1, "the widgets in one column: %v and %v", w_plus.rect.min.x, o_plus.rect.min.x)
	testing.expectf(t, abs(label.rect.min.x - crayon.rect.min.x) <= 1, "the control's label in line with the tools' labels: %v and %v", label.rect.min.x, crayon.rect.min.x)
	session.click(s, "w_plus")
	session.frames(s, 2)
	testing.expect_value(t, r.width, 1)
	testing.expect(t, ui.toolbar_menu_open("fbar"), "a control used: the menu stays open")
	// (the keyboard: Down selects the first tool (no title, no control row is an item), Enter runs it)
	session.key(s, .Down)
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect_value(t, r.pen, 1)
	testing.expect(t, !ui.toolbar_menu_open("fbar"), "a tool run closes the menu")
	// (a click on a tool's row runs it too)
	session.click(s, "toolbar_more")
	session.wait_text(s, "Gras")
	session.click_text(s, "Gras")
	session.frames(s, 2)
	testing.expect_value(t, r.bold, 1)
}) }

@(private = "file")
Menu_Run :: struct {
	overflow: ui.Toolbar_Overflow,
	bar_w:    f32,    // the bar's width (0: the window's)
	inserted: int,    // the rectangles inserted from the tool's menu
	returned: int,    // the times the tool with a menu said true (never)
}

// A tool bar with a tool that opens a menu, and that menu, built by the program as any menu, outside the bar.
@(private = "file")
menu_bar_build :: proc(s: ^session.Session) {
	r := (^Menu_Run)(s.user)
	ui.next({width = r.bar_w > 0 ? ui.px(r.bar_w) : ui.fill(), height = ui.px(40)})
	if ui.toolbar("mbar", {overflow = r.overflow}) {
		if ui.toolbar_group("draw", {title = "Dessin"}) {
			if ui.toolbar_tool("insert", {label = "Insérer", words = true, menu = "insert_menu"}) { r.returned += 1 }
		}
		if ui.toolbar_group("end", {pinned = true}) { _ = ui.toolbar_tool("done", {label = "Terminé", words = true}) }
	}
	if ui.menu("insert_menu") {
		if ui.menu_item("Rectangle").clicked { r.inserted += 1 }
		_ = ui.menu_item("Ellipse")
	}
}

// In the bar, a tool with a menu opens it under itself and is lit while it is open; what is chosen in it runs.
@(test)
a_toolbar_tool_opens_its_menu_in_the_bar :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Menu_Run{overflow = .Wrap}
	s := session.start(t, {size = {900, 400}, user = &r, no_renderer = true, build = menu_bar_build})
	session.frames(s, 3)
	tool := session.get(s, "insert")
	testing.expect(t, .Lit not_in tool.flags, "not lit while its menu is closed")
	session.click(s, "insert")
	rect := session.wait_text(s, "Rectangle")
	tool = session.get(s, "insert")
	testing.expect(t, ui.menu_is_open("insert_menu"), "the click opens its menu")
	testing.expect(t, .Lit in tool.flags, "lit while its menu is open")
	testing.expectf(t, rect.rect.min.y >= tool.rect.max.y && abs(rect.parent.rect.min.x - tool.rect.min.x) <= 2 * tool.font_size, "the menu under the tool: %v, the tool %v", rect.rect, tool.rect)
	session.click_text(s, "Rectangle")
	session.frames(s, 2)
	testing.expect_value(t, r.inserted, 1)
	testing.expect(t, !ui.menu_any_open(), "a choice closes the menu")
	testing.expect(t, .Lit not_in session.get(s, "insert").flags, "no longer lit")
	// (a second click on the tool closes its open menu)
	session.click(s, "insert")
	session.wait_text(s, "Rectangle")
	session.click(s, "insert")
	session.frames(s, 2)
	testing.expect(t, !ui.menu_any_open(), "the tool closes its menu")
	testing.expect_value(t, r.returned, 0)
}) }

// Folded, a tool with a menu is a submenu row of the "…" menu: its menu, built by the same block, opens beside the row,
// by the pointer and by the keyboard, and what is chosen in it runs.
@(test)
a_folded_toolbar_tool_is_a_submenu :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Menu_Run{overflow = .Fold}
	s := session.start(t, {size = {900, 400}, user = &r, no_renderer = true, build = menu_bar_build})
	session.frames(s, 3)
	// (as narrow as Done and the "…" button: the tool folds)
	done := session.get(s, "done")
	r.bar_w = done.size.x * 1.5
	session.frames(s, 4)
	more := session.get(s, "toolbar_more")
	r.bar_w = done.size.x + more.size.x + more.font_size
	session.frames(s, 4)
	testing.expect(t, session.find(s, "insert") == nil, "the tool folded")
	session.click(s, "toolbar_more")
	row := session.wait_text(s, "Insérer")
	testing.expect(t, session.find_text(s, "Rectangle") == nil, "its menu waits for its row")
	session.click_text(s, "Insérer")
	rect := session.wait_text(s, "Rectangle")
	row = session.find_text(s, "Insérer")
	testing.expect(t, row != nil && rect.rect.min.x >= row.parent.rect.max.x - 4, "its menu beside its row")
	testing.expect(t, ui.toolbar_menu_open("mbar"), "the \"…\" menu stays open behind it")
	session.click_text(s, "Rectangle")
	session.frames(s, 2)
	testing.expect_value(t, r.inserted, 1)
	testing.expect(t, !ui.menu_any_open(), "a choice closes both")
	// (the keyboard: Down selects the row, Right opens its menu on its first item, Enter chooses it)
	session.click(s, "toolbar_more")
	session.wait_text(s, "Insérer")
	session.key(s, .Down)
	session.key(s, .Right)
	session.wait_text(s, "Rectangle")
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect_value(t, r.inserted, 2)
	testing.expect(t, !ui.menu_any_open(), "closed")
	testing.expect_value(t, r.returned, 0)
}) }
