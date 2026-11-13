package scenarios_test

// Marks on a view's scroll bar (ui/scroll_marks.odin): each mark where its item is, a press on one puts the item at the
// view's top at once (no glide, with smooth scrolling on), a press on the thumb over a mark drags it, the keyboard goes from
// mark to mark, the filter keeps the marks that say what is typed, marks too close to tell apart are one. The places come
// from a lazy column (its `y` before each item).

import "core:fmt"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") MARKS_VIEW_H :: 200
@(private = "file") MARKS_ROW_H :: 30
@(private = "file") MARKS_ROWS :: 60
@(private = "file") MARKS_MARGIN :: 8
@(private = "file") MARKS_NAMES := [?]string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta"}
@(private = "file") MARKS_ROWS_SPREAD := [?]int{0, 10, 20, 30, 40, 50}   // a mark every 10 rows
@(private = "file") MARKS_ROWS_CLOSE := [?]int{0, 10, 40, 41}            // the last two closer than a mark is tall

@(private = "file")
Marks_Run :: struct {
	marks:  ui.Scroll_Marks,
	rows:   []int,   // the rows marked, one per name
	jumped: int,     // the last mark the bar said it jumped to (-1: none)
}

@(private = "file")
marks_build :: proc(s: ^session.Session) {
	run := (^Marks_Run)(s.user)
	if ui.scroll_marks_stale(&run.marks, 1) {
		given := make([]ui.Scroll_Mark, len(run.rows), context.temp_allocator)
		for row, i in run.rows { given[i] = {id = fmt.tprintf("row%d", row), text = fmt.tprintf("%s\nmore of it\nand so on\nthe end", MARKS_NAMES[i])} }
		ui.scroll_marks_set(&run.marks, 1, given)
	}
	ui.next({width = ui.px(400), height = ui.px(MARKS_VIEW_H), axis = .X})
	if ui.row(id = "###lane") {
		// (before the view: a jump is in place when its content is built)
		if i := ui.scroll_marks("###marks", &run.marks, ui.prev_box("###view"), {name = "Rows", margin = MARKS_MARGIN}); i >= 0 { run.jumped = i }
		ui.next({width = ui.px(300), height = ui.px(MARKS_VIEW_H)})
		if ui.scroll_y("###view") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###col") {
				lz := ui.lazy_begin()
				k := 0
				for i in 0 ..< MARKS_ROWS {
					if k < len(run.rows) && run.rows[k] == i { ui.scroll_marks_place(&run.marks, k, lz.y); k += 1 }
					if ui.lazy_item(lz, fmt.tprintf("###row%d", i)) {
						ui.next({width = ui.fill(), height = ui.px(MARKS_ROW_H)})
						ui.label(fmt.tprintf("Row %d###label", i))
					}
				}
			}
		}
	}
}

@(private = "file")
marks_start :: proc(t: ^testing.T, run: ^Marks_Run, rows: []int = nil, drawn := false) -> ^session.Session {
	run.jumped = -1
	run.rows = rows != nil ? rows : MARKS_ROWS_SPREAD[:]
	s := session.start(t, {user = run, build = marks_build, no_renderer = !drawn, smooth_scroll = .On, animations = true})
	session.frames(s, 2)
	return s
}

// The marks stand on the bar where their rows are in the content, top to bottom; a press on one puts its row at the view's
// top, the margin above it, in the same frame: no glide.
@(test)
a_press_on_a_mark_jumps_there_at_once :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Marks_Run
	defer ui.scroll_marks_destroy(&run.marks)
	s := marks_start(t, &run)
	view := session.get(s, "view")
	track, _, has_bar := ui.scrollbar_rects(view)
	if !testing.expect(t, has_bar, "a bar") { return }
	last: f32 = -1
	for i in 0 ..< len(MARKS_NAMES) {
		at, ok := ui.scroll_marks_at(&run.marks, view, i)
		if !testing.expectf(t, ok, "mark %d has a place", i) { return }
		testing.expectf(t, at.y > last, "mark %d below the one before it: %v", i, at.y)
		testing.expectf(t, at.x > track.min.x && at.x < track.max.x, "mark %d on the bar's track: %v", i, at)
		last = at.y
	}
	at, _ := ui.scroll_marks_at(&run.marks, view, 3)
	session.click_at(s, at)
	testing.expect_value(t, run.jumped, 3)
	want := f32(30 * MARKS_ROW_H - MARKS_MARGIN)
	testing.expect_value(t, view.view_off.y, want)
	testing.expect_value(t, view.view_target.y, want)
	testing.expect(t, !view.view_anim[1].active, "no glide")
	row := session.get(s, "row30")
	testing.expect_value(t, row.rect.min.y - view.rect.min.y, f32(MARKS_MARGIN))
}) }

