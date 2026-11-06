// The notification area icon (platform/tray.odin): the shell's notifications translated into events, the calls made
// to the shell (add, version 4, modify, delete; again after the shell restarted), menus, icons. The shell is replaced by
// tray_test_hook: no icon appears on the desktop. A hidden window receives the notifications through its window
// procedure (tray_inject sends them as the shell does).
//   odin test tests/tray -vet -define:ODIN_TEST_THREADS=1
package tray_test

import "core:testing"
import win "core:sys/windows"
import "../../platform"

// Room for an item's text read back; the menu's flags core:sys/windows does not name.
@(private = "file") TEXT_MAX :: 64
@(private = "file") MFT_RADIOCHECK :: 0x200
@(private = "file") MFT_SEPARATOR :: 0x800

foreign import user32 "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32 { GetMenuItemCount :: proc(menu: win.HMENU) -> i32 --- }

@(private = "file") ops: [dynamic]platform.Tray_Op
@(private = "file") refuse_add: bool

@(private = "file")
hook :: proc(op: platform.Tray_Op, t: ^platform.Tray) -> bool {
	append(&ops, op)
	return !(refuse_add && op == .Add)
}

@(private = "file")
setup :: proc() -> ^platform.Window {
	clear(&ops)
	refuse_add = false
	platform.tray_test_hook = hook
	return platform.open_window("tray test", {200, 120})   // (never shown)
}

// A shell that restarted and is not ready refuses the icon: it is asked again at the next change.
@(test)
an_icon_refused_at_a_restart_is_asked_again :: proc(t: ^testing.T) {
	w := setup()
	defer teardown(w)
	tr := platform.tray_create(w, nil, "tip")
	testing.expect(t, tr != nil)
	if tr == nil { return }
	defer platform.tray_destroy(tr)
	refuse_add = true
	platform.tray_inject_shell_restart(w)
	testing.expect(t, !tr.added)
	refuse_add = false
	clear(&ops)
	testing.expect(t, platform.tray_set_tooltip(tr, "again"))
	testing.expect(t, tr.added, "it is back")
	testing.expect_value(t, ops[0], platform.Tray_Op.Add)
	ev := platform.tray_poll(tr)
	if testing.expect_value(t, len(ev), 1) { testing.expect_value(t, ev[0].kind, platform.Tray_Event_Kind.Recreated) }
}

@(private = "file")
teardown :: proc(w: ^platform.Window) {
	platform.destroy_window(w)
	platform.tray_test_hook = nil
	delete(ops)
	ops = nil
}

@(test)
notifications_become_events :: proc(t: ^testing.T) {
	cases := []struct { code: u32, kind: platform.Tray_Event_Kind, keyboard: bool }{
		{0x0400, .Click, false},          // NIN_SELECT
		{0x0401, .Click, true},           // NIN_KEYSELECT
		{0x0203, .Double_Click, false},   // WM_LBUTTONDBLCLK
		{0x007B, .Right_Click, false},    // WM_CONTEXTMENU
		{0x0208, .Middle_Click, false},   // WM_MBUTTONUP
		{0x0402, .Notify_Shown, false},
		{0x0403, .Notify_Hidden, false},
		{0x0404, .Notify_Timeout, false},
		{0x0405, .Notify_Click, false},
		{0x0406, .Hover_Open, false},
		{0x0407, .Hover_Close, false},
		{0x0200, .None, false},           // WM_MOUSEMOVE
		{0x0201, .None, false},           // WM_LBUTTONDOWN
		{0x0202, .None, false},           // WM_LBUTTONUP
	}
	for c in cases {
		k, kb := platform.tray_event_from_notify(c.code)
		testing.expectf(t, k == c.kind && kb == c.keyboard, "%x: %v %v", c.code, k, kb)
	}
}

