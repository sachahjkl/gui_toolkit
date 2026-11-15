package scenarios_test

// A tool bar's two answers to a narrow window (src/md/features/toolbar.md): .Wrap takes more lines, each group whole, the
// pinned group at the end of the last line; .Fold puts what does not fit in the "…" menu, as sections of menu rows.

import "core:fmt"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

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
	// (the bar as tall as its lines, no more, and in the window: its first line's tools at its top, its last line's at its
	// bottom, a line's room around a tool aside. A box of the bar sized by a share of a box sized by its children took the
	// page's height: the groups went down out of sight, and the positions alone, compared with each other, still agreed)
	hugs :: proc(t: ^testing.T, s: ^session.Session, window_h: f32, loc := #caller_location) {
		bar := session.get(s, "wbar")
		first, last := max(f32), f32(0)
		names := make([dynamic]string, context.temp_allocator)
		for g in 0 ..< WRAP_GROUPS { for i in 0 ..< WRAP_TOOLS { append(&names, fmt.tprintf("g%d_%d", g, i)) } }
		append(&names, "cancel", "done")
		for name in names {
			b := session.get(s, name)
			first, last = min(first, b.rect.min.y), max(last, b.rect.max.y)
			testing.expectf(t, b.rect.min.y >= bar.rect.min.y - 1 && b.rect.max.y <= bar.rect.max.y + 1, "%s inside the bar: %v in %v", name, b.rect, bar.rect, loc = loc)
		}
		em := session.get(s, "done").font_size
		testing.expectf(t, first - bar.rect.min.y <= em && bar.rect.max.y - last <= em, "the bar as tall as its lines: %v, its tools from %v to %v", bar.rect, first, last, loc = loc)
		testing.expectf(t, bar.rect.max.y <= window_h, "the bar in the window: %v", bar.rect, loc = loc)
	}
	session.frames(s, 3)
	hugs(t, s, 400)
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
	hugs(t, s, 400)
	// (a group's separator only between two groups of one line: a group that starts a line has no room before it)
	left := session.get(s, "g0_0").rect.min.x
	starts := 0
	for g in 1 ..< WRAP_GROUPS {
		first := session.get(s, fmt.tprintf("g%d_0", g))
		before := session.get(s, fmt.tprintf("g%d_%d", g - 1, WRAP_TOOLS - 1))
		if first.rect.min.y != before.rect.min.y {
			starts += 1
			testing.expectf(t, abs(first.rect.min.x - left) <= 1, "g%d starts its line with no separator: at %v, the line at %v", g, first.rect.min.x, left)
		} else {
			testing.expectf(t, first.rect.min.x - before.rect.max.x >= first.font_size * 0.8, "g%d: a separator's room after the group of its line", g)
		}
	}
	testing.expect(t, starts > 0, "a group starts a line")
	done, cancel := session.get(s, "done"), session.get(s, "cancel")
	bar := session.get(s, "wbar")
	testing.expectf(t, done.rect.max.x <= f32(width) + 1 && done.rect.max.x >= bar.rect.max.x - 2 * done.font_size, "Done at the bar's end: %v of %v", done.rect.max.x, bar.rect.max.x)
	testing.expect(t, cancel.rect.min.y == done.rect.min.y && cancel.rect.max.x <= done.rect.min.x, "Cancel just before Done, on its line")
	testing.expectf(t, done.rect.min.y >= lowest - 1, "the pinned group on the last line: %v, the last group at %v", done.rect.min.y, lowest)
}) }

@(private = "file")
Align_Run :: struct {
	overflow: ui.Toolbar_Overflow,
	align:    ui.Toolbar_Align,
	bar_w:    f32,   // the bar's width (0: the window's)
}

