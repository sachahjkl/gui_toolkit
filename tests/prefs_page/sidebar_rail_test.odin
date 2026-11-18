package prefs_page_test

// The settings' sidebar folds to its rail (src/md/features/side-panels.md): in a dialog narrowed under its threshold it
// folds, widened back it opens; a manual choice holds until the width next crosses the threshold, either way; a sweep
// around the threshold changes the state once each way; the rail's icons show the pages (a click, Up and Down); its
// magnifier opens the sidebar with the search focused; its "…" menu holds the version, the file, Export and Import; a
// pull of its edge opens it; the fold button is at the same pixel in both states.

import "core:math"
import "core:testing"
import config "gt:config"
import lucide "gt:lucide"
import prefs_page "gt:prefs_page"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
Rail_App :: struct {
	prefs: config.Prefs,
	page:  prefs_page.Page,
	width: f32,   // the dialog's width (frame px)
	em:    f32,   // the font size of the last build
}

// The standard pages, each with its icon (a program's Page_Options.pages).
@(private = "file")
rail_pages :: proc() -> []prefs_page.Page_Info {
	return slice_of(
		{category = "appearance", title = "Appearance", icon = lucide.PALETTE},
		{category = "window", title = "Window", icon = lucide.APP_WINDOW},
		{category = "scrolling", title = "Scrolling", icon = lucide.MOUSE},
		{category = "input", title = "Input", icon = lucide.KEYBOARD},
		{category = "timing", title = "Delays and menus", icon = lucide.TIMER},
		{category = "rendering", title = "Rendering", icon = lucide.MONITOR},
	)
}

@(private = "file")
slice_of :: proc(pages: ..prefs_page.Page_Info) -> []prefs_page.Page_Info {
	out := make([]prefs_page.Page_Info, len(pages), context.temp_allocator)
	copy(out, pages)
	return out
}

@(private = "file") RAIL_VERSION :: "Sample 1.2.3"
@(private = "file") RAIL_FILE :: "/nowhere/sample/settings.toml"

@(private = "file")
rail_build :: proc(s: ^session.Session) {
	app := (^Rail_App)(s.user)
	app.em = ui.font_size()
	// (a dialog: a box of a fixed width in the window's middle, which clips what is in it)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###around") {
		ui.spacer(ui.fill())
		ui.next({width = ui.px(app.width), height = ui.fill(), axis = .Y})
		ui.push_parent(ui.build_box({.Clip, .Draw_Border}, "###dialog"))
		ui.next({width = ui.fill(), height = ui.fill()})
		prefs_page.build(&app.page, &app.prefs, {user = app, pages = rail_pages(), icon_font = ui.lucide_icons(),
			search_icon = lucide.SEARCH, version = RAIL_VERSION, file = RAIL_FILE})
		ui.pop_parent()
		ui.spacer(ui.fill())
	}
}

@(private = "file")
rail_start :: proc(t: ^testing.T, app: ^Rail_App, width: f32 = 1100) -> ^session.Session {
	app.width = width
	app.prefs = config.prefs_make()
	d := prefs_page.STANDARD_DEFAULTS
	d.theme, d.app_name = "Midnight", "Sample"
	prefs_page.standard_register(&app.prefs, prefs_page.STANDARD_ALL, d, context.temp_allocator)
	s := session.start(t, {size = {1200, 800}, user = app, build = rail_build})
	session.frames(s, 3)
	return s
}

@(private = "file")
rail_end :: proc(app: ^Rail_App) {
	prefs_page.destroy(&app.page)
	config.prefs_destroy(&app.prefs)
}

// The sidebar's fold, as its preference says it.
@(private = "file")
fold_of :: proc(app: ^Rail_App) -> ui.Side_Fold {
	f, _ := ui.side_fold_parse(config.string_of(&app.prefs, prefs_page.SIDEBAR_FOLD_PREF))
	return f
}

// Whether the sidebar shows as its rail (its magnifier built in the last build).
@(private = "file")
railed :: proc(s: ^session.Session) -> bool {
	b := session.find(s, "prefs_rail_search")
	return b != nil && b.last_build == s.state.build_index
}

@(private = "file")
dialog_width :: proc(s: ^session.Session, app: ^Rail_App, w: f32) {
	app.width = math.round(w)
	session.frames(s, 3)
}

// The dialog's width at which the open sidebar leaves the page its least (side-panels.md: room - open < BODY_MIN_EM).
@(private = "file")
threshold_of :: proc(s: ^session.Session, app: ^Rail_App) -> f32 {
	nav := session.get(s, "prefs_nav")
	return (nav.rect.max.x - nav.rect.min.x) + prefs_page.BODY_MIN_EM * app.em
}

