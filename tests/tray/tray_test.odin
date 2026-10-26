// The notification area icon (platform/tray.odin): the shell's notifications translated into events, the calls made
// to the shell (add, version 4, modify, delete; again after the shell restarted), menus, icons. The shell is replaced by
// tray_test_hook: no icon appears on the desktop. A hidden window receives the notifications through its window
// procedure (tray_inject sends them as the shell does).
//   odin test tests/tray -vet -define:ODIN_TEST_THREADS=1
package tray_test

import "core:testing"
import "../../platform"

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
