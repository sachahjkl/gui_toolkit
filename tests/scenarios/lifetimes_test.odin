package scenarios_test

// What outlives a frame and what ends it: a box that goes while something holds it, a window the user leaves, an Escape
// that comes with a new dialog, a style given to nothing, the links of a paragraph.

import "core:testing"
import "../../platform"
import "../../testkit/session"
import "../../ui"

@(private = "file") WINDOW :: [2]int{600, 500}
@(private = "file") FIELD_WIDTH :: 200
@(private = "file") SCROLL_SIZE :: 300
@(private = "file") CONTENT_HEIGHT :: 2000
@(private = "file") ODD_WIDTH :: 77
// Past the tap's slop of autoscroll, and past the dead zone.
@(private = "file") FAR_PX :: 60
@(private = "file") LINK_SEARCH_STEP_PX :: 3
@(private = "file") SPLIT_START :: 200
@(private = "file") SPLIT_MIN :: 50
@(private = "file") SPLIT_MAX :: 400
@(private = "file") SPLIT_MOVE_PX :: 40
@(private = "file") SETTLE_FRAMES :: 4

@(private = "file")
Run :: struct {
	show:   bool,
	field:  ui.Text_Field,
	clicks: int,
	size:   f32,
	finished: int,
	first, second: bool,
	menu:   ui.Key,
	rich:   ui.Rich_Result,
}

@(private = "file")
scroller :: proc() {
	ui.next({width = ui.px(SCROLL_SIZE), height = ui.px(SCROLL_SIZE)})
	if ui.scroll_y("###region") {
		ui.next({width = ui.fill(), height = ui.px(CONTENT_HEIGHT)})
		ui.build_box({}, "###tall")
	}
}

// A press on a box that goes: what is under the pointer is hot again, with the button still down.
@(test)
a_press_ends_with_its_box :: proc(t: ^testing.T) {
	r := Run{show = true}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.show { ui.button("Gone###gone") }
		ui.button("Under###under")
	}})
	session.press(s, session.center(session.get(s, "gone")))
	testing.expect(t, s.state.active_key[.Left] != 0, "held")
	r.show = false
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, s.state.active_key[.Left], ui.Key(0))
	testing.expect_value(t, session.hot_name(s), "under")
}

// The focus goes with its box: a box of that key built later has not got it.
@(test)
the_focus_ends_with_its_box :: proc(t: ^testing.T) {
	r := Run{show = true}
	defer ui.field_destroy(&r.field)
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.show { ui.next({width = ui.px(FIELD_WIDTH)}); ui.line_edit("###f", &r.field) }
	}})
	session.click(s, "f")
	testing.expect_value(t, session.focused_name(s), "f")
	r.show = false
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, s.state.focus_key, ui.Key(0))
	r.show = true
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, s.state.focus_key, ui.Key(0))
}

// What was never built has not gone: a focus given to a box of the next frames stands.
@(test)
a_focus_given_ahead_of_its_box_stands :: proc(t: ^testing.T) {
	r: Run
	defer ui.field_destroy(&r.field)
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.show { ui.next({width = ui.px(FIELD_WIDTH)}); ui.line_edit("###f", &r.field) }
	}})
	key := ui.key_from_string(ui.key_from_string(0, "root"), "###f")
	ui.set_focus(key)
	session.frames(s, SETTLE_FRAMES)
	r.show = true
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, s.state.focus_key, key)
}

// A splitter that went in the middle of its drag says it is finished when it comes back: the app saves what it changed.
@(test)
a_drag_cut_short_finishes_when_its_box_is_back :: proc(t: ^testing.T) {
	r := Run{show = true, size = SPLIT_START}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if !r.show { return }
		if ui.splitter("###split", .X, &r.size, SPLIT_MIN, SPLIT_MAX).finished { r.finished += 1 }
	}})
	at := session.center(session.get(s, "split"))
	session.press(s, at)
	session.move(s, at + {SPLIT_MOVE_PX, 0})
	r.show = false
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, r.finished, 0)
	r.show = true
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, r.finished, 1)
}

@(private = "file")
links_build :: proc(s: ^session.Session) {
	r := (^Run)(s.user)
	if !r.show { return }
	ui.next({width = ui.px(SCROLL_SIZE)})
	r.rich = ui.rich_paragraph("###rich", {{text = "one", link = "a"}, {text = " plain words here "}, {text = "two", link = "b"}})
}

// The point of the paragraph over link run `run` (-1: over no link).
@(private = "file")
point_on_run :: proc(s: ^session.Session, r: ^Run, run: int) -> [2]f32 {
	b := session.get(s, "rich")
	y := session.center(b).y
	for x := b.rect.min.x + 1; x < b.rect.max.x; x += LINK_SEARCH_STEP_PX {
		session.move(s, {x, y})
		if r.rich.link_hovered == run { return {x, y} }
	}
	session.failed(s, "no such point in the paragraph")
}