@(test)
lifecycle_and_events :: proc(t: ^testing.T) {
	w := setup()
	defer teardown(w)
	tr := platform.tray_create(w, nil, "Chat: 3 unread")
	if !testing.expect(t, tr != nil) { return }
	testing.expect_value(t, len(ops), 2)
	testing.expect_value(t, ops[0], platform.Tray_Op.Add)
	testing.expect_value(t, ops[1], platform.Tray_Op.Set_Version)
	testing.expect_value(t, tr.tooltip, "Chat: 3 unread")

	testing.expect(t, platform.tray_set_tooltip(tr, "Chat"))
	testing.expect_value(t, ops[len(ops) - 1], platform.Tray_Op.Modify)

	platform.tray_inject(tr, 0x0400, {1200, -5})   // a left click at a negative coordinate (a monitor above)
	platform.tray_inject(tr, 0x0201, {1200, 900})  // the raw button message: no event
	platform.tray_inject(tr, 0x0203, {1200, 900})
	ev := platform.tray_poll(tr)
	if testing.expect_value(t, len(ev), 2) {
		testing.expect_value(t, ev[0].kind, platform.Tray_Event_Kind.Click)
		testing.expect_value(t, ev[0].pos, [2]i32{1200, -5})
		testing.expect_value(t, ev[1].kind, platform.Tray_Event_Kind.Double_Click)
	}
	testing.expect_value(t, len(platform.tray_poll(tr)), 0)

	// a right click without a menu (auto_menu opens nothing: no blocking menu loop in a test)
	platform.tray_inject(tr, 0x007B, {10, 20})
	ev = platform.tray_poll(tr)
	if testing.expect_value(t, len(ev), 1) { testing.expect_value(t, ev[0].kind, platform.Tray_Event_Kind.Right_Click) }

	// the shell restarted: added again, a Recreated event
	clear(&ops)
	platform.tray_inject_shell_restart(w)
	testing.expect_value(t, len(ops), 2)
	testing.expect_value(t, ops[0], platform.Tray_Op.Add)
	ev = platform.tray_poll(tr)
	if testing.expect_value(t, len(ev), 1) { testing.expect_value(t, ev[0].kind, platform.Tray_Event_Kind.Recreated) }

	testing.expect(t, platform.tray_notify(tr, {title = "New message", body = "Hello", icon = .App}))
	testing.expect_value(t, ops[len(ops) - 1], platform.Tray_Op.Notify)

	clear(&ops)
	platform.tray_destroy(tr)
	testing.expect_value(t, len(ops), 1)
	testing.expect_value(t, ops[0], platform.Tray_Op.Delete)
}

// Two icons on one window each get their own notifications; destroying the window removes both.
@(test)
two_icons_one_window :: proc(t: ^testing.T) {
	w := setup()
	a := platform.tray_create(w, nil, "a")
	b := platform.tray_create(w, nil, "b")
	if !testing.expect(t, a != nil && b != nil) { return }
	testing.expect(t, a.id != b.id)
	platform.tray_inject(b, 0x0400)
	testing.expect_value(t, len(platform.tray_poll(a)), 0)
	testing.expect_value(t, len(platform.tray_poll(b)), 1)
	clear(&ops)
	platform.destroy_window(w)
	testing.expect_value(t, len(ops), 2)
	for op in ops { testing.expect_value(t, op, platform.Tray_Op.Delete) }
	platform.tray_test_hook = nil
	delete(ops)
	ops = nil
}

@(test)
refused_add_gives_nil :: proc(t: ^testing.T) {
	w := setup()
	defer teardown(w)
	refuse_add = true
	testing.expect(t, platform.tray_create(w, nil, "x") == nil)
}

@(test)
icons_from_pixels :: proc(t: ^testing.T) {
	w := setup()
	defer teardown(w)
	tr := platform.tray_create(w)
	if !testing.expect(t, tr != nil) { return }
	px := make([]u8, 24 * 24 * 4)
	defer delete(px)
	for i := 0; i < len(px); i += 4 { px[i], px[i + 3] = 255, u8(i / 4 % 256) }
	testing.expect(t, platform.tray_set_icon_rgba(tr, px, {24, 24}))
	testing.expect(t, !platform.tray_set_icon_rgba(tr, px[:10], {24, 24}), "too few pixels")
	png := platform.png_encode({px, {24, 24}})
	defer delete(png)
	testing.expect(t, platform.tray_set_icon(tr, png), "an icon from a PNG file")
	testing.expect(t, !platform.tray_set_icon(tr, []u8{1, 2, 3, 4}), "not an image")
	testing.expect(t, platform.tray_set_icon(tr, nil), "the exe's icon (or the system's)")
}

@(test)
menu_copy_and_find :: proc(t: ^testing.T) {
	w := setup()
	defer teardown(w)
	tr := platform.tray_create(w)
	if !testing.expect(t, tr != nil) { return }
	sub := []platform.Tray_Menu_Item{{id = 10, text = "Online", kind = .Radio, checked = true}, {id = 11, text = "Away", kind = .Radio}}
	items := []platform.Tray_Menu_Item{
		{id = 1, text = "Open", default = true},
		{kind = .Separator},
		{id = 2, text = "Mute", kind = .Check, checked = true},
		{text = "Status", children = sub},
		{id = 3, text = "Quit", disabled = true},
	}
	platform.tray_set_menu(tr, items)
	testing.expect_value(t, len(tr.menu), 5)
	testing.expect(t, raw_data(tr.menu[0].text) != raw_data(items[0].text), "the text is copied")
	f := platform.tray_menu_find(tr.menu[:], 11)
	if testing.expect(t, f != nil) { testing.expect_value(t, f.text, "Away") }
	testing.expect(t, platform.tray_menu_find(tr.menu[:], 0) == nil, "a separator is no item")
	platform.tray_set_menu(tr, items[:1])
	testing.expect_value(t, len(tr.menu), 1)
}

