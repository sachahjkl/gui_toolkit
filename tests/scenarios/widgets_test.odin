package scenarios_test

// Widgets no other package reaches, each by what it is for: the colour pickers, toasts, popovers, Tab stops turned off, muted scopes, density, rounding,
// a virtual list scrolled by the program (and one of 100 000 rows that changes nothing, not walked), a menu's heading, posted calls by the window, selection cleared.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"
import syntax "../../src/syntax"

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
@(private = "file") LONG_LIST_ROWS :: 100_000

// A press on the saturation and value square gives the colour under it: right is more saturated, up is brighter. The hue strip goes from top to bottom.
@(test)
the_colour_pickers_take_a_press :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { hue, sat, val: f32, changed: int }
	r := Run{hue = 0.5, sat = 0.5, val = 0.5}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(PICKER_SIZE), height = ui.px(PICKER_SIZE)})
		if ui.sat_val_picker("###sv", r.hue, &r.sat, &r.val) { r.changed += 1 }
		ui.next({width = ui.px(HUE_WIDTH), height = ui.px(PICKER_SIZE)})
		if ui.hue_picker("###hue", &r.hue, .Y) { r.changed += 1 }
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
}) }

// A toast comes, in its place, says what it was given, and goes by the clock.
@(test)
a_toast_goes_by_the_clock :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { say, clear: bool }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.say {
			ui.announce(&ui.Announcer{mode = .Window}, .Good, fmt.tprintf("Saved %d files", 3))
			r.say = false
		}
		if r.clear { ui.toasts_clear() }
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
}) }

// A toast that says what can be done does it when clicked, once, and goes.
@(test)
a_toast_with_an_action_does_it_when_clicked :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { say: bool, done: int }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.say {
			ui.announce(&ui.Announcer{mode = .Off}, .Good, "Version 2: click to install", action = proc(user: rawptr) { (^Run)(user).done += 1 }, user = r)
			r.say = false
		}
	}})
	r.say = true
	session.frames(s, 2)
	b := session.wait_text(s, "Version 2: click to install")
	session.click_at(s, session.center(b))
	session.wait_idle(s)
	testing.expect_value(t, r.done, 1)
	testing.expect(t, session.find_text(s, "Version 2: click to install") == nil, "gone")
}) }

// A popover stays open while the app builds it, by its anchor.
@(test)
a_popover_stands_by_its_anchor :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
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
}) }

// What is built under tab_stops(false) can be clicked, and Tab goes over it.
@(test)
tab_stops_can_be_turned_off :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(100)})
		ui.button("a", "A")
		if ui.tab_stops(false) {
			ui.next({width = ui.px(100)})
			ui.button("b", "B")
		}
		ui.next({width = ui.px(100)})
		ui.button("c", "C")
	}})
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "a")
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "c")
	testing.expect_value(t, ui.tab_direction(s.state), 0)   // (only in the build right after the move)
	session.click(s, "b")
	testing.expect_value(t, session.focused_name(s), "b")
}) }

// Density and the corners: what the settings of an application change.
@(test)
density_and_rounding_change_what_is_drawn :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
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
}) }

// A virtual list: only what is in view is built; the program can take it elsewhere.
@(test)
a_virtual_list_is_scrolled_by_the_program :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
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
}) }

// A virtual list of 100 000 rows: a build that changes nothing does no pass over the rows (its offsets are not made
// again); new ids, by their content or by the program's version of them, make them again once.
@(test)
an_unchanged_long_list_is_not_walked :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { st: ui.Virtual_List, ids: []u64, version: u64 }
	r := new(Run)
	r.ids = make([]u64, LONG_LIST_ROWS)
	defer { ui.vlist_destroy(&r.st); delete(r.ids); free(r) }
	for i in 0 ..< LONG_LIST_ROWS { r.ids[i] = u64(i + 1) }
	s := session.start(t, {size = WINDOW, user = r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.fill()})
		if rows, ok := ui.vlist("###list", &r.st, r.ids, ids_version = r.version); ok {
			for i in rows.first ..< rows.last {
				ui.next({height = ui.px(LIST_ROW_HEIGHT)})
				ui.list_row(&r.st.list, i, "")
			}
		}
	}})
	// (the first builds measure the rows in view: their heights make the offsets again)
	session.frames(s, 4)
	made := r.st.offsets_made
	session.frames(s, 5)
	testing.expect_value(t, r.st.offsets_made, made)
	_, height := ui.vlist_row_extent(&r.st, 0)
	testing.expect_value(t, height, LIST_ROW_HEIGHT)
	// the ids compared: one changed, the offsets once more
	r.ids[LONG_LIST_ROWS - 1] = 0
	session.frames(s, 3)
	testing.expect_value(t, r.st.offsets_made, made + 1)
	// the program's version: the ids are not compared, a new version makes the offsets again
	r.version = 1
	session.frames(s, 3)
	testing.expect_value(t, r.st.offsets_made, made + 2)
	session.frames(s, 3)
	testing.expect_value(t, r.st.offsets_made, made + 2)
}) }

