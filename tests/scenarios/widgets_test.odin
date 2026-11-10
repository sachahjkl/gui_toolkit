package scenarios_test

// Widgets no other package reaches, each by what it is for: the colour pickers, toasts, popovers, Tab stops turned off, muted scopes, density, rounding,
// a virtual list scrolled by the program, a menu's heading, posted calls by the window, selection cleared.

import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{500, 400}
// A toast's life is over by then (ui TOAST_LIFE_MS, its fade out).
@(private = "file") TOAST_OVER_MS :: 10000
// Three pixels into a gradient, in sRGB.
@(private = "file") CORNER_TOLERANCE :: 48
@(private = "file") PICKER_SIZE :: 200
@(private = "file") HUE_WIDTH :: 20
@(private = "file") LIST_ROWS :: 200
@(private = "file") SCROLL_TO_Y :: 500
@(private = "file") LIST_ROW_HEIGHT :: 30

// A press on the saturation and value square gives the colour under it: right is more saturated, up is brighter. The hue strip goes from top to bottom.
@(test)
the_colour_pickers_take_a_press :: proc(t: ^testing.T) {
	Run :: struct { hue, sat, val: f32, changed: int }
	r := Run{hue = 0.5, sat = 0.5, val = 0.5}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(PICKER_SIZE), height = ui.px(PICKER_SIZE)})
		if ui.sat_val_picker("###sv", r.hue, &r.sat, &r.val) { r.changed += 1 }
		ui.next({width = ui.px(HUE_WIDTH), height = ui.px(PICKER_SIZE)})
		if ui.hue_picker("###hue", &r.hue) { r.changed += 1 }
	}})
	sv := session.get(s, "sv")
	session.click_at(s, {sv.rect.max.x - 2, sv.rect.min.y + 2})
	testing.expectf(t, r.sat > 0.95 && r.val > 0.95, "the top right is the full colour: %v %v", r.sat, r.val)
	testing.expect(t, r.changed > 0, "it says it changed")
	session.click_at(s, {sv.rect.min.x + 2, sv.rect.max.y - 2})
	testing.expectf(t, r.sat < 0.05 && r.val < 0.05, "the bottom left is black: %v %v", r.sat, r.val)
	hue := session.get(s, "hue")
	session.click_at(s, {session.center(hue).x, session.center(hue).y})
	testing.expectf(t, r.hue > 0.4 && r.hue < 0.6, "the middle of the strip: %v", r.hue)
	session.drag(s, session.center(hue), {session.center(hue).x, hue.rect.min.y + 1})
	testing.expectf(t, r.hue < 0.05, "dragged to its start: %v", r.hue)
	// its picture: the corners of the square are what they say (its marker elsewhere)
	session.click_at(s, session.center(sv))
	img := session.capture(s)
	black := session.pixel(img, int(sv.rect.min.x) + 3, int(sv.rect.max.y) - 3)
	testing.expect(t, session.near(black, {0, 0, 0, 255}, CORNER_TOLERANCE), "black at the bottom")
	white := session.pixel(img, int(sv.rect.min.x) + 3, int(sv.rect.min.y) + 3)
	testing.expect(t, session.near(white, {255, 255, 255, 255}, CORNER_TOLERANCE), "white at the top left")
}

// A toast comes, in its place, says what it was given, and goes by the clock.
@(test)
a_toast_goes_by_the_clock :: proc(t: ^testing.T) {
	Run :: struct { say, clear: bool }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.say {
			ui.toast(.Good, "Saved %d files", 3)
			r.say = false
		}
		if r.clear { ui.toasts_clear() }
		ui.toasts_build()
	}})
	ui.set_toast_position(s.state, .Top_Left)
	r.say = true
	session.frames(s, 2)
	b := session.wait_text(s, "Saved 3 files")
	testing.expect(t, b.rect.min.x < f32(WINDOW.x) / 2 && b.rect.min.y < f32(WINDOW.y) / 2, "at the top left")
	session.advance(s, TOAST_OVER_MS)
	session.wait_idle(s)
	testing.expect(t, session.find_text(s, "Saved 3 files") == nil, "gone")
	r.say = true
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Saved 3 files") != nil, "another")
	r.clear = true
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Saved 3 files") == nil, "toasts_clear takes them")
}

