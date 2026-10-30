// Keyboard behaviour of menus, lists and line edits, without a window: synthetic input events, builds, assertions on
// the results and on the laid-out boxes. The ui state of a build is global: one test thread.
//   odin test tests/keyboard -vet -define:ODIN_TEST_THREADS=1
package keyboard_test

import "core:sync"
import "core:fmt"
import "core:testing"
import "../../font"
import "../../platform"
import "../../ui"

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
	ui.apply_palette(&f.theme, ui.PALETTE_MIDNIGHT)
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
frame :: proc(f: ^Fx, events: []platform.Event, body: proc(f: ^Fx, user: rawptr), user: rawptr) {
	ui.begin_build(&f.s, {
		window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
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
	key:     ui.Key,
	chosen:  string,
	sub_open: bool,
}

@(private = "file")
build_menu :: proc(f: ^Fx, user: rawptr) {
	r := (^Menu_Run)(user)
	if ui.ctx_menu(r.key) {
		if ui.menu_item("Back", "Alt+Left", enabled = false).clicked { r.chosen = "back" }
		if ui.menu_item("Forward", "Alt+Right").clicked { r.chosen = "forward" }
		ui.menu_separator()
		if ui.menu_item("Reload", "F5").clicked { r.chosen = "reload" }
		r.sub_open = false
		if ui.menu_submenu("Search with") {
			r.sub_open = true
			if ui.menu_item("Alpha").clicked { r.chosen = "alpha" }
			if ui.menu_item("Beta").clicked { r.chosen = "beta" }
		}
		if ui.menu_item("Save as...", enabled = false).clicked { r.chosen = "save" }
		if ui.menu_item("View source", "Ctrl+U").clicked { r.chosen = "source" }
	}
}

@(private = "file")
nothing :: proc(f: ^Fx, user: rawptr) {}

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
	r := Menu_Run{key = ui.Key(0x1234)}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.ctx_menu_open((^Menu_Run)(user).key, {100, 100}, from_keyboard = true) }, &r)
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
	testing.expect(t, !ui.ctx_menu_any_open(), "closed after choosing")
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
	r := Menu_Run{key = ui.Key(0x4321)}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.ctx_menu_open((^Menu_Run)(user).key, {100, 100}, from_keyboard = true) }, &r)
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
	key, other:    ui.Key,
	open_after:    bool,   // the menu is still open right after the chosen item (the rest of the block is part of it)
	open_other:    bool,   // answer the click by opening another menu
	later_in_menu: int,    // items after the chosen one that were built as items of a menu
}

@(private = "file")
build_choose :: proc(f: ^Fx, user: rawptr) {
	r := (^Choose_Run)(user)
	r.later_in_menu = 0
	if ui.ctx_menu(r.key) {
		if ui.menu_item("A").clicked {
			r.open_after = ui.ctx_menu_any_open()
			if r.open_other { ui.ctx_menu_open(r.other, {50, 50}) }
		}
		for label in ([?]string{"B", "C"}) {
			ui.menu_item(label)
			if ui.menu_depth() > 0 { r.later_in_menu += 1 }
		}
	}
	if ui.ctx_menu(r.other) { ui.menu_item("Other") }
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
		r := Choose_Run{key = ui.Key(0x1234), other = ui.Key(0x5678), open_other = open_other}
		frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.ctx_menu_open((^Choose_Run)(user).key, {100, 100}, from_keyboard = true) }, &r)
		frame(&f, nil, build_choose, &r)
		frame(&f, nil, build_choose, &r)
		frame(&f, {key(.Return)}, build_choose, &r)
		testing.expect(t, r.open_after, "still open right after the chosen item")
		testing.expect_value(t, r.later_in_menu, 2)
		if open_other {
			testing.expect(t, ui.ctx_menu_is_open(r.other), "the menu opened by the click stays")
			testing.expect(t, !ui.ctx_menu_is_open(r.key))
		} else {
			testing.expect(t, !ui.ctx_menu_any_open(), "closed once the block ended")
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
	r := Menu_Run{key = ui.Key(0x777)}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.ctx_menu_open((^Menu_Run)(user).key, {100, 100}, from_keyboard = true) }, &r)
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
	testing.expect(t, ui.ctx_menu_any_open(), "Left closes only the submenu")
	frame(&f, {key(.Return)}, build_menu, &r)
	frame(&f, nil, build_menu, &r)
	frame(&f, {key(.Down), key(.Return)}, build_menu, &r)
	testing.expect_value(t, r.chosen, "beta")
	testing.expect(t, !ui.ctx_menu_any_open(), "choosing in a submenu closes the whole menu")

	// Escape closes level by level
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.ctx_menu_open((^Menu_Run)(user).key, {100, 100}, from_keyboard = true) }, &r)
	frame(&f, nil, build_menu, &r)
	frame(&f, {typed('s'), key(.Return)}, build_menu, &r)
	frame(&f, nil, build_menu, &r)
	testing.expect_value(t, ui.menu_depth(), 2)
	frame(&f, {key(.Escape)}, build_menu, &r)
	frame(&f, nil, build_menu, &r)
	testing.expect_value(t, ui.menu_depth(), 1)
	frame(&f, {key(.Escape)}, build_menu, &r)
	testing.expect(t, !ui.ctx_menu_any_open(), "the second Escape closes the menu")
}