// A dialog open over a list that has the keyboard holds its keys: Enter is the dialog's, the row behind is not opened.
@(test)
a_dialog_holds_the_keys_of_the_list_behind :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { st: ui.Virtual_List, ids: [LIST_ROWS]u64, labels: [LIST_ROWS]string, asking, activated, moved: bool }
	r := new(Run)
	defer { ui.vlist_destroy(&r.st); free(r) }
	for i in 0 ..< LIST_ROWS { r.ids[i], r.labels[i] = u64(i + 1), "A row" }
	s := session.start(t, {size = WINDOW, user = r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.fill()})
		if rows, ok := ui.vlist("###list", &r.st, r.ids[:], r.labels[:]); ok {
			// (the list keeps the keyboard under the dialog: a dialog that takes no focus, a recorder of keys)
			if s.frames == 1 || r.asking { ui.set_focus(r.st.key) }
			for i in rows.first ..< rows.last {
				ui.next({height = ui.px(LIST_ROW_HEIGHT)})
				ui.list_row(&r.st.list, i, r.labels[i])
			}
			if r.st.list.activated { r.activated = true }
		}
		if ui.confirm("ask", &r.asking, {title = "Delete it?", act = "Delete"}) != .None { r.asking = false }
	}})
	session.frames(s, 2)
	session.key(s, .Down)
	testing.expect(t, r.st.list.sel >= 0, "the list has the keys")
	sel := r.st.list.sel
	r.asking = true
	session.frames(s, 2)
	session.key(s, .Down)
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect(t, !r.activated, "Enter answered the dialog, not the row")
	testing.expect_value(t, r.st.list.sel, sel)
	testing.expect(t, !r.asking, "the dialog answered")
}) }

// A list with no type-ahead leaves the letters typed for the program: its filter takes them though the list has the keyboard.
@(test)
a_list_with_no_typeahead_leaves_the_letters :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { st: ui.Virtual_List, ids: [LIST_ROWS]u64, labels: [LIST_ROWS]string, filter: ui.Line_Edit, field: ui.Key }
	r := new(Run)
	defer { ui.vlist_destroy(&r.st); ui.line_edit_destroy(&r.filter); free(r) }
	for i in 0 ..< LIST_ROWS { r.ids[i], r.labels[i] = u64(i + 1), "A row" }
	r.st.list.no_typeahead = true
	s := session.start(t, {size = WINDOW, user = r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.px(200)})
		if rows, ok := ui.vlist("###list", &r.st, r.ids[:], r.labels[:]); ok {
			if s.frames == 1 { ui.set_focus(r.st.key) }
			for i in rows.first ..< rows.last {
				ui.next({height = ui.px(LIST_ROW_HEIGHT)})
				ui.list_row(&r.st.list, i, r.labels[i])
			}
		}
		ui.type_to_field(r.field)
		res := ui.line_edit("###filter", &r.filter)
		r.field = res.box != nil ? res.box.key : 0
	}})
	session.frames(s, 2)
	session.type_text(s, "ro")
	session.frames(s, 2)
	testing.expect_value(t, ui.line_edit_string(&r.filter), "ro")
}) }

// Text selected outside a field, then taken away by the program.
@(test)
a_selection_is_cleared_by_the_program :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
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
}) }

