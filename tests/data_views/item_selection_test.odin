// The selection of a list's rows alone (ui.Item_Selection, src/md/features/selection.md): every rule, with no window.
//   odin test tests/data_views -vet -define:ODIN_TEST_THREADS=1
package data_views_test

import "core:testing"
import "../../src/ui"

// Rows 0 to 5 by identity 10 to 15; row 3 a header (it cannot be selected).
@(private = "file") IDS := [?]u64{10, 11, 12, 13, 14, 15}
@(private = "file") CAN := [?]bool{true, true, true, false, true, true}

@(private = "file")
rows_of :: proc() -> ui.Item_Rows { return {count = len(IDS), ids = IDS[:], selectable = CAN[:]} }

// Whether exactly the rows `want` are selected.
@(private = "file")
exactly :: proc(sel: ^ui.Item_Selection, want: ..int) -> bool {
	rows := rows_of()
	if ui.item_selection_count(sel, rows) != len(want) { return false }
	for i in want { if !ui.item_selection_has(sel, rows, i) { return false } }
	return true
}

@(private = "file")
multi_selection :: proc() -> ui.Item_Selection { return {sel = -1, multi = true} }

@(test)
a_click_selects_its_row_alone :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	ui.item_selection_click(&sel, rows, 1, {})
	ui.item_selection_click(&sel, rows, 4, {})
	testing.expect(t, exactly(&sel, 4) && sel.sel == 4, "the row alone")
	ui.item_selection_click(&sel, rows, 3, {})
	testing.expect(t, exactly(&sel, 4) && sel.sel == 4, "a header: nothing")
}

@(test)
ctrl_click_toggles_and_moves_the_anchor :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	ui.item_selection_click(&sel, rows, 0, {})
	ui.item_selection_click(&sel, rows, 2, {.Ctrl})
	testing.expect(t, exactly(&sel, 0, 2), "added")
	ui.item_selection_click(&sel, rows, 0, {.Ctrl})
	testing.expect(t, exactly(&sel, 2), "removed")
	testing.expect(t, sel.anchored && sel.anchor == 10 && sel.sel == 0, "the anchor and the cursor on the row toggled")
	ui.item_selection_click(&sel, rows, 2, {.Ctrl})
	testing.expect(t, exactly(&sel), "nothing selected, the cursor stays")
	testing.expect_value(t, sel.sel, 2)
}

@(test)
shift_click_selects_the_range_alone_and_replaces_it :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	ui.item_selection_click(&sel, rows, 5, {})
	ui.item_selection_click(&sel, rows, 1, {.Ctrl})   // (the anchor on 1, 5 selected)
	ui.item_selection_click(&sel, rows, 4, {.Shift})
	testing.expect(t, exactly(&sel, 1, 2, 4), "1 to 4, the header skipped, 5 dropped")
	ui.item_selection_click(&sel, rows, 2, {.Shift})
	testing.expect(t, exactly(&sel, 1, 2), "a nearer row: the range smaller")
	ui.item_selection_click(&sel, rows, 0, {.Shift})
	testing.expect(t, exactly(&sel, 0, 1), "the other side of the anchor")
	testing.expect(t, sel.anchor == 11 && sel.sel == 0, "the anchor stays")
}

@(test)
ctrl_shift_click_adds_the_range_to_the_base :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	ui.item_selection_click(&sel, rows, 0, {})
	ui.item_selection_click(&sel, rows, 2, {.Ctrl})
	ui.item_selection_click(&sel, rows, 5, {.Ctrl, .Shift})
	testing.expect(t, exactly(&sel, 0, 2, 4, 5), "the base and 2 to 5")
	ui.item_selection_click(&sel, rows, 4, {.Ctrl, .Shift})
	testing.expect(t, exactly(&sel, 0, 2, 4), "its range replaced, the base kept")
	ui.item_selection_click(&sel, rows, 4, {.Shift})
	testing.expect(t, exactly(&sel, 2, 4), "plain Shift: the base dropped")
}

@(test)
a_shift_with_no_anchor_starts_at_the_cursor :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	ui.item_selection_click(&sel, rows, 4, {.Shift})
	testing.expect(t, exactly(&sel, 4), "no cursor: the row itself")
	sel2 := ui.Item_Selection{sel = 1, multi = true}
	defer ui.item_selection_destroy(&sel2)
	ui.item_selection_click(&sel2, rows, 2, {.Shift})
	testing.expect(t, ui.item_selection_count(&sel2, rows) == 2 && ui.item_selection_has(&sel2, rows, 1), "from the cursor")
}

