// Keyboard behaviour of menus, lists and line edits, without a window: synthetic input events, builds, assertions on
// the results and on the laid-out boxes. The ui state of a build is global: one test thread.
//   odin test tests/keyboard -vet -define:ODIN_TEST_THREADS=1
package keyboard_test

import "core:sync"
import "core:fmt"
import "core:testing"
import "../../src/font"
import "../../src/platform"
import "../../src/ui"

// A focused field's next wake right after an edit: the caret's flip (530 ms) and the margin of a wake, at most: the real clock goes on between the edit and the look.
CARET_FLIP_WAKE_MS :: 535

caret_wake_due :: proc(ms: i64) -> bool { return ms > 0 && ms <= CARET_FLIP_WAKE_MS }

WINDOW :: ui.Vec2{800, 600}

Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	clip:  string,
	base_font: font.Font_Id,
}

@(private = "file")
the_clip: ^string

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	icons, iok := font.load_embedded(&f.fonts, ui.ICON_FONT_DATA)
	if !iok { return false }
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	ui.init(&f.s, &f.fonts, &f.theme)
	f.s.icon_font = icons
	f.base_font = id
	the_clip = &f.clip
	return true
}

@(private = "file")
close :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
	delete(f.clip)
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event, body: proc(f: ^Fx, user: rawptr), user: rawptr, window := WINDOW) {
	ui.begin_build(&f.s, {
		window_size = window, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
		clipboard_get = proc() -> string { return the_clip^ },
		clipboard_set = proc(t: string) { delete(the_clip^); the_clip^ = clone(t) },
	})
	body(f, user)
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file")
clone :: proc(s: string) -> string {
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}

@(private = "file")
key :: proc(k: platform.Key, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Key_Press, key = k, mods = mods} }

@(private = "file")
typed :: proc(r: rune) -> platform.Event { return {kind = .Text, text = r} }

////////////////////////////////
// Menus

Menu_Run :: struct {
	key:     string,
	chosen:  string,
	sub_open: bool,
}

@(private = "file")
build_menu :: proc(f: ^Fx, user: rawptr) {
	r := (^Menu_Run)(user)
	if ui.menu(r.key) {
		if ui.menu_item("Back", "Alt+Left", disabled = true).clicked { r.chosen = "back" }
		if ui.menu_item("Forward", "Alt+Right").clicked { r.chosen = "forward" }
		ui.menu_separator()
		if ui.menu_item("Reload", "F5").clicked { r.chosen = "reload" }
		r.sub_open = false
		if ui.menu_submenu("Search with") {
			r.sub_open = true
			if ui.menu_item("Alpha").clicked { r.chosen = "alpha" }
			if ui.menu_item("Beta").clicked { r.chosen = "beta" }
		}
		if ui.menu_item("Save as...", disabled = true).clicked { r.chosen = "save" }
		if ui.menu_item("View source", "Ctrl+U").clicked { r.chosen = "source" }
	}
}

@(private = "file")
nothing :: proc(f: ^Fx, user: rawptr) {}

// These menus open without search (search = false): the classic menu, whose typed letter selects the next row that
// starts with it and which turns to the other side of its point at a window's edge. A menu that searches (the default
// of menu_open) has its tests in tests/scenarios/widgets_test.odin.

// The tests drive the toolkit's global UI state: the test runner's threads take turns (no -define:ODIN_TEST_THREADS=1
// needed).
@(private = "file")
ui_state_lock: sync.Mutex

@(test)
menu_keyboard :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Menu_Run{key = "menu_1234"}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Menu_Run)(user).key, ui.Vec2{100, 100}, from_keyboard = true, search = false) }, &r)
	frame(&f, nil, build_menu, &r)
	frame(&f, nil, build_menu, &r)
	_, sel, ok := ui.menu_rect(0)
	testing.expect(t, ok, "the menu is laid out")
	testing.expect_value(t, sel, 1)   // "Back" is disabled: the first enabled item starts selected

	// Down skips the separator; End goes to the last enabled item; Up from the first one wraps over the disabled ones
	frame(&f, {key(.Down)}, build_menu, &r)
	_, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, 2)
	frame(&f, {key(.End)}, build_menu, &r)
	_, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, 5)
	frame(&f, {key(.Up)}, build_menu, &r)
	_, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, 3)   // Save as... (4) is disabled
	frame(&f, {key(.Home)}, build_menu, &r)
	frame(&f, {key(.Up)}, build_menu, &r)
	_, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, 5)

	// a typed letter selects the next item starting with it
	frame(&f, {typed('r')}, build_menu, &r)
	_, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, 2)

	// Enter chooses and closes
	frame(&f, {key(.Return)}, build_menu, &r)
	testing.expect_value(t, r.chosen, "reload")
	testing.expect(t, !ui.menu_any_open(), "closed after choosing")
}

// A pointer that moves from an enabled row onto a disabled one leaves nothing selected: the disabled row gets no signal, and the
// row the pointer left used to stay selected.
@(test)
menu_pointer_over_a_disabled_row_selects_nothing :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Menu_Run{key = "menu_4321"}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Menu_Run)(user).key, ui.Vec2{100, 100}, from_keyboard = true, search = false) }, &r)
	for _ in 0 ..< 3 { frame(&f, nil, build_menu, &r) }
	rect, sel, ok := ui.menu_rect(0)
	testing.expect(t, ok)
	testing.expect_value(t, sel, 1)   // "Forward", the first enabled row, from the keyboard
	// the first row, "Back", is disabled
	over := platform.Event{kind = .Mouse_Move, pos = {rect.min.x + 30, rect.min.y + 15}}
	for _ in 0 ..< 3 { frame(&f, {over}, build_menu, &r); over.pos.x += 1 }
	_, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, -1)
}

Choose_Run :: struct {
	key, other:    string,
	open_after:    bool,   // the menu is still open right after the chosen item (the rest of the block is part of it)
	open_other:    bool,   // answer the click by opening another menu
	later_in_menu: int,    // items after the chosen one that were built as items of a menu
}

@(private = "file")
build_choose :: proc(f: ^Fx, user: rawptr) {
	r := (^Choose_Run)(user)
	r.later_in_menu = 0
	if ui.menu(r.key) {
		if ui.menu_item("A").clicked {
			r.open_after = ui.menu_any_open()
			if r.open_other { ui.menu_open(r.other, ui.Vec2{50, 50}, search = false) }
		}
		for label in ([?]string{"B", "C"}) {
			ui.menu_item(label)
			if ui.menu_depth() > 0 { r.later_in_menu += 1 }
		}
	}
	if ui.menu(r.other) { ui.menu_item("Other") }
}

// Choosing an item closes the menu when its block ends, not in the middle of it: the items after the chosen one are still
// built as menu items, and a menu opened in answer to the click is not closed with the first.
@(test)
menu_closes_at_the_end_of_its_block :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	for open_other in ([?]bool{false, true}) {
		f: Fx
		if !testing.expect(t, open(&f), "fonts") { return }
		r := Choose_Run{key = "menu_1234", other = "menu_5678", open_other = open_other}
		frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Choose_Run)(user).key, ui.Vec2{100, 100}, from_keyboard = true, search = false) }, &r)
		frame(&f, nil, build_choose, &r)
		frame(&f, nil, build_choose, &r)
		frame(&f, {key(.Return)}, build_choose, &r)
		testing.expect(t, r.open_after, "still open right after the chosen item")
		testing.expect_value(t, r.later_in_menu, 2)
		if open_other {
			testing.expect(t, ui.menu_is_open(r.other), "the menu opened by the click stays")
			testing.expect(t, !ui.menu_is_open(r.key))
		} else {
			testing.expect(t, !ui.menu_any_open(), "closed once the block ended")
		}
		close(&f)
	}
}

@(test)
menu_submenus :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Menu_Run{key = "menu_777"}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Menu_Run)(user).key, ui.Vec2{100, 100}, from_keyboard = true, search = false) }, &r)
	frame(&f, nil, build_menu, &r)
	frame(&f, {typed('s')}, build_menu, &r)   // "Search with" (Save as... is disabled)
	frame(&f, {key(.Right)}, build_menu, &r)
	frame(&f, nil, build_menu, &r)
	testing.expect(t, r.sub_open, "Right opens the submenu")
	testing.expect_value(t, ui.menu_depth(), 2)
	parent_r, _, _ := ui.menu_rect(0)
	sub_r, sub_sel, ok := ui.menu_rect(1)
	testing.expect(t, ok && sub_r.min.x >= parent_r.max.x - 4, "the submenu opens to the right")
	testing.expect_value(t, sub_sel, 0)
	frame(&f, {key(.Left)}, build_menu, &r)
	frame(&f, nil, build_menu, &r)
	testing.expect_value(t, ui.menu_depth(), 1)
	testing.expect(t, ui.menu_any_open(), "Left closes only the submenu")
	frame(&f, {key(.Return)}, build_menu, &r)
	frame(&f, nil, build_menu, &r)
	frame(&f, {key(.Down), key(.Return)}, build_menu, &r)
	testing.expect_value(t, r.chosen, "beta")
	testing.expect(t, !ui.menu_any_open(), "choosing in a submenu closes the whole menu")

	// Escape closes level by level
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Menu_Run)(user).key, ui.Vec2{100, 100}, from_keyboard = true, search = false) }, &r)
	frame(&f, nil, build_menu, &r)
	frame(&f, {typed('s'), key(.Return)}, build_menu, &r)
	frame(&f, nil, build_menu, &r)
	testing.expect_value(t, ui.menu_depth(), 2)
	frame(&f, {key(.Escape)}, build_menu, &r)
	frame(&f, nil, build_menu, &r)
	testing.expect_value(t, ui.menu_depth(), 1)
	frame(&f, {key(.Escape)}, build_menu, &r)
	testing.expect(t, !ui.menu_any_open(), "the second Escape closes the menu")
}

Nested_Run :: struct {
	key, nested:  string,
	open_at:      [2]f32,   // not zero: open the nested menu there in this frame
	row:          ^ui.Box,  // a plain row of the menu (not an item)
	chosen:       string,
}

