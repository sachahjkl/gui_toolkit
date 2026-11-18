package scenarios_test

// Find in a view (ui/find.odin, ui/find_bar.odin; src/md/features/find-in-view.md): the bar opens over its view, counts the
// matches of every row, built or not, steps from one to the next and brings it in, lights them, asks the program to open
// a folded part, takes its options and scopes, stands alone in its view, closes with Escape, puts its matches on the
// scroll bar, and counts a long list in bounded slices. A program drives it between builds, reads when it scrolled, and
// sets the current match; a press in the bar leaves the keyboard in its field.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") FIND_VIEW_W :: 560
@(private = "file") FIND_VIEW_H :: 200
@(private = "file") FIND_ROW_H :: 30
@(private = "file") FIND_ROWS :: 60
@(private = "file") FIND_HITS := [?]int{5, 20, 50}   // the rows that say "needle"
@(private = "file") FIND_FOLDED :: 30                 // a row whose folded part says "needle"
@(private = "file") FIND_LONG :: 20000

@(private = "file")
Find_Run :: struct {
	count:     int,
	hits:      []int,
	folded:    int,           // -1: none
	open:      bool,          // its folded part is shown
	reveals:   int,           // the program was asked to open it
	reveal_at: int,
	reads:     int,           // whole texts read since the counter was reset
	inserted:  int,           // rows put before the first one (their ids are new)
	version:   u64,
	scopes:    []ui.Find_Scope,
	marks_on:  bool,
	marks:     ui.Scroll_Marks,
	plain:     bool,          // a view with no rows: box mode
	second:    bool,          // a second view beside the first
	res:       ui.Find_Result,
	scrolls:   int,           // builds whose result said the find moved the view
}

@(private = "file")
find_row_text :: proc(r: ^Find_Run, i: int) -> string {
	row := i - r.inserted
	if row < 0 { return fmt.tprintf("new row %d", i) }
	for h in r.hits { if h == row { return fmt.tprintf("row %d holds a needle", row) } }
	return fmt.tprintf("row %d", row)
}

@(private = "file")
find_text_of :: proc(user: rawptr, i: int, allocator: runtime.Allocator, whole: bool) -> (string, bool) {
	r := (^Find_Run)(user)
	if whole { r.reads += 1 }
	text := find_row_text(r, i)
	if r.folded >= 0 && i - r.inserted == r.folded && (whole || r.open) { return strings.concatenate({text, "\nfolded: a needle inside"}, allocator), true }
	return strings.clone(text, allocator), true
}

@(private = "file")
find_id_of :: proc(user: rawptr, i: int) -> u64 {
	r := (^Find_Run)(user)
	return u64(i - r.inserted + 1_000_000)
}

@(private = "file")
find_stamp_of :: proc(user: rawptr, i: int) -> u64 { return 1 }

@(private = "file")
find_reveal :: proc(user: rawptr, row: int, offset: int) {
	r := (^Find_Run)(user)
	r.reveals += 1
	r.reveal_at = offset
	if row - r.inserted == r.folded { r.open = true }
}

@(private = "file")
find_view :: proc(s: ^session.Session, r: ^Find_Run, id: string) {
	ui.next({width = ui.px(FIND_VIEW_W), height = ui.px(FIND_VIEW_H)})
	if ui.scroll_y(id) {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			if r.plain {
				for i in 0 ..< r.count {
					ui.next({width = ui.fill(), height = ui.px(FIND_ROW_H)})
					ui.label(fmt.tprintf("%s###t%d", find_row_text(r, i), i))
				}
				return
			}
			rows := ui.Text_Rows{count = r.count, text = find_text_of, id = find_id_of, stamp = find_stamp_of, user = r, reveal = find_reveal, version = r.version}
			lz := ui.lazy_begin(rows = rows)
			for i in 0 ..< r.count {
				if r.marks_on && (i - r.inserted) % 10 == 0 { ui.scroll_marks_place(&r.marks, (i - r.inserted) / 10, lz.y) }
				if ui.lazy_item(lz, fmt.tprintf("###r%d", find_id_of(r, i))) {
					ui.next({width = ui.fill(), height = ui.px(FIND_ROW_H), flags = {.Selectable}})
					ui.label(fmt.tprintf("%s###t", find_row_text(r, i)))
					if i - r.inserted == r.folded && r.open {
						ui.next({width = ui.fill(), height = ui.px(FIND_ROW_H), flags = {.Selectable}})
						ui.label("folded: a needle inside###more")
					}
				}
			}
		}
	}
}