@(test)
a_right_click_keeps_the_selection_it_is_in :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	ui.item_selection_click(&sel, rows, 0, {})
	ui.item_selection_click(&sel, rows, 2, {.Shift})
	ui.item_selection_context(&sel, rows, 1)
	testing.expect(t, exactly(&sel, 0, 1, 2) && sel.sel == 1, "inside: kept, the cursor on it")
	ui.item_selection_context(&sel, rows, 5)
	testing.expect(t, exactly(&sel, 5), "outside: the row alone")
}

@(test)
the_arrows_select_extend_or_move_the_cursor :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	testing.expect(t, ui.item_selection_key(&sel, rows, .Down, {}), "used")
	testing.expect(t, exactly(&sel, 0) && sel.sel == 0, "Down from none: the first row")
	ui.item_selection_key(&sel, rows, .Down, {})
	testing.expect(t, exactly(&sel, 1), "Down: the next row alone")
	ui.item_selection_key(&sel, rows, .Down, {.Shift})
	ui.item_selection_key(&sel, rows, .Down, {.Shift})
	testing.expect(t, exactly(&sel, 1, 2, 4) && sel.sel == 4, "Shift+Down: the range, over the header")
	ui.item_selection_key(&sel, rows, .Up, {.Shift})
	testing.expect(t, exactly(&sel, 1, 2), "Shift+Up: smaller")
	ui.item_selection_key(&sel, rows, .Down, {.Ctrl})
	ui.item_selection_key(&sel, rows, .Down, {.Ctrl})
	testing.expect(t, exactly(&sel, 1, 2) && sel.sel == 5, "Ctrl+Down: the cursor alone moves")
	ui.item_selection_key(&sel, rows, .Space, {.Ctrl})
	testing.expect(t, exactly(&sel, 1, 2, 5), "Ctrl+Space: toggled")
	ui.item_selection_key(&sel, rows, .Space, {.Ctrl})
	testing.expect(t, exactly(&sel, 1, 2), "Ctrl+Space again")
	ui.item_selection_key(&sel, rows, .Home, {.Ctrl, .Shift})
	testing.expect(t, exactly(&sel, 0, 1, 2, 4, 5), "Ctrl+Shift+Home: from the anchor (5) to the first row, over the base")
	ui.item_selection_key(&sel, rows, .End, {})
	testing.expect(t, exactly(&sel, 5), "End: the last row alone")
	ui.item_selection_key(&sel, rows, .Page_Up, {.Shift}, page = 2)
	testing.expect(t, exactly(&sel, 2, 4, 5) && sel.sel == 2, "Shift+Page Up: two rows that can be selected up")
}

// Escape on several rows keeps the cursor's alone; on one, or none, it is the program's (the list's cancel): a list
// always shows the row an act would take.
@(test)
ctrl_a_selects_all_and_escape_keeps_the_cursors_row :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	testing.expect(t, !ui.item_selection_key(&sel, rows, .Escape, {}), "Escape on nothing: not the selection's (the list's cancel)")
	ui.item_selection_click(&sel, rows, 1, {})
	testing.expect(t, !ui.item_selection_key(&sel, rows, .Escape, {}), "Escape on one row: the program's")
	testing.expect(t, exactly(&sel, 1), "the row stays")
	testing.expect(t, ui.item_selection_key(&sel, rows, .A, {.Ctrl}), "Ctrl+A used")
	testing.expect(t, exactly(&sel, 0, 1, 2, 4, 5), "every row that can be selected")
	testing.expect(t, !ui.item_selection_key(&sel, rows, .Escape, {.Shift}), "Shift+Escape: the program's")
	testing.expect(t, ui.item_selection_key(&sel, rows, .Escape, {}), "Escape on several: the selection's")
	testing.expect(t, exactly(&sel, 1) && sel.sel == 1, "the cursor's row alone")
	ui.item_selection_key(&sel, rows, .Down, {.Shift})
	testing.expect(t, exactly(&sel, 1, 2), "the anchor on the cursor's row: Shift ranges from it")
	testing.expect(t, ui.item_selection_escape(&sel, rows), "item_selection_escape: the same, for a program's own Escape")
	testing.expect(t, exactly(&sel, 2), "the cursor's row alone")
	ui.item_selection_clear(&sel)
	testing.expect(t, exactly(&sel), "cleared")
	testing.expect(t, !ui.item_selection_key(&sel, rows, .A, {}), "A alone: the program's (type-ahead)")
	testing.expect(t, !ui.item_selection_key(&sel, rows, .Down, {.Alt}), "Alt+Down: the program's")
	testing.expect(t, !ui.item_selection_key(&sel, rows, .Return, {}), "Enter: the list's")
}