// Text selected in a dialog is copied: Ctrl+C and Ctrl+Insert, which the selection reads outside the dialog's build, are its
// while the dialog on top holds it. Text selected behind a dialog is not: the dialog holds the keys.
@(test)
text_selected_in_a_dialog_is_copied :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { open, behind: bool }
	r := Run{open = true}
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), flags = {.Selectable}})
		ui.label("Words behind it###behind")
		if r.behind { return }
		if ui.modal("dialog", &r.open, {width_em = 400 / ui.font_size()}) {
			ui.next({width = ui.fill(), flags = {.Selectable}})
			ui.label("/home/sacha/.local/bin/a-path###path")
		}
	}})
	session.frames(s, 3)
	b := session.get(s, "path")
	session.drag(s, {b.rect.min.x + 1, session.center(b).y}, {b.rect.max.x - 1, session.center(b).y})
	testing.expect(t, ui.has_selection(s.state), "selected in the dialog")
	want := ui.selected_text(s.state, context.temp_allocator)
	testing.expect(t, len(want) > 0, "it has text")
	session.key(s, .C, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), want)
	session.set_clipboard(s, "")
	session.key(s, .Insert, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), want)
	// behind a dialog: the selection is not the keys'
	ui.clear_selection(s.state)
	r.behind = true
	session.frames(s, 2)
	w := session.get(s, "behind")
	session.drag(s, {w.rect.min.x + 1, session.center(w).y}, {w.rect.max.x - 1, session.center(w).y})
	testing.expect(t, ui.has_selection(s.state), "selected behind")
	r.behind = false
	session.frames(s, 2)
	session.set_clipboard(s, "")
	session.key(s, .C, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), "")
}) }

// What is in front at the pointer has it: a panel a later one covers is not under the pointer where it is covered, the one
// in front is, and so is what is in a panel (its text) and what is around it where nothing else covers it.
@(test)
the_pointer_is_on_what_is_in_front :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { back, front, label, around: bool }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(400), height = ui.px(300)})
		around := ui.build_box({}, "###around")
		if ui.parent(around) {
			ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(200), height = ui.px(200)})
			back := ui.build_box({.Draw_Background}, "###back")
			if ui.parent(back) {
				ui.next({width = ui.px(150), height = ui.px(30)})
				label := ui.build_box({.Draw_Text}, "Words###label")
				r.label = ui.pointer_on(label)
			}
			ui.next({fixed_x = 120, fixed_y = 20, width = ui.px(200), height = ui.px(200)})
			front := ui.build_box({.Draw_Background}, "###front")
			r.back, r.front = ui.pointer_on(back), ui.pointer_on(front)
		}
		r.around = ui.pointer_on(around)
	}})
	at :: proc(s: ^session.Session, p: [2]f32) { session.move(s, p); session.frames(s, 2) }
	at(s, {60, 30})    // (on the back panel's text, nothing over it)
	testing.expect(t, r.back && !r.front && r.label && r.around, "the back panel and its text")
	at(s, {150, 100})  // (where the front panel covers the back one)
	testing.expect(t, !r.back && r.front && r.around, "the front panel, not the one it covers")
	at(s, {300, 100})  // (the front panel alone)
	testing.expect(t, !r.back && r.front, "the front panel")
	at(s, {380, 280})  // (neither: only what is around them)
	testing.expect(t, !r.back && !r.front && r.around, "what is around them")
}) }

// A text area that scrolls itself has the toolkit's scroll bar: its thumb at rest is the one of a view that scrolls, in the
// interface's greys in the machined finish (it had a look of its own, a tint of the text).
@(test)
a_text_area_has_the_toolkit_s_scroll_bar :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { area: ui.Text_Edit, view: ui.Rect }
	r: Run
	ui.text_edit_set(&r.area, strings.repeat("a line of the text area\n", 60, context.temp_allocator))
	defer ui.text_edit_destroy(&r.area)
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row() {
			ui.next({width = ui.pct(0.5), height = ui.fill()})
			if ui.scroll_y("###view") {
				r.view = ui.parent_box().rect
				for i in 0 ..< 60 { ui.label(fmt.tprintf("row %d###r%d", i, i)) }
			}
			ui.next({width = ui.pct(0.5), height = ui.fill()})
			ui.text_edit("###area", &r.area)
		}
	}})
	// (the machined finish, a program's: its thumbs in the interface's greys; flat, both are a tint of the text)
	if s.state.theme != nil { s.state.theme.finish = .Machined }
	session.frames(s, 3)
	img := session.capture(s)
	view := session.get(s, "view")
	_, thumb, ok := ui.scrollbar_rects(view)
	if !testing.expect(t, ok, "the view scrolls") { return }
	want := session.pixel(img, int((thumb.min.x + thumb.max.x) * 0.5), int((thumb.min.y + thumb.max.y) * 0.5))
	area := session.get(s, "area")
	found := false
	for x in int(area.rect.max.x) - 16 ..< int(area.rect.max.x) {
		for y in int(area.rect.min.y) ..< int(area.rect.min.y) + 40 {
			if session.near(session.pixel(img, x, y), want, 2) { found = true }
		}
	}
	testing.expectf(t, found, "the area's thumb is the view's: %v", want)
}) }