// Three groups of tools, a group with a control taller than a tool, Cancel and Done pinned.
@(private = "file")
align_build :: proc(s: ^session.Session) {
	r := (^Align_Run)(s.user)
	ui.next({width = r.bar_w > 0 ? ui.px(r.bar_w) : ui.fill(), height = ui.px(40)})
	if ui.toolbar("abar", {overflow = r.overflow, align = r.align}) {
		for g in 0 ..< 3 {
			if ui.toolbar_group(fmt.tprintf("g%d", g), {separator = g > 0}) {
				for i in 0 ..< 2 { _ = ui.toolbar_tool(fmt.tprintf("g%d_%d", g, i), {label = "Outil", words = true}) }
			}
		}
		if ui.toolbar_group("tall", {separator = true}) {
			_ = ui.toolbar_tool("short", {label = "Court", words = true})
			if ui.toolbar_control("big", {label = "Grand"}) {
				ui.next({height = ui.px(ui.font_size() * 3.4)})
				_ = ui.button("tall_widget", "Grand")
			}
		}
		if ui.toolbar_group("end", {pinned = true}) {
			_ = ui.toolbar_tool("cancel", {label = "Annuler", words = true})
			_ = ui.toolbar_tool("done", {label = "Terminé", words = true})
		}
	}
}