@(test)
menu_stays_on_screen :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Menu_Run{key = ui.Key(0x999)}
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.ctx_menu_open((^Menu_Run)(user).key, {790, 590}) }, &r)
	for _ in 0 ..< 3 { frame(&f, nil, build_menu, &r) }
	rect, _, ok := ui.menu_rect(0)
	testing.expect(t, ok, "laid out")
	testing.expect(t, rect.min.x >= 0 && rect.max.x <= WINDOW.x && rect.min.y >= 0 && rect.max.y <= WINDOW.y, "inside the window")
	testing.expect(t, rect.max.x <= 791 && rect.max.y <= 591, "flipped to the other side of the point")

	// a press outside closes it
	frame(&f, {{kind = .Mouse_Press, button = .Left, pos = {10, 10}}, {kind = .Mouse_Release, button = .Left, pos = {10, 10}}}, build_menu, &r)
	testing.expect(t, !ui.ctx_menu_any_open(), "closed by a press outside")
	testing.expect_value(t, r.chosen, "")
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

Edit_Run :: struct { field: ui.Text_Field }

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
	defer ui.field_destroy(&r.field)
	frame(&f, nil, build_edit, &r)
	k := ui.key_from_string(ui.key_from_string(0, "root"), "###e")
	ui.set_focus(k)
	frame(&f, {typed('a')}, build_edit, &r)
	testing.expect_value(t, ui.wake_ms(&f.s), 265)
	for inactive in ([2]bool{true, false}) {
		ui.begin_build(&f.s, {
			window_size = WINDOW, dt = 1.0 / 60, dpi_scale = 1, inactive = inactive,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
		})
		testing.expect_value(t, ui.inactive(), inactive)
		build_edit(&f, &r)
		ui.end_build()
		free_all(context.temp_allocator)
		testing.expect_value(t, ui.wake_ms(&f.s), inactive ? 0 : 265)
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
	defer ui.field_destroy(&r.field)
	frame(&f, nil, build_edit, &r)
	ui.set_focus(ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###e")).key)
	frame(&f, {typed('a'), typed('b'), typed('c')}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "abc")
	frame(&f, {key(.A, {.Ctrl}), key(.X, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "")
	testing.expect_value(t, f.clip, "abc")
	frame(&f, {key(.Z, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "abc")
	frame(&f, {key(.Z, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "")   // the typing was one step
	frame(&f, {key(.Y, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "abc")
	frame(&f, {key(.End), key(.V, {.Ctrl})}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "abcabc")
	testing.expect(t, ui.field_can_undo(&r.field), "paste is undoable")
}

@(private = "file")
build_secret :: proc(f: ^Fx, user: rawptr) {
	r := (^Edit_Run)(user)
	ui.next({width = ui.px(300), height = ui.px(30)})
	ui.line_edit("###e", &r.field, secret = true)
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
	defer ui.field_destroy(&r.field)
	frame(&f, nil, build_secret, &r)
	ui.set_focus(ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###e")).key)
	frame(&f, {typed('p'), typed('é'), typed('w')}, build_secret, &r)
	testing.expect_value(t, ui.field_string(&r.field), "péw")
	f.clip = ""
	frame(&f, {key(.A, {.Ctrl}), key(.C, {.Ctrl}), key(.X, {.Ctrl})}, build_secret, &r)
	testing.expect_value(t, f.clip, "")
	testing.expect_value(t, ui.field_string(&r.field), "péw")   // not cut
	frame(&f, {key(.End)}, build_secret, &r)   // (one key a frame: a frame applies its keys in the widget's order)
	frame(&f, {key(.Left)}, build_secret, &r)
	frame(&f, {key(.Backspace)}, build_secret, &r)
	testing.expect_value(t, ui.field_string(&r.field), "pw")
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
	defer ui.field_destroy(&r.field)
	FAMILY :: "\U0001F468\u200D\U0001F469\u200D\U0001F467"
	frame(&f, nil, build_edit, &r)
	ui.set_focus(ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###e")).key)
	events := make([dynamic]platform.Event, context.temp_allocator)
	for c in "a" + FAMILY + "e\u0301\U0001F1EB\U0001F1F7" { append(&events, typed(c)) }
	frame(&f, events[:], build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "a" + FAMILY + "e\u0301\U0001F1EB\U0001F1F7")
	frame(&f, {key(.Backspace)}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "a" + FAMILY + "e\u0301")
	frame(&f, {key(.Backspace)}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "a" + FAMILY)
	frame(&f, {key(.Backspace)}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "a")
	// the arrows step over a family in one press, and Delete takes it whole
	clear(&events)
	for c in FAMILY + "y" { append(&events, typed(c)) }
	frame(&f, events[:], build_edit, &r)
	frame(&f, {key(.Left)}, build_edit, &r)
	frame(&f, {key(.Left)}, build_edit, &r)
	frame(&f, {key(.Delete)}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "ay")
	frame(&f, {key(.Right)}, build_edit, &r)
	frame(&f, {key(.Backspace)}, build_edit, &r)
	testing.expect_value(t, ui.field_string(&r.field), "a")
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
		ui.begin_build(&f.s, {
			window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, smooth_scroll = smooth, dpi_scale = 1,
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
// application says so (smooth_scroll = .On), and jumps when it follows the animations.
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
