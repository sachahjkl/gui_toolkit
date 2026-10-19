// Keyboard behaviour of menus, lists and line edits, without a window: synthetic input events, builds, assertions on
// the results and on the laid-out boxes. The ui state of a build is global: one test thread.
//   odin test tests/keyboard -vet -define:ODIN_TEST_THREADS=1
package keyboard_test

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

@(test)
menu_keyboard :: proc(t: ^testing.T) {
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

@(test)
menu_submenus :: proc(t: ^testing.T) {
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

@(test)
line_edit_history :: proc(t: ^testing.T) {
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
build_para :: proc(f: ^Fx, user: rawptr) {
	ui.next({width = ui.px(160)})
	ui.paragraph("A description long enough to need several lines at this width.###p")
}

@(test)
paragraph_wraps :: proc(t: ^testing.T) {
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
