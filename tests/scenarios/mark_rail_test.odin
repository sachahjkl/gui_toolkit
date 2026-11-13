package scenarios_test

// A rail of marks beside a view (ui/mark_rail.odin): each mark where its item is, a press on one puts the item at the
// view's top at once (no glide, with smooth scrolling on), the keyboard goes from mark to mark, the filter keeps the
// marks that say what is typed. The places come from a lazy column (its `y` before each item).

import "core:fmt"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") RAIL_VIEW_H :: 200
@(private = "file") RAIL_ROW_H :: 30
@(private = "file") RAIL_ROWS :: 60
@(private = "file") RAIL_EVERY :: 10          // a mark every this many rows
@(private = "file") RAIL_MARGIN :: 8
@(private = "file") RAIL_NAMES := [?]string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta"}

@(private = "file")
Rail_Run :: struct {
	rail:   ui.Mark_Rail,
	jumped: int,   // the last mark the rail said it jumped to (-1: none)
}

@(private = "file")
rail_build :: proc(s: ^session.Session) {
	run := (^Rail_Run)(s.user)
	if ui.mark_rail_stale(&run.rail, 1) {
		marks: [len(RAIL_NAMES)]ui.Rail_Mark
		for name, i in RAIL_NAMES { marks[i] = {id = fmt.tprintf("row%d", i * RAIL_EVERY), text = fmt.tprintf("%s\nmore of it", name)} }
		ui.mark_rail_set(&run.rail, 1, marks[:])
	}
	ui.next({width = ui.px(400), height = ui.px(RAIL_VIEW_H), axis = .X})
	if ui.row(id = "###lane") {
		// (the rail first, floating at the right: a jump is in place when the view is built)
		ui.next({fixed_x = 300, fixed_y = 0, width = ui.px(24), height = ui.px(RAIL_VIEW_H)})
		if i := ui.mark_rail("###rail", &run.rail, ui.prev_box("###view"), {name = "Rows", margin = RAIL_MARGIN}); i >= 0 { run.jumped = i }
		ui.next({width = ui.px(300), height = ui.px(RAIL_VIEW_H)})
		if ui.scroll_y("###view") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###col") {
				lz := ui.lazy_begin()
				for i in 0 ..< RAIL_ROWS {
					if i % RAIL_EVERY == 0 { ui.mark_rail_place(&run.rail, i / RAIL_EVERY, lz.y) }
					if ui.lazy_item(lz, fmt.tprintf("###row%d", i)) {
						ui.next({width = ui.fill(), height = ui.px(RAIL_ROW_H)})
						ui.label(fmt.tprintf("Row %d###label", i))
					}
				}
			}
		}
	}
}

@(private = "file")
rail_start :: proc(t: ^testing.T, run: ^Rail_Run) -> ^session.Session {
	run.jumped = -1
	s := session.start(t, {user = run, build = rail_build, no_renderer = true, smooth_scroll = .On, animations = true})
	session.frames(s, 2)
	return s
}

// The marks stand where their rows are in the content, top to bottom; a press on one puts its row at the view's top, the
// margin above it, in the same frame: no glide.
@(test)
a_press_on_a_mark_jumps_there_at_once :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Rail_Run
	defer ui.mark_rail_destroy(&run.rail)
	s := rail_start(t, &run)
	view := session.get(s, "view")
	last: f32 = -1
	for i in 0 ..< len(RAIL_NAMES) {
		at, ok := ui.mark_rail_dot(&run.rail, view, i)
		if !testing.expectf(t, ok, "mark %d has a place", i) { return }
		testing.expectf(t, at.y > last, "mark %d below the one before it: %v", i, at.y)
		last = at.y
	}
	at, _ := ui.mark_rail_dot(&run.rail, view, 3)
	session.click_at(s, at)
	testing.expect_value(t, run.jumped, 3)
	want := f32(3 * RAIL_EVERY * RAIL_ROW_H - RAIL_MARGIN)
	testing.expect_value(t, view.view_off.y, want)
	testing.expect_value(t, view.view_target.y, want)
	testing.expect(t, !view.view_anim[1].active, "no glide")
	row := session.get(s, "row30")
	testing.expect_value(t, row.rect.min.y - view.rect.min.y, f32(RAIL_MARGIN))
}) }

// The wheel over the rail scrolls the view (it glides, as over the view).
@(test)
the_wheel_over_the_rail_scrolls_the_view :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Rail_Run
	defer ui.mark_rail_destroy(&run.rail)
	s := rail_start(t, &run)
	view := session.get(s, "view")
	session.wheel(s, session.center(session.get(s, "rail")), {0, 3})
	testing.expect(t, view.view_target.y > 0, "the view heads down")
	testing.expect_value(t, run.jumped, -1)
}) }