// A toast that says what can be done does it when clicked, once, and goes.
@(test)
a_toast_with_an_action_does_it_when_clicked :: proc(t: ^testing.T) {
	Run :: struct { say: bool, done: int }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.say {
			ui.toast_action(.Good, proc(user: rawptr) { (^Run)(user).done += 1 }, r, "Version %d: click to install", 2)
			r.say = false
		}
		ui.toasts_build()
	}})
	r.say = true
	session.frames(s, 2)
	b := session.wait_text(s, "Version 2: click to install")
	session.click_at(s, session.center(b))
	session.wait_idle(s)
	testing.expect_value(t, r.done, 1)
	testing.expect(t, session.find_text(s, "Version 2: click to install") == nil, "gone")
}

// A popover stays open while the app builds it, by its anchor.
@(test)
a_popover_stands_by_its_anchor :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		anchor := ui.Rect{{200, 200}, {260, 230}}
		if ui.popover("###pop", anchor, 150) {
			ui.stat_heading("###head", "Numbers", 130)
			ui.stat_row("###row", "Frames", "60", 130)
		}
	}})
	session.frame(s)
	pop := session.find_text(s, "Numbers")
	if !testing.expect(t, pop != nil, "its content") { return }
	testing.expect(t, pop.rect.max.y <= 200, "above its anchor, by default")
	testing.expect(t, session.find_text(s, "Frames") != nil, "with its rows")
}

// What is built under tab_stops(false) can be clicked, and Tab goes over it.
@(test)
tab_stops_can_be_turned_off :: proc(t: ^testing.T) {
	s := session.start(t, {no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(100)})
		ui.button("A###a")
		if ui.tab_stops(false) {
			ui.next({width = ui.px(100)})
			ui.button("B###b")
		}
		ui.next({width = ui.px(100)})
		ui.button("C###c")
	}})
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "a")
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "c")
	testing.expect_value(t, ui.tab_direction(s.state), 0)   // (only in the build right after the move)
	session.click(s, "b")
	testing.expect_value(t, session.focused_name(s), "b")
}

// Density and the corners: what the settings of an application change.
@(test)
density_and_rounding_change_what_is_drawn :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 40, fixed_y = 40, width = ui.px(100), height = ui.px(ui.dense(40)), radius = 20, bg = {1, 0, 0, 1}})
		ui.build_box({.Draw_Background}, "###box")
	}})
	h := session.get(s, "box").rect.max.y - session.get(s, "box").rect.min.y
	ui.set_density(s.state, ui.DENSITY_COMPACT)
	session.frames(s, 2)
	testing.expect(t, session.get(s, "box").rect.max.y - session.get(s, "box").rect.min.y < h, "compact is lower")
	ui.set_density(s.state, 1)
	session.frames(s, 2)
	testing.expect(t, !session.near(session.pixel(session.capture(s), 40, 40), {255, 0, 0, 255}), "a rounded corner")
	ui.set_rounding(s.state, 0)
	session.frames(s, 2)
	testing.expect(t, session.near(session.pixel(session.capture(s), 40, 40), {255, 0, 0, 255}), "with no rounding, a square one")
}

// A virtual list: only what is in view is built; the program can take it elsewhere.
@(test)
a_virtual_list_is_scrolled_by_the_program :: proc(t: ^testing.T) {
	Run :: struct { st: ui.Virtual_List, ids: [LIST_ROWS]u64, labels: [LIST_ROWS]string, first, built: int }
	r := new(Run)
	defer { ui.vlist_destroy(&r.st); free(r) }
	for i in 0 ..< LIST_ROWS { r.ids[i], r.labels[i] = u64(i + 1), "A row" }
	s := session.start(t, {size = WINDOW, user = r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.fill()})
		r.built = 0
		if rows, ok := ui.vlist("###list", &r.st, r.ids[:], r.labels[:]); ok {
			r.first = rows.first
			for i in rows.first ..< rows.last {
				ui.next({height = ui.px(LIST_ROW_HEIGHT)})
				ui.list_row(&r.st.list, i, r.labels[i])
				r.built += 1
			}
		}
	}})
	testing.expect_value(t, r.first, 0)
	testing.expect(t, r.built < LIST_ROWS / 2, "only what is in view is built")
	ui.vlist_scroll_to(&r.st, SCROLL_TO_Y)
	session.wait_idle(s)
	testing.expect(t, r.first > 0 && r.first <= SCROLL_TO_Y / LIST_ROW_HEIGHT, "the rows of there, and a margin")
	top, height := ui.vlist_row_extent(&r.st, r.first)
	testing.expect(t, top <= SCROLL_TO_Y, "the first built is at or above the view")
	testing.expect_value(t, height, LIST_ROW_HEIGHT)
	ui.vlist_invalidate(&r.st)
	session.wait_idle(s)
	testing.expect(t, r.built > 0, "it measures again")
}

