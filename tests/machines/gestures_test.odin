package machines_test

// Gestures and latches over several frames: an edge of a dialog held, a pane pulled out and pushed back, a stepper held off
// its button, the keyboard latches of a menu, the undo steps and the column of a text, the rows of a list that go.

import "core:testing"
import "../../platform"
import "../../testkit/session"
import "../../ui"

@(private = "file") WINDOW :: [2]int{600, 500}
@(private = "file") SMALL_WINDOW :: [2]int{300, 250}
@(private = "file") FIELD_WIDTH :: 200
@(private = "file") AREA_SIZE :: 300
@(private = "file") LIST_SIZE :: 200
@(private = "file") ROWS :: 200
@(private = "file") ROW_HEIGHT :: 30
@(private = "file") SETTLE_FRAMES :: 4
@(private = "file") PREFERRED :: ui.Vec2{420, 320}
@(private = "file") GRIP_MOVE_PX :: 20
@(private = "file") HOLD_MS :: 2000
@(private = "file") LONG_TIME_MS :: 1200
@(private = "file") PANE_SIZE :: 200
@(private = "file") PANE_SNAP_PX :: 2   // (still over the strip)
@(private = "file") PANE_OUT_PX :: 150
@(private = "file") VIEW_FAR :: 500
@(private = "file") FEW_BUILDS :: 30

@(private = "file")
Sized :: struct { open: bool, size: ui.Vec2 }

@(private = "file")
sized_build :: proc(s: ^session.Session) {
	r := (^Sized)(s.user)
	if ui.modal_sized("sized", PREFERRED, &r.size, &r.open) { ui.label("Hello") }
}

// A press on an edge that does not move leaves the person's size alone: the size this small window clamps it to is not theirs.
@(test)
a_press_on_a_dialog_edge_chooses_no_size :: proc(t: ^testing.T) {
	r := Sized{open = true}
	s := session.start(t, {size = SMALL_WINDOW, user = &r, build = sized_build})
	session.frames(s, SETTLE_FRAMES)
	at := session.center(session.get(s, "modal_grip3"))
	session.press(s, at)
	session.release(s, at)
	testing.expect_value(t, r.size, ui.Vec2{})
}

// A double click goes back to the preferred size, and stays there with a frame made while the button is down.
@(test)
a_double_click_on_a_dialog_edge_holds :: proc(t: ^testing.T) {
	r := Sized{open = true, size = PREFERRED + {40, 0}}
	s := session.start(t, {size = WINDOW, user = &r, build = sized_build})
	session.frames(s, SETTLE_FRAMES)
	at := session.center(session.get(s, "modal_grip3"))
	session.click_at(s, at)
	session.press(s, at)   // (the second press: the button stays down)
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, r.size, ui.Vec2{})
	session.release(s, at)
}

// A move back to where the press was is a move: the size follows it there.
@(test)
a_dialog_edge_comes_back_with_the_pointer :: proc(t: ^testing.T) {
	r := Sized{open = true}
	s := session.start(t, {size = WINDOW, user = &r, build = sized_build})
	session.frames(s, SETTLE_FRAMES)
	at := session.center(session.get(s, "modal_grip3"))
	session.press(s, at)
	session.move(s, at + {GRIP_MOVE_PX, 0})
	session.move(s, at)
	session.release(s, at)
	testing.expect_value(t, r.size, PREFERRED)
}

@(private = "file")
Folding :: struct { p: ui.Pane, res: ui.Pane_Result, toggles: int }

@(private = "file")
folding_build :: proc(s: ^session.Session) {
	r := (^Folding)(s.user)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row() {
		opts := ui.Pane_Options{collapsible = true, default_size = PANE_SIZE}
		ui.spacer(ui.px(ui.pane_extent(&r.p, .X, opts)))
		r.res = ui.pane_split("###split", .X, &r.p, opts)
		if r.res.toggled { r.toggles += 1 }
	}
}

// A strip pulled out and pushed back under the snap, then let go: a gesture that ends folded, no click that opens.
@(test)
a_strip_pushed_back_stays_folded :: proc(t: ^testing.T) {
	r := Folding{p = {collapsed = true}}
	s := session.start(t, {size = WINDOW, user = &r, build = folding_build})
	at := session.center(session.get(s, "split"))
	session.press(s, at)
	session.move(s, at + {PANE_OUT_PX, 0})
	testing.expect(t, !r.p.collapsed, "pulled out")
	session.move(s, at + {PANE_SNAP_PX, 0})
	testing.expect(t, r.p.collapsed, "pushed back")
	session.release(s, at + {PANE_SNAP_PX, 0})
	testing.expect(t, r.p.collapsed, "the release is no click")
}