// .Start (the default) begins each line at the bar's start; .Center centres each line of a .Wrap bar in the flow's room
// (equal room left and right within a pixel, the last line too), and the groups of a .Fold bar in the room before its
// pinned groups. In every mode an item sits on its line's middle, a control taller than a tool too.
@(test)
a_toolbar_aligns_its_groups :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	// (the items' boxes: a control's has its own room around its widget, part of its line)
	names := [?]string{"ti_g0_0", "ti_g0_1", "ti_g1_0", "ti_g1_1", "ti_g2_0", "ti_g2_1", "ti_short", "ti_big"}
	for overflow in ui.Toolbar_Overflow {
		for align in ui.Toolbar_Align {
			r := Align_Run{overflow = overflow, align = align}
			s := session.start(t, {size = {1400, 400}, user = &r, no_renderer = true, build = align_build})
			session.frames(s, 3)
			if overflow == .Wrap {
				// (narrow: the groups take several lines)
				r.bar_w = session.get(s, "g0_0").size.x * 7
				session.frames(s, 4)
			}
			bar := session.get(s, "abar")
			// (the lines: the boxes by their middle's height)
			Line :: struct { y, left, right: f32 }
			lines := make([dynamic]Line, context.temp_allocator)
			for name in names {
				b := session.get(s, name)
				cy := (b.rect.min.y + b.rect.max.y) * 0.5
				found := false
				for &l in lines {
					if abs(l.y - cy) <= 1 { l.left, l.right = min(l.left, b.rect.min.x), max(l.right, b.rect.max.x); found = true }
				}
				if !found { append(&lines, Line{cy, b.rect.min.x, b.rect.max.x}) }
			}
			// (on its line's middle: the taller control and the tool beside it)
			short, tall := session.get(s, "short"), session.get(s, "tall_widget")
			testing.expectf(t, abs((short.rect.min.y + short.rect.max.y) * 0.5 - (tall.rect.min.y + tall.rect.max.y) * 0.5) <= 1, "%v %v: the taller control on its line's middle: %v and %v", overflow, align, tall.rect, short.rect)
			// (the room the groups stand in: .Wrap the flow's, .Fold the bar's before Cancel)
			room_l, room_r := bar.rect.min.x, session.get(s, "ti_cancel").rect.min.x
			if overflow == .Wrap {
				flow := session.get(s, "flow")
				room_l, room_r = flow.rect.min.x, flow.rect.max.x
				testing.expectf(t, len(lines) > 1, "%v %v: several lines", overflow, align)
			}
			for l in lines {
				left, right := l.left - room_l, room_r - l.right
				switch align {
				case .Start:  testing.expectf(t, left <= 1, "%v .Start: the line at %v starts at the room's start: %v px", overflow, l.y, left)
				case .Center: testing.expectf(t, abs(left - right) <= 1, "%v .Center: the line at %v centred: %v px left, %v px right", overflow, l.y, left, right)
				}
			}
		}
	}
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
				_ = ui.toolbar_tool("eraser", {label = "Gomme", words = true})
			}
			// (a group of one item: no title in the menu, its row says it)
			if ui.toolbar_group("fill", {title = "Remplissage", separator = true}) {
				if ui.toolbar_control("fill_on", {label = "Remplir"}) { _ = ui.button("fill_plus", "Oui") }
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
	testing.expect(t, session.find(s, "mc_fill_on") != nil && session.find_text(s, "Remplissage") == nil, "a group of one item: its row, no title")
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

// A .Fold bar as cliche's history builds it (fill width in a row, a margin each side; groups of one segmented control
// each, by priority): at every width of the window, nothing the bar shows runs past the bar's end, and the bar ends inside
// the window (a narrow window left the last segment cut by the window's edge instead of folding it).
@(test)
a_folding_bar_of_segmented_controls_never_runs_past_its_end :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {1000, 200}, no_renderer = true, build = proc(s: ^session.Session) {
		em := ui.font_size()
		kinds := []string{"Tout", "Captures d'écran", "Enregistrements", "Mises en ligne", "Texte"}
		sizes := []string{"P", "M", "G"}
		views := []string{"Grille", "Liste"}
		@(static) kind, size, view: int
		ui.next({width = ui.fill(), height = ui.px(40), axis = .X, cross = .Center})
		if ui.row(id = "###row") {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.fill(), height = ui.px(em * 2.2)})
			if ui.toolbar("sbar", {overflow = .Fold}) {
				if ui.toolbar_group("kind", {title = "Genre", priority = 4}) {
					if ui.toolbar_control("kind", {label = "Genre"}) { _ = ui.segmented("kind", kinds, &kind) }
				}
				if ui.toolbar_group("size", {title = "Taille", priority = 1}) {
					if ui.toolbar_control("size", {label = "Taille"}) { _ = ui.segmented("size", sizes, &size) }
				}
				if ui.toolbar_group("view", {title = "Vue", priority = 2}) {
					if ui.toolbar_control("view", {label = "Vue"}) { _ = ui.segmented("view", views, &view) }
				}
				// (cliche's last group: icon tools, one with a menu, one on, one folded first, one the palette's command)
				if ui.toolbar_group("window", {title = "Fenêtre", priority = 3}) {
					_ = ui.toolbar_tool("period", {label = "Par date…", icon = "", menu = "###period_menu", menu_search = false})
					_ = ui.toolbar_tool("preview", {label = "Aperçu", icon = "", on = true})
					_ = ui.toolbar_tool("folder", {label = "Dossier", icon = "", priority = 0})
					_ = ui.toolbar_tool("workflows", {label = "Workflows", icon = ""})
					_ = ui.toolbar_tool("palette", {command = ui.palette_command()})
					_ = ui.toolbar_tool("settings", {label = "Réglages", icon = ""})
				}
			}
			ui.spacer(ui.px(em * 0.6))
		}
	}})
	for w := 1000; w >= 300; w -= 23 {
		session.resize(s, {w, 200})
		session.frames(s, 4)
		bar := session.get(s, "sbar")
		testing.expectf(t, bar.rect.max.x <= f32(w) + 0.5, "at %d px: the bar ends at %v, past the window", w, bar.rect.max.x)
		for name in ([]string{"kind", "size", "view", "period", "preview", "folder", "workflows", "palette", "settings", "toolbar_more"}) {
			b := session.find(s, name, within = bar)
			if b == nil { continue }
			testing.expectf(t, b.rect.max.x <= bar.rect.max.x + 0.5, "at %d px: %s ends at %v, past the bar's end %v", w, name, b.rect.max.x, bar.rect.max.x)
		}
	}
}) }

