package views_test

// Read-only ui.view_info(vs, id, instance) query (src/ui/views.odin, docs/views.md): reports presentation, dock
// edge/stack, active tab state, keyboard focus, and shown title without exposing private View_Record internals.

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
Info_Run :: struct {
	views:   ui.Views,
	a_edit:  ui.Line_Edit,
	b_edit:  ui.Line_Edit,
	pg_edit: ui.Line_Edit,
}

@(private = "file")
info_panel_a :: proc(v: ^ui.View, r: ^Info_Run) {
	ui.next({width = ui.fill(), height = ui.px(28)})
	ui.line_edit("###info_a_field", &r.a_edit)
}

@(private = "file")
info_panel_b :: proc(v: ^ui.View, r: ^Info_Run) {
	ui.next({width = ui.fill(), height = ui.px(28)})
	ui.line_edit("###info_b_field", &r.b_edit)
}

@(test)
view_info_reports_dock_tabs_focus_and_float :: proc(t: ^testing.T) {
	r: Info_Run
	defer {
		ui.views_destroy(&r.views)
		ui.line_edit_destroy(&r.a_edit)
		ui.line_edit_destroy(&r.b_edit)
		ui.line_edit_destroy(&r.pg_edit)
	}
	ui.view_register(&r.views, "alpha", info_panel_a, {title = "Alpha", home = .Panel, home_place = {edge = .Left}})
	ui.view_register(&r.views, "beta", info_panel_b, {title = "Beta", home = .Panel, home_place = {edge = .Left}})
	s := session.start(t, {size = {800, 500}, user = &r, build = proc(s: ^session.Session) {
		r := (^Info_Run)(s.user)
		if ui.views_frame(&r.views) {
			ui.next({width = ui.px(200), height = ui.px(28)})
			ui.line_edit("###info_page_field", &r.pg_edit)
		}
	}})
	session.frames(s, 2)

	// Closed / unknown views return ok = false.
	_, ok := ui.view_info(&r.views, "missing")
	testing.expect(t, !ok, "unknown view returns ok = false")
	_, ok = ui.view_info(&r.views, "alpha")
	testing.expect(t, !ok, "closed view returns ok = false")

	// Open both views in the same Left stack: beta (opened second) is active, alpha is inactive.
	ui.view_open(&r.views, "alpha", &r, owner = s.state)
	ui.view_open(&r.views, "beta", &r, owner = s.state)
	session.wait_box(s, "view_tabs")
	session.frames(s, 2)

	ia, oka := ui.view_info(&r.views, "alpha")
	ib, okb := ui.view_info(&r.views, "beta")
	testing.expect(t, oka && ia.open && okb && ib.open, "both docked views report open")
	testing.expect_value(t, ia.presentation, ui.View_Presentation.Panel)
	testing.expect_value(t, ib.presentation, ui.View_Presentation.Panel)
	testing.expect_value(t, ia.edge, ui.View_Edge.Left)
	testing.expect_value(t, ib.edge, ui.View_Edge.Left)
	testing.expect_value(t, ia.stack, 0)
	testing.expect_value(t, ib.stack, 0)
	testing.expect_value(t, ia.title, "Alpha")
	testing.expect_value(t, ib.title, "Beta")
	testing.expect(t, !ia.active && ib.active, "beta is active tab, alpha is inactive")
	testing.expect(t, !ia.focused, "inactive tab is not focused")

	// Switching tab to alpha flips active state.
	session.click(s, "view_tab_view_alpha")
	session.frames(s, 2)
	ia, _ = ui.view_info(&r.views, "alpha")
	ib, _ = ui.view_info(&r.views, "beta")
	testing.expect(t, ia.active && !ib.active, "clicking alpha tab flips active state")

	// Focusing alpha's field reports focused = true; focusing page field clears it.
	session.click(s, "info_a_field")
	session.frames(s, 2)
	ia, _ = ui.view_info(&r.views, "alpha")
	testing.expect(t, ia.focused, "focus inside alpha sets focused = true")

	session.click(s, "info_page_field")
	session.frames(s, 2)
	ia, _ = ui.view_info(&r.views, "alpha")
	testing.expect(t, !ia.focused, "focus on main content clears focused")

	// Floating alpha reports presentation = .Internal and active = true.
	ui.view_present(&r.views, "alpha", .Internal)
	session.wait_box(s, "internal_view_alpha")
	session.frames(s, 2)
	ia, oka = ui.view_info(&r.views, "alpha")
	testing.expect(t, oka && ia.presentation == .Internal && ia.active, "floated view reports Internal and active")

	// Closing alpha makes view_info return ok = false.
	ui.view_close(&r.views, "alpha")
	session.frames(s, 2)
	_, ok = ui.view_info(&r.views, "alpha")
	testing.expect(t, !ok, "closed view returns ok = false")
}