// A screen reader's value on a folded pane brings it back: that is a toggle too.
@(test)
a_value_set_on_a_folded_pane_toggles :: proc(t: ^testing.T) {
	r := Folding{p = {collapsed = true}}
	s := session.start(t, {size = WINDOW, user = &r, build = folding_build})
	ui.a11y_capture(s.state, true)
	session.frames(s, 2)
	ui.a11y_inject(s.state, {action = .Set_Value, data = .Numeric_Value, num = PANE_SIZE, target = u64(session.get(s, "split").key)})
	session.frames(s, 2)
	testing.expect(t, !r.p.collapsed, "open")
	testing.expect_value(t, r.toggles, 1)
}

// A stepper held with the pointer off its button waits, as a scroll bar's arrow does.
@(test)
a_stepper_held_off_its_button_waits :: proc(t: ^testing.T) {
	Step :: struct { v: int }
	r: Step
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Step)(s.user)
		ui.stepper("###st", &r.v, 0, 1000)
	}})
	at := session.center(session.get(s, "inc"))
	session.press(s, at)
	session.move(s, at + {0, ROW_HEIGHT * 4})
	v := r.v
	session.advance(s, HOLD_MS)
	testing.expect_value(t, r.v, v)
	session.release(s, at + {0, ROW_HEIGHT * 4})
}

@(private = "file")
Menus :: struct {
	key, other: ui.Key,
	sub_on:   bool,
	open_other: bool,
	stray:    int,   // rows of the old menu found in the new one
	field:    ui.Text_Field,
}

@(private = "file")
menu_build :: proc(s: ^session.Session) {
	r := (^Menus)(s.user)
	ui.button("Page###page")
	if ui.ctx_menu(r.key) {
		if ui.menu_submenu("Sub###sub", enabled = r.sub_on) { ui.menu_item("Inner###inner") }
		if ui.menu_item("Plain###plain", enabled = false).clicked {}
		if ui.menu_item("Second###second", keep_open = true).clicked { ui.ctx_menu_open(r.other, {200, 200}) }
		ui.menu_item("After###after")
	}
	if ui.ctx_menu_is_open(r.other) { r.stray = max(r.stray, len(s.state.menus[0].items)) }
	if ui.ctx_menu(r.other) { ui.menu_item("Other###other") }
	ui.next({width = ui.px(FIELD_WIDTH)})
	ui.line_edit("###f", &r.field)
}

@(private = "file")
menus_start :: proc(t: ^testing.T, r: ^Menus) -> ^session.Session {
	r.key, r.other = ui.key_from_string(0, "m"), ui.key_from_string(0, "o")
	r.sub_on = true
	s := session.start(t, {size = WINDOW, user = r, build = menu_build})
	return s
}

// The side buttons are buttons: a press of one outside closes the menu.
@(test)
a_side_button_outside_closes_a_menu :: proc(t: ^testing.T) {
	r: Menus
	s := menus_start(t, &r)
	ui.ctx_menu_open(r.key, {200, 200})
	session.frames(s, SETTLE_FRAMES)
	session.click_at(s, {500, 450}, .Back)
	testing.expect(t, !ui.ctx_menu_any_open(), "closed")
}

// Right on a submenu that turned disabled opens nothing, then or later.
@(test)
open_sub_ends_with_its_frame :: proc(t: ^testing.T) {
	r: Menus
	s := menus_start(t, &r)
	ui.ctx_menu_open(r.key, {200, 200}, from_keyboard = true)
	session.frames(s, SETTLE_FRAMES)
	r.sub_on = false
	session.event(s, {kind = .Key_Press, key = .Right})
	session.frame(s)
	r.sub_on = true
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, ui.menu_depth(), 1)
}

// A menu opened in a menu's block opens when the block ends: the rows after it are the old menu's, and the new one has only its own.
@(test)
a_menu_opened_in_a_block_opens_after_it :: proc(t: ^testing.T) {
	r: Menus
	s := menus_start(t, &r)
	ui.ctx_menu_open(r.key, {200, 200})
	session.frames(s, SETTLE_FRAMES)
	row, found := ui.menu_item_rect(0, 2)
	testing.expect(t, found, "the row is there")
	session.click_at(s, (row.min + row.max) * 0.5)
	session.frames(s, SETTLE_FRAMES)
	testing.expect(t, ui.ctx_menu_is_open(r.other), "the other menu is open")
	testing.expect(t, r.stray <= 1, "the rows of the old block stayed in it")
}

