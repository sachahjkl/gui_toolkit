// A stack's tabs too many for its strip (ui/docking.odin, ui/strip.odin): they scroll with the toolkit's arrows, as
// every row of tabs does; the tab on top is in view, the stack's buttons stay at the end.
//   odin test tests/docking -collection:gt=src -vet -define:ODIN_TEST_THREADS=1
package docking_test

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") STRIP_TITLES := [?]string{"", "Alpha panel", "Beta panel", "Gamma panel", "Delta panel", "Epsilon panel"}

@(private = "file")
Strip_App :: struct { dock: ui.Dock }

@(private = "file")
strip_app_build :: proc(s: ^session.Session) {
	app := (^Strip_App)(s.user)
	ui.dock_begin(&app.dock, "###dock", {title = proc(user: rawptr, id: u32) -> string { return STRIP_TITLES[id] }, user = app})
	for p in u32(1) ..< len(STRIP_TITLES) { if ui.dock_panel(&app.dock, p) { ui.label("content###content") } }
	ui.dock_end(&app.dock)
}

@(test)
a_stacks_tabs_too_many_scroll_with_arrows :: proc(t: ^testing.T) {
	app: Strip_App
	ui.dock_init(&app.dock)
	defer ui.dock_destroy(&app.dock)
	// (one stack of five, the last on top, in a window too narrow for their titles)
	testing.expect(t, ui.dock_parse(&app.dock, "dock1 [a,b,c,d,*e]", id_of, nil))
	s := session.start(t, {build = strip_app_build, user = &app, size = {260, 300}, no_renderer = true})
	session.wait_idle(s)
	leaf := app.dock.main
	view := session.get(s, "strip_view")
	testing.expect(t, ui.view_limit(view, .X) > 0, "the tabs overflow their strip")
	testing.expect(t, session.find(s, "strip_left") != nil, "an arrow at the start: tabs hidden there")
	_, _, bar := ui.scrollbar_rects(view, .X)
	testing.expect(t, !bar, "no scroll bar")
	// the tab on top in view, clear of the arrow
	top := ui.box_from_key(ui.dock_tab_key(&app.dock, leaf, 5))
	if !testing.expect(t, top != nil, "the tab on top") { return }
	left := session.get(s, "strip_left")
	testing.expectf(t, top.rect.min.x >= left.rect.max.x - 0.5 && top.rect.max.x <= view.rect.max.x + 0.5, "in view: %v in %v after %v", top.rect, view.rect, left.rect)
	// the stack's menu at the strip's end, in the window
	menu := session.get(s, "dock_menu_btn")
	testing.expectf(t, menu.rect.max.x <= 260.5 && menu.rect.min.x >= view.rect.max.x - 0.5, "the menu's button after the tabs: %v", menu.rect)
}