@(private = "file")
build_nested :: proc(f: ^Fx, user: rawptr) {
	r := (^Nested_Run)(user)
	if ui.menu(r.key, 300) {
		ui.next({width = ui.px(300), height = ui.px(30)})
		r.row = ui.button("row", "A row").box
		ui.next({width = ui.px(300), height = ui.px(30)})
		ui.button("row2", "Another row")
		if r.open_at != {} { ui.menu_open(r.nested, r.open_at, nested = true, search = false); r.open_at = {} }
		if ui.menu(r.nested) {
			if ui.menu_item("Open").clicked { r.chosen = "open" }
			if ui.menu_item("Remove").clicked { r.chosen = "remove" }
		}
	}
}

// A menu opened from inside an open one (a row's context menu in a drop-down panel): over it, the outer menu stays
// open; a press outside the nested menu but inside the outer one closes only the nested one; Escape closes the top
// level; choosing an item closes both.
@(test)
nested_menu_levels :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Nested_Run{key = "menu_a1", nested = "menu_a2"}
	reopen :: proc(f: ^Fx, r: ^Nested_Run) {
		r.open_at = {150, 120}
		frame(f, nil, build_nested, r)
		frame(f, nil, build_nested, r)
	}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Nested_Run)(user).key, ui.Vec2{100, 100}, search = false) }, &r)
	frame(&f, nil, build_nested, &r)
	frame(&f, nil, build_nested, &r)
	reopen(&f, &r)
	testing.expect_value(t, ui.menu_depth(), 2)
	outer, _, _ := ui.menu_rect(0)
	inner, _, ok := ui.menu_rect(1)
	testing.expect(t, ok && inner.min == {150, 120}, "the nested menu opens at its point")

	// a press on the outer menu's row, outside the nested one: only the nested one closes
	row := r.row.rect
	p := [2]f32{row.min.x + 10, (row.min.y + row.max.y) * 0.5}
	testing.expect(t, !(p.x >= inner.min.x && p.x < inner.max.x && p.y >= inner.min.y && p.y < inner.max.y), "the press point is outside the nested menu")
	frame(&f, {{kind = .Mouse_Press, button = .Left, pos = p}, {kind = .Mouse_Release, button = .Left, pos = p}}, build_nested, &r)
	frame(&f, nil, build_nested, &r)
	testing.expect_value(t, ui.menu_depth(), 1)
	testing.expect(t, ui.menu_is_open(r.key), "the outer menu stays open")

	// Escape closes the nested menu, then the outer one
	reopen(&f, &r)
	testing.expect_value(t, ui.menu_depth(), 2)
	frame(&f, {key(.Escape)}, build_nested, &r)
	frame(&f, nil, build_nested, &r)
	testing.expect_value(t, ui.menu_depth(), 1)
	frame(&f, {key(.Escape)}, build_nested, &r)
	testing.expect(t, !ui.menu_any_open(), "the second Escape closes the outer menu")

	// a press outside both closes both; choosing an item closes both
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Nested_Run)(user).key, ui.Vec2{100, 100}, search = false) }, &r)
	frame(&f, nil, build_nested, &r)
	reopen(&f, &r)
	frame(&f, {{kind = .Mouse_Press, button = .Left, pos = {outer.max.x + 100, 10}}}, build_nested, &r)
	testing.expect(t, !ui.menu_any_open(), "a press outside every level closes the menu")
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Nested_Run)(user).key, ui.Vec2{100, 100}, search = false) }, &r)
	frame(&f, nil, build_nested, &r)
	reopen(&f, &r)
	frame(&f, {key(.Down), key(.Down), key(.Return)}, build_nested, &r)
	testing.expect_value(t, r.chosen, "remove")
	testing.expect(t, !ui.menu_any_open(), "choosing in the nested menu closes the menu")
}

@(test)
menu_stays_on_screen :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Menu_Run{key = "menu_999"}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Menu_Run)(user).key, ui.Vec2{790, 590}, search = false) }, &r)
	for _ in 0 ..< 3 { frame(&f, nil, build_menu, &r) }
	rect, _, ok := ui.menu_rect(0)
	testing.expect(t, ok, "laid out")
	testing.expect(t, rect.min.x >= 0 && rect.max.x <= WINDOW.x && rect.min.y >= 0 && rect.max.y <= WINDOW.y, "inside the window")
	testing.expect(t, rect.max.x <= 791 && rect.max.y <= 591, "flipped to the other side of the point")

	// a press outside closes it
	frame(&f, {{kind = .Mouse_Press, button = .Left, pos = {10, 10}}, {kind = .Mouse_Release, button = .Left, pos = {10, 10}}}, build_menu, &r)
	testing.expect(t, !ui.menu_any_open(), "closed by a press outside")
	testing.expect_value(t, r.chosen, "")
}

// A long menu: rows "Row 0".."Row 38" and "Zebra" last.
Long_Run :: struct {
	key: string,
}

LONG_MENU_ROWS :: 40
LAST_ROW :: LONG_MENU_ROWS - 1

@(private = "file")
build_long :: proc(f: ^Fx, user: rawptr) {
	r := (^Long_Run)(user)
	if ui.menu(r.key) {
		for i in 0 ..< LONG_MENU_ROWS { ui.menu_item(i == LAST_ROW ? "Zebra###z" : fmt.tprintf("Row %d###r%d", i, i), "Ctrl+K") }
	}
}

// Row `idx` of the open menu is wholly in view.
@(private = "file")
row_shown :: proc(idx: int) -> bool {
	panel, _, _ := ui.menu_rect(0)
	a, ok := ui.menu_item_rect(0, idx)
	return ok && a.min.y >= panel.min.y && a.max.y <= panel.max.y
}

// Rows are Feel.menu_item_em tall (29 px for 15 px text), times the density: 22 px compact, 34 px at the roomiest (DENSITY_MAX).
@(test)
menu_rows_follow_the_density :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Long_Run{key = "menu_d1"}
	for c in ([?][2]f32{{1, 29}, {ui.DENSITY_COMPACT, 22}, {ui.DENSITY_MAX, 34}}) {
		ui.set_density(&f.s, c[0])
		frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Long_Run)(user).key, ui.Vec2{100, 100}, search = false) }, &r)
		for _ in 0 ..< 2 { frame(&f, nil, build_long, &r) }
		row, _ := ui.menu_item_rect(0, 0)
		testing.expect_value(t, row.max.y - row.min.y, c[1])
	}
	ui.set_density(&f.s, 1)
}

// A menu taller than the window is as tall as the window and scrolls: the keyboard's selection comes into view (Down to the
// last row, a typed letter of a hidden row, Home), the wheel scrolls it. A menu that then fits a taller window is whole.
@(test)
menu_taller_than_the_window_scrolls :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Long_Run{key = "menu_d2"}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Long_Run)(user).key, ui.Vec2{100, 100}, from_keyboard = true, search = false) }, &r)
	for _ in 0 ..< 3 { frame(&f, nil, build_long, &r) }
	panel, sel, ok := ui.menu_rect(0)
	testing.expect(t, ok, "laid out")
	testing.expect_value(t, sel, 0)
	testing.expect_value(t, panel.min.y, 0)
	testing.expect_value(t, panel.max.y, WINDOW.y)
	testing.expect(t, row_shown(0) && !row_shown(LAST_ROW), "the last row is out of view")

	downs: [LONG_MENU_ROWS - 1]platform.Event
	for &e in downs { e = key(.Down) }
	frame(&f, downs[:], build_long, &r)
	frame(&f, nil, build_long, &r)
	panel, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, LAST_ROW)
	testing.expect(t, row_shown(LAST_ROW), "Down to the last row scrolls it into view")

	frame(&f, {key(.Home)}, build_long, &r)
	frame(&f, nil, build_long, &r)
	panel, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, 0)
	testing.expect(t, row_shown(0) && !row_shown(LAST_ROW), "Home scrolls back to the top")
	frame(&f, {typed('z')}, build_long, &r)
	frame(&f, nil, build_long, &r)
	panel, sel, _ = ui.menu_rect(0)
	testing.expect_value(t, sel, LAST_ROW)
	testing.expect(t, row_shown(LAST_ROW), "type-ahead reaches a hidden row and shows it")

	mid := [2]f32{(panel.min.x + panel.max.x) * 0.5, (panel.min.y + panel.max.y) * 0.5}
	last, _ := ui.menu_item_rect(0, LAST_ROW)
	before := last.min.y
	frame(&f, {{kind = .Mouse_Move, pos = mid}, {kind = .Scroll, pos = mid, delta = {0, -3}}}, build_long, &r)
	frame(&f, nil, build_long, &r)
	last, _ = ui.menu_item_rect(0, LAST_ROW)
	testing.expectf(t, last.min.y > before, "the wheel scrolls the menu: %v -> %v", before, last.min.y)
	testing.expect(t, ui.menu_any_open(), "still open")

	tall := [2]f32{800, 1400}
	for _ in 0 ..< 3 { frame(&f, nil, build_long, &r, tall) }
	panel, _, _ = ui.menu_rect(0)
	testing.expect(t, panel.max.y - panel.min.y < tall.y && row_shown(0) && row_shown(LAST_ROW), "a window tall enough shows it whole")
}

Wheel_Run :: struct {
	key:  string,
	long: bool,   // the long menu (it scrolls), else the short one (it fits)
}

// A scroller under the open menu, which is built after it (over it).
@(private = "file")
build_menu_over_scroller :: proc(f: ^Fx, user: rawptr) {
	r := (^Wheel_Run)(user)
	build_scroller(f, nil)
	if r.long { lr := Long_Run{key = r.key}; build_long(f, &lr) } else { mr := Menu_Run{key = r.key}; build_menu(f, &mr) }
}