@(private = "file")
find_build :: proc(s: ^session.Session) {
	r := (^Find_Run)(s.user)
	if r.marks_on && ui.scroll_marks_stale(&r.marks, 1) {
		given := make([]ui.Scroll_Mark, r.count / 10, context.temp_allocator)
		for &m, i in given { m = {id = fmt.tprintf("m%d", i), text = fmt.tprintf("mark %d", i)} }
		ui.scroll_marks_set(&r.marks, 1, given)
	}
	ui.next({width = ui.px(2 * FIND_VIEW_W + 40), height = ui.px(FIND_VIEW_H), axis = .X})
	if ui.row(id = "###lane") {
		if r.marks_on { ui.scroll_marks("###marks", &r.marks, ui.prev_box("###view")) }
		find_view(s, r, "###view")
		r.res = ui.find_bar(ui.prev_box("###view"), {scopes = r.scopes})
		if r.res.scrolled { r.scrolls += 1 }
		if r.second {
			find_view(s, r, "###other")
			ui.find_bar(ui.prev_box("###other"))
		}
	}
}

@(private = "file")
find_start :: proc(t: ^testing.T, r: ^Find_Run) -> ^session.Session {
	if r.count == 0 { r.count = FIND_ROWS }
	if r.hits == nil { r.hits = FIND_HITS[:] }
	s := session.start(t, {user = r, build = find_build, no_renderer = true, size = {2 * FIND_VIEW_W + 100, 400}})
	session.frames(s, 2)
	return s
}

// Opens the find over the view, types `needle` and waits for its count.
@(private = "file")
find_type :: proc(s: ^session.Session, needle: string, view := "view") {
	ui.find_open(s.state, session.get(s, view).key)
	session.frames(s, 2)
	session.type_text(s, needle)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_count() > 0 }, "the count")
}

// The match lit as current, by the last layout (nil: none).
@(private = "file")
find_lit_current :: proc() -> ^ui.Box {
	for m in ui.find_matches() { if m.index >= 0 && m.index == ui.find_index() { return ui.box_from_key(m.box) } }
	return nil
}

// The current match's box is built and inside the view.
@(private = "file")
find_current_shown :: proc(s: ^session.Session) -> bool {
	b := find_lit_current()
	v := session.find(s, "view")
	return b != nil && v != nil && b.rect.min.y >= v.rect.min.y && b.rect.max.y <= v.rect.max.y
}

// The bar opens with the keyboard in its field, counts every row's matches, lights the first one below the view's top,
// says "1/4"; Enter, Shift+Enter and F3 step and the view brings each one in.
@(test)
the_bar_counts_steps_and_lights :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = FIND_FOLDED}
	s := find_start(t, &r)
	ui.find_open(s.state, session.get(s, "view").key)
	session.frames(s, 2)
	testing.expect_value(t, session.focused_name(s), "field")
	session.type_text(s, "needle")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_index() >= 0 }, "the first match")
	testing.expect_value(t, ui.find_count(), 4)   // (rows 5, 20, 50 and the folded part of row 30)
	testing.expect_value(t, ui.find_index(), 0)
	session.wait_until(s, find_current_shown, "the first match lit in view")
	testing.expect(t, session.find_text(s, "1/4") != nil, "the count says where it is")
	session.key(s, .Return)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 1 && find_current_shown(s) }, "the second, brought in")
	testing.expect(t, strings.contains(find_lit_current().text, "row 20"), "on row 20")
	session.key(s, .Return, {.Shift})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 0 && find_current_shown(s) }, "back to the first")
	session.key(s, .F3)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 1 }, "F3 steps")
	session.key(s, .F3, {.Shift})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 0 }, "Shift+F3 steps back")
}) }

// A match in a row the lazy column never built is counted, and a step to it builds its row and brings it in.
@(test)
a_match_in_a_row_not_built_is_counted_and_reached :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1}
	s := find_start(t, &r)
	testing.expect(t, session.find(s, "r1000050") == nil, "row 50 is not built")
	find_type(s, "needle")
	testing.expect_value(t, ui.find_count(), 3)
	session.key(s, .F3)
	session.key(s, .F3)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 2 && find_current_shown(s) }, "row 50's match, lit in view")
	testing.expect(t, strings.contains(find_lit_current().text, "row 50"), "on row 50")
}) }