// A press on a row of a menu leaves the focus where it was: a field's context menu gives it back its keyboard.
@(test)
a_press_in_a_menu_keeps_the_focus :: proc(t: ^testing.T) {
	r: Menus
	defer ui.field_destroy(&r.field)
	s := menus_start(t, &r)
	session.click(s, "f")
	want := s.state.focus_key
	ui.ctx_menu_open(r.key, {200, 200})
	session.frames(s, SETTLE_FRAMES)
	row, found := ui.menu_item_rect(0, 3)
	testing.expect(t, found, "the row is there")
	session.click_at(s, (row.min + row.max) * 0.5)
	testing.expect(t, !ui.ctx_menu_any_open(), "chosen")
	testing.expect_value(t, s.state.focus_key, want)
}

// A menu opened from the keyboard selects its first item once. A pointer that moves onto a disabled row then leaves nothing selected.
@(test)
from_keyboard_selects_once :: proc(t: ^testing.T) {
	r: Menus
	s := menus_start(t, &r)
	ui.ctx_menu_open(r.key, {200, 200}, from_keyboard = true)
	session.frames(s, SETTLE_FRAMES)
	_, sel, _ := ui.menu_rect(0)
	testing.expect_value(t, sel, 0)
	rect, _ := ui.menu_item_rect(0, 1)
	session.move(s, (rect.min + rect.max) * 0.5)
	session.frames(s, SETTLE_FRAMES)
	_, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, -1)
}

// Type, move the caret, type: two undo steps, in a field and in a text area.
@(test)
a_caret_move_ends_an_undo_step :: proc(t: ^testing.T) {
	Texts :: struct { f: ui.Text_Field, a: ui.Text_Area }
	r: Texts
	defer { ui.field_destroy(&r.f); ui.area_destroy(&r.a) }
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Texts)(s.user)
		ui.next({width = ui.px(FIELD_WIDTH)})
		ui.line_edit("###f", &r.f)
		ui.next({width = ui.px(AREA_SIZE), height = ui.px(AREA_SIZE / 2)})
		ui.text_edit("###a", &r.a)
	}})
	session.click(s, "f")
	session.type_text(s, "ab")
	session.key(s, .Left)
	session.type_text(s, "c")
	testing.expect_value(t, ui.field_string(&r.f), "acb")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.field_string(&r.f), "ab")

	session.click(s, "a")
	session.type_text(s, "ab")
	session.key(s, .Left)
	session.type_text(s, "c")
	testing.expect_value(t, ui.area_string(&r.a), "acb")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.area_string(&r.a), "ab")
}

// Arrow keys show the caret of a field at once: it is not caught in the off half of its blink.
@(test)
a_caret_moved_by_a_key_shows :: proc(t: ^testing.T) {
	Texts :: struct { f: ui.Text_Field }
	r: Texts
	defer ui.field_destroy(&r.f)
	ui.field_set(&r.f, "hello")
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Texts)(s.user)
		ui.next({width = ui.px(FIELD_WIDTH)})
		ui.line_edit("###f", &r.f)
	}})
	session.click(s, "f")
	session.advance(s, LONG_TIME_MS)
	session.key(s, .Left)
	testing.expect_value(t, r.f.edited_ms, s.clock - session.FRAME_MS)
}

// Select all, then Up: the column of the last Up or Down is over; the move starts from where the caret is.
@(test)
the_column_ends_with_any_other_move :: proc(t: ^testing.T) {
	Texts :: struct { a: ui.Text_Area }
	r: Texts
	defer ui.area_destroy(&r.a)
	ui.area_set(&r.a, "aaaaaaaa\nb\ncccccccc")
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Texts)(s.user)
		ui.next({width = ui.px(AREA_SIZE), height = ui.px(AREA_SIZE)})
		ui.text_edit("###a", &r.a)
	}})
	session.click(s, "a")
	session.key(s, .Home, {.Ctrl})
	session.key(s, .End)
	session.key(s, .Down)
	testing.expect(t, r.a.has_pref, "the column is kept")
	session.key(s, .A, {.Ctrl})
	testing.expect(t, !r.a.has_pref, "select all ended it")
	session.key(s, .Down)
	session.key(s, .Z, {.Ctrl})
	session.type_text(s, "x")
	session.key(s, .Z, {.Ctrl})
	testing.expect(t, !r.a.has_pref, "undo ended it")
}