// A wheel over an open menu is the menu's: one that scrolls scrolls, one that fits does not move, and the scroller under
// either gets nothing; both report the wheel consumed and the point on a menu. With the menu closed, the scroller scrolls.
@(test)
menu_takes_the_wheel_over_it :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	at :: [2]f32{120, 100}   // on the scroller, and on the menu opened there
	notch :: proc(f: ^Fx, r: ^Wheel_Run) {
		frame(f, {{kind = .Mouse_Move, pos = at}, {kind = .Scroll, pos = at, delta = {0, 3}}, {kind = .Scroll, pos = at, delta = {2, 0}}}, build_menu_over_scroller, r)
	}
	for long in ([?]bool{true, false}) {
		r := Wheel_Run{key = "menu_d4", long = long}
		frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.menu_open((^Wheel_Run)(user).key, ui.Vec2{100, 50}, search = false) }, &r)
		for _ in 0 ..< 3 { frame(&f, nil, build_menu_over_scroller, &r) }
		testing.expect(t, ui.menu_at(at), "the point is on the menu")
		first, _ := ui.menu_item_rect(0, 0)
		notch(&f, &r)
		testing.expect(t, ui.wheel_consumed(), "the wheel is consumed")
		frame(&f, nil, build_menu_over_scroller, &r)
		moved, _ := ui.menu_item_rect(0, 0)
		testing.expectf(t, (moved.min.y < first.min.y) == long, "the menu scrolls only when it is taller than the window (long %v): %v -> %v", long, first.min.y, moved.min.y)
		testing.expect_value(t, moved.min.x, first.min.x)
		testing.expect_value(t, the_scroller.view_target, [2]f32{})
		ui.menu_close()
		frame(&f, nil, build_menu_over_scroller, &r)
		testing.expect(t, !ui.menu_at(at), "no menu there once closed")
		notch(&f, &r)
		testing.expect(t, ui.wheel_consumed(), "the scroller takes it")
		testing.expect(t, the_scroller.view_target.y > 0, "with the menu closed, the scroller scrolls")
		the_scroller.view_target, the_scroller.view_off = {}, {}
	}
}

// Under an anchor near the bottom, a menu opens above it; one with room on neither side shifts up to stay whole; a window
// made shorter while it is open places it again.
@(test)
menu_near_the_bottom_flips_or_shifts :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Menu_Run{key = "menu_d3"}
	@(static) anchor: ui.Rect
	anchor = {{100, 550}, {140, 580}}
	open_under :: proc(f: ^Fx, user: rawptr) { ui.menu_open((^Menu_Run)(user).key, anchor, 0, search = false) }
	frame(&f, nil, open_under, &r)
	for _ in 0 ..< 3 { frame(&f, nil, build_menu, &r) }
	rect, _, ok := ui.menu_rect(0)
	testing.expect(t, ok, "laid out")
	testing.expectf(t, rect.max.y <= anchor.min.y && rect.min.y >= 0, "above the anchor: %v", rect)

	short := [2]f32{800, 260}
	anchor = {{100, 100}, {140, 130}}
	frame(&f, nil, open_under, &r, short)
	for _ in 0 ..< 3 { frame(&f, nil, build_menu, &r, short) }
	rect, _, _ = ui.menu_rect(0)
	h := rect.max.y - rect.min.y
	testing.expectf(t, h < short.y && rect.max.y <= short.y && rect.min.y > 0 && rect.min.y < anchor.max.y, "shifted up, whole: %v", rect)

	shorter := [2]f32{800, h - 40}
	for _ in 0 ..< 3 { frame(&f, nil, build_menu, &r, shorter) }
	rect, _, _ = ui.menu_rect(0)
	testing.expectf(t, rect.min.y == 0 && rect.max.y == shorter.y, "capped at the shorter window: %v", rect)
}

////////////////////////////////
// Lists

List_Run :: struct {
	st:    ui.List_State,
	names: []string,
}

@(private = "file")
build_list :: proc(f: ^Fx, user: rawptr) {
	r := (^List_Run)(user)
	ui.next({width = ui.px(300), height = ui.px(150)})
	if ui.list("###l", &r.st) {
		for name, i in r.names {
			ui.next({height = ui.px(30)})
			row := ui.list_row(&r.st, i, name, selectable = name[0] != '#')
			if ui.parent(row.box) {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(name)
			}
		}
	}
}

@(test)
list_keyboard :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	names := []string{"# group", "apple###a", "apricot###b", "banana###c", "# other", "blueberry###d", "cherry###e", "citron###f", "date###g", "elder###h"}
	r := List_Run{st = {sel = -1}, names = names}
	defer ui.list_state_destroy(&r.st)
	frame(&f, nil, build_list, &r)
	ui.set_focus(r.st.key)
	frame(&f, nil, build_list, &r)
	frame(&f, {key(.Down)}, build_list, &r)
	testing.expect_value(t, r.st.sel, 1)   // the header row is skipped
	frame(&f, {key(.Down), key(.Down), key(.Down)}, build_list, &r)
	testing.expect_value(t, r.st.sel, 5)   // every key of the frame counts; "# other" is skipped
	frame(&f, {key(.End)}, build_list, &r)
	testing.expect_value(t, r.st.sel, 9)
	for _ in 0 ..< 4 { frame(&f, nil, build_list, &r) }
	lb := ui.box_from_key(r.st.key)
	testing.expect(t, lb != nil && lb.view_target.y > 0, "the active row is scrolled into view")
	frame(&f, {key(.Home)}, build_list, &r)
	testing.expect_value(t, r.st.sel, 1)
	frame(&f, {key(.Page_Down)}, build_list, &r)
	testing.expect(t, r.st.sel > 2, "Page Down moves by a page")

	// type-ahead: "c" goes to cherry, "c" again to citron; "ba" spells banana
	frame(&f, {key(.Home)}, build_list, &r)
	frame(&f, {typed('c')}, build_list, &r)
	testing.expect_value(t, r.st.sel, 6)
	frame(&f, {typed('c')}, build_list, &r)
	testing.expect_value(t, r.st.sel, 7)
	r.st.typed_ms = -10000   // as if a while passed
	frame(&f, {typed('b'), typed('a')}, build_list, &r)
	testing.expect_value(t, r.st.sel, 3)

	// the active row is scrolled into view
	frame(&f, {key(.End)}, build_list, &r)
	for _ in 0 ..< 6 { frame(&f, nil, build_list, &r) }
	r.st.typed_ms = -10000
	frame(&f, {typed('a'), typed('p'), typed('r')}, build_list, &r)
	for _ in 0 ..< 6 { frame(&f, nil, build_list, &r) }
	testing.expect_value(t, r.st.sel, 2)
	{
		lb2 := ui.box_from_key(r.st.key)
		row := ui.box_from_key(ui.key_from_string(r.st.key, "###lrow_2"))
		testing.expect(t, row != nil && lb2 != nil && row.rect.min.y >= lb2.rect.min.y - 0.5 && row.rect.max.y <= lb2.rect.max.y + 0.5, "apricot is visible")
	}

	frame(&f, {key(.Return)}, build_list, &r)
	testing.expect(t, r.st.activated, "Enter activates the row")
	frame(&f, {key(.Escape)}, build_list, &r)
	testing.expect(t, r.st.cancelled, "Escape cancels")
}

////////////////////////////////
// Line edit history and wrapped text

Edit_Run :: struct { field: ui.Line_Edit }

@(private = "file")
build_edit :: proc(f: ^Fx, user: rawptr) {
	r := (^Edit_Run)(user)
	ui.next({width = ui.px(300), height = ui.px(30)})
	ui.line_edit("###e", &r.field)
}

// A window that is not the user's (Build_Params.inactive: an application with several windows) shows no caret in its
// focused field and asks for no wake to blink it; the field keeps the focus and comes back blinking with the window.
@(test)
line_edit_caret_only_in_the_users_window :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Edit_Run
	defer ui.line_edit_destroy(&r.field)
	frame(&f, nil, build_edit, &r)
	k := ui.key_from_string(ui.key_from_string(0, "root"), "###e")
	ui.set_focus(k)
	frame(&f, {typed('a')}, build_edit, &r)
	testing.expectf(t, caret_wake_due(i64(ui.wake_ms(&f.s))), "the caret's flip wakes the loop (%d ms)", ui.wake_ms(&f.s))
	for inactive in ([2]bool{true, false}) {
		ui.begin_build(&f.s, {
			window_size = WINDOW, dt = 1.0 / 60, dpi_scale = 1, inactive = inactive,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
		})
		testing.expect_value(t, ui.inactive(), inactive)
		build_edit(&f, &r)
		ui.end_build()
		free_all(context.temp_allocator)
		if inactive { testing.expect_value(t, ui.wake_ms(&f.s), 0) } else { testing.expectf(t, caret_wake_due(i64(ui.wake_ms(&f.s))), "the caret's flip wakes the loop again (%d ms)", ui.wake_ms(&f.s)) }
		testing.expect_value(t, ui.focus_key(), k)
	}
}