// The link a focused paragraph is on goes with it.
@(test)
a_paragraph_that_goes_forgets_its_link :: proc(t: ^testing.T) {
	r := Run{show = true}
	s := session.start(t, {size = WINDOW, user = &r, build = links_build})
	session.key(s, .Tab)
	testing.expect_value(t, len(s.state.rich_link), 1)
	r.show = false
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, len(s.state.rich_link), 0)
}

// Enter chooses the link that has the focus, wherever the pointer is: on the other link, on the words between.
@(test)
enter_chooses_the_focused_link_not_the_pointers :: proc(t: ^testing.T) {
	r := Run{show = true}
	s := session.start(t, {size = WINDOW, user = &r, build = links_build})
	session.key(s, .Tab)
	testing.expect_value(t, r.rich.link_focused, 0)
	_ = point_on_run(s, &r, 2)
	session.event(s, {kind = .Key_Press, key = .Return})
	session.frame(s)
	testing.expect_value(t, r.rich.link_clicked, 0)
	_ = point_on_run(s, &r, -1)
	session.event(s, {kind = .Key_Press, key = .Return})
	session.frame(s)
	testing.expect_value(t, r.rich.link_clicked, 0)
}

// A screen reader that puts the focus on the second link of a paragraph without the focus leaves it there.
@(test)
a_screen_readers_focus_on_a_link_stays :: proc(t: ^testing.T) {
	r := Run{show = true}
	s := session.start(t, {size = WINDOW, user = &r, build = links_build})
	ui.a11y_capture(s.state, true)
	session.frames(s, 2)
	box := session.get(s, "rich")
	parts := box.a11y.parts
	testing.expect(t, len(parts) >= 2, "the paragraph has parts")
	ui.a11y_inject(s.state, {action = .Focus, target = parts[len(parts) - 1].id})
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, r.rich.link_focused, 2)
}

// Leaving the window ends what the pointer or the keyboard was doing there: an open menu, a hold, the modifiers.
@(test)
a_menu_closes_with_the_window :: proc(t: ^testing.T) {
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		r.menu = ui.key_from_string(0, "menu")
		if ui.ctx_menu(r.menu) { ui.menu_item("Item###item") }
	}})
	ui.ctx_menu_open(r.menu, {10, 10})
	session.frames(s, SETTLE_FRAMES)
	testing.expect(t, ui.ctx_menu_any_open(), "open")
	session.activate(s, false)
	testing.expect(t, !ui.ctx_menu_any_open(), "closed with the window")
}

@(test)
a_hold_and_the_modifiers_end_with_the_window :: proc(t: ^testing.T) {
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if ui.button("Hold###hold").clicked { r.clicks += 1 }
	}})
	at := session.center(session.get(s, "hold"))
	session.event(s, {kind = .Key_Press, key = .Shift, mods = {.Shift}})
	session.press(s, at)
	session.activate(s, false)   // (no release: X11 and Wayland send none)
	testing.expect_value(t, s.state.active_key[.Left], ui.Key(0))
	testing.expect_value(t, s.state.mods, platform.Modifiers{})
	session.release(s, at)
	testing.expect_value(t, r.clicks, 0)
}

// A latched session waits for a click that will not come in a window the user left.
@(test)
a_latched_autoscroll_ends_with_the_window :: proc(t: ^testing.T) {
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) { scroller() }})
	ui.set_autoscroll_enabled(s.state, true)
	session.click_at(s, session.center(session.get(s, "region")), .Middle)
	testing.expect(t, ui.autoscroll_running(s.state), "latched")
	session.activate(s, false)
	testing.expect(t, !ui.autoscroll_running(s.state), "ended")
	session.wait_idle(s)
}

// So does one whose window moves under the pointer.
@(test)
an_autoscroll_ends_when_the_window_moves :: proc(t: ^testing.T) {
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) { scroller() }})
	ui.set_autoscroll_enabled(s.state, true)
	session.click_at(s, session.center(session.get(s, "region")), .Middle)
	testing.expect(t, ui.autoscroll_running(s.state), "latched")
	platform.move_window(s.win, FAR_PX, FAR_PX)
	session.frames(s, SETTLE_FRAMES)
	testing.expect(t, !ui.autoscroll_running(s.state), "ended")
}

// A press and a release that moved, read in one frame: no tap, though no move came between them.
@(test)
a_tap_that_moved_in_its_last_event_is_no_tap :: proc(t: ^testing.T) {
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) { scroller() }})
	ui.set_autoscroll_enabled(s.state, true)
	at := session.center(session.get(s, "region"))
	session.press(s, at, .Middle)
	s.buttons -= {.Middle}
	session.event(s, {kind = .Mouse_Move, pos = at + {0, FAR_PX}})
	session.event(s, {kind = .Mouse_Release, button = .Middle, pos = at + {0, FAR_PX}})
	session.frames(s, 2)
	testing.expect(t, !ui.autoscroll_running(s.state), "a drag ended by its release")
}