// A lazy column whose view jumps far in one build (a conversation just read, put at its bottom at once) builds the items that the
// view shows in that very build: it placed them from the last layout's rect and the new offset together, off by the jump, and
// the view showed only spaces for a frame.
@(test)
a_lazy_column_builds_where_its_view_jumped :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { jump: bool, last_seen: bool }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###view") {
			sb := ui.parent_box()
			if r.jump { ui.view_jump(sb, ui.view_limit(sb)); r.jump = false }
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				lz := ui.lazy_begin()
				r.last_seen = false
				for i in 0 ..< 400 {
					if ui.lazy_item(lz, fmt.tprintf("###it%d", i)) {
						ui.next({height = ui.px(f32(20 + (i % 7) * 13))})
						ui.label(fmt.tprintf("item %d", i))
						if i == 399 { r.last_seen = true }
					}
				}
			}
		}
	}})
	session.frames(s, 3)
	testing.expect(t, !r.last_seen, "at the top: the last item is not built")
	r.jump = true
	session.frames(s, 1)
	testing.expect(t, r.last_seen, "the build that jumped to the bottom built the last item")
}) }

// A menu's heading is no item: the keyboard goes over it.
@(test)
a_menu_heading_is_not_an_item :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { chosen: string }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		key := "menu"
		if s.frames == 1 { ui.menu_open(key, ui.Vec2{50, 50}, from_keyboard = true) }
		if ui.menu(key) {
			ui.menu_heading("Section")
			if ui.menu_item("First").clicked { r.chosen = "first" }
			if ui.menu_item("Second").clicked { r.chosen = "second" }
		}
	}})
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Section") != nil, "the heading shows")
	session.key(s, .Return)
	testing.expect_value(t, r.chosen, "first")
}) }

// A menu that searches: typed letters keep the items that have them in order (a submenu's items come up), the first
// match is selected; Backspace takes a letter back; Enter chooses it.
@(test)
a_menu_that_searches :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { chosen: string }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		key := "menu"
		if s.frames == 1 { ui.menu_open(key, ui.Vec2{50, 50}) }
		if ui.menu(key) {
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
	testing.expect(t, session.find(s, "menu_search") != nil && session.find(s, "menu_caret") != nil, "a field, its caret")
	session.type_text(s, "dmx")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "dmx") != nil && session.find_text(s, "Type to search") == nil, "the field shows what is typed")
	testing.expect(t, session.find_text(s, "Open") == nil, "no match: nothing")
	session.key(s, .Backspace)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Date modified") != nil, "the submenu's item came up")
	testing.expect(t, session.find_text(s, "Rename") == nil, "the others went")
	session.key(s, .Return)
	testing.expect_value(t, r.chosen, "date")
}) }

// A menu's search is a field: Ctrl+A and Backspace empty it, Ctrl+Backspace takes a word back, the caret moves. While
// it filters the menu keeps its corner and its width (it ran from under the pointer, narrower at each letter).
@(test)
a_menu_s_search_edits_as_a_field :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { chosen: string }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		key := "menu"
		if s.frames == 1 { ui.menu_open(key, ui.Vec2{50, 50}) }
		if ui.menu(key) {
			if ui.menu_item("Open").clicked { r.chosen = "open" }
			if ui.menu_item("Rename the selected files").clicked { r.chosen = "rename" }
			if ui.menu_item("Copy path").clicked { r.chosen = "copy" }
		}
	}})
	session.frames(s, 3)
	panel :: proc(s: ^session.Session) -> ui.Rect {
		b := session.find(s, fmt.tprintf("menu_%d", u64(ui.key_from_string(0, "menu"))))
		return b != nil ? b.rect : {}
	}
	before := panel(s)
	testing.expect(t, before.max.x > before.min.x, "the menu")
	session.type_text(s, "copy pa")
	session.frames(s, 2)
	after := panel(s)
	testing.expectf(t, after.min == before.min, "its corner kept (%v, was %v)", after.min, before.min)
	testing.expectf(t, after.max.x - after.min.x == before.max.x - before.min.x, "its width kept (%v, was %v)", after, before)
	testing.expect(t, session.find_text(s, "Open") == nil, "filtered")
	session.key(s, .Backspace, {.Ctrl})
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "copy ") != nil, "Ctrl+Backspace: a word back")
	session.key(s, .A, {.Ctrl})
	session.key(s, .Backspace)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Type to search") != nil && session.find_text(s, "Open") != nil, "Ctrl+A, Backspace: empty, all the items")
	session.type_text(s, "opn")
	session.key(s, .Left)
	session.type_text(s, "e")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "open") != nil, "the caret moved: a letter typed in the middle")
	session.key(s, .Return)
	testing.expect_value(t, r.chosen, "open")
}) }