@(test)
line_edit_history :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Edit_Run
	defer ui.line_edit_destroy(&r.field)
	frame(&f, nil, build_edit, &r)
	ui.set_focus(ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###e")).key)
	frame(&f, {typed('a'), typed('b'), typed('c')}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "abc")
	frame(&f, {key(.A, {.Ctrl}), key(.X, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "")
	testing.expect_value(t, f.clip, "abc")
	frame(&f, {key(.Z, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "abc")
	frame(&f, {key(.Z, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "")   // the typing was one step
	frame(&f, {key(.Y, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "abc")
	frame(&f, {key(.End), key(.V, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "abc")   // (asked: the text comes in the next build)
	frame(&f, nil, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "abcabc")
	testing.expect(t, ui.line_edit_can_undo(&r.field), "paste is undoable")
}

@(private = "file")
build_secret :: proc(f: ^Fx, user: rawptr) {
	r := (^Edit_Run)(user)
	ui.next({width = ui.px(300), height = ui.px(30)})
	ui.line_edit("###e", &r.field, {kind = .Secret})
}

// A secret field takes what is typed, is never copied or cut, and its caret moves by characters (not by the bytes of the
// bullets it shows).
@(test)
line_edit_secret :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Edit_Run
	defer ui.line_edit_destroy(&r.field)
	frame(&f, nil, build_secret, &r)
	ui.set_focus(ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###e")).key)
	frame(&f, {typed('p'), typed('é'), typed('w')}, build_secret, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "péw")
	f.clip = ""
	frame(&f, {key(.A, {.Ctrl}), key(.C, {.Ctrl}), key(.X, {.Ctrl})}, build_secret, &r)
	testing.expect_value(t, f.clip, "")
	testing.expect_value(t, ui.line_edit_string(&r.field), "péw")   // not cut
	frame(&f, {key(.End)}, build_secret, &r)   // (one key a frame: a frame applies its keys in the widget's order)
	frame(&f, {key(.Left)}, build_secret, &r)
	frame(&f, {key(.Backspace)}, build_secret, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "pw")
}

// Arrows, Backspace and Delete work on grapheme clusters: an emoji family (5 code points), a letter and its combining
// mark, a flag (2 regional indicators) are each one step.
@(test)
line_edit_clusters :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Edit_Run
	defer ui.line_edit_destroy(&r.field)
	FAMILY :: "\U0001F468\u200D\U0001F469\u200D\U0001F467"
	frame(&f, nil, build_edit, &r)
	ui.set_focus(ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###e")).key)
	events := make([dynamic]platform.Event, context.temp_allocator)
	for c in "a" + FAMILY + "e\u0301\U0001F1EB\U0001F1F7" { append(&events, typed(c)) }
	frame(&f, events[:], build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "a" + FAMILY + "e\u0301\U0001F1EB\U0001F1F7")
	frame(&f, {key(.Backspace)}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "a" + FAMILY + "e\u0301")
	frame(&f, {key(.Backspace)}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "a" + FAMILY)
	frame(&f, {key(.Backspace)}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "a")
	// the arrows step over a family in one press, and Delete takes it whole
	clear(&events)
	for c in FAMILY + "y" { append(&events, typed(c)) }
	frame(&f, events[:], build_edit, &r)
	frame(&f, {key(.Left)}, build_edit, &r)
	frame(&f, {key(.Left)}, build_edit, &r)
	frame(&f, {key(.Delete)}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "ay")
	frame(&f, {key(.Right)}, build_edit, &r)
	frame(&f, {key(.Backspace)}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "a")
}

@(private = "file")
build_para :: proc(f: ^Fx, user: rawptr) {
	ui.next({width = ui.px(160)})
	ui.paragraph("A description long enough to need several lines at this width.###p")
}

@(test)
paragraph_wraps :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	frame(&f, nil, build_para, nil)
	b := ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###p"))
	testing.expect(t, b != nil, "built")
	m := font.metrics(&f.fonts, f.base_font, 15)
	testing.expect(t, b.size.y >= 3 * m.line_height, "several lines tall")
	text := "A description long enough to need several lines at this width."
	lines := ui.wrap_lines(f.base_font, 15, text, 160 - 12)
	testing.expect(t, len(lines) >= 3, "wrapped")
	for l in lines { testing.expect(t, font.text_width(&f.fonts, f.base_font, 15, text[l[0]:l[1]]) <= 160 - 12 + 1, "each line fits") }
}

@(private = "file")
build_find :: proc(f: ^Fx, user: rawptr) {
	ui.find("fox", 0)
	ui.next({width = ui.px(300)})
	ui.label("The Fox and the fox###a")
	runs := []ui.Rich_Run{{text = "a quick "}, {text = "fo", bold = true}, {text = "x jumps, FOX"}}
	ui.next({width = ui.px(300)})
	ui.rich_paragraph("###r", runs)
	ui.next({width = ui.px(300)})
	ui.label("no match here###b")
}

// Find in page: occurrences in labels and rich paragraphs, case ignored, a match across runs, in reading order, each
// with a rectangle inside its box.
@(test)
find_in_page :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	for _ in 0 ..< 2 { frame(f, nil, build_find, nil) }
	testing.expect_value(t, ui.find_count(), 4)
	ms := ui.find_matches()
	a := ui.box_from_key(ms[0].box)
	r := ui.box_from_key(ms[len(ms) - 1].box)
	testing.expect(t, a != nil && r != nil && a != r, "matches in the label, then in the paragraph")
	for m in ms {
		b := ui.box_from_key(m.box)
		testing.expect(t, m.rect.max.x > m.rect.min.x && m.rect.max.y > m.rect.min.y, "a rectangle")
		testing.expect(t, m.rect.min.y >= b.rect.min.y - 1 && m.rect.max.y <= b.rect.max.y + 1, "inside its box")
	}
	testing.expect(t, ms[0].rect.min.x < ms[1].rect.min.x, "reading order")
	frame(f, nil, proc(f: ^Fx, user: rawptr) { ui.find("", 0) }, nil)
	frame(f, nil, nothing, nil)
	testing.expect_value(t, ui.find_count(), 0)
}

@(private = "file")
the_scroller: ^ui.Box

@(private = "file")
build_scroller :: proc(f: ^Fx, user: rawptr) {
	ui.next({width = ui.px(300), height = ui.px(200)})
	if ui.scroll_y("###sc") {
		for i in 0 ..< 40 {
			ui.next({width = ui.px(300), height = ui.px(30)})
			ui.label(fmt.tprintf("row %d###r%d", i, i))
		}
	}
	the_scroller = ui.prev_box("###sc")
}

// The view offset of the scroller after a wheel notch and one more frame, with animations off and the given glide.
@(private = "file")
scroll_after_notch :: proc(f: ^Fx, smooth: ui.Smooth_Scroll) -> (off, target: f32, busy: bool) {
	one :: proc(f: ^Fx, events: []platform.Event, smooth: ui.Smooth_Scroll) {
		ui.set_smooth_scroll(&f.s, smooth)
		ui.begin_build(&f.s, {
			window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
		})
		build_scroller(f, nil)
		ui.end_build()
		free_all(context.temp_allocator)
	}
	for _ in 0 ..< 2 { one(f, nil, smooth) }   // (no pointer move before the notch: the wheel is where its event says)
	one(f, {{kind = .Scroll, pos = {100, 100}, delta = {0, 1}}}, smooth)
	b := the_scroller
	return b.view_off.y, b.view_target.y, ui.needs_frame(&f.s)
}

// Smooth scrolling is its own setting: with the interface's animations off, a wheel notch still glides when the
// application says so (set_smooth_scroll .On), and jumps when it follows the animations.
@(test)
smooth_scroll_without_animations :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	off, target, busy := scroll_after_notch(f, .On)
	testing.expectf(t, target > 0 && off > 0 && off < target, "a glide: %v of %v", off, target)
	testing.expect(t, busy, "frames keep coming while it glides")
	close(f)
	f^ = {}
	if !testing.expect(t, open(f)) { return }
	off, target, busy = scroll_after_notch(f, .Follow)
	testing.expectf(t, target > 0 && off == target, "a jump: %v of %v", off, target)
}

// The layout warns of the percentage that goes past a box sized by its children (a label stretching its row to the
// window's height), once per box.
@(test)
layout_warns_of_a_percentage_past_a_box_sized_by_its_children :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	ui.set_layout_warnings(&f.s, true)
	for _ in 0 ..< 3 {
		frame(f, nil, proc(f: ^Fx, user: rawptr) {
			ui.next({width = ui.px(300), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###stretched") {
				ui.next({width = ui.px(80), height = ui.pct(1)})
				ui.label("tall###lbl")
			}
		}, nil)
	}
	testing.expect_value(t, len(f.s.layout_warned), 1)
}

// rich_paragraph's version names its content: the same version finds the layout made for it without hashing the runs
// (the text that changed under the same version is not seen: the caller's promise), a new version lays out again.
@(test)
rich_paragraph_version_finds_its_layout :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	Case :: struct { text: string, version: u64 }
	height_of :: proc(f: ^Fx, c: Case) -> f32 {
		@(static) cur: Case
		cur = c
		for _ in 0 ..< 2 {
			frame(f, nil, proc(f: ^Fx, user: rawptr) {
				ui.next({width = ui.px(120)})
				ui.rich_paragraph("###p", {{text = cur.text}}, version = cur.version)
				the_para = ui.prev_box("###p")
			}, nil)
		}
		return the_para.size.y
	}
	short := height_of(f, {"short", 7})
	same := height_of(f, {"a much longer text that wraps over several lines of a narrow box", 7})
	testing.expect_value(t, same, short)   // the same version: the layout of "short"
	longer := height_of(f, {"a much longer text that wraps over several lines of a narrow box", 8})
	testing.expect(t, longer > short, "a new version lays the text out again")
}

@(private = "file")
the_para: ^ui.Box

@(private = "file")
lazy_built: int
@(private = "file")
lazy_scroller: ^ui.Box

@(private = "file")
build_lazy :: proc(f: ^Fx, user: rawptr) {
	lazy_built = 0
	ui.next({width = ui.px(300), height = ui.px(200)})
	if ui.scroll_y("###lz") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			lz := ui.lazy_begin()
			for i in 0 ..< 50 {
				if ui.lazy_item(lz, fmt.tprintf("###it%d", i)) {
					lazy_built += 1
					ui.next({width = ui.fill(), height = ui.px(40)})
					ui.label(fmt.tprintf("item %d###l", i))
				}
			}
		}
	}
	lazy_scroller = ui.prev_box("###lz")
}

// A lazy column builds the items near the view only, keeps the content's height, and builds the others when the view
// reaches them.
@(test)
lazy_column_builds_what_is_near_the_view :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	for _ in 0 ..< 3 { frame(f, nil, build_lazy, nil) }
	testing.expectf(t, lazy_built > 0 && lazy_built <= 16, "a screen and a margin built, not 50: %d", lazy_built)
	testing.expect_value(t, lazy_scroller.view_bounds.y, 2000)   // all 50 items' height
	lazy_scroller.view_target.y = 1800
	lazy_scroller.view_off.y = 1800
	for _ in 0 ..< 3 { frame(f, nil, build_lazy, nil) }
	b := ui.box_from_key(lazy_scroller.first.key)   // the column
	last := b.last
	testing.expect(t, last != nil && last.first != nil, "the last item is built at the bottom")
	testing.expectf(t, lazy_built <= 16, "still a screen's worth: %d", lazy_built)
}

// The side buttons of the mouse come through as the others do, and click nothing.
@(test)
side_buttons_are_read :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	seen: [2]bool
	body :: proc(f: ^Fx, user: rawptr) {
		s := (^[2]bool)(user)
		s[0] ||= ui.mouse_pressed(.Back)
		s[1] ||= ui.mouse_pressed(.Forward)
	}
	frame(f, {{kind = .Mouse_Press, pos = {10, 10}, button = .Back}}, body, &seen)
	frame(f, {{kind = .Mouse_Release, pos = {10, 10}, button = .Back}}, body, &seen)
	testing.expect(t, seen[0] && !seen[1], "back, not forward")
	frame(f, {{kind = .Mouse_Press, pos = {10, 10}, button = .Forward}}, body, &seen)
	frame(f, {{kind = .Mouse_Release, pos = {10, 10}, button = .Forward}}, body, &seen)
	testing.expect(t, seen[1], "forward")
}

@(private = "file")
sized_size: ui.Vec2
@(private = "file")
sized_open: bool
@(private = "file")
sized_panel: ^ui.Box

@(private = "file")
build_sized :: proc(f: ^Fx, user: rawptr) {
	if ui.modal("t", &sized_open, {width_em = 400 / ui.font_size(), height_em = 300 / ui.font_size(), min_width_em = 200 / ui.font_size(), min_height_em = 100 / ui.font_size(), size = &sized_size}) { sized_panel = ui.parent_box() }
}

// A dialog of a size of its own: centered, within the window however small, resized by its edges with the opposite side following,
// back to what it prefers on a double click.
@(test)
a_resizable_modal_stays_centered_and_in_the_window :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	sized_size, sized_open = {}, true
	for _ in 0 ..< 2 { frame(f, nil, build_sized, nil) }
	r := sized_panel.rect
	testing.expect_value(t, r, ui.Rect{{200, 150}, {600, 450}})

	// the right edge pulled by 20: both sides move, the edge stays under the pointer
	frame(f, {{kind = .Mouse_Move, pos = {599, 300}}}, build_sized, nil)
	frame(f, {{kind = .Mouse_Press, pos = {599, 300}, button = .Left}}, build_sized, nil)
	frame(f, {{kind = .Mouse_Move, pos = {619, 300}}}, build_sized, nil)
	frame(f, nil, build_sized, nil)
	testing.expect_value(t, sized_size, ui.Vec2{440, 300} / 15)   // (in ems: the base style is 15 px)
	testing.expect_value(t, sized_panel.rect, ui.Rect{{180, 150}, {620, 450}})
	// past what the window allows, then released: it stops at the margin
	frame(f, {{kind = .Mouse_Move, pos = {2000, 300}}}, build_sized, nil)
	frame(f, {{kind = .Mouse_Release, pos = {2000, 300}, button = .Left}}, build_sized, nil)
	frame(f, nil, build_sized, nil)
	testing.expect(t, sized_panel.rect.min.x > 0 && sized_panel.rect.max.x < WINDOW.x, "within the window")
	testing.expect_value(t, sized_panel.rect.min.x, WINDOW.x - sized_panel.rect.max.x)

	// a window too small for even its least: the window wins, and the size chosen is kept for when it grows
	chosen := ui.Vec2{500, 400} / 15
	sized_size = chosen
	for _ in 0 ..< 2 { frame(f, nil, build_sized, nil, {150, 80}) }
	r = sized_panel.rect
	testing.expect(t, r.min.x >= 0 && r.min.y >= 0 && r.max.x <= 150 && r.max.y <= 80, "within a tiny window")
	testing.expect_value(t, sized_size, chosen)
	for _ in 0 ..< 2 { frame(f, nil, build_sized, nil) }
	testing.expect_value(t, sized_panel.rect, ui.Rect{{150, 100}, {650, 500}})

	// a double click on an edge: what it prefers
	click :: proc(f: ^Fx) {
		frame(f, {{kind = .Mouse_Move, pos = {649, 300}}}, build_sized, nil)
		frame(f, {{kind = .Mouse_Press, pos = {649, 300}, button = .Left}}, build_sized, nil)
		frame(f, {{kind = .Mouse_Release, pos = {649, 300}, button = .Left}}, build_sized, nil)
	}
	click(f)
	click(f)
	frame(f, nil, build_sized, nil)
	testing.expect_value(t, sized_size, ui.Vec2{})
	testing.expect_value(t, sized_panel.rect, ui.Rect{{200, 150}, {600, 450}})
	sized_open = false
	frame(f, nil, build_sized, nil)
}

@(private = "file")
build_tall_modal :: proc(f: ^Fx, user: rawptr) {
	if ui.modal("tall", &sized_open, {width_em = 2000 / ui.font_size(), top = 0.5}) {
		sized_panel = ui.parent_box()
		ui.next({width = ui.fill(), height = ui.px(450)})
		ui.label("tall###x")
	}
}

// A plain dialog does not leave the window either: narrower, and higher than asked when what is in it would pass the bottom.
@(test)
modal_stays_in_the_window :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	sized_open = true
	for _ in 0 ..< 3 { frame(f, nil, build_tall_modal, nil) }
	r := sized_panel.rect
	testing.expect(t, r.min.x > 0 && r.max.x < WINDOW.x, "narrower than asked")
	testing.expect(t, r.max.y < WINDOW.y, "above the bottom")
	sized_open = false
	frame(f, nil, build_tall_modal, nil)
}