// A match in a part the program folded is counted; stepping to it asks the program to open it (at the match's offset in
// the row's whole text), and once open it is lit as the current one.
@(test)
a_folded_match_is_revealed_then_lit :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = FIND_FOLDED}
	s := find_start(t, &r)
	find_type(s, "needle")
	testing.expect_value(t, ui.find_count(), 4)
	session.key(s, .F3)   // row 20
	session.key(s, .F3)   // row 30's folded part
	session.wait_until(s, proc(s: ^session.Session) -> bool { return (^Find_Run)(s.user).reveals > 0 }, "the program asked to reveal it")
	testing.expect_value(t, r.reveals, 1)
	testing.expect_value(t, r.reveal_at, len("row 30\nfolded: a "))
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 2 && find_current_shown(s) }, "lit once open")
	testing.expect(t, strings.contains(find_lit_current().text, "folded"), "in the part opened")
}) }

// Match case and whole word: Alt+C and Alt+W in the field, or their buttons, count again.
@(test)
the_options_count_again :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1}
	s := find_start(t, &r)
	find_type(s, "Row 2")   // rows 2, 20..29 and the hit on row 20
	all := ui.find_count()
	testing.expect_value(t, all, 11)
	session.key(s, .C, {.Alt})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_count() == 0 }, "case kept: no \"Row\"")
	testing.expect(t, session.find_text(s, "No results") != nil, "it says so")
	testing.expect_value(t, ui.find_needle(), "Row 2")   // (Alt+C typed nothing)
	session.click(s, "case")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_count() == 11 }, "case ignored again")
	session.key(s, .W, {.Alt})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_count() == 1 }, "whole word: row 2 alone")
}) }

// The scopes the program names restrict the rows searched; the choice shows in the bar.
@(test)
a_scope_restricts_the_rows :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	scopes := [?]ui.Find_Scope{{name = "All"}, {name = "Tens", keep = proc(user: rawptr, row: int) -> bool { return row % 10 == 0 }}}
	r := Find_Run{folded = -1, scopes = scopes[:]}
	s := find_start(t, &r)
	find_type(s, "needle")
	testing.expect_value(t, ui.find_count(), 3)
	testing.expect(t, session.find(s, "scope") != nil, "the scopes in the bar")
	session.click(s, "seg1")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_count() == 2 }, "rows 20 and 50 only")
}) }

// One find per window: opened again over its view it focuses its field; opened over another view it moves there.
@(test)
one_bar_per_view :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1, second = true}
	s := find_start(t, &r)
	view, other := session.get(s, "view"), session.get(s, "other")
	ui.find_open(s.state, view.key)
	session.frames(s, 2)
	bar_of :: proc(s: ^session.Session, v: ^ui.Box) -> ^ui.Box { return session.find(s, fmt.tprintf("find_bar_%x", u64(v.key))) }
	testing.expect(t, bar_of(s, view) != nil && bar_of(s, other) == nil, "a bar over the first view")
	b := bar_of(s, view)
	testing.expectf(t, b.rect.max.x <= view.rect.max.x && b.rect.min.y >= view.rect.min.y, "inside it, at its top right: %v in %v", b.rect, view.rect)
	ui.set_focus(0)
	ui.find_open(s.state, view.key)
	session.frames(s, 2)
	testing.expect_value(t, session.focused_name(s), "field")
	testing.expect(t, bar_of(s, other) == nil, "still one bar")
	ui.find_open(s.state, other.key)
	session.frames(s, 2)
	testing.expect(t, bar_of(s, view) == nil && bar_of(s, other) != nil, "moved to the other view")
}) }

// Escape in the field closes the bar, its light goes, and the keyboard goes back to what had it.
@(test)
escape_closes_the_bar :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1}
	s := find_start(t, &r)
	find_type(s, "needle")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return len(ui.find_matches()) > 0 }, "a match lit")
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect(t, !ui.find_is_open(), "closed")
	testing.expect_value(t, len(ui.find_matches()), 0)
	testing.expect_value(t, ui.find_count(), 0)
	testing.expect(t, session.focused_name(s) != "field", "the field let the keyboard go")
	ui.find_open(s.state, session.get(s, "view").key)
	session.frames(s, 2)
	testing.expect_value(t, ui.find_needle(), "needle")   // (its text stays for the next time)
}) }