// A row whose identity changes (unfolded: its id carries its height) keeps its selection, its place in the base and
// the anchor; the version moves.
@(test)
a_row_rekeyed_keeps_its_selection :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	ids := []u64{10, 11, 12}
	rows := ui.Item_Rows{count = 3, ids = ids}
	ui.item_selection_click(&sel, rows, 1, {})
	before := sel.version
	ids[1] = 99
	ui.item_selection_rekey(&sel, 11, 99)
	testing.expect(t, 99 in sel.selected && 11 not_in sel.selected && 99 in sel.base, "the set and the base follow")
	testing.expect(t, sel.anchored && sel.anchor == 99, "the anchor follows")
	testing.expect(t, sel.version != before, "the version moves")
	ui.item_selection_click(&sel, rows, 2, {.Shift})
	testing.expect(t, ui.item_selection_has(&sel, rows, 1) && ui.item_selection_has(&sel, rows, 2), "a Shift range from the rekeyed anchor")
	ui.item_selection_rekey(&sel, 12345, 1)
	testing.expect_value(t, len(sel.selected), 2)   // (an id not selected: nothing)
}

@(test)
a_single_list_selects_one_row_and_leaves_the_modified_keys :: proc(t: ^testing.T) {
	sel := ui.Item_Selection{sel = -1}
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	ui.item_selection_click(&sel, rows, 1, {})
	ui.item_selection_click(&sel, rows, 4, {.Ctrl})
	testing.expect(t, exactly(&sel, 4), "Ctrl+click: one row")
	ui.item_selection_click(&sel, rows, 0, {.Shift})
	testing.expect(t, exactly(&sel, 0), "Shift+click: one row")
	testing.expect(t, !ui.item_selection_key(&sel, rows, .Page_Down, {.Shift}), "Shift+Page Down: the program's")
	testing.expect(t, !ui.item_selection_key(&sel, rows, .A, {.Ctrl}), "Ctrl+A: the program's")
	testing.expect(t, !ui.item_selection_key(&sel, rows, .Escape, {}), "Escape: the list's cancel")
	ui.item_selection_key(&sel, rows, .Down, {})
	testing.expect(t, exactly(&sel, 1) && len(sel.selected) == 0, "Down: the next row, no set kept")
	testing.expect_value(t, len(ui.item_selection_ids(&sel, rows)), 1)
}

@(test)
the_selection_goes_with_the_identities :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	ui.item_selection_click(&sel, rows, 1, {})
	ui.item_selection_click(&sel, rows, 5, {.Shift})   // (11, 12, 14, 15; the anchor 11)
	// sorted again, 12 gone, the anchor's row gone
	sorted := [?]u64{15, 14, 13, 10}
	after := ui.Item_Rows{count = len(sorted), ids = sorted[:]}
	ui.item_selection_keep(&sel, after)
	testing.expect(t, ui.item_selection_count(&sel, after) == 2 && ui.item_selection_has(&sel, after, 0) && ui.item_selection_has(&sel, after, 1), "15 and 14 stay, in their new rows")
	testing.expect(t, !sel.anchored, "the anchor's row is gone: no anchor")
	ids := ui.item_selection_ids(&sel, after)
	testing.expect(t, len(ids) == 2 && ids[0] == 15 && ids[1] == 14, "the ids in the rows' order")
}

@(test)
the_version_moves_with_each_change_only :: proc(t: ^testing.T) {
	sel := multi_selection()
	defer ui.item_selection_destroy(&sel)
	rows := rows_of()
	ui.item_selection_click(&sel, rows, 2, {})
	v := sel.version
	ui.item_selection_click(&sel, rows, 2, {})
	testing.expect_value(t, sel.version, v)   // (the same row alone again: no change)
	ui.item_selection_key(&sel, rows, .Down, {.Ctrl})
	testing.expect_value(t, sel.version, v)   // (the cursor alone)
	ui.item_selection_set(&sel, rows, 0)
	testing.expect(t, sel.version != v && exactly(&sel, 0, 2), "a program's change")
}