@(private = "file")
find_items: int
@(private = "file")
find_around: bool   // a match in the scope before the lazy column and one after it

@(private = "file")
build_lazy_find :: proc(f: ^Fx, user: rawptr) {
	lazy_built = 0
	ui.next({width = ui.px(300), height = ui.px(200)})
	if ui.scroll_y("###fz") {
		ui.find("fox", ui.parent_box().key)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###fout") {
		ui.next({width = ui.fill(), height = ui.px(20)})
		ui.label(find_around ? "a fox before###before" : "before###before")
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###fcol") {
			ui.next({width = ui.fill(), height = ui.px(20)})
			ui.label(find_around ? "a fox at the column's top###ctop" : "the column's top###ctop")
			lz := ui.lazy_begin(sweep = ui.find_sweep())
			for i in 0 ..< find_items {
				if ui.lazy_item(lz, fmt.tprintf("###fi%d", i), always = i == find_items - 1) {
					lazy_built += 1
					ui.next({width = ui.fill(), height = ui.px(40)})
					ui.label(fmt.tprintf("fox %d###l", i))
				}
			}
			ui.next({width = ui.fill(), height = ui.px(20)})
			ui.label(find_around ? "a fox at the column's foot###cfoot" : "the column's foot###cfoot")
		}
		ui.next({width = ui.fill(), height = ui.px(20)})
		ui.label(find_around ? "a fox after###after" : "after###after")
		}
	}
	lazy_scroller = ui.prev_box("###fz")
}

// A find over a lazy column: read once when the needle rests, a slice of items at each frame (no frame builds the whole column), then
// lazy again, the indices those of the whole text; a match far from the view is known without being built, and text that comes in is
// read by a new sweep.
@(test)
find_sweeps_a_lazy_column_once :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	clock: f64 = 1000
	ui.set_clock(&f.s, &clock)
	defer ui.set_clock(&f.s, nil)
	find_items = 50
	for _ in 0 ..< 3 { frame(f, nil, build_lazy_find, nil) }
	testing.expect(t, ui.find_pending(), "the needle has not rested")
	testing.expect(t, ui.wake_ms(&f.s) > 0, "its sweep is waited for")
	testing.expect_value(t, ui.find_count(), 0)
	testing.expectf(t, lazy_built <= 16, "typing builds a screen's worth: %d", lazy_built)

	clock += ui.FIND_QUIET_MS
	frame(f, nil, build_lazy_find, nil)
	testing.expectf(t, lazy_built <= 16 + ui.FIND_SWEEP_ITEMS, "a slice, not the column: %d", lazy_built)
	testing.expect(t, ui.find_pending(), "under way")
	testing.expect_value(t, ui.find_count(), ui.FIND_SWEEP_ITEMS)   // (what it has read so far)
	testing.expect(t, ui.find_progress() < 1, "it says how far it is")
	testing.expect(t, ui.needs_frame(&f.s), "the next slice is due at once")
	frames := 1
	for ui.find_pending() && frames < 10 {
		frame(f, nil, build_lazy_find, nil)
		testing.expectf(t, lazy_built <= 16 + ui.FIND_SWEEP_ITEMS, "a slice, not the column: %d", lazy_built)
		frames += 1
	}
	testing.expect_value(t, frames, (50 + ui.FIND_SWEEP_ITEMS - 1) / ui.FIND_SWEEP_ITEMS)
	testing.expect(t, !ui.find_pending())
	testing.expect_value(t, ui.find_count(), 50)
	testing.expect_value(t, ui.find_progress(), 1)
	all := ui.find_all()
	testing.expect_value(t, len(all), 50)
	testing.expect(t, all[49].rect.min.y > 1940 && all[49].rect.max.y <= 2040, "the last match, in the content (under the labels before the items)")
	testing.expect(t, ui.needs_frame(&f.s), "the answer is read by a frame, whatever else happens")

	for _ in 0 ..< 3 { frame(f, nil, build_lazy_find, nil) }
	testing.expectf(t, lazy_built <= 17, "lazy again: %d", lazy_built)
	testing.expect_value(t, ui.find_count(), 50)
	testing.expect(t, !ui.needs_frame(&f.s), "nothing is due")
	testing.expect_value(t, ui.find_matches()[0].index, 0)

	// what the sweep found, far from where it was read: lit there, with its index in the whole
	lazy_scroller.view_target.y = 1800
	lazy_scroller.view_off.y = 1800
	for _ in 0 ..< 3 { frame(f, nil, build_lazy_find, nil) }
	ms := ui.find_matches()
	testing.expect(t, len(ms) < 50, "only what is built")
	testing.expect_value(t, ms[len(ms) - 1].index, 49)
	testing.expect_value(t, ui.find_count(), 50)

	// a new item with a match: known to be missing at once, read no sooner than the gap
	find_items = 51
	frame(f, nil, build_lazy_find, nil)
	frame(f, nil, build_lazy_find, nil)
	testing.expect_value(t, ui.find_count(), 50)
	testing.expect(t, ui.wake_ms(&f.s) > 0, "a new sweep is due")
	clock += ui.FIND_SWEEP_GAP_MS
	frame(f, nil, build_lazy_find, nil)
	testing.expect_value(t, ui.find_count(), 50)   // (what the last sweep found stands while the next one reads)
	testing.expectf(t, lazy_built <= 16 + ui.FIND_SWEEP_ITEMS, "a slice: %d", lazy_built)
	for i := 0; ui.find_count() != 51 && i < 10; i += 1 { frame(f, nil, build_lazy_find, nil) }
	testing.expect_value(t, ui.find_count(), 51)

	// text the application knows of, far from what is built
	for _ in 0 ..< 2 { frame(f, nil, build_lazy_find, nil) }
	testing.expect(t, !ui.needs_frame(&f.s), "nothing is due")
	ui.find_refresh()
	clock += ui.FIND_SWEEP_GAP_MS
	frame(f, nil, build_lazy_find, nil)
	testing.expect(t, ui.find_progress() < 1, "read again")
	for i := 0; ui.find_progress() < 1 && i < 10; i += 1 { frame(f, nil, build_lazy_find, nil) }
	testing.expect_value(t, ui.find_count(), 51)

	// text of the scope around the column: counted too, in reading order
	find_around = true
	defer find_around = false
	ui.find_refresh()
	clock += ui.FIND_SWEEP_GAP_MS
	for i := 0; ui.find_count() != 55 && i < 10; i += 1 { frame(f, nil, build_lazy_find, nil) }
	testing.expect_value(t, ui.find_count(), 55)
	around := ui.find_all()
	if testing.expect_value(t, len(around), 55) {
		testing.expect(t, around[0].rect.max.y <= 20, "the text before the column, first")
		testing.expect(t, around[1].rect.max.y <= 40, "then the column's own, before its items")
		for i in 1 ..< 55 { testing.expectf(t, around[i].rect.min.y >= around[i - 1].rect.max.y, "in reading order at %d", i) }
	}

	// another needle starts over; none stops
	frame(f, nil, proc(f: ^Fx, user: rawptr) { ui.find("", 0) }, nil)
	frame(f, nil, nothing, nil)
	testing.expect_value(t, ui.find_count(), 0)
	testing.expect(t, !ui.find_pending())
	testing.expect_value(t, len(ui.find_matches()), 0)
}