// A tool's `tip` is its tooltip whatever it shows (a zoom's words "100 %" say "Zoom" under the pointer); a tool's menu
// opens with a search by default, without one when the tool says `menu_search = false` (a typed letter selects there).
@(test)
a_toolbar_tool_has_its_tip_and_its_menu_search :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {900, 400}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("tbar", {overflow = .Wrap}) {
			if ui.toolbar_group("view") {
				_ = ui.toolbar_tool("zoom", {label = "100 %", words = true, tip = "Zoom", menu = "zoom_menu", menu_search = false})
				_ = ui.toolbar_tool("insert", {label = "Insérer", words = true, menu = "insert_menu"})
				_ = ui.toolbar_tool("plain", {label = "Sans bulle", words = true})
			}
		}
		if ui.menu("zoom_menu") {
			_ = ui.menu_item("50 %")
			_ = ui.menu_item("200 %")
		}
		if ui.menu("insert_menu") { _ = ui.menu_item("Rectangle") }
	}})
	session.frames(s, 3)
	session.hover(s, "zoom")
	session.advance(s, TOOLTIP_WAIT_MS)
	testing.expect(t, session.find_text(s, "Zoom") != nil, "the words tool shows its tip")
	session.hover(s, "plain")
	session.advance(s, TOOLTIP_WAIT_MS)
	testing.expect(t, session.find_text(s, "Zoom") == nil, "words with no tip and no shortcut: no tooltip")
	session.click(s, "zoom")
	session.wait_text(s, "200 %")
	testing.expect(t, session.find(s, "menu_search") == nil, "menu_search = false: no search field")
	session.key(s, .Escape)
	session.frames(s, 2)
	session.click(s, "insert")
	session.wait_text(s, "Rectangle")
	testing.expect(t, session.find(s, "menu_search") != nil, "by default its menu searches")
}) }

// A slider in a control has its width: its track and its value, not the knob alone, with no width given and with one
// too small.
@(test)
a_toolbar_control_slider_keeps_its_width :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { a, b: f32 }
	r := Run{4, 4}
	s := session.start(t, {size = {900, 300}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("sbar", {overflow = .Wrap}) {
			if ui.toolbar_group("style") {
				if ui.toolbar_control("free", {label = "Width"}) { _ = ui.slider("###free", &r.a, 1, 20, 1, "%.0f px") }
				if ui.toolbar_control("small", {label = "Size"}) {
					ui.next({width = ui.px(ui.font_size() * 3)})
					_ = ui.slider("###small", &r.b, 1, 20, 1, "%.0f px")
				}
			}
		}
	}})
	session.frames(s, 3)
	for name in ([]string{"free", "small"}) {
		b := session.get(s, name)
		testing.expectf(t, b.size.x >= 10 * b.font_size, "%s: its track and its value, %v px at %v px a letter", name, b.size.x, b.font_size)
	}
}) }

// Longer than a tooltip's delay (ui.FEEL_DEFAULT.tooltip_delay_ms, 500 ms).
@(private = "file") TOOLTIP_WAIT_MS :: 600

@(private = "file")
Menu_Run :: struct {
	overflow: ui.Toolbar_Overflow,
	bar_w:    f32,    // the bar's width (0: the window's)
	inserted: int,    // the rectangles inserted from the tool's menu
	returned: int,    // the times the tool with a menu said true (never)
	show:     bool,   // the program opens the "…" menu itself (toolbar_menu_show), until it opened
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
	if r.show && ui.toolbar_menu_show("mbar") { r.show = false }
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
	// (the program opens the "…" menu itself, as a click does: under its button)
	r.show = true
	row = session.wait_text(s, "Insérer")
	testing.expect(t, !r.show && ui.toolbar_menu_open("mbar"), "toolbar_menu_show opens the \"…\" menu")
	more = session.get(s, "toolbar_more")
	testing.expect(t, row.rect.min.y >= more.rect.max.y, "under its \"…\" button")
}) }
