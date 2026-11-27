package scenarios_test

// The menu bar's keys (src/ui/menu_bar.odin, src/md/features/menus.md): Alt+letter opens the menu of that access letter,
// underlined while Alt is held; Left and Right go from a menu of the bar to the one beside it; Escape closes the menu and
// leaves its entry lit, the keys the bar's; F10 and Alt alone light the bar, whose keys move and open.

import "core:testing"
import "gt:platform"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Bar_Run :: struct { chosen: string, claim: bool }

@(private = "file")
bar_build :: proc(s: ^session.Session) {
	r := (^Bar_Run)(s.user)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.parent(ui.build_box({}, "###bar")) {
		if ui.menu(ui.menu_bar_button("&File")) {
			if ui.menu_item("Open").clicked { r.chosen = "Open" }
			if ui.menu_item("Save").clicked { r.chosen = "Save" }
		}
		if ui.menu(ui.menu_bar_button("Ed&it")) {
			if ui.menu_item("Undo").clicked { r.chosen = "Undo" }
		}
		if ui.menu(ui.menu_bar_button("View")) {
			if ui.menu_item("Zoom in").clicked { r.chosen = "Zoom in" }
		}
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.build_box({}, "###content")
	// (a widget that keeps every key while it has the keyboard: a shortcut recorder, a terminal)
	ui.next({width = ui.px(200), height = ui.px(40)})
	rec := ui.build_box({.Clickable, .Focusable}, "###recorder")
	ui.signal(rec)
	if r.claim { ui.keys_claim(rec.key) }
}

// Whether the bar is lit: Down then opens its entry's menu (closed again, Escape twice).
@(private = "file")
bar_lit :: proc(s: ^session.Session) -> bool {
	session.key(s, .Down)
	session.frames(s, 2)
	lit := ui.menu_any_open()
	if lit { session.key(s, .Escape); session.key(s, .Escape); session.frames(s, 2) }
	return lit
}

// Alt let go with no tap in it: the system made the release as the focus left (Alt+Tab), in either order with the
// window's Activate; the pointer was taken by a window manager's Alt+drag; the wheel turned with Alt.
@(test)
an_alt_that_was_no_tap_lights_nothing :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Bar_Run
	s := session.start(t, {size = {600, 400}, user = &r, build = bar_build})
	session.wait_idle(s)
	session.key(s, .Alt, {.Alt})
	testing.expect(t, bar_lit(s), "a tap of Alt lights the bar")

	// (Linux: the window says it left, then makes the release)
	session.event(s, {kind = .Key_Press, key = .Alt, mods = {.Alt}})
	platform.set_offscreen_active(s.win, false)
	session.event(s, {kind = .Key_Release, key = .Alt})
	session.frames(s, 2)
	platform.set_offscreen_active(s.win, true)
	session.frames(s, 2)
	testing.expect(t, !bar_lit(s), "Alt+Tab away (Activate, then the release) lights nothing")

	// (Windows: the release as the focus goes, the Activate after it)
	session.event(s, {kind = .Key_Press, key = .Alt, mods = {.Alt}})
	session.event(s, {kind = .Key_Release, key = .Alt})
	platform.set_offscreen_active(s.win, false)
	session.frames(s, 2)
	platform.set_offscreen_active(s.win, true)
	session.frames(s, 2)
	testing.expect(t, !bar_lit(s), "Alt+Tab away (the release, then Activate) lights nothing")

	session.event(s, {kind = .Key_Press, key = .Alt, mods = {.Alt}})
	session.event(s, {kind = .Mouse_Leave})
	session.event(s, {kind = .Key_Release, key = .Alt})
	session.frames(s, 2)
	testing.expect(t, !bar_lit(s), "a window manager's Alt+drag lights nothing")

	session.event(s, {kind = .Key_Press, key = .Alt, mods = {.Alt}})
	session.wheel(s, session.center(session.get(s, "content")), {0, 1}, {.Alt})
	session.event(s, {kind = .Key_Release, key = .Alt})
	session.frames(s, 2)
	testing.expect(t, !bar_lit(s), "Alt with the wheel lights nothing")

	// (Windows repeats a held Alt: a click between its repeats still spoils the tap)
	session.event(s, {kind = .Key_Press, key = .Alt, mods = {.Alt}})
	session.click_at(s, session.center(session.get(s, "content")))
	session.event(s, {kind = .Key_Press, key = .Alt, mods = {.Alt}, repeat = true})
	session.event(s, {kind = .Key_Release, key = .Alt})
	session.frames(s, 2)
	testing.expect(t, !bar_lit(s), "Alt held across a click lights nothing")

	// (Windows' AltGr is Ctrl+Alt: no access letter shows under it)
	session.event(s, {kind = .Key_Press, key = .Ctrl, mods = {}})
	session.event(s, {kind = .Key_Press, key = .Alt, mods = {.Ctrl, .Alt}})
	session.frames(s, 2)
	file := session.find_text(s, "File")
	testing.expect(t, file != nil && file.custom == nil, "AltGr held: no letter underlined")
	session.event(s, {kind = .Key_Press, key = .E, mods = {.Ctrl, .Alt}})
	session.frames(s, 2)
	testing.expect(t, !ui.menu_any_open(), "AltGr+E (€) opens no menu")
	session.event(s, {kind = .Key_Release, key = .E, mods = {.Ctrl, .Alt}})
	session.event(s, {kind = .Key_Release, key = .Alt, mods = {.Ctrl}})
	session.event(s, {kind = .Key_Release, key = .Ctrl})
	session.frames(s, 2)
	testing.expect(t, !bar_lit(s), "AltGr let go lights nothing")
}) }