// A field in a panel opened as a menu (a vault's search): a click gives it the focus, what is typed goes into it, and the
// menu stays open.
@(test)
a_field_in_a_menu_takes_the_click_and_the_keys :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { field: ui.Line_Edit }
	r: Run
	defer ui.line_edit_destroy(&r.field)
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		key := "panel"
		if s.frames == 1 { ui.menu_open(key, ui.Rect{{40, 20}, {80, 40}}, search = false) }
		if ui.menu(key) {
			ui.next({width = ui.px(200), height = ui.px(30)})
			_ = ui.line_edit("###panel_search", &r.field, {placeholder = "Search"})
			if ui.menu_item("Item").clicked {}
		}
	}})
	session.frames(s, 3)
	session.click(s, "panel_search")
	session.frames(s, 2)
	session.type_text(s, "abc")
	session.frames(s, 2)
	testing.expect_value(t, ui.line_edit_string(&r.field), "abc")
	testing.expect(t, ui.menu_any_open(), "the menu stays open")
}) }

// A menu opened against the window's right edge (a burger menu) shows in its place from its first visible frame: its
// rows learn their width a frame late, and it showed past the edge, then jumped back.
@(test)
a_menu_at_the_right_edge_shows_in_its_place :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {800, 600}, no_renderer = true, build = proc(s: ^session.Session) {
		key := "burger"
		if s.frames == 2 { ui.menu_open(key, ui.Rect{{760, 10}, {790, 40}}, search = false) }
		if ui.menu(key) {
			_ = ui.menu_item("New tab", "Ctrl+T")
			_ = ui.menu_item("New window with a long name", "Ctrl+N")
			_ = ui.menu_item("Settings")
		}
	}})
	shown: ui.Rect
	seen := false
	for i in 0 ..< 6 {
		session.frame(s)
		b := session.find(s, fmt.tprintf("menu_%d", u64(ui.key_from_string(0, "burger"))))
		if b == nil || b.transparency >= 1 { continue }
		testing.expectf(t, b.rect.max.x <= 800, "frame %d: inside the window (%v)", i, b.rect)
		if seen { testing.expectf(t, b.rect == shown, "frame %d: where it first showed (%v, then %v)", i, shown, b.rect) }
		shown, seen = b.rect, true
	}
	testing.expect(t, seen, "the menu shows")
}) }

// A list to choose from in a dialog: the pointer moving over a row selects it, a click chooses it.
@(test)
a_choice_follows_the_pointer :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { sel, chosen: int }
	r := Run{chosen = -1}
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(300), height = ui.children_sum(), axis = .Y})
		if ui.parent(ui.build_box({}, "###list")) {
			for name, i in ([]string{"one", "two", "three"}) {
				if ui.choice_row(fmt.tprintf("choice_%d", i), i, &r.sel, name, "detail") { r.chosen = i }
			}
		}
	}})
	session.frames(s, 2)
	testing.expect_value(t, r.sel, 0)
	session.hover(s, "choice_2")
	session.frames(s, 2)
	testing.expect_value(t, r.sel, 2)
	session.click(s, "choice_1")
	session.frames(s, 1)
	testing.expect_value(t, r.chosen, 1)
	testing.expect_value(t, r.sel, 1)
}) }

// A confirmation: Enter cancels an act that is not safe, the act's button acts; what it acts on is named, the rest counted.
@(test)
a_confirmation_answers :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { open, safe: bool, answer: ui.Confirm_Answer, answers: int }
	r := Run{open = true}
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		lines := []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"}
		if a := ui.confirm("ask", &r.open, {title = "Delete 10 items for good?", note = "They do not go to the trash.", lines = lines, act = "Delete", enter_confirms = r.safe}); a != .None {
			r.answer = a
			r.answers += 1
		}
	}})
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Cancel (Enter)") != nil, "Enter cancels: it says so")
	testing.expect(t, session.find(s, "confirm_line_7") != nil && session.find(s, "confirm_line_8") == nil, "eight named")
	testing.expect(t, session.find_text(s, "and 2 more") != nil, "the others counted")
	session.key(s, .Return)
	session.frames(s, 1)
	testing.expect_value(t, r.answer, ui.Confirm_Answer.Cancelled)
	testing.expect(t, !r.open, "closed")
	r.open, r.safe = true, true
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Delete (Enter)") != nil, "a safe act: Enter acts")
	session.click(s, "confirm_act")
	session.frames(s, 1)
	testing.expect_value(t, r.answer, ui.Confirm_Answer.Confirmed)
	r.open = true
	session.frames(s, 2)
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect_value(t, r.answer, ui.Confirm_Answer.Cancelled)
	testing.expect_value(t, r.answers, 3)
}) }