// The rects of an editor that went are gone with it.
@(test)
caret_rects_end_with_the_editor :: proc(t: ^testing.T) {
	Texts :: struct { a: ui.Text_Area, show: bool }
	r := Texts{show = true}
	defer ui.area_destroy(&r.a)
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Texts)(s.user)
		if !r.show { return }
		ui.next({width = ui.px(AREA_SIZE), height = ui.px(AREA_SIZE)})
		ui.text_edit("###a", &r.a)
	}})
	session.frames(s, 2)
	_, _, ok := ui.text_edit_caret_rect(&r.a)
	testing.expect(t, ok, "known while it is drawn")
	r.show = false
	session.frames(s, 2)
	_, _, ok = ui.text_edit_caret_rect(&r.a)
	testing.expect(t, !ok, "gone with it")
}

// A click of a screen reader on a field is no pointer: the caret stays where it was.
@(test)
a_screen_readers_click_leaves_the_caret :: proc(t: ^testing.T) {
	Texts :: struct { f: ui.Text_Field }
	r: Texts
	defer ui.field_destroy(&r.f)
	ui.field_set(&r.f, "hello world")
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Texts)(s.user)
		ui.next({width = ui.px(FIELD_WIDTH)})
		ui.line_edit("###f", &r.f)
		ui.button("Far###far")
	}})
	ui.a11y_capture(s.state, true)
	session.frames(s, 2)
	session.move(s, session.center(session.get(s, "far")))
	ui.a11y_inject(s.state, {action = .Click, target = u64(session.get(s, "f").key)})
	session.frames(s, 2)
	testing.expect_value(t, r.f.cursor, len("hello world"))
}

@(private = "file")
Rows :: struct { st: ui.List_State, count: int, changes: int }

@(private = "file")
rows_build :: proc(s: ^session.Session) {
	r := (^Rows)(s.user)
	ui.next({width = ui.px(LIST_SIZE), height = ui.px(LIST_SIZE)})
	if ui.list("###l", &r.st) {
		for i in 0 ..< r.count {
			ui.next({height = ui.px(ROW_HEIGHT)})
			ui.list_row(&r.st, i, "row")
		}
	}
	if r.st.changed { r.changes += 1 }
}

// Rows gone from under the active row move it: that is a change.
@(test)
a_row_clamped_is_a_change :: proc(t: ^testing.T) {
	r := Rows{count = 5}
	defer ui.list_state_destroy(&r.st)
	s := session.start(t, {size = WINDOW, user = &r, build = rows_build})
	ui.list_select(&r.st, 4)
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, r.changes, 0)
	r.count = 2
	session.frames(s, SETTLE_FRAMES)
	testing.expect_value(t, r.st.sel, 1)
	testing.expect_value(t, r.changes, 1)
}

// Escape on an empty list asks to bring no row into view: nothing stays armed.
@(test)
no_row_is_nothing_to_reveal :: proc(t: ^testing.T) {
	r: Rows
	defer ui.list_state_destroy(&r.st)
	s := session.start(t, {size = WINDOW, user = &r, build = rows_build})
	ui.set_focus(r.st.key)
	session.frames(s, 2)
	session.key(s, .Escape)
	testing.expect_value(t, r.st.reveal, 0)
}

// A row asked for before the list's first build comes into view with nothing else happening.
@(test)
a_row_selected_before_the_first_build_shows :: proc(t: ^testing.T) {
	r := Rows{count = ROWS}
	defer ui.list_state_destroy(&r.st)
	ui.list_select(&r.st, ROWS - 1)
	s := session.start(t, {size = WINDOW, user = &r, build = rows_build})
	testing.expect(t, ui.needs_frame(s.state), "its first build asks for the frame that shows it")
	session.wait_idle(s)
	testing.expect(t, session.get(s, "l").view_target.y > 0, "the view went to it")
}

@(private = "file")
Virtual :: struct { st: ui.Virtual_List, ids: [ROWS]u64, zero: bool, show: bool }

@(private = "file")
virtual_build :: proc(s: ^session.Session) {
	r := (^Virtual)(s.user)
	if !r.show { return }
	ui.next({width = ui.px(LIST_SIZE), height = ui.px(LIST_SIZE)})
	if rows, ok := ui.vlist("###v", &r.st, r.ids[:]); ok {
		for i in rows.first ..< rows.last {
			ui.next({height = ui.px(r.zero ? 0 : ROW_HEIGHT)})
			ui.list_row(&r.st, i, "row")
		}
	}
}