// The thumb over a mark is the thumb's: a press there does not go to the mark, and a drag moves the view as on any bar.
@(test)
the_thumb_over_a_mark_drags :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Marks_Run
	defer ui.scroll_marks_destroy(&run.marks)
	s := marks_start(t, &run)
	view := session.get(s, "view")
	at, _ := ui.scroll_marks_at(&run.marks, view, 0)   // (the view at its top: the thumb is over the first mark)
	_, thumb, _ := ui.scrollbar_rects(view)
	testing.expectf(t, at.y >= thumb.min.y && at.y < thumb.max.y, "under the thumb: %v in %v", at, thumb)
	session.drag(s, at, at + {0, 40})
	testing.expect_value(t, run.jumped, -1)
	testing.expect(t, view.view_off.y > 0, "the drag scrolled")
}) }

// The wheel over the bar scrolls the view (it glides, as over the view).
@(test)
the_wheel_over_the_marks_scrolls_the_view :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Marks_Run
	defer ui.scroll_marks_destroy(&run.marks)
	s := marks_start(t, &run)
	view := session.get(s, "view")
	at, _ := ui.scroll_marks_at(&run.marks, view, 2)
	session.wheel(s, at, {0, 3})
	testing.expect(t, view.view_target.y > 0, "the view heads down")
	testing.expect_value(t, run.jumped, -1)
}) }

// The pointer over a mark shows its card beside the bar: the first three lines of its text, the last cut with "…".
@(test)
a_mark_under_the_pointer_shows_its_first_lines :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Marks_Run
	defer ui.scroll_marks_destroy(&run.marks)
	s := marks_start(t, &run)
	at, _ := ui.scroll_marks_at(&run.marks, session.get(s, "view"), 2)
	session.move(s, at)
	session.frames(s, 2)
	tip := session.find(s, "tooltip")
	if !testing.expect(t, tip != nil, "a tooltip") { return }
	testing.expect(t, session.find_text(s, "gamma") != nil, "the mark's first line")
	testing.expect(t, session.find_text(s, "more of it") != nil, "its second line")
	testing.expect(t, session.find_text(s, "and so on…") != nil, "its third line, which says there is more")
	testing.expect(t, session.find_text(s, "the end") == nil, "only the first three lines")
}) }

// Two marks closer than a mark is tall are drawn as one: the pointer over it shows the first line of both, a press goes to
// the nearer.
@(test)
marks_too_close_are_one :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Marks_Run
	defer ui.scroll_marks_destroy(&run.marks)
	s := marks_start(t, &run, MARKS_ROWS_CLOSE[:], drawn = true)
	view := session.get(s, "view")
	a, _ := ui.scroll_marks_at(&run.marks, view, 2)
	b, _ := ui.scroll_marks_at(&run.marks, view, 3)
	testing.expectf(t, b.y - a.y < 4, "close: %v, %v", a.y, b.y)
	session.move(s, a)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "gamma") != nil, "the first one's line")
	testing.expect(t, session.find_text(s, "delta") != nil, "the second one's line")
	session.click_at(s, b)
	testing.expect_value(t, run.jumped, 3)
}) }

