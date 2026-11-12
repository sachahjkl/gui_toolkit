package system_title_test

// A window whose title bar is the system's has the system's caption buttons: ui.window_buttons draws none. Switched to an
// integrated title (the program draws it), they are there; switched back, gone again.

import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/ui"

@(test)
window_buttons_follow_the_title_bar :: proc(t: ^testing.T) {
	s := session.start(t, {size = {600, 200}, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(32)})
		if ui.title_bar("###tb") {
			ui.spacer(ui.fill())
			_, _ = ui.window_buttons()
		}
	}})
	testing.expect(t, platform.system_title_available(s.win), "an offscreen window can have the system's")
	session.frames(s, 2)
	testing.expect(t, session.find(s, "wb_close") == nil, "the system's title bar: its buttons are the system's")
	platform.set_integrated_title(s.win, true)
	session.frames(s, 2)
	testing.expect(t, session.find(s, "wb_close") != nil, "an integrated title bar: the program's buttons")
	platform.set_integrated_title(s.win, false)
	session.frames(s, 2)
	testing.expect(t, session.find(s, "wb_close") == nil, "the system's again")
}

// An offscreen window has no menu of the system's to show (show_system_menu does nothing there): an app does not offer
// the item that opens it. The option that gives the app the caption's right clicks is the window's.
@(test)
system_menu_of_an_offscreen_window :: proc(t: ^testing.T) {
	s := session.start(t, {size = {600, 200}, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(32)})
		if ui.title_bar("###tb") { ui.spacer(ui.fill()) }
	}})
	testing.expect(t, !platform.system_menu_available(s.win), "offscreen: no system menu")
	testing.expect(t, !s.win.caption_menu_app, "the system's by default")
	platform.set_caption_menu_app(s.win, true)
	testing.expect(t, s.win.caption_menu_app)
	platform.set_caption_menu_app(nil, true)   // (no window: nothing)
}
