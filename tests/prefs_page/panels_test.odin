package prefs_page_test

// The Window page's panels (src/md/features/views.md, section 6.1b): with Page_Options.views, a line says how far the
// frame's bottom panel goes across; a choice there is the person's span, kept with the layout; its reset gives the
// program's back. The top panel's line shows only while the frame has a top zone.

import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
PANEL_DEFS := [?]config.Def{
	{name = "window.look", description = "How the window looks.", kind = .String, default = {s = "flat"}, choices = {"flat", "machined"}},
}

@(private = "file")
PANEL_PAGES := [?]prefs_page.Page_Info{{category = "window", title = "Window"}}

@(private = "file")
Panels_App :: struct {
	prefs: config.Prefs,
	page:  prefs_page.Page,
	views: ui.Views,
	want:  [dynamic]string,
}

@(private = "file")
panel_words :: proc(v: ^ui.View, app: ^Panels_App) { ui.label("A panel###panel_words") }

@(private = "file")
panels_build :: proc(s: ^session.Session) {
	app := (^Panels_App)(s.user)
	for id in app.want { ui.view_open(&app.views, id, app) }
	clear(&app.want)
	if ui.views_frame(&app.views) {
		ui.next({width = ui.fill(), height = ui.fill()})
		prefs_page.build(&app.page, &app.prefs, {user = app, pages = PANEL_PAGES[:], views = &app.views})
	}
}

@(test)
the_window_page_sets_the_bottom_panel_s_span :: proc(t: ^testing.T) {
	app: Panels_App
	app.prefs = config.prefs_make()
	config.register(&app.prefs, PANEL_DEFS[:])
	defer {
		prefs_page.destroy(&app.page)
		ui.views_destroy(&app.views)
		config.prefs_destroy(&app.prefs)
		delete(app.want)
	}
	ui.view_register(&app.views, "side", panel_words, ui.View_Options{title = "Side", home = .Panel, home_place = {edge = .Left}, extent_em = 8})
	ui.view_register(&app.views, "low", panel_words, ui.View_Options{title = "Low", home = .Panel, home_place = {edge = .Bottom}, extent_em = 6})
	ui.view_register(&app.views, "high", panel_words, ui.View_Options{title = "High", home = .Panel, home_place = {edge = .Top}, extent_em = 4})
	append(&app.want, "side", "low")
	s := session.start(t, {size = {1300, 800}, build = panels_build, user = &app})
	row := session.wait_box(s, "set_panels.bottom")
	if row == nil { return }
	testing.expect(t, session.find(s, "set_panels.top") == nil, "no top zone: no top line")
	testing.expect(t, session.find(s, "reset", within = row) == nil, "the program's span: no reset")
	session.click_text(s, "Full")
	session.frames(s, 3)
	span, chosen := ui.views_space_span(&app.views, "", .Bottom)
	testing.expectf(t, span == .Full && chosen, "the person's .Full: %v, %v", span, chosen)
	row = session.find(s, "set_panels.bottom")
	reset := row != nil ? session.find(s, "reset", within = row) : nil
	if !testing.expect(t, reset != nil, "a reset while the person chose") { return }
	session.click_at(s, session.center(reset))
	session.frames(s, 3)
	span, chosen = ui.views_space_span(&app.views, "", .Bottom)
	testing.expectf(t, span == .Content && !chosen, "the program's again: %v, %v", span, chosen)
	append(&app.want, "high")
	testing.expect(t, session.wait_box(s, "set_panels.top") != nil, "a top zone: its line")
}
