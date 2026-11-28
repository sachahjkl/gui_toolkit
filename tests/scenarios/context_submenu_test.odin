package scenarios_test

// Context menus with submenus (src/ui/popups.odin, docs/menus.md): hover delay, safe-triangle diagonal movement
// toward an open submenu, keyboard Right/Enter/Left/Escape, arbitrary nesting, screen-edge left flip, and search
// filter pulling submenu items up into level 0.

import "core:testing"
import lucide "gt:lucide"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Ctx_Run :: struct {
	picked: string,
}

@(private = "file")
ctx_build :: proc(s: ^session.Session) {
	r := (^Ctx_Run)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	area := ui.build_box({.Clickable, .Draw_Background}, "###area")
	if ui.signal(area).right_clicked { ui.menu_open("ctx_menu", ui.mouse_pos()) }
	if ui.menu("ctx_menu") {
		if ui.menu_item("Open", icon = lucide.FOLDER_OPEN, icon_font = ui.lucide_icons()).clicked { r.picked = "Open" }
		if ui.menu_submenu("Copy", icon = lucide.COPY, icon_font = ui.lucide_icons()) {
			if ui.menu_item("Copy path").clicked { r.picked = "Copy path" }
			if ui.menu_item("Copy name").clicked { r.picked = "Copy name" }
			if ui.menu_submenu("Copy as") {
				if ui.menu_item("Markdown").clicked { r.picked = "Markdown" }
				if ui.menu_item("HTML").clicked { r.picked = "HTML" }
			}
		}
		if ui.menu_item("Rename", icon = lucide.PENCIL, icon_font = ui.lucide_icons()).clicked { r.picked = "Rename" }
		ui.menu_separator()
		if ui.menu_item("Delete", icon = lucide.TRASH_2, icon_font = ui.lucide_icons()).clicked { r.picked = "Delete" }
	}
}

@(test)
context_menu_copy_submenu_hover_keyboard_flip_and_filter :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Ctx_Run
	s := session.start(t, {size = {640, 480}, user = &r, build = ctx_build})
	session.wait_idle(s)

	// 1. Open context menu by right-click, hover "Copy" to open submenu, move diagonally across "Rename" into
	// submenu (safe triangle keeps it open), and click "Copy path".
	session.click_at(s, {80, 80}, .Right)
	session.frames(s, 3)
	testing.expect_value(t, ui.menu_depth(), 1)
	copy_row := session.find_text(s, "Copy")
	if !testing.expect(t, copy_row != nil, "Copy submenu row built") { return }
	copy_center := session.center(copy_row)
	session.move(s, copy_center)
	session.advance(s, f64(s.state.feel.menu_hover_ms) + 40)
	session.frames(s, 3)
	testing.expect_value(t, ui.menu_depth(), 2)
	sub_rect, _, sub_ok := ui.menu_rect(1)
	if !testing.expect(t, sub_ok, "Copy submenu rect measured") { return }

	// Move diagonally across Rename toward the bottom of the open submenu: safe triangle holds submenu open.
	rename_row := session.find_text(s, "Rename")
	if testing.expect(t, rename_row != nil, "Rename row built") {
		mid := ui.Vec2{copy_center.x + (sub_rect.min.x - copy_center.x) * 0.5, session.center(rename_row).y}
		session.move(s, mid)
		session.advance(s, 60)
		session.frames(s, 2)
		testing.expect_value(t, ui.menu_depth(), 2)
	}
	path_row := session.find_text(s, "Copy path")
	if !testing.expect(t, path_row != nil, "Copy path item in submenu") { return }
	session.click_at(s, session.center(path_row))
	session.frames(s, 3)
	testing.expect_value(t, r.picked, "Copy path")
	testing.expect(t, !ui.menu_any_open(), "picking submenu item closes entire menu")

	// 2. Keyboard navigation: open menu, Down to Open -> Down to Copy -> Right opens Copy -> Down to Copy name -> Return picks it.
	r.picked = ""
	session.click_at(s, {80, 80}, .Right)
	session.frames(s, 3)
	session.key(s, .Down)
	session.key(s, .Down)
	session.key(s, .Right)
	session.frames(s, 3)
	testing.expect_value(t, ui.menu_depth(), 2)
	session.key(s, .Down)
	session.key(s, .Return)
	session.frames(s, 3)
	testing.expect_value(t, r.picked, "Copy name")
	testing.expect(t, !ui.menu_any_open(), "Return on submenu item closes menu")

	// 3. Nested submenu + Left / Escape close only the innermost submenu, leaving parent open.
	session.click_at(s, {80, 80}, .Right)
	session.frames(s, 3)
	session.key(s, .Down)
	session.key(s, .Down)
	session.key(s, .Right)
	session.frames(s, 3)
	testing.expect_value(t, ui.menu_depth(), 2)
	// Move to "Copy as" (3rd item) and open depth 3.
	session.key(s, .Down)
	session.key(s, .Down)
	session.key(s, .Right)
	session.frames(s, 3)
	testing.expect_value(t, ui.menu_depth(), 3)
	// Left closes depth 3 -> depth 2 stays open.
	session.key(s, .Left)
	session.frames(s, 2)
	testing.expect_value(t, ui.menu_depth(), 2)
	// Escape closes depth 2 -> depth 1 stays open.
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect_value(t, ui.menu_depth(), 1)
	// Second Escape closes the root context menu.
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect_value(t, ui.menu_depth(), 0)

	// 4. Near right screen edge: Copy submenu flips to the left of the parent menu and stays inside [0, 640].
	session.click_at(s, {610, 80}, .Right)
	session.frames(s, 3)
	session.key(s, .Down)
	session.key(s, .Down)
	session.key(s, .Right)
	session.frames(s, 4)
	testing.expect_value(t, ui.menu_depth(), 2)
	parent_r, _, pok := ui.menu_rect(0)
	flip_r, _, fok := ui.menu_rect(1)
	if testing.expect(t, pok && fok, "parent and flipped submenu rects exist") {
		testing.expectf(t, flip_r.max.x <= parent_r.min.x + 4, "submenu flipped left of parent: %v vs %v", flip_r, parent_r)
		testing.expectf(t, flip_r.min.x >= 0 && flip_r.max.x <= 640 && flip_r.min.y >= 0 && flip_r.max.y <= 480, "submenu inside window bounds: %v", flip_r)
	}
	session.key(s, .Escape)
	session.key(s, .Escape)
	session.frames(s, 2)

	// 5. Typing in the context menu pulls nested submenu items ("Markdown") up into level 0.
	r.picked = ""
	session.click_at(s, {80, 80}, .Right)
	session.frames(s, 3)
	session.type_text(s, "mark")
	session.frames(s, 3)
	session.key(s, .Return)
	session.frames(s, 3)
	testing.expect_value(t, r.picked, "Markdown")
}) }