// An empty state: its title, its note, a button for each action; a click answers its index.
@(test)
an_empty_state_offers_its_actions :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { clicked: int }
	r := Run{clicked = -1}
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if a := ui.empty_state("empty", {icon = "x", title = "No row matches", note = "The filter hides every row.", actions = {{text = "Clear the filter"}, {text = "Show hidden files"}}}); a >= 0 { r.clicked = a }
	}})
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "No row matches") != nil && session.find_text(s, "The filter hides every row.") != nil, "its title and note")
	title := session.find(s, "empty_title")
	if title != nil { testing.expectf(t, title.rect.min.y > f32(WINDOW.y) * 0.2, "in the middle, not at the top (%v)", title.rect) }
	if icon := session.find(s, "empty_icon"); icon != nil { testing.expectf(t, icon.font_size > ui.font_size() * 2, "its icon large (%v)", icon.font_size) } else { testing.expect(t, false, "its icon") }
	session.click(s, "empty_action1")
	testing.expect_value(t, r.clicked, 1)
}) }

// key_take: the frame's first key press not taken yet, with its modifiers; a key a build took already is not given.
@(test)
the_first_key_not_taken_is_given :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { key: platform.Key, mods: platform.Modifiers, ok: bool, enter_taken: bool }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if ui.key_press(.Return) { r.enter_taken = true }
		if hk, ok := ui.key_take(); ok { r.key, r.mods, r.ok = hk.key, hk.mods, true }
	}})
	session.frame(s)
	session.key(s, .K, {.Ctrl, .Shift})
	testing.expect(t, r.ok)
	testing.expect_value(t, r.key, platform.Key.K)
	testing.expect_value(t, r.mods, platform.Modifiers{.Ctrl, .Shift})
	r = {}
	session.key(s, .Return)
	testing.expect(t, r.enter_taken && !r.ok, "taken by the build before: not given")
}) }

// A call posted to a window runs in that window's next build, on its thread.
@(test)
a_call_posted_to_a_window_runs_in_its_next_build :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
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
}) }

// A window's state on the virtual screen: what the system would do for a real one.
@(test)
an_offscreen_window_has_the_state_of_a_window :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
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
}) }

// Every flavour of the process's clipboard, and nothing of the machine's.
@(test)
the_process_s_clipboard_keeps_every_flavour :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
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
	testing.expect(t, platform.clipboard_set_image(w, {rgba = px, size = {2, 1}}), "an image")
	img, iok := platform.clipboard_get_image(w, context.temp_allocator)
	testing.expect(t, iok && img.size == {2, 1} && img.rgba[4] == 0 && img.rgba[5] == 255 && img.rgba[7] == 128, "comes back whole")
}) }

// A cut comes back with its files (a file manager's paste moves them); a plain set of files is a copy.
@(test)
files_cut_on_the_process_s_clipboard :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
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
}) }

// An image asked for comes as its owner holds it, still encoded, and decodes off the interface's thread to its pixels.
@(test)
a_clipboard_image_comes_encoded :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true})
	w := s.win
	_ = platform.poll_events(w, false)   // (what the start queued)
	px := []u8{255, 0, 0, 255, 0, 0, 255, 128}
	testing.expect(t, platform.clipboard_set_image(w, {rgba = px, size = {2, 1}}), "an image")
	asked := platform.clipboard_request(w, .Image)
	answers := 0
	for e in platform.poll_events(w, false) {
		if e.kind != .Clipboard_Data { continue }
		answers += 1
		r := e.clipboard
		testing.expect(t, r.id == asked && r.ok && r.format == .Image, "the image")
		testing.expect_value(t, r.mime, "image/png")
		img, ok := platform.clipboard_image_decode(r.mime, r.data, context.temp_allocator)
		testing.expect(t, ok && img.size == {2, 1} && slice.equal(img.rgba, px), "its pixels")
	}
	testing.expect_value(t, answers, 1)
}) }