@(test)
the_settings_fold_in_a_narrow_dialog :: proc(t: ^testing.T) {
	app: Rail_App
	defer rail_end(&app)
	s := rail_start(t, &app)
	testing.expect(t, !railed(s), "wide: open")
	threshold := threshold_of(s, &app)
	dialog_width(s, &app, threshold - 2 * app.em)
	testing.expect(t, railed(s), "narrowed under its threshold: the rail")
	nav := session.get(s, "prefs_nav")
	testing.expectf(t, abs((nav.rect.max.x - nav.rect.min.x) - math.round(prefs_page.RAIL_EM * app.em)) <= 1, "the rail's width: %v", nav.rect)
	testing.expectf(t, fold_of(&app) == {folded = true, narrow = true}, "the automatic state, kept: %v", fold_of(&app))
	testing.expect(t, session.find(s, "prefs_query") == nil || session.get(s, "prefs_query").last_build != s.state.build_index, "no field in the rail")
	session.resize(s, {int(app.width) + 80, 600})
	session.frames(s, 3)
	session.save_png(s, "settings-rail.png")
	session.resize(s, {1200, 800})
	dialog_width(s, &app, threshold + 2 * app.em)
	testing.expect(t, !railed(s), "widened back: open")
	testing.expectf(t, fold_of(&app) == {}, "the automatic state: %v", fold_of(&app))
}

@(test)
a_restore_while_narrow_holds_until_the_next_crossing :: proc(t: ^testing.T) {
	app: Rail_App
	defer rail_end(&app)
	s := rail_start(t, &app)
	threshold := threshold_of(s, &app)
	dialog_width(s, &app, threshold - 2 * app.em)
	if !testing.expect(t, railed(s), "the rail") { return }
	session.click(s, "prefs_fold")
	session.frames(s, 2)
	testing.expect(t, !railed(s), "a manual Restore: open")
	testing.expectf(t, fold_of(&app) == {narrow = true}, "a manual opening, kept: %v", fold_of(&app))
	dialog_width(s, &app, threshold - 4 * app.em)
	testing.expect(t, !railed(s), "another narrow width: it holds")
	dialog_width(s, &app, threshold + 2 * app.em)
	testing.expect(t, !railed(s), "widened past: open (the automatic state)")
	testing.expectf(t, fold_of(&app) == {}, "the choice ended: %v", fold_of(&app))
	dialog_width(s, &app, threshold - 2 * app.em)
	testing.expect(t, railed(s), "narrow again: folded by itself")
}

@(test)
a_fold_while_wide_holds_until_the_next_crossing :: proc(t: ^testing.T) {
	app: Rail_App
	defer rail_end(&app)
	s := rail_start(t, &app)
	threshold := threshold_of(s, &app)
	open_at := session.get(s, "prefs_fold").rect
	session.click(s, "prefs_fold")
	session.frames(s, 2)
	testing.expect(t, railed(s), "a manual Minimise: the rail")
	testing.expectf(t, fold_of(&app) == {folded = true}, "a manual fold, kept: %v", fold_of(&app))
	// (the fold button at the same pixel in both states: it stays under the pointer)
	folded_at := session.get(s, "prefs_fold").rect
	testing.expectf(t, abs(folded_at.min.x - open_at.min.x) <= 0.5 && abs(folded_at.min.y - open_at.min.y) <= 0.5, "the same pixel: %v, %v", folded_at, open_at)
	dialog_width(s, &app, 1000)
	testing.expect(t, railed(s), "another wide width: it holds")
	dialog_width(s, &app, threshold - 2 * app.em)
	testing.expect(t, railed(s), "narrowed past: folded (the automatic state)")
	dialog_width(s, &app, 1100)
	testing.expect(t, !railed(s), "widened again: open by itself")
}

// A sweep of the dialog's width around the threshold, down then up: once each way; then a jitter: never.
@(test)
the_settings_sidebar_does_not_flap :: proc(t: ^testing.T) {
	app: Rail_App
	defer rail_end(&app)
	s := rail_start(t, &app)
	threshold := threshold_of(s, &app)
	changes := 0
	was := false
	widths := make([dynamic]f32, context.temp_allocator)
	for w := threshold + 2 * app.em; w >= threshold - 2 * app.em; w -= 3 { append(&widths, w) }
	for w := threshold - 2 * app.em; w <= threshold + 2 * app.em; w += 3 { append(&widths, w) }
	for w in widths {
		app.width = math.round(w)
		session.frames(s, 2)
		if now := railed(s); now != was { changes += 1; was = now }
	}
	testing.expectf(t, changes == 2, "once each way: %d", changes)
	dialog_width(s, &app, threshold - app.em)
	changes, was = 0, railed(s)
	for i in 0 ..< 20 {
		app.width = math.round(threshold + f32(i % 2 == 0 ? 3 : -3))
		session.frames(s, 2)
		if now := railed(s); now != was { changes += 1; was = now }
	}
	testing.expectf(t, changes == 0, "a jitter: %d", changes)
}