// Up and Down go from mark to mark, Enter jumps.
@(test)
the_keyboard_goes_from_mark_to_mark :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Marks_Run
	defer ui.scroll_marks_destroy(&run.marks)
	s := marks_start(t, &run)
	view := session.get(s, "view")
	at, _ := ui.scroll_marks_at(&run.marks, view, 1)
	session.click_at(s, at)
	testing.expect_value(t, session.focused_name(s), "marks")
	session.key(s, .Down)
	session.key(s, .Down)
	testing.expect_value(t, run.marks.current, 3)
	testing.expect_value(t, view.view_off.y, f32(10 * MARKS_ROW_H - MARKS_MARGIN))   // (a step is no jump)
	session.key(s, .Return)
	testing.expect_value(t, run.jumped, 3)
	testing.expect_value(t, view.view_off.y, f32(30 * MARKS_ROW_H - MARKS_MARGIN))
	session.key(s, .Home)
	testing.expect_value(t, run.marks.current, 0)
	session.key(s, .Up)
	testing.expect_value(t, run.marks.current, 0)   // (the first stays)
}) }

// A word typed while the marks have the keyboard opens their filter: only the marks that hold it are shown, the keyboard
// goes among them, Enter jumps, Escape gives them all back.
@(test)
the_filter_keeps_the_marks_that_say_what_is_typed :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Marks_Run
	defer ui.scroll_marks_destroy(&run.marks)
	s := marks_start(t, &run)
	view := session.get(s, "view")
	testing.expect_value(t, len(ui.scroll_marks_shown(&run.marks)), len(MARKS_NAMES))
	at, _ := ui.scroll_marks_at(&run.marks, view, 1)
	session.click_at(s, at)
	session.type_text(s, "et")   // beta, zeta (and not the others)
	session.frames(s, 1)
	testing.expect_value(t, ui.scroll_marks_query(&run.marks), "et")
	shown := ui.scroll_marks_shown(&run.marks)
	if !testing.expect_value(t, len(shown), 2) { return }
	testing.expect(t, shown[0] == 1 && shown[1] == 5, "beta and zeta")
	_, hidden := ui.scroll_marks_at(&run.marks, view, 2)
	testing.expect(t, !hidden, "gamma is not shown")
	session.key(s, .Down)
	testing.expect_value(t, run.marks.current, 5)
	session.key(s, .Return)
	testing.expect_value(t, run.jumped, 5)
	testing.expect_value(t, view.view_off.y, f32(50 * MARKS_ROW_H - MARKS_MARGIN))
	session.key(s, .Escape)
	testing.expect_value(t, ui.scroll_marks_query(&run.marks), "")
	testing.expect_value(t, len(ui.scroll_marks_shown(&run.marks)), len(MARKS_NAMES))
	testing.expect(t, !run.marks.filtering, "the field closed")
}) }

// The magnifier above the bar opens the filter's field; a second press closes it.
@(test)
the_magnifier_opens_the_filter :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	run: Marks_Run
	defer ui.scroll_marks_destroy(&run.marks)
	s := marks_start(t, &run)
	session.click(s, "marks")
	testing.expect(t, run.marks.filtering, "open")
	testing.expect(t, session.find(s, "field") != nil, "its field")
	session.click(s, "marks")
	testing.expect(t, !run.marks.filtering, "closed")
}) }

// New marks (a version of the program's) are taken; the old ones' texts are let go (the test's allocator says so).
@(test)
a_new_version_replaces_the_marks :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	k: ui.Scroll_Marks
	defer ui.scroll_marks_destroy(&k)
	testing.expect(t, ui.scroll_marks_stale(&k, 0), "marks never given are stale")
	ui.scroll_marks_set(&k, 7, {{id = "a", text = "one"}, {id = "b", text = "  \n two \n three"}})
	testing.expect(t, !ui.scroll_marks_stale(&k, 7), "the version given")
	testing.expect(t, ui.scroll_marks_stale(&k, 8), "another one")
	testing.expect_value(t, ui.scroll_marks_id(&k, 1), "b")
	testing.expect_value(t, ui.scroll_marks_id(&k, 2), "")
	ui.scroll_marks_set(&k, 8, {{id = "c", text = "x", weak = true}})
	testing.expect_value(t, len(ui.scroll_marks_shown(&k)), 1)
	ui.scroll_marks_place(&k, 4, 10)   // (out of range: passed over)
}) }