// A read of the clipboard asked for returns at once: nothing is answered in the call, each request gets one answer at the
// next poll_events, by its id, and none comes after. A reply injected (another program's clipboard, played) comes whole.
@(test)
a_clipboard_request_is_answered_at_the_next_poll :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true})
	w := s.win
	_ = platform.poll_events(w, false)   // (what the start queued)
	paths := []string{"C:/a.txt", "C:/b c.txt"}
	testing.expect(t, platform.clipboard_set(w, {files = paths, files_cut = true, text = "two files"}), "cut")
	files := platform.clipboard_request(w, .Files)
	text := platform.clipboard_request(w, .Text)
	image := platform.clipboard_request(w, .Image)
	testing.expect(t, files != 0 && text != 0 && image != 0 && files != text && text != image, "each request has its id")
	testing.expect(t, platform.events_waiting(w), "the answers wait for the next poll")
	answers := 0
	for e in platform.poll_events(w, false) {
		if e.kind != .Clipboard_Data { continue }
		answers += 1
		r := e.clipboard
		if r.id == files {
			testing.expect(t, r.ok && r.format == .Files && len(r.files) == 2 && r.files[1] == "C:/b c.txt" && r.cut, "the files, cut")
		} else if r.id == text {
			testing.expect(t, r.ok && r.format == .Text && r.text == "two files", "the text")
		} else if r.id == image {
			testing.expect(t, !r.ok, "no image on it")
		} else {
			testing.expect(t, false, "an answer no request asked for")
		}
	}
	testing.expect_value(t, answers, 3)
	for e in platform.poll_events(w, false) { testing.expect(t, e.kind != .Clipboard_Data, "answered once") }

	// copied, not cut; and an empty clipboard answers not ok
	testing.expect(t, platform.clipboard_set_files(w, paths), "copied")
	copied := platform.clipboard_request(w, .Files)
	for e in platform.poll_events(w, false) {
		if e.kind == .Clipboard_Data { testing.expect(t, e.clipboard.id == copied && e.clipboard.ok && !e.clipboard.cut, "copied, not cut") }
	}
	testing.expect(t, platform.clipboard_set(w, {}), "emptied")
	none := platform.clipboard_request(w, .Files)
	for e in platform.poll_events(w, false) {
		if e.kind == .Clipboard_Data { testing.expect(t, e.clipboard.id == none && !e.clipboard.ok && len(e.clipboard.files) == 0, "no files") }
	}

	// another program's answer, played: its strings outlive the literals given
	name := strings.clone("/home/x/played.txt", context.temp_allocator)
	platform.inject_event(w, {kind = .Clipboard_Data, clipboard = {id = 99, format = .Files, ok = true, files = {name}}})
	played := false
	for e in platform.poll_events(w, false) {
		if e.kind == .Clipboard_Data && e.clipboard.id == 99 { played = len(e.clipboard.files) == 1 && e.clipboard.files[0] == "/home/x/played.txt" && raw_data(e.clipboard.files[0]) != raw_data(name) }
	}
	testing.expect(t, played, "the injected answer, copied")
}) }

////////////////////////////////
// hotkey_field

@(private = "file") recorded: platform.Hotkey
@(private = "file") recorded_changes: int

@(private = "file")
hotkey_session :: proc(t: ^testing.T) -> ^session.Session {
	recorded, recorded_changes = {key = .V, mods = {.Ctrl}}, 0
	return session.start(t, {size = {400, 200}, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(240)})
		if ui.hotkey_field("###keys", &recorded) { recorded_changes += 1 }
	}})
}

// A click arms the field; the combination pressed is its value; a key named by the character it types is taken too.
@(test)
a_hotkey_field_records_the_keys_pressed :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := hotkey_session(t)
	testing.expect(t, session.find_text(s, "Ctrl+V") != nil, "the value shows")
	session.click(s, "keys")
	testing.expect(t, ui.hotkey_recording(), "armed")
	testing.expect(t, session.find_text(s, "Press the keys…") != nil, "it says so")
	session.key(s, .K)   // (a key alone: no shortcut, it waits)
	testing.expect(t, ui.hotkey_recording())
	session.key(s, .F5, {.Ctrl, .Shift})
	testing.expect_value(t, recorded, platform.Hotkey{key = .F5, mods = {.Ctrl, .Shift}})
	testing.expect_value(t, recorded_changes, 1)
	testing.expect(t, !ui.hotkey_recording(), "done")
	session.click(s, "keys")
	session.event(s, {kind = .Key_Press, char = 'ù', mods = {.Ctrl, .Shift}})
	session.frame(s)
	session.frame(s)
	testing.expect_value(t, recorded, platform.Hotkey{mods = {.Ctrl, .Shift}, char = 'ù'})
	testing.expect(t, session.find_text(s, "Ctrl+Shift+ù") != nil)
}) }