// Text selected outside a field, then taken away by the program.
@(test)
a_selection_is_cleared_by_the_program :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), flags = {.Selectable}})
		ui.label("Some words to select###words")
	}})
	b := session.get(s, "words")
	session.drag(s, {b.rect.min.x + 2, session.center(b).y}, {b.rect.max.x - 2, session.center(b).y})
	testing.expect(t, ui.has_selection(s.state), "dragged over")
	text := ui.selected_text(s.state, context.temp_allocator)
	testing.expect(t, len(text) > 0, "it has text")
	ui.clear_selection(s.state)
	testing.expect(t, !ui.has_selection(s.state), "gone")
}

// A menu's heading is no item: the keyboard goes over it.
@(test)
a_menu_heading_is_not_an_item :: proc(t: ^testing.T) {
	Run :: struct { chosen: string }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		key := ui.key_from_string(0, "menu")
		if s.frames == 1 { ui.ctx_menu_open(key, {50, 50}, from_keyboard = true) }
		if ui.ctx_menu(key) {
			ui.menu_heading("Section")
			if ui.menu_item("First").clicked { r.chosen = "first" }
			if ui.menu_item("Second").clicked { r.chosen = "second" }
		}
	}})
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Section") != nil, "the heading shows")
	session.key(s, .Return)
	testing.expect_value(t, r.chosen, "first")
}

// A menu that searches: typed letters keep the items that have them in order (a submenu's items come up), the first
// match is selected; Backspace takes a letter back; Enter chooses it.
@(test)
a_menu_that_searches :: proc(t: ^testing.T) {
	Run :: struct { chosen: string }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		key := ui.key_from_string(0, "menu")
		if s.frames == 1 { ui.ctx_menu_open(key, {50, 50}, search = true) }
		if ui.ctx_menu(key) {
			if ui.menu_item("Open").clicked { r.chosen = "open" }
			if ui.menu_item("Rename").clicked { r.chosen = "rename" }
			ui.menu_separator()
			if ui.menu_submenu("Sort by") {
				if ui.menu_item("Name").clicked { r.chosen = "name" }
				if ui.menu_item("Date modified").clicked { r.chosen = "date" }
			}
		}
	}})
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Type to search") != nil, "what typing does")
	session.type_text(s, "dmx")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Open") == nil, "no match: nothing")
	session.key(s, .Backspace)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Date modified") != nil, "the submenu's item came up")
	testing.expect(t, session.find_text(s, "Rename") == nil, "the others went")
	session.key(s, .Return)
	testing.expect_value(t, r.chosen, "date")
}

// key_take: the frame's first key press not taken yet, with its modifiers; a key a build took already is not given.
@(test)
the_first_key_not_taken_is_given :: proc(t: ^testing.T) {
	Run :: struct { key: platform.Key, mods: platform.Modifiers, ok: bool, enter_taken: bool }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if ui.key_press(.Return) { r.enter_taken = true }
		if k, m, ok := ui.key_take(); ok { r.key, r.mods, r.ok = k, m, true }
	}})
	session.frame(s)
	session.key(s, .K, {.Ctrl, .Shift})
	testing.expect(t, r.ok)
	testing.expect_value(t, r.key, platform.Key.K)
	testing.expect_value(t, r.mods, platform.Modifiers{.Ctrl, .Shift})
	r = {}
	session.key(s, .Return)
	testing.expect(t, r.enter_taken && !r.ok, "taken by the build before: not given")
}

// A call posted to a window runs in that window's next build, on its thread.
@(test)
a_call_posted_to_a_window_runs_in_its_next_build :: proc(t: ^testing.T) {
	Run :: struct { calls: int, words: u64 }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true})
	session.frame(s)   // (its queue is made with a build)
	testing.expect(t, !ui.posts_pending(s.state), "nothing waits")
	testing.expect(t, ui.post_window(s.win, proc(data: rawptr, word: u64) {
		r := (^Run)(data)
		r.calls += 1
		r.words = word
	}, &r, 7), "the window takes it")
	testing.expect_value(t, r.calls, 0)
	testing.expect(t, ui.posts_pending(s.state), "it waits")
	session.frame(s)
	testing.expect_value(t, r.calls, 1)
	testing.expect_value(t, r.words, 7)
}

