package scenarios_test

// A row of equal cells (ui.cell_row, src/md/features/cell-row.md): of ten thousand cells, only those in view are built;
// the chosen one is in the middle; the wheel moves the row and it stays there; another chosen cell brings the view back
// to it; a count that shrinks clamps the view.

import "core:fmt"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") ROW_WIDTH :: 600
@(private = "file") ROW_CELL :: 50
@(private = "file") ROW_GAP :: 10

@(private = "file")
Row_Run :: struct {
	st:     ui.Cell_Row,
	count:  int,
	chosen: int,
	built:  int,    // the cells built by the last build
	first:  int,
	clicked: int,
	focusable: bool,   // the cells take the focus
}

@(private = "file")
row_build :: proc(s: ^session.Session) {
	r := (^Row_Run)(s.user)
	r.built = 0
	ui.next({width = ui.px(ROW_WIDTH), height = ui.px(ROW_CELL + 2 * ROW_GAP)})
	if cells, ok := ui.cell_row("###row", &r.st, r.count, {cell = ROW_CELL, gap = ROW_GAP, chosen = r.chosen}); ok {
		r.first = cells.first
		for i in cells.first ..< cells.last {
			ui.cell_row_next(&r.st, i)
			b := ui.build_box(r.focusable ? {.Clickable, .Focusable} : {.Clickable}, fmt.tprintf("###cell%d", i))
			if ui.signal(b).clicked { r.clicked = i }
			r.built += 1
		}
	}
}

@(test)
only_the_cells_in_view_are_built :: proc(t: ^testing.T) {
	r := new(Row_Run)
	defer free(r)
	r^ = {count = 10_000, chosen = 5_000, clicked = -1}
	s := session.start(t, {build = row_build, user = r, no_renderer = true})
	session.wait_idle(s)
	// (600 px of 60 px cells: 10 in view, 11 when one is cut at each end)
	testing.expectf(t, r.built >= 10 && r.built <= 12, "%d cells built of 10 000", r.built)
	row := session.get(s, "row")
	chosen := session.get(s, "cell5000")
	mid := (row.rect.min.x + row.rect.max.x) / 2
	testing.expectf(t, abs((chosen.rect.min.x + chosen.rect.max.x) / 2 - mid) < 1, "the chosen cell in the middle: %v", chosen.rect)
	testing.expect_value(t, chosen.rect.max.x - chosen.rect.min.x, f32(ROW_CELL))

	// the wheel moves the row toward the end, and it stays there
	session.wheel(s, session.center(row), {0, 3})
	session.wait_idle(s)
	testing.expect(t, r.st.free, "free after the wheel")
	testing.expectf(t, r.first > 5_000 - 6, "moved toward the end: first %d", r.first)
	testing.expect(t, session.find(s, "cell5000") == nil || session.get(s, "cell5000").rect.max.x < mid, "the chosen cell left the middle")
	first_after := r.first
	session.frames(s, 3)
	testing.expect_value(t, r.first, first_after)

	// a click chooses a cell: the view goes to it
	target := r.first + 1
	session.click(s, fmt.tprintf("cell%d", target))
	testing.expect_value(t, r.clicked, target)
	r.chosen = target
	session.wait_idle(s)
	testing.expect(t, !r.st.free, "following again")
	c := session.get(s, fmt.tprintf("cell%d", target))
	testing.expectf(t, abs((c.rect.min.x + c.rect.max.x) / 2 - mid) < 1, "the new chosen cell in the middle: %v", c.rect)

	// fewer cells than the row holds: from the left, the view clamped
	r.count, r.chosen = 3, 2
	session.wait_idle(s)
	testing.expect_value(t, r.built, 3)
	testing.expect_value(t, session.get(s, "cell0").rect.min.x, row.rect.min.x + ROW_GAP)
}

// A screen reader is told each built cell's place in the whole row and the row's count, the chosen one selected; a
// focused cell that the wheel moves out of view keeps the focus (it is not built, not gone), and has it when it comes back.
@(test)
a_cell_out_of_view_keeps_its_place_and_its_focus :: proc(t: ^testing.T) {
	r := new(Row_Run)
	defer free(r)
	r^ = {count = 10_000, chosen = 5_000, clicked = -1, focusable = true}
	s := session.start(t, {build = row_build, user = r, no_renderer = true})
	session.wait_idle(s)
	row := session.get(s, "row")
	testing.expect(t, row.a11y != nil && row.a11y.role == .List_Box, "the row is a list")
	chosen := session.get(s, "cell5000")
	if testing.expect(t, chosen.a11y != nil) {
		testing.expect_value(t, chosen.a11y.role, ui.A11y_Role.List_Box_Option)
		testing.expect_value(t, chosen.a11y.position, 5001)
		testing.expect_value(t, chosen.a11y.set_size, 10_000)
		testing.expect(t, chosen.a11y.selected.? or_else false, "the chosen cell is selected")
	}
	other := session.get(s, "cell5001")
	testing.expect(t, other.a11y != nil && other.a11y.position == 5002 && !(other.a11y.selected.? or_else true))

	session.click(s, "cell5000")
	testing.expect_value(t, session.focused_name(s), "cell5000")
	key := ui.focus_key_of(s.state)
	// the wheel takes the row far from the chosen cell: it is no longer built, the focus waits for it
	for _ in 0 ..< 10 { session.wheel(s, session.center(row), {0, 3}) }
	session.wait_idle(s)
	testing.expect(t, session.find(s, "cell5000") == nil, "out of view: not built")
	testing.expect_value(t, ui.focus_key_of(s.state), key)
	// the chosen cell again: the view goes back to it, and it has the focus
	r.chosen = 4_999
	session.wait_idle(s)
	r.chosen = 5_000
	session.wait_idle(s)
	testing.expect_value(t, session.focused_name(s), "cell5000")
}