// The native menu made from a model: one entry per item, separators, check and radio marks, the default item, a
// disabled one, a submenu; each command maps back to its item's id. Built, read with GetMenuItemInfoW, never shown.
@(test)
the_native_menu_of_a_model :: proc(t: ^testing.T) {
	sub := []platform.Tray_Menu_Item{{id = 10, text = "Online", kind = .Radio, checked = true}, {id = 11, text = "Away", kind = .Radio}}
	items := []platform.Tray_Menu_Item{
		{id = 1, text = "Open", default = true},
		{kind = .Separator},
		{id = 2, text = "Mute", kind = .Check, checked = true},
		{id = 4, text = "Spell check", kind = .Check},
		{text = "Status", children = sub},
		{id = 3, text = "Quit", disabled = true},
	}
	ids: [dynamic]int
	defer delete(ids)
	menu := platform.tray_menu_build(items, &ids)
	if !testing.expect(t, menu != nil) { return }
	defer win.DestroyMenu(menu)
	testing.expect_value(t, GetMenuItemCount(menu), i32(len(items)))
	testing.expect_value(t, len(ids), 6)   // the commands: every item but the separator and the submenu's own entry

	Entry :: struct { ftype, state: u32, cmd: int, text: string, sub: win.HMENU }
	entry :: proc(menu: win.HMENU, pos: int) -> (e: Entry) {
		buf: [TEXT_MAX]u16
		mi := win.MENUITEMINFOW{cbSize = size_of(win.MENUITEMINFOW), fMask = win.MIIM_FTYPE | win.MIIM_STATE | win.MIIM_ID | win.MIIM_SUBMENU | win.MIIM_STRING, dwTypeData = &buf[0], cch = TEXT_MAX}
		if !win.GetMenuItemInfoW(menu, u32(pos), true, &mi) { return }
		text, _ := win.utf16_to_utf8(buf[:mi.cch], context.temp_allocator)
		return {mi.fType, mi.fState, int(mi.wID), text, mi.hSubMenu}
	}
	id_of :: proc(ids: []int, cmd: int) -> int { return cmd >= 1 && cmd <= len(ids) ? ids[cmd - 1] : -1 }

	open := entry(menu, 0)
	testing.expect_value(t, open.text, "Open")
	testing.expect_value(t, id_of(ids[:], open.cmd), 1)
	testing.expect(t, open.state & win.MFS_DEFAULT != 0, "the default item is marked")
	testing.expect(t, open.state & (win.MFS_GRAYED | win.MFS_CHECKED) == 0)
	testing.expect(t, entry(menu, 1).ftype & MFT_SEPARATOR != 0, "a separator")
	mute := entry(menu, 2)
	testing.expect_value(t, id_of(ids[:], mute.cmd), 2)
	testing.expect(t, mute.state & win.MFS_CHECKED != 0 && mute.ftype & MFT_RADIOCHECK == 0, "a check mark, not a radio dot")
	testing.expect(t, entry(menu, 3).state & win.MFS_CHECKED == 0, "an unchecked check item")
	status := entry(menu, 4)
	testing.expect_value(t, status.text, "Status")
	if testing.expect(t, status.sub != nil, "a submenu") {
		testing.expect_value(t, GetMenuItemCount(status.sub), i32(2))
		online, away := entry(status.sub, 0), entry(status.sub, 1)
		testing.expect_value(t, id_of(ids[:], online.cmd), 10)
		testing.expect_value(t, id_of(ids[:], away.cmd), 11)
		testing.expect(t, online.ftype & MFT_RADIOCHECK != 0 && online.state & win.MFS_CHECKED != 0, "the radio item chosen")
		testing.expect(t, away.ftype & MFT_RADIOCHECK != 0 && away.state & win.MFS_CHECKED == 0, "the other radio item")
	}
	quit := entry(menu, 5)
	testing.expect_value(t, id_of(ids[:], quit.cmd), 3)
	testing.expect(t, quit.state & win.MFS_GRAYED != 0, "a disabled item is grayed")
}