// A window's state on the virtual screen: what the system would do for a real one.
@(test)
an_offscreen_window_has_the_state_of_a_window :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true})
	w := s.win
	testing.expect(t, !platform.is_minimized(w) && !platform.is_fullscreen(w) && !platform.is_maximized(w), "normal at first")
	platform.minimize(w)
	testing.expect(t, platform.is_minimized(w), "minimized")
	platform.toggle_maximize(w)
	testing.expect(t, platform.is_maximized(w), "maximized")
	platform.toggle_maximize(w)
	testing.expect(t, !platform.is_maximized(w), "back")
	platform.set_fullscreen(w, true)
	testing.expect(t, platform.is_fullscreen(w), "full screen")
	platform.set_fullscreen(w, false)
	testing.expect(t, !platform.is_fullscreen(w), "back")
	testing.expect(t, !platform.is_window_visible(w), "never on a screen")
	platform.show_window(w)
	testing.expect(t, !platform.is_window_visible(w), "even shown")
	testing.expect(t, !platform.is_closed(w))
	platform.request_close(w)
	seen := false
	for e in platform.poll_events(w, false) { if e.kind == .Close { seen = true } }
	testing.expect(t, seen && platform.is_closed(w), "a close asked for comes as an event")
}

// Every flavour of the process's clipboard, and nothing of the machine's.
@(test)
the_process_s_clipboard_keeps_every_flavour :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true})
	w := s.win
	testing.expect(t, platform.clipboard_set_html(w, "<b>x</b>", "x", "https://a.example/"), "html and its text")
	html, url, ok := platform.clipboard_get_html(w, context.temp_allocator)
	testing.expect(t, ok, "html")
	testing.expect_value(t, html, "<b>x</b>")
	testing.expect_value(t, url, "https://a.example/")
	testing.expect_value(t, platform.get_clipboard(w, context.temp_allocator), "x")
	testing.expect(t, platform.clipboard_formats() >= {.Text, .Html}, "both are said to be there")
	paths := []string{"C:/a.txt", "C:/b.txt"}
	testing.expect(t, platform.clipboard_set_files(w, paths), "files")
	got, has := platform.clipboard_get_files(w, context.temp_allocator)
	testing.expect(t, has && len(got) == 2 && got[1] == "C:/b.txt", "come back")
	testing.expect_value(t, platform.get_clipboard(w, context.temp_allocator), "")
	before := platform.clipboard_sequence()
	testing.expect(t, platform.clipboard_set(w, {text = "again"}), "text")
	testing.expect(t, platform.clipboard_sequence() != before, "the count moves")
	px := []u8{255, 0, 0, 255, 0, 255, 0, 128}
	testing.expect(t, platform.clipboard_set_image(w, {px, {2, 1}}), "an image")
	img, iok := platform.clipboard_get_image(w, context.temp_allocator)
	testing.expect(t, iok && img.size == {2, 1} && img.rgba[4] == 0 && img.rgba[5] == 255 && img.rgba[7] == 128, "comes back whole")
}

// A cut comes back with its files (a file manager's paste moves them); a plain set of files is a copy.
@(test)
files_cut_on_the_process_s_clipboard :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true})
	w := s.win
	paths := []string{"C:/a.txt", "C:/b c.txt"}
	testing.expect(t, platform.clipboard_set(w, {files = paths, files_cut = true}), "cut")
	got, has := platform.clipboard_get_files(w, context.temp_allocator)
	testing.expect(t, has && len(got) == 2 && got[1] == "C:/b c.txt", "the files come back")
	testing.expect(t, platform.clipboard_files_cut(w), "said cut")
	testing.expect(t, platform.clipboard_set_files(w, paths), "copied")
	testing.expect(t, !platform.clipboard_files_cut(w), "said copied")
	testing.expect(t, platform.clipboard_set(w, {text = "x", files_cut = true}), "text alone")
	testing.expect(t, !platform.clipboard_files_cut(w), "no files, no cut")
}