@(private = "file")
lazy_empty: int

// A scroll box that follows its bottom, as a conversation does, whose last items but one show nothing.
@(private = "file")
build_lazy_empty :: proc(f: ^Fx, user: rawptr) {
	ui.next({width = ui.px(300), height = ui.px(200)})
	id := fmt.tprintf("###lze%d", lazy_empty)
	if sb := ui.prev_box(id); sb != nil { sb.view_target.y = ui.view_limit(sb) }
	if ui.scroll_y(id) {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			lz := ui.lazy_begin()
			for i in 0 ..< 50 {
				if ui.lazy_item(lz, fmt.tprintf("###it%d", i), always = i == 49) {
					if i >= 49 - lazy_empty && i < 49 { continue }
					ui.next({width = ui.fill(), height = ui.px(40)})
					ui.label(fmt.tprintf("item %d###l", i))
				}
			}
		}
	}
	lazy_scroller = ui.prev_box(id)
}

// An item that shows nothing has a height, 0, not an unknown one. Standing for the mean of the others it put what follows
// further down than it is, out of what is built; there it stood as a space, the content grew, the view followed and built it
// again: a content's height changing at each frame, a conversation's scroll bar jumping at its bottom.
@(test)
lazy_items_of_no_height_stay_so :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	for k in 1 ..< 40 {
		lazy_empty = k
		for _ in 0 ..< 12 { frame(f, nil, build_lazy_empty, nil) }
		h := lazy_scroller.view_bounds.y
		for _ in 0 ..< 6 {
			frame(f, nil, build_lazy_empty, nil)
			testing.expectf(t, lazy_scroller.view_bounds.y == h, "%d items of no height: the content goes from %v to %v", k, h, lazy_scroller.view_bounds.y)
		}
	}
}

@(private = "file")
lazy_pin_at: int

@(private = "file")
lazy_pin_grow: f32

// A column whose items above the pinned one grow from one frame to the next, as a page read before them would.
@(private = "file")
build_lazy_pin :: proc(f: ^Fx, user: rawptr) {
	ui.next({width = ui.px(300), height = ui.px(200)})
	if ui.scroll_y("###lzp") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			lz := ui.lazy_begin()
			ui.lazy_pin(lz, "###it30", 10)
			for i in 0 ..< 50 {
				if ui.lazy_item(lz, fmt.tprintf("###it%d", i), always = i == 30) {
					ui.next({width = ui.fill(), height = ui.px(i < 30 ? 40 + lazy_pin_grow : 40)})
					ui.label(fmt.tprintf("item %d###l", i))
				}
			}
			found, moved := ui.lazy_pinned(lz)
			if found && !moved { lazy_pin_at += 1 }
		}
	}
	lazy_scroller = ui.prev_box("###lzp")
}

// The view stays on the pinned item, 10 px into it, whatever grows above it: in place a few builds after it is asked for, and again after
// each change.
@(test)
lazy_pin_keeps_the_view_on_its_item :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	lazy_pin_at, lazy_pin_grow = 0, 0
	for _ in 0 ..< 8 { frame(f, nil, build_lazy_pin, nil) }
	item := ui.box_from_key(ui.key_from_string(ui.key_from_string(lazy_scroller.key, "###col"), "###it30"))
	testing.expect(t, item != nil)
	testing.expect(t, lazy_pin_at > 0, "it settles")
	if item != nil { testing.expect_value(t, lazy_scroller.rect.min.y - item.rect.min.y, f32(10)) }
	lazy_pin_grow = 25
	for _ in 0 ..< 8 { frame(f, nil, build_lazy_pin, nil) }
	item = ui.box_from_key(ui.key_from_string(ui.key_from_string(lazy_scroller.key, "###col"), "###it30"))
	if item != nil { testing.expect_value(t, lazy_scroller.rect.min.y - item.rect.min.y, f32(10)) }
}

// Hidden while the pointer is elsewhere, shown over its box and for a moment when revealed; always shown when not asked for.
@(test)
scrollbar_autohide_follows_the_pointer :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	testing.expect(t, !f.s.scrollbar_autohide, "off by default")
	for _ in 0 ..< 3 { frame(f, nil, build_lazy, nil) }
	testing.expect_value(t, ui.scrollbar_opacity(&f.s, lazy_scroller), 1)
	ui.set_scrollbar_autohide(&f.s, true)
	defer ui.set_scrollbar_autohide(&f.s, false)
	away := []platform.Event{{kind = .Mouse_Move, pos = {600, 500}}}
	for _ in 0 ..< 60 { frame(f, away, build_lazy, nil) }
	testing.expect(t, ui.scrollbar_opacity(&f.s, lazy_scroller) < 0.02, "hidden with the pointer away")
	over := []platform.Event{{kind = .Mouse_Move, pos = {100, 100}}}
	for _ in 0 ..< 60 { frame(f, over, build_lazy, nil) }
	testing.expect(t, ui.scrollbar_opacity(&f.s, lazy_scroller) > 0.98, "shown with the pointer over its box")
	for _ in 0 ..< 60 { frame(f, away, build_lazy, nil) }
	ui.scrollbar_reveal(lazy_scroller)
	for _ in 0 ..< 30 { frame(f, nil, build_lazy, nil) }
	testing.expect(t, ui.scrollbar_opacity(&f.s, lazy_scroller) > 0.5, "shown for a moment when revealed")
}

@(private = "file")
merged_box: ^ui.Box

// next_merge completes the pending next: a helper sizes its box, the caller's position stays.
@(test)
next_merge_keeps_what_the_caller_set :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	for _ in 0 ..< 2 {
		frame(f, nil, proc(f: ^Fx, user: rawptr) {
			ui.next({fixed_x = 50, fixed_y = 30})                   // the caller places it
			ui.next_merge({width = ui.px(20), height = ui.px(10)})  // the helper sizes it
			merged_box = ui.build_box({}, "###merged")
		}, nil)
	}
	r := merged_box.rect
	testing.expect_value(t, [4]f32{r.min.x, r.min.y, r.max.x - r.min.x, r.max.y - r.min.y}, [4]f32{50, 30, 20, 10})
}

// box_at finds a box of the last build from its path of ids, from outside the build.
@(test)
box_at_finds_a_box_by_its_ids :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	frame(f, nil, build_lazy, nil)
	frame(f, nil, build_lazy, nil)
	sc := ui.box_at("###lz")
	testing.expect(t, sc != nil && sc == lazy_scroller, "the scroll box")
	testing.expect(t, ui.box_at("###lz", "###col") != nil, "the column inside it")
	testing.expect(t, ui.box_at("###nothing") == nil, "none")
}

// A lazy column whose items all close before their content (`if !lazy_item(...) { continue }`) is said; one of empty
// items among full ones is not.
@(test)
lazy_items_left_empty_are_warned_of :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	ui.set_layout_warnings(&f.s, true)
	@(static) wrong: bool
	build :: proc(f: ^Fx, user: rawptr) {
		ui.next({width = ui.px(300), height = ui.px(200)})
		if ui.scroll_y("###lz") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###col") {
				lz := ui.lazy_begin()
				for i in 0 ..< 10 {
					if wrong {
						if !ui.lazy_item(lz, fmt.tprintf("###it%d", i)) { continue }
						ui.next({width = ui.fill(), height = ui.px(40)})
						ui.label(fmt.tprintf("item %d###l", i))
					} else if ui.lazy_item(lz, fmt.tprintf("###it%d", i)) {
						if i != 3 {   // (item 3 stays empty)
							ui.next({width = ui.fill(), height = ui.px(40)})
							ui.label(fmt.tprintf("item %d###l", i))
						}
					}
				}
			}
		}
	}
	wrong = false
	for _ in 0 ..< 3 { frame(f, nil, build, nil) }
	testing.expect_value(t, len(f.s.layout_warned), 0)
	wrong = true
	for _ in 0 ..< 3 { frame(f, nil, build, nil) }
	testing.expect_value(t, len(f.s.layout_warned), 1)
}

// A long lazy column never builds every item: not at its first frame (items never built stand as an estimate), not when
// its width changes (the old heights stand until the items come near the view).
@(private = "file") lz2_w: f32 = 300
@(private = "file") lz2_h: f32 = 40
@(private = "file") lz2_built: int
@(private = "file") lz2_scroller: ^ui.Box

@(private = "file")
build_lazy2 :: proc(f: ^Fx, user: rawptr) {
	lz2_built = 0
	ui.next({width = ui.px(lz2_w), height = ui.px(200)})
	if ui.scroll_y("###lz") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			lz := ui.lazy_begin()
			for i in 0 ..< 2000 {
				if ui.lazy_item(lz, fmt.tprintf("###it%d", i)) {
					lz2_built += 1
					ui.next({width = ui.fill(), height = ui.px(lz2_h)})
					ui.label(fmt.tprintf("item %d###l", i))
				}
			}
		}
	}
	lz2_scroller = ui.prev_box("###lz")
}