// The rail's icons: a click shows a page, Up and Down the page before and after, the page shown lit; each has its title
// as its accessible name.
@(test)
the_rail_s_icons_show_the_pages :: proc(t: ^testing.T) {
	app: Rail_App
	defer rail_end(&app)
	s := rail_start(t, &app)
	session.click(s, "prefs_fold")
	session.frames(s, 2)
	if !testing.expect(t, railed(s), "the rail") { return }
	pages := rail_pages()
	session.click(s, "nav2")
	session.frames(s, 2)
	testing.expect_value(t, app.page.current, pages[2].category)
	testing.expect(t, session.find_text(s, "Smooth scrolling") != nil, "the page shown")
	session.key(s, .Down)
	session.frames(s, 2)
	testing.expect_value(t, app.page.current, pages[3].category)
	testing.expect_value(t, session.focused_name(s), "nav3")
	session.key(s, .Up)
	session.key(s, .Up)
	session.frames(s, 2)
	testing.expect_value(t, app.page.current, pages[1].category)
	testing.expect_value(t, session.focused_name(s), "nav1")
	b := session.get(s, "nav1")
	testing.expectf(t, b.a11y != nil && b.a11y.name == pages[1].title, "its title as its name: %v", b.a11y^ if b.a11y != nil else ui.A11y_Info{})
}

// The magnifier opens the sidebar with the search focused (a manual opening); what is typed shows its results.
@(test)
the_magnifier_opens_the_search :: proc(t: ^testing.T) {
	app: Rail_App
	defer rail_end(&app)
	s := rail_start(t, &app)
	threshold := threshold_of(s, &app)
	dialog_width(s, &app, threshold - 2 * app.em)
	if !testing.expect(t, railed(s), "the rail") { return }
	session.click(s, "prefs_rail_search")
	session.frames(s, 3)
	testing.expect(t, !railed(s), "open")
	testing.expect_value(t, session.focused_name(s), "prefs_query")
	session.type_text(s, "tooltip")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Tooltip delay") != nil, "its results in the page")
}

// The "…" menu: the version, the settings file, Export and Import.
@(test)
the_rail_s_menu_holds_the_foot :: proc(t: ^testing.T) {
	app: Rail_App
	defer rail_end(&app)
	s := rail_start(t, &app, 500)
	if !testing.expect(t, railed(s), "a dialog this narrow: the rail") { return }
	testing.expect(t, session.find(s, "prefs_export") == nil, "no foot in the rail")
	session.click(s, "prefs_more")
	session.frames(s, 3)
	for words in ([]string{RAIL_VERSION, "Export…", "Import…"}) {
		testing.expectf(t, session.find_text(s, words) != nil, "%s in the menu", words)
	}
	testing.expect(t, session.find_text(s, "settings.toml") != nil || session.find_text(s, RAIL_FILE) != nil, "the file in the menu")
	session.resize(s, {int(app.width) + 80, 600})
	session.frames(s, 3)
	if !ui.menu_is_open("###prefs_more_menu") {
		session.click(s, "prefs_more")
		session.frames(s, 3)
	}
	session.save_png(s, "settings-rail-menu.png")
}

// A pull of the rail's edge opens the sidebar at the pointer (a manual opening), past the sidebar's least.
@(test)
pulling_the_settings_rail_opens_it :: proc(t: ^testing.T) {
	app: Rail_App
	defer rail_end(&app)
	s := rail_start(t, &app)
	session.click(s, "prefs_fold")
	session.frames(s, 2)
	if !testing.expect(t, railed(s), "the rail") { return }
	h := session.get(s, "prefs_split")
	at := session.center(h)
	session.drag(s, at, at + {app.em, 0})
	session.frames(s, 2)
	testing.expect(t, railed(s), "a short pull: still folded")
	session.press(s, at)
	session.move(s, at + {10 * app.em, 0})
	session.move(s, at + {20 * app.em, 0})
	session.frames(s, 2)
	testing.expect(t, !railed(s), "pulled past its least: open")
	nav := session.get(s, "prefs_nav")
	testing.expectf(t, abs(nav.rect.max.x - (at.x + 20 * app.em)) <= 2 * app.em, "at the pointer: %v, %v", nav.rect.max.x, at.x + 20 * app.em)
	session.release(s, at + {20 * app.em, 0})
	session.frames(s, 2)
	testing.expectf(t, fold_of(&app) == {}, "open, kept: %v", fold_of(&app))
}