// The marks' magnifier opens the find over their view; a second press closes it; a character typed on the marks opens it
// with that character.
@(test)
the_magnifier_opens_the_find :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1, marks_on = true}
	defer ui.scroll_marks_destroy(&r.marks)
	s := find_start(t, &r)
	view := session.get(s, "view")
	session.click(s, "marks")
	session.frames(s, 1)
	testing.expect(t, ui.find_is_open(view.key), "open over the marks' view")
	testing.expect_value(t, session.focused_name(s), "field")
	session.click(s, "marks")
	session.frames(s, 1)
	testing.expect(t, !ui.find_is_open(), "closed")
	testing.expect_value(t, session.focused_name(s), "marks")
	session.type_text(s, "n")
	session.frames(s, 2)
	testing.expect(t, ui.find_is_open(view.key), "a letter opens it")
	testing.expect_value(t, ui.find_needle(), "n")
}) }

// Every match is a tick on the view's scroll bar, in the content's order, on the track.
@(test)
matches_are_ticks_on_the_bar :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1}
	s := find_start(t, &r)
	find_type(s, "needle")
	session.frames(s, 1)
	view := session.get(s, "view")
	ticks := ui.find_ticks(view)
	if !testing.expect_value(t, len(ticks), 3) { return }
	track, _, _ := ui.scrollbar_rects(view)
	for y, i in ticks {
		testing.expectf(t, y >= track.min.y && y <= track.max.y, "tick %d on the track: %v in %v", i, y, track)
		if i > 0 { testing.expectf(t, y > ticks[i - 1], "tick %d below the one before", i) }
	}
	ui.find_close(s.state)
	session.frames(s, 1)
	testing.expect_value(t, len(ui.find_ticks(view)), 0)
}) }

// A view that gives no rows is searched in its built boxes: counted, stepped, brought in.
@(test)
a_view_with_no_rows_is_searched_in_its_boxes :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1, plain = true}
	s := find_start(t, &r)
	find_type(s, "needle")
	testing.expect_value(t, ui.find_count(), 3)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 0 }, "the first")
	session.key(s, .Return)
	session.key(s, .Return)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 2 && find_current_shown(s) }, "the third, brought in")
}) }

// Rows put before the current match's row (a page of older messages): it stays on its row, found again by its id.
@(test)
the_current_match_follows_its_row :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1}
	s := find_start(t, &r)
	find_type(s, "needle")
	session.key(s, .F3)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 1 }, "on row 20")
	r.inserted, r.count = 10, r.count + 10
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_index() == 1 && (^Find_Run)(s.user).res.row == 30 }, "row 20, now the 31st")
	testing.expect_value(t, ui.find_count(), 3)
}) }

// A long list is counted in slices: no frame reads more than the budget of rows, the count ends right, and a frame with
// nothing new reads none.
@(test)
a_long_list_is_counted_in_bounded_slices :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	hits := make([]int, FIND_LONG / 100, context.temp_allocator)
	for &h, i in hits { h = i * 100 + 7 }
	r := Find_Run{folded = -1, count = FIND_LONG, hits = hits}
	s := find_start(t, &r)
	ui.find_open(s.state, session.get(s, "view").key)
	session.frames(s, 2)
	session.type_text(s, "needle")
	frames, most := 0, 0
	for i := 0; i < 200 && (i == 0 || ui.find_pending()); i += 1 {
		r.reads = 0
		session.frame(s)
		most = max(most, r.reads)
		frames += 1
	}
	testing.expect(t, !ui.find_pending(), "counted")
	testing.expect_value(t, ui.find_count(), FIND_LONG / 100)
	testing.expectf(t, most <= ui.FIND_ROWS_PER_FRAME + 16, "a frame read %d rows", most)
	// (the frame that typed the needle read its first slice)
	testing.expectf(t, frames + 1 >= FIND_LONG / ui.FIND_ROWS_PER_FRAME, "in %d frames", frames)
	r.reads = 0
	session.frames(s, 3)
	testing.expect_value(t, r.reads, 0)
	// (another needle: counted from the texts kept, none read again)
	session.key(s, .Backspace)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_count() == FIND_LONG / 100 }, "\"needl\" counted")
	testing.expect_value(t, r.reads, 0)
}) }