@(test)
lazy_column_never_builds_everything :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	lz2_w, lz2_h = 300, 40
	frame(f, nil, build_lazy2, nil)
	testing.expectf(t, lz2_built < 100, "the first frame builds a screen's worth, not 2000: %d", lz2_built)
	for _ in 0 ..< 2 { frame(f, nil, build_lazy2, nil) }
	testing.expectf(t, lz2_built <= 16, "then a screen and a margin: %d", lz2_built)
	lz2_w = 400
	frame(f, nil, build_lazy2, nil)
	testing.expectf(t, lz2_built <= 16, "a new width rebuilds what is near the view only: %d", lz2_built)
}

// When the items near the view change height (built again at another width), the item the view was on keeps its place
// on screen: in the very frame the heights change, not one frame later.
@(test)
lazy_column_keeps_the_view_on_its_item :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	lz2_w, lz2_h = 300, 40
	for _ in 0 ..< 3 { frame(f, nil, build_lazy2, nil) }
	lz2_scroller.view_target.y = 20000
	lz2_scroller.view_off.y = 20000
	for _ in 0 ..< 3 { frame(f, nil, build_lazy2, nil) }
	at :: proc(id: string) -> f32 {
		b := ui.box_at("###lz", "###col", id)
		return b != nil ? b.rect.min.y : -1
	}
	before := at("###it500")
	testing.expectf(t, before >= 0, "item 500 is on screen (view at 20000, 40 px items)")
	lz2_h = 60   // every item built from now on is taller: those above the view in the band too
	frame(f, nil, build_lazy2, nil)
	testing.expect_value(t, at("###it500"), before)
	frame(f, nil, build_lazy2, nil)
	testing.expect_value(t, at("###it500"), before)
}

// A find whose scope is no longer built (a page left while the needle stays) finds nothing instead of reading the
// freed frame memory of that subtree.
@(test)
find_with_a_scope_no_longer_built :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	@(static) show: bool
	build :: proc(f: ^Fx, user: rawptr) {
		if show {
			ui.next({width = ui.px(300), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###scope") {
				runs := [?]ui.Rich_Run{{text = "find the needle here"}}
				ui.next({width = ui.fill()})
				ui.rich_paragraph("###rp", runs[:])
			}
			if b := ui.box_at("###scope"); b != nil { ui.find("needle", b.key) }
		}
	}
	show = true
	for _ in 0 ..< 3 { frame(f, nil, build, nil) }
	testing.expect_value(t, ui.find_count(), 1)
	show = false
	for _ in 0 ..< 3 { frame(f, nil, build, nil) }
	testing.expect_value(t, ui.find_count(), 0)
	ui.find("")
}

// A wheel's big jump: the frame that applies it shows items, not the spaces of the items built around the old place.
@(test)
lazy_column_after_a_jump_shows_items :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	lz2_w, lz2_h = 300, 40
	for _ in 0 ..< 3 { frame(f, nil, build_lazy2, nil) }
	sb := lz2_scroller
	mid := [2]f32{(sb.rect.min.x + sb.rect.max.x) * 0.5, (sb.rect.min.y + sb.rect.max.y) * 0.5}
	jump := []platform.Event{{kind = .Mouse_Move, pos = mid}, {kind = .Scroll, pos = mid, delta = {0, 60}}}
	frame(f, jump, build_lazy2, nil)
	testing.expectf(t, lz2_scroller.view_off.y > 1000, "the view jumped: %v", lz2_scroller.view_off.y)
	col := ui.box_at("###lz", "###col")
	shown := 0
	for c := col.first; c != nil; c = c.next {
		if c.first != nil && c.rect.max.y > sb.rect.min.y && c.rect.min.y < sb.rect.max.y { shown += 1 }
	}
	testing.expectf(t, shown >= 3, "items in the view in the very frame of the jump: %d", shown)
}

////////////////////////////////
// Selection read during a build, list_select ahead of the rows, Escape in dialogs

@(private = "file")
Sel_Run :: struct { label: ui.Key, read: string, copied: bool }

@(private = "file")
build_copy_above_text :: proc(f: ^Fx, user: rawptr) {
	r := (^Sel_Run)(user)
	ui.next({fixed_x = 300, fixed_y = 0, width = ui.px(100)})
	if ui.button("copy", "Copy").clicked {
		r.read = ui.selected_text(&f.s)
		r.copied = true
	}
	ui.next({fixed_x = 0, fixed_y = 100, width = ui.px(200), flags = {.Selectable}})
	r.label = ui.label("Some text###text").box.key
}

// A Copy button in a toolbar is built before the text: the selection reads the same then, from the last build's boxes.
@(test)
selected_text_during_a_build_before_its_boxes :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Sel_Run
	defer delete(r.read)
	frame(&f, nil, build_copy_above_text, &r)
	frame(&f, nil, build_copy_above_text, &r)
	ui.select_box(&f.s, r.label)
	frame(&f, {{kind = .Mouse_Move, pos = {350, 10}}}, build_copy_above_text, &r)
	frame(&f, {{kind = .Mouse_Press, pos = {350, 10}, button = .Left}, {kind = .Mouse_Release, pos = {350, 10}, button = .Left}}, build_copy_above_text, &r)
	testing.expect(t, r.copied, "the button clicked")
	testing.expect_value(t, r.read, "Some text")
}

// list_select says which row is active before the rows are built: the first build of a list, a row added this frame.
@(test)
list_select_ahead_of_the_rows :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := List_Run{names = {"a", "b", "c"}}
	defer ui.list_state_destroy(&r.st)
	ui.list_select(&r.st, 2)
	frame(&f, nil, build_list, &r)
	testing.expect_value(t, r.st.sel, 2)
	frame(&f, nil, build_list, &r)
	testing.expect_value(t, r.st.sel, 2)
	// past the rows that are built: the last one
	ui.list_select(&r.st, 9)
	frame(&f, nil, build_list, &r)
	testing.expect_value(t, r.st.sel, 2)
	// the rows went away: the active row with them
	r.names = {"a"}
	frame(&f, nil, build_list, &r)
	frame(&f, nil, build_list, &r)
	testing.expect_value(t, r.st.sel, 0)
	// a list never told has no active row
	z := List_Run{names = {"a", "b"}}
	defer ui.list_state_destroy(&z.st)
	frame(&f, nil, build_list, &z)
	testing.expect_value(t, z.st.sel, -1)
}

@(private = "file")
Modal_Run :: struct { outer, inner: bool, field: ui.Line_Edit, res: ui.Edit_Result, with_field: bool }

@(private = "file")
build_nested_modals :: proc(f: ^Fx, user: rawptr) {
	r := (^Modal_Run)(user)
	if ui.modal("outer", &r.outer, {width_em = 300 / ui.font_size()}) {
		if r.with_field {
			ui.next({width = ui.px(200), height = ui.px(30)})
			r.res = ui.line_edit("###in_dialog", &r.field)
		}
		if ui.modal("inner", &r.inner, {width_em = 200 / ui.font_size()}) { ui.label("inner") }
	}
}

@(private = "file")
build_stacked_modals :: proc(f: ^Fx, user: rawptr) {
	r := (^Modal_Run)(user)
	if ui.modal("first", &r.outer, {width_em = 300 / ui.font_size()}) { ui.label("first") }
	if ui.modal("second", &r.inner, {width_em = 200 / ui.font_size()}) { ui.label("second") }
}

// Escape closes the dialog on top, and a widget inside a dialog has it first.
@(test)
modal_escape_goes_to_what_is_on_top :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Modal_Run{outer = true, inner = true}
	defer ui.line_edit_destroy(&r.field)
	frame(&f, nil, build_nested_modals, &r)
	frame(&f, nil, build_nested_modals, &r)
	frame(&f, {key(.Escape)}, build_nested_modals, &r)
	frame(&f, nil, build_nested_modals, &r)   // (the build after the key closes it: the dialog on top is known at the end of the build)
	testing.expect(t, r.outer && !r.inner, "nested: the inner one closes")
	frame(&f, nil, build_nested_modals, &r)
	frame(&f, {key(.Escape)}, build_nested_modals, &r)
	frame(&f, nil, build_nested_modals, &r)
	testing.expect(t, !r.outer, "then the outer one")

	r.outer, r.inner = true, true
	frame(&f, nil, build_stacked_modals, &r)
	frame(&f, nil, build_stacked_modals, &r)
	frame(&f, {key(.Escape)}, build_stacked_modals, &r)
	frame(&f, nil, build_stacked_modals, &r)
	testing.expect(t, r.outer && !r.inner, "stacked: the one built last closes")

	r.outer, r.inner, r.with_field = true, false, true
	frame(&f, nil, build_nested_modals, &r)
	frame(&f, nil, build_nested_modals, &r)
	ui.set_focus(r.res.box.key)
	frame(&f, nil, build_nested_modals, &r)
	frame(&f, {key(.Escape)}, build_nested_modals, &r)
	testing.expect(t, r.res.cancelled && r.outer, "the field takes Escape, the dialog stays")
	frame(&f, {key(.Escape)}, build_nested_modals, &r)
	frame(&f, nil, build_nested_modals, &r)
	testing.expect(t, !r.outer, "with no field focused the dialog closes")
}

////////////////////////////////
// Middle-click autoscroll in the box tree

@(private = "file")
build_auto :: proc(f: ^Fx, user: rawptr) {
	build_scroller(f, nil)
	r := (^Edit_Run)(user)
	ui.next({fixed_x = 400, fixed_y = 0, width = ui.px(200), height = ui.px(30)})
	ui.line_edit("###auto_e", &r.field)
}

@(private = "file") middle_tap :: proc(p: ui.Vec2) -> [2]platform.Event { return {{kind = .Mouse_Press, pos = p, button = .Middle}, {kind = .Mouse_Release, pos = p, button = .Middle}} }