// What ends a session does not end the frame's input: a middle press read with it starts the next one.
@(test)
a_middle_press_read_with_an_end_is_seen :: proc(t: ^testing.T) {
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) { scroller() }})
	ui.set_autoscroll_enabled(s.state, true)
	at := session.center(session.get(s, "region"))
	session.press(s, at, .Middle)
	session.event(s, {kind = .Key_Press, key = .Escape})
	session.event(s, {kind = .Mouse_Release, button = .Middle, pos = at})
	session.event(s, {kind = .Mouse_Press, button = .Middle, pos = at})
	session.frame(s)
	testing.expect(t, ui.autoscroll_running(s.state), "the press after the Escape began a session")
	testing.expect_value(t, s.state.pressed_key[.Middle], ui.Key(0))
}

// The Escape that ended a session was the session's: an open menu does not get it too.
@(test)
the_escape_of_autoscroll_is_not_the_menus :: proc(t: ^testing.T) {
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		scroller()
		r.menu = ui.key_from_string(0, "menu")
		if ui.ctx_menu(r.menu) { ui.menu_item("Item###item") }
	}})
	ui.set_autoscroll_enabled(s.state, true)
	session.press(s, session.center(session.get(s, "region")), .Middle)
	ui.ctx_menu_open(r.menu, {SCROLL_SIZE + FAR_PX, 10})
	session.frames(s, SETTLE_FRAMES)
	session.key(s, .Escape)
	testing.expect(t, !ui.autoscroll_running(s.state), "the session ended")
	testing.expect(t, ui.ctx_menu_any_open(), "the menu stays")
}

// An Escape read in the frame a new dialog opens is the new dialog's: the one under it stays.
@(test)
escape_in_the_first_frame_of_a_dialog_is_its_own :: proc(t: ^testing.T) {
	r := Run{first = true}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if ui.modal("first", 400, &r.first) { ui.label("First") }
		if ui.modal("second", 300, &r.second) { ui.label("Second") }
	}})
	session.frames(s, SETTLE_FRAMES)
	session.event(s, {kind = .Key_Press, key = .Escape})
	r.second = true
	session.frames(s, SETTLE_FRAMES)
	testing.expect(t, r.first, "the dialog under it stays")
	testing.expect(t, !r.second, "the one on top closed")
}

// A style given to a widget that builds nothing is gone with it: it is not the next box's.
@(test)
next_goes_with_what_builds_nothing :: proc(t: ^testing.T) {
	Latches :: struct { open: bool, size: ui.Vec2 }
	r: Latches
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Latches)(s.user)
		ui.next({width = ui.px(ODD_WIDTH)})
		if ui.modal("closed", 300, &r.open) {}
		ui.button("A###a")
		ui.next({width = ui.px(ODD_WIDTH)})
		if ui.modal_sized("closed2", {300, 300}, &r.size, &r.open) {}
		ui.button("B###b")
		ui.next({width = ui.px(ODD_WIDTH)})
		if ui.ctx_menu(ui.key_from_string(0, "closed3")) {}
		ui.button("C###c")
	}})
	session.frame(s)
	for name in ([]string{"a", "b", "c"}) {
		b := session.get(s, name)
		testing.expectf(t, b.rect.max.x - b.rect.min.x != ODD_WIDTH, "%s has its own width", name)
	}
}

// The text that goes with the drag: the drag is over, with nothing to wait for.
@(test)
a_selection_that_goes_ends_its_drag :: proc(t: ^testing.T) {
	r := Run{show = true}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({flags = {.Selectable}})
		ui.label("Stays###stays")
		if r.show { ui.next({flags = {.Selectable}}); ui.label("Some words to select###words") }
	}})
	at := session.center(session.get(s, "words"))
	session.press(s, at)
	r.show = false
	session.frames(s, SETTLE_FRAMES)
	testing.expect(t, !ui.needs_frame(s.state), "no frames kept coming for a drag of nothing")
	testing.expect(t, !ui.has_selection(s.state), "no selection")
}

// select_box is the end of the drag going on: what it selected is not moved by the pointer.
@(test)
select_box_ends_a_drag :: proc(t: ^testing.T) {
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		ui.next({flags = {.Selectable}})
		ui.label("Some words to select###words")
	}})
	b := session.get(s, "words")
	at := session.center(b)
	session.press(s, at)
	ui.select_box(s.state, b.key)
	session.move(s, at + {1, 0})
	text := ui.selected_text(s.state, context.temp_allocator)
	testing.expect_value(t, text, "Some words to select")
	session.release(s, at)
}

// A button pressed between two presses on a text: they are no double click.
@(test)
a_press_elsewhere_breaks_a_double_click_on_text :: proc(t: ^testing.T) {
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		ui.next({flags = {.Selectable}})
		ui.label("Some words to select###words")
		ui.button("Press###press")
	}})
	at := session.center(session.get(s, "words"))
	button := session.center(session.get(s, "press"))
	session.click_at(s, at)
	session.click_at(s, button)
	session.move(s, at)
	session.click_at(s, at)
	testing.expect(t, !ui.has_selection(s.state), "a caret, not a word")
}