// Super is a shortcut's modifier like the others: Super+S alone is a shortcut, recorded with its Super.
@(test)
a_hotkey_field_records_super :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := hotkey_session(t)
	session.click(s, "keys")
	session.event(s, {kind = .Key_Press, key = .S, super = true})
	session.frame(s)
	session.frame(s)
	testing.expect_value(t, recorded, platform.Hotkey{key = .S, super = true})
	testing.expect(t, !ui.hotkey_recording(), "done")
	testing.expect(t, session.find_text(s, platform.hotkey_text({key = .S, super = true})) != nil, "it shows")
}) }

// Escape gives the recording up: the value stays.
@(test)
escape_gives_a_hotkey_recording_up :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := hotkey_session(t)
	session.click(s, "keys")
	session.key(s, .Escape)
	testing.expect(t, !ui.hotkey_recording())
	testing.expect_value(t, recorded, platform.Hotkey{key = .V, mods = {.Ctrl}})
	testing.expect_value(t, recorded_changes, 0)
}) }

////////////////////////////////
// code_runs

// Code as runs: each class in its theme colour, the plain text between them as it was, the whole text kept.
@(test)
code_takes_the_theme_s_colours :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { runs: [dynamic]ui.Rich_Run, keyword, str: ui.Color }
	r: Run
	defer delete(r.runs)
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		l, _ := syntax.language("odin")
		clear(&r.runs)   // (kept past the frame: the test reads them)
		ui.code_runs(`x := proc() { return "hi" }`, l, {}, &r.runs)
		r.keyword, r.str = ui.color("code_keyword"), ui.color("code_string")
		ui.rich_paragraph("###code", r.runs[:])
	}})
	session.frame(s)
	whole := ""
	for run in r.runs { whole = strings.concatenate({whole, run.text}, context.temp_allocator) }
	testing.expect_value(t, whole, `x := proc() { return "hi" }`)
	found_kw, found_str := false, false
	for run in r.runs {
		if run.text == "proc" { found_kw = run.color == r.keyword }
		if run.text == `"hi"` { found_str = run.color == r.str }
	}
	testing.expect(t, found_kw, "a keyword in code_keyword")
	testing.expect(t, found_str, "a string in code_string")
	testing.expect(t, r.keyword != r.str, "two colours")
}) }

// A dialog holds the keys: code built outside it gets no Escape while it is open; inside, it does.
@(test)
a_dialog_holds_the_keys :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { open: bool, outside, inside: bool }
	r := Run{open = true}
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if ui.key_press(.Escape) { r.outside = true }
		if ui.modal("###keys_dialog", &r.open, {width_em = 300 / ui.font_size()}) {
			if ui.key_pressed_peek(.Escape) { r.inside = true }
			ui.label("A dialog###d")
		}
	}})
	session.frames(s, 2)
	session.key(s, .Escape)
	session.frame(s)
	testing.expect(t, !r.outside, "not the page's")
	testing.expect(t, r.inside, "the dialog's")
	testing.expect(t, !r.open, "Escape closes it")
	session.key(s, .Escape)
	testing.expect(t, r.outside, "closed: the page's again")
}) }

// A dialog closed by its own button gives the keys back at once: the first key after the click is the page's, with no
// frame between them (a dialog of the last build that closed in it holds none).
@(test)
a_dialog_closed_by_a_button_holds_no_key :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { open: bool, outside: bool }
	r := Run{open = true}
	s := session.start(t, {size = WINDOW, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if ui.key_press(.Escape) { r.outside = true }
		if ui.modal("###closed_dialog", &r.open, {width_em = 300 / ui.font_size()}) {
			if ui.button("close", "Close").clicked { r.open = false }
		}
	}})
	session.frames(s, 2)
	// (by hand: the click's release builds the frame that closes it, and the key comes in the very next one)
	at := session.center(session.get(s, "close"))
	session.move(s, at)
	session.event(s, {kind = .Mouse_Press, button = .Left, pos = at})
	session.frame(s)
	session.event(s, {kind = .Mouse_Release, button = .Left, pos = at})
	session.frame(s)
	testing.expect(t, !r.open, "the button closes it")
	session.event(s, {kind = .Key_Press, key = .Escape})
	session.frame(s)
	testing.expect(t, r.outside, "the next key is the page's")
}) }