// The click that ends a latched session does nothing else: no focus moved, no scrollbar jumped to.
@(test)
autoscroll_ending_click_does_nothing_else :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	// (on by default: nothing to turn on)
	r: Edit_Run
	defer ui.line_edit_destroy(&r.field)
	frame(&f, nil, build_auto, &r)
	frame(&f, nil, build_auto, &r)
	field := ui.box_at("###auto_e")
	ui.set_focus(field.key)
	tap := middle_tap({100, 100})
	frame(&f, tap[:], build_auto, &r)
	testing.expect(t, ui.autoscroll_running(&f.s), "a tap latches")
	frame(&f, {{kind = .Mouse_Press, pos = {700, 500}, button = .Left}, {kind = .Mouse_Release, pos = {700, 500}, button = .Left}}, build_auto, &r)
	testing.expect(t, !ui.autoscroll_running(&f.s), "the click ends it")
	testing.expect_value(t, ui.focus_key(), field.key)
	frame(&f, tap[:], build_auto, &r)
	testing.expect(t, ui.autoscroll_running(&f.s), "latched again")
	frame(&f, {{kind = .Mouse_Press, pos = {293, 190}, button = .Left}}, build_auto, &r)   // on the scrollbar's track
	testing.expect(t, !ui.autoscroll_running(&f.s), "the click ends it")
	testing.expect_value(t, the_scroller.view_target.y, 0)
	frame(&f, {{kind = .Mouse_Release, pos = {293, 190}, button = .Left}}, build_auto, &r)
}

@(private = "file")
Auto_Edit_Run :: struct { area: ui.Text_Edit, in_region: bool }

@(private = "file")
build_auto_edit :: proc(f: ^Fx, user: rawptr) {
	r := (^Auto_Edit_Run)(user)
	if r.in_region {
		ui.next({width = ui.px(300), height = ui.px(200)})
		if ui.scroll_y("###reg") {
			ui.next({width = ui.px(280), height = ui.px(500)})
			ui.text_edit("###te", &r.area)
		}
	} else {
		ui.next({width = ui.px(300), height = ui.px(200)})
		ui.text_edit("###te", &r.area)
	}
}

// A text_edit scrolls itself and autoscroll cannot drive it: a middle press on one starts no session, unless it stands in a
// scroll region, which is then what scrolls.
@(test)
autoscroll_starts_on_what_it_can_scroll :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	ui.set_autoscroll_enabled(&f.s, true)
	r: Auto_Edit_Run
	defer ui.text_edit_destroy(&r.area)
	frame(&f, nil, build_auto_edit, &r)
	frame(&f, nil, build_auto_edit, &r)
	press := []platform.Event{{kind = .Mouse_Press, pos = {100, 100}, button = .Middle}}
	frame(&f, press, build_auto_edit, &r)
	testing.expect(t, !ui.autoscroll_running(&f.s), "no session on a box that scrolls itself")
	frame(&f, {{kind = .Mouse_Release, pos = {100, 100}, button = .Middle}}, build_auto_edit, &r)
	r.in_region = true
	frame(&f, nil, build_auto_edit, &r)
	frame(&f, nil, build_auto_edit, &r)
	frame(&f, press, build_auto_edit, &r)
	testing.expect(t, ui.autoscroll_running(&f.s), "the region around it scrolls")
}

// The settings are in logical pixels: at 200 % the dead zone is 24 frame pixels, so the pointer moves inside the marker
// without scrolling.
@(test)
autoscroll_distances_follow_the_scale :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	ui.set_autoscroll_enabled(&f.s, true)
	one :: proc(f: ^Fx, events: []platform.Event) {
		ui.begin_build(&f.s, {
			window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 2,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
		})
		build_scroller(f, nil)
		ui.end_build()
		free_all(context.temp_allocator)
	}
	one(&f, nil)
	one(&f, nil)
	one(&f, {{kind = .Mouse_Press, pos = {100, 100}, button = .Middle}})
	one(&f, {{kind = .Mouse_Move, pos = {100, 118}}})
	one(&f, nil)
	testing.expect(t, ui.autoscroll_running(&f.s), "held")
	testing.expect_value(t, the_scroller.view_target.y, 0)
	one(&f, {{kind = .Mouse_Move, pos = {100, 190}}})
	one(&f, nil)
	testing.expect(t, the_scroller.view_target.y > 0, "past the dead zone it scrolls")
}

////////////////////////////////
// Edit history

// A Backspace or a Delete with nothing to delete is no edit: the redo history stays.
@(test)
line_edit_deleting_nothing_is_no_edit :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	f.clip = clone("x")
	r: Edit_Run
	defer ui.line_edit_destroy(&r.field)
	frame(&f, nil, build_edit, &r)
	ui.set_focus(ui.box_at("###e").key)
	frame(&f, {typed('a')}, build_edit, &r)
	frame(&f, {key(.V, {.Ctrl})}, build_edit, &r)
	frame(&f, nil, build_edit, &r)   // (the paste's text comes in the build after the key)
	testing.expect_value(t, ui.line_edit_string(&r.field), "ax")
	frame(&f, {key(.Z, {.Ctrl})}, build_edit, &r)
	frame(&f, {key(.End), key(.Delete)}, build_edit, &r)
	frame(&f, {key(.Delete, {.Ctrl})}, build_edit, &r)
	frame(&f, {key(.Home), key(.Backspace)}, build_edit, &r)
	frame(&f, {key(.Backspace, {.Ctrl})}, build_edit, &r)
	testing.expect(t, ui.line_edit_can_redo(&r.field), "redo kept")
	frame(&f, {key(.Y, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "ax")
}

@(private = "file")
Area_Run :: struct { area: ui.Text_Edit }

@(private = "file")
build_area :: proc(f: ^Fx, user: rawptr) {
	r := (^Area_Run)(user)
	ui.next({width = ui.px(300), height = ui.px(200)})
	ui.text_edit("###a", &r.area)
}

@(test)
text_edit_deleting_nothing_is_no_edit :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	f.clip = clone("x")
	r: Area_Run
	defer ui.text_edit_destroy(&r.area)
	frame(&f, nil, build_area, &r)
	ui.set_focus(ui.box_at("###a").key)
	frame(&f, {typed('a')}, build_area, &r)
	frame(&f, {key(.V, {.Ctrl})}, build_area, &r)
	frame(&f, nil, build_area, &r)   // (the paste's text comes in the build after the key)
	frame(&f, {key(.Z, {.Ctrl})}, build_area, &r)
	frame(&f, {key(.End), key(.Delete)}, build_area, &r)
	frame(&f, {key(.Delete, {.Ctrl})}, build_area, &r)
	frame(&f, {key(.Home), key(.Backspace)}, build_area, &r)
	frame(&f, {key(.Backspace, {.Ctrl})}, build_area, &r)
	testing.expect(t, len(r.area.history.redo) == 1, "redo kept")
	frame(&f, {key(.Y, {.Ctrl})}, build_area, &r)
	testing.expect_value(t, ui.text_edit_string(&r.area), "ax")
}

// What a screen reader sets can be undone; a selection asked in the same build is on the new text.
@(test)
a11y_edits_of_fields_are_edits :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Edit_Run
	defer ui.line_edit_destroy(&r.field)
	ui.line_edit_set(&r.field, "ab")
	frame(&f, nil, build_edit, &r)
	b := ui.box_at("###e")
	ui.a11y_inject(&f.s, {action = .Set_Value, data = .Value, value = "Grace Hopper", target = u64(b.key)})
	run := ui.a11y_run_id(b, 0)
	ui.a11y_inject(&f.s, {action = .Set_Text_Selection, data = .Text_Selection, sel = {run, 2, run, 5}, target = u64(b.key)})
	frame(&f, nil, build_edit, &r)
	testing.expect_value(t, ui.line_edit_string(&r.field), "Grace Hopper")
	testing.expect_value(t, r.field.mark, 2)
	testing.expect_value(t, r.field.cursor, 5)
	testing.expect(t, ui.line_edit_undo(&r.field), "undoable")
	testing.expect_value(t, ui.line_edit_string(&r.field), "ab")

	a: Area_Run
	defer ui.text_edit_destroy(&a.area)
	ui.text_edit_set(&a.area, "ab")
	frame(&f, nil, build_area, &a)
	ab := ui.box_at("###a")
	ui.a11y_inject(&f.s, {action = .Set_Value, data = .Value, value = "Grace Hopper", target = u64(ab.key)})
	arun := ui.a11y_run_id(ab, 0)
	ui.a11y_inject(&f.s, {action = .Set_Text_Selection, data = .Text_Selection, sel = {arun, 2, arun, 5}, target = u64(ab.key)})
	frame(&f, nil, build_area, &a)
	testing.expect_value(t, ui.text_edit_string(&a.area), "Grace Hopper")
	testing.expect_value(t, a.area.cursor, 5)
	testing.expect(t, ui.text_edit_undo(&a.area), "undoable")
	testing.expect_value(t, ui.text_edit_string(&a.area), "ab")
}

@(private = "file")
build_lazy_glide :: proc(f: ^Fx, user: rawptr) {
	ui.next({width = ui.px(300), height = ui.px(200)})
	if ui.scroll_y("###lzg") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			lz := ui.lazy_begin()
			for i in 0 ..< 100 {
				if ui.lazy_item(lz, fmt.tprintf("###g%d", i)) {
					ui.next({width = ui.fill(), height = ui.px(40)})
					ui.label(fmt.tprintf("item %d###l", i))
				}
			}
		}
	}
	lazy_scroller = ui.prev_box("###lzg")
}

// A view of a lazy column that moves by less than a pixel a frame (a slow glide, the wheel's click just past its dead zone) goes
// where it is sent. The column kept the item it was on in its place, measured on rects rounded to whole pixels: their error, read
// as a move of the content, put the view back where it was every few frames, and it did not move.
@(test)
a_lazy_column_lets_its_view_move_by_less_than_a_pixel :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	for _ in 0 ..< 3 { frame(f, nil, build_lazy_glide, nil) }
	y: f32 = 2000.3
	ui.view_jump(lazy_scroller, y)
	for _ in 0 ..< 2 { frame(f, nil, build_lazy_glide, nil) }
	for i in 0 ..< 40 {
		y -= 0.2
		ui.view_jump(lazy_scroller, y)
		frame(f, nil, build_lazy_glide, nil)
		if !testing.expectf(t, abs(lazy_scroller.view_off.y - y) < 0.01, "frame %d: at %v, sent to %v", i, lazy_scroller.view_off.y, y) { return }
	}
}

// Turned off, a click of the wheel scrolls nothing (a program whose middle button is its own).
@(test)
autoscroll_turned_off :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	ui.set_autoscroll_enabled(&f.s, false)
	r: Edit_Run
	defer ui.line_edit_destroy(&r.field)
	frame(&f, nil, build_auto, &r)
	frame(&f, nil, build_auto, &r)
	tap := middle_tap({100, 100})
	frame(&f, tap[:], build_auto, &r)
	testing.expect(t, !ui.autoscroll_running(&f.s), "off: no session")
}