// A widget that claims the keys (keys_claim) keeps Alt+letter, F10 and Alt alone: a shortcut recorder records them, a
// terminal sends them.
@(test)
a_widget_that_claims_the_keys_keeps_them :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Bar_Run{claim = true}
	s := session.start(t, {size = {600, 400}, user = &r, build = bar_build})
	session.wait_idle(s)
	session.click(s, "recorder")
	session.frames(s, 2)
	testing.expect_value(t, session.focused_name(s), "recorder")
	session.key(s, .F, {.Alt})
	session.frames(s, 2)
	testing.expect(t, !ui.menu_any_open(), "Alt+F stays the widget's")
	session.key(s, .F10)
	testing.expect(t, !bar_lit(s), "F10 stays the widget's")
	session.key(s, .Alt, {.Alt})
	testing.expect(t, !bar_lit(s), "Alt alone stays the widget's")
	r.claim = false
	session.frames(s, 3)
	session.key(s, .F, {.Alt})
	session.frames(s, 2)
	testing.expect(t, open_menu_shows(s, "Open"), "no claim: Alt+F opens File")
}) }

// The open menu's first item, by its words ("": none open).
@(private = "file")
open_menu_shows :: proc(s: ^session.Session, words: string) -> bool {
	return ui.menu_any_open() && session.find_text(s, words) != nil
}

@(test)
the_menu_bar_takes_the_keyboard :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Bar_Run
	s := session.start(t, {size = {600, 400}, user = &r, build = bar_build})
	session.wait_idle(s)
	file := session.find_text(s, "File")
	testing.expect(t, file != nil && file.custom == nil, "no letter underlined at rest")

	// (Alt held: the access letters underlined)
	session.event(s, {kind = .Key_Press, key = .Alt, mods = {.Alt}})
	session.frames(s, 2)
	file = session.find_text(s, "File")
	testing.expect(t, file != nil && file.custom != nil, "Alt held: File's letter underlined")
	session.save_png(s, "alt_held.png")
	session.event(s, {kind = .Key_Press, key = .I, mods = {.Alt}})
	session.event(s, {kind = .Key_Release, key = .I, mods = {.Alt}})
	session.event(s, {kind = .Key_Release, key = .Alt})
	session.frames(s, 3)
	testing.expect(t, open_menu_shows(s, "Undo"), "Alt+I opens Edit (its marked letter)")

	// (Right and Left: the menu beside, its first item selected)
	session.key(s, .Right)
	session.frames(s, 2)
	testing.expect(t, open_menu_shows(s, "Zoom in"), "Right: View")
	session.key(s, .Right)
	session.frames(s, 2)
	testing.expect(t, open_menu_shows(s, "Open"), "Right from the last: File")
	session.key(s, .Left)
	session.frames(s, 2)
	testing.expect(t, open_menu_shows(s, "Zoom in"), "Left from the first: View")
	session.key(s, .Left)
	session.frames(s, 2)
	session.key(s, .Left)
	session.frames(s, 2)
	testing.expect(t, open_menu_shows(s, "Open"), "Left twice: File")
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect_value(t, r.chosen, "Open")   // (opened by the keys: its first item selected)

	// (F10 lights the bar; its keys move and open; Escape steps back to the lit entry, then out)
	session.key(s, .F10)
	session.key(s, .Right)
	session.key(s, .Down)
	session.frames(s, 2)
	testing.expect(t, open_menu_shows(s, "Undo"), "F10, Right, Down: Edit")
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect(t, !ui.menu_any_open(), "Escape closes the menu")
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect(t, open_menu_shows(s, "Undo"), "its entry stayed lit: Enter opens it again")
	session.key(s, .Escape)
	session.key(s, .Escape)
	session.key(s, .Down)
	session.frames(s, 2)
	testing.expect(t, !ui.menu_any_open(), "a second Escape gave the keys back: Down opens nothing")

	// (Alt alone lights the bar; a letter then opens its menu; a press of the pointer gives the keys back)
	session.key(s, .Alt, {.Alt})
	session.key(s, .V)
	session.frames(s, 2)
	testing.expect(t, open_menu_shows(s, "Zoom in"), "Alt, then V: View")
	session.key(s, .Escape)
	session.key(s, .Escape)
	session.key(s, .Alt, {.Alt})
	session.click_at(s, session.center(session.get(s, "content")))
	session.key(s, .Down)
	session.frames(s, 2)
	testing.expect(t, !ui.menu_any_open(), "a press elsewhere gave the keys back")
	// (Alt with another key between its press and its release lights nothing)
	session.event(s, {kind = .Key_Press, key = .Alt, mods = {.Alt}})
	session.key(s, .Left, {.Alt})
	session.event(s, {kind = .Key_Release, key = .Alt})
	session.frames(s, 2)
	session.key(s, .Down)
	session.frames(s, 2)
	testing.expect(t, !ui.menu_any_open(), "Alt+Left is no tap of Alt")
}) }