// The pointer over a mark shows its first line beside the rail.
@(test)
a_mark_under_the_pointer_shows_its_first_line :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Rail_Run
	defer ui.mark_rail_destroy(&run.rail)
	s := rail_start(t, &run)
	at, _ := ui.mark_rail_dot(&run.rail, session.get(s, "view"), 2)
	session.move(s, at)
	session.frames(s, 2)
	tip := session.find(s, "tooltip")
	if !testing.expect(t, tip != nil, "a tooltip") { return }
	testing.expect(t, session.find_text(s, "gamma") != nil, "the mark's first line")
	testing.expect(t, session.find_text(s, "more of it") == nil, "only the first line")
}) }

// Up and Down go from mark to mark, Enter jumps.
@(test)
the_keyboard_goes_from_mark_to_mark :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Rail_Run
	defer ui.mark_rail_destroy(&run.rail)
	s := rail_start(t, &run)
	view := session.get(s, "view")
	at, _ := ui.mark_rail_dot(&run.rail, view, 1)
	session.click_at(s, at)
	testing.expect_value(t, session.focused_name(s), "rail")
	session.key(s, .Down)
	session.key(s, .Down)
	testing.expect_value(t, run.rail.current, 3)
	testing.expect_value(t, view.view_off.y, f32(1 * RAIL_EVERY * RAIL_ROW_H - RAIL_MARGIN))   // (a step is no jump)
	session.key(s, .Return)
	testing.expect_value(t, run.jumped, 3)
	testing.expect_value(t, view.view_off.y, f32(3 * RAIL_EVERY * RAIL_ROW_H - RAIL_MARGIN))
	session.key(s, .Home)
	testing.expect_value(t, run.rail.current, 0)
	session.key(s, .Up)
	testing.expect_value(t, run.rail.current, 0)   // (the first stays)
}) }

// A word typed on the rail opens its filter: only the marks that hold it are shown, the keyboard goes among them, Enter
// jumps, Escape gives them all back.
@(test)
the_filter_keeps_the_marks_that_say_what_is_typed :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Rail_Run
	defer ui.mark_rail_destroy(&run.rail)
	s := rail_start(t, &run)
	view := session.get(s, "view")
	testing.expect_value(t, len(ui.mark_rail_shown(&run.rail)), len(RAIL_NAMES))
	at, _ := ui.mark_rail_dot(&run.rail, view, 0)
	session.click_at(s, at)
	session.type_text(s, "et")   // beta, zeta (and not the others)
	session.frames(s, 1)
	testing.expect_value(t, ui.mark_rail_query(&run.rail), "et")
	shown := ui.mark_rail_shown(&run.rail)
	if !testing.expect_value(t, len(shown), 2) { return }
	testing.expect(t, shown[0] == 1 && shown[1] == 5, "beta and zeta")
	_, hidden := ui.mark_rail_dot(&run.rail, view, 2)
	testing.expect(t, !hidden, "gamma is not shown")
	session.key(s, .Down)
	testing.expect_value(t, run.rail.current, 5)
	session.key(s, .Return)
	testing.expect_value(t, run.jumped, 5)
	testing.expect_value(t, view.view_off.y, f32(5 * RAIL_EVERY * RAIL_ROW_H - RAIL_MARGIN))
	session.key(s, .Escape)
	testing.expect_value(t, ui.mark_rail_query(&run.rail), "")
	testing.expect_value(t, len(ui.mark_rail_shown(&run.rail)), len(RAIL_NAMES))
	testing.expect(t, !run.rail.filtering, "the field closed")
}) }

// New marks (a version of the program's) are taken; the old ones' texts are let go (the test's allocator says so).
@(test)
a_new_version_replaces_the_marks :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: ui.Mark_Rail
	defer ui.mark_rail_destroy(&r)
	testing.expect(t, ui.mark_rail_stale(&r, 0), "a rail never given marks is stale")
	ui.mark_rail_set(&r, 7, {{id = "a", text = "one"}, {id = "b", text = "  \n two \n three"}})
	testing.expect(t, !ui.mark_rail_stale(&r, 7), "the version given")
	testing.expect(t, ui.mark_rail_stale(&r, 8), "another one")
	testing.expect_value(t, ui.mark_rail_id(&r, 1), "b")
	testing.expect_value(t, ui.mark_rail_id(&r, 2), "")
	ui.mark_rail_set(&r, 8, {{id = "c", text = "x", weak = true}})
	testing.expect_value(t, len(ui.mark_rail_shown(&r)), 1)
	ui.mark_rail_place(&r, 4, 10)   // (out of range: passed over)
}) }