// A view asked for while the list has no box is where the list is when it comes.
@(test)
vlist_scroll_to_waits_for_its_box :: proc(t: ^testing.T) {
	r: Virtual
	for &id, i in r.ids { id = u64(i + 1) }
	defer ui.vlist_destroy(&r.st)
	s := session.start(t, {size = WINDOW, user = &r, build = virtual_build})
	ui.vlist_scroll_to(&r.st, VIEW_FAR)
	r.show = true
	session.frames(s, SETTLE_FRAMES)
	testing.expect(t, session.get(s, "v").view_target.y > 0, "the view went there (the rows measured since keep it on its row)")
}

// Rows of no height are never measured: the view does not wait for them, build after build.
@(test)
a_row_of_no_height_is_not_waited_for :: proc(t: ^testing.T) {
	r := Virtual{zero = true, show = true}
	for &id, i in r.ids { id = u64(i + 1) }
	defer ui.vlist_destroy(&r.st)
	s := session.start(t, {size = WINDOW, user = &r, build = virtual_build})
	ui.list_select(&r.st.list, 1)
	session.frames(s, FEW_BUILDS)
	testing.expect(t, !ui.needs_frame(s.state), "it settled")
}

// A toast that only stands asks for no frame: a wake at its fade.
@(test)
a_toast_that_stands_sleeps :: proc(t: ^testing.T) {
	Toasts :: struct { said: bool }
	r: Toasts
	s := session.start(t, {size = WINDOW, user = &r, animations = true, build = proc(s: ^session.Session) {
		r := (^Toasts)(s.user)
		if !r.said { r.said = true; ui.toast(.Info, "Hello") }
		ui.toasts_build()
	}})
	session.advance(s, LONG_TIME_MS)
	testing.expect(t, !ui.needs_frame(s.state), "no frames while nothing moves")
	testing.expect(t, ui.wake_ms(s.state) > 0, "a wake for its fade")
}

// An area given for one frame is that frame's, whether toasts_build ran or not.
@(test)
a_toast_area_lasts_a_frame :: proc(t: ^testing.T) {
	Toasts :: struct { set: bool }
	r := Toasts{set = true}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Toasts)(s.user)
		if r.set { ui.set_toast_area({{0, 0}, {10, 10}}) }
	}})
	r.set = false
	session.frames(s, 2)
	testing.expect(t, !s.state.toast_area_set, "gone with the frame")
}

// What a box of the last build held in its arena is gone at the next one: a look at it finds nothing, not freed memory.
@(test)
a_box_of_the_last_build_holds_no_text :: proc(t: ^testing.T) {
	Seen :: struct { text: string, name: string, key: ui.Key }
	r: Seen
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Seen)(s.user)
		if r.key != 0 {
			b := ui.box_from_key(r.key)
			r.text, r.name = b.text, b.name
		}
		ui.label("Some words###words")
	}})
	r.key = session.get(s, "words").key
	r.text, r.name = "not read", "not read"
	session.frame(s)
	testing.expect_value(t, r.text, "")
	testing.expect_value(t, r.name, "")
}

// An arrow and a Tab read in one frame: both move the focus.
@(test)
keys_of_one_frame_all_count :: proc(t: ^testing.T) {
	Two :: struct { x: int }
	r: Two
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		if ui.row() {
			ui.button("A###a")
			ui.button("B###b")
			ui.button("C###c")
		}
	}})
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "a")
	session.event(s, {kind = .Key_Press, key = .Right})
	session.event(s, {kind = .Key_Press, key = .Tab})
	session.frames(s, 2)
	testing.expect_value(t, session.focused_name(s), "c")
}

// A modifier let go during a drag is not held any more.
@(test)
the_modifiers_follow_their_release :: proc(t: ^testing.T) {
	Mods :: struct { sig: ui.Signal }
	r: Mods
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Mods)(s.user)
		r.sig = ui.button("Hold###hold")
	}})
	session.event(s, {kind = .Key_Press, key = .Shift, mods = {.Shift}})
	session.frame(s)
	testing.expect(t, .Shift in r.sig.mods, "held")
	session.event(s, {kind = .Key_Release, key = .Shift})
	session.frame(s)
	testing.expect_value(t, r.sig.mods, platform.Modifiers{})
}