// A program opens and closes a window's find between two builds, while another window's State is the current one (its
// command line, its menu): that window's next build applies it, and it asks for that build.
@(test)
the_program_drives_a_window_s_find_between_builds :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1}
	s := find_start(t, &r)
	other := session.start(t, {size = {300, 200}, build = proc(s: ^session.Session) {}})
	view := session.get(s, "view")
	ui.use(other.state)
	ui.find_open(s.state, view.key, "needle")
	testing.expect(t, !ui.find_is_open(), "not the current window's find")
	testing.expect(t, ui.needs_frame(s.state), "the build that applies it is asked for")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_count() == 3 }, "counted in its window")
	testing.expect(t, ui.find_is_open(view.key), "open over its view")
	testing.expect_value(t, session.focused_name(s), "field")
	ui.use(other.state)
	ui.find_close(s.state)
	testing.expect(t, ui.needs_frame(s.state), "the build that closes it is asked for")
	session.frames(s, 2)
	testing.expect(t, !ui.find_is_open(), "closed")
	testing.expect_value(t, len(ui.find_matches()), 0)
}) }

// The bar's result says the build in which the find moved the view to bring a match in, and only then.
@(test)
the_result_says_when_the_find_scrolled :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1}
	s := find_start(t, &r)
	find_type(s, "needle")
	session.wait_until(s, find_current_shown, "the first match lit in view")
	session.frames(s, 3)
	r.scrolls = 0
	session.frames(s, 3)
	testing.expect_value(t, r.scrolls, 0)   // (nothing moved: nothing said)
	session.key(s, .F3)   // row 20, below the view
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 1 && find_current_shown(s) }, "row 20 brought in")
	testing.expect(t, r.scrolls > 0, "the result said the view moved")
	session.frames(s, 3)
	r.scrolls = 0
	session.frames(s, 3)
	testing.expect_value(t, r.scrolls, 0)
}) }

// A pointer press on an option, a scope or an arrow of the bar leaves the keyboard in the field: what is typed next goes on
// with the needle.
@(test)
a_press_in_the_bar_leaves_the_keyboard_in_the_field :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	scopes := [?]ui.Find_Scope{{name = "All"}, {name = "Tens", keep = proc(user: rawptr, row: int) -> bool { return row % 10 == 0 }}}
	r := Find_Run{folded = -1, scopes = scopes[:]}
	s := find_start(t, &r)
	find_type(s, "needle")
	testing.expect_value(t, session.focused_name(s), "field")
	session.click(s, "case")
	testing.expect_value(t, session.focused_name(s), "field")
	session.click(s, "word")
	testing.expect_value(t, session.focused_name(s), "field")
	session.click(s, "seg1")   // (an unchosen scope: not focusable, the press gave the keyboard to nothing)
	testing.expect_value(t, session.focused_name(s), "field")
	session.click(s, "next")
	testing.expect_value(t, session.focused_name(s), "field")
	session.type_text(s, "s")
	session.frames(s, 1)
	testing.expect_value(t, ui.find_needle(), "needles")
}) }

// find_set_current makes a match current by its index, clamped, and brings it in as a step does; asked before the count
// is known, it waits for it.
@(test)
the_program_sets_the_current_match :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Find_Run{folded = -1}
	s := find_start(t, &r)
	ui.find_open(s.state, session.get(s, "view").key, "needle")
	ui.find_set_current(s.state, 1)   // (before any row is counted)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_index() == 1 && find_current_shown(s) }, "the second, brought in")
	testing.expect(t, strings.contains(find_lit_current().text, "row 20"), "on row 20")
	ui.find_set_current(s.state, 99)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 2 && find_current_shown(s) }, "clamped to the last")
	testing.expect(t, strings.contains(find_lit_current().text, "row 50"), "on row 50")
	ui.find_set_current(s.state, -5)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_index() == 0 && find_current_shown(s) }, "clamped to the first")
	testing.expect(t, strings.contains(find_lit_current().text, "row 5 "), "on row 5")
}) }
