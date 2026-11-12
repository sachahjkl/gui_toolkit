package hotkey_test

// A tray menu item's shortcut (platform/tray.odin), in the forms the systems show it: dbusmenu's keys on Linux, the
// item's text after a tab on Windows.

import "core:testing"
import "../../src/platform"

@(test)
a_shortcut_becomes_dbusmenu_keys :: proc(t: ^testing.T) {
	keys, ok := platform.dbusmenu_shortcut("Ctrl+Print")
	testing.expect(t, ok)
	testing.expect_value(t, len(keys), 2)
	if len(keys) == 2 {
		testing.expect_value(t, keys[0], "Control")
		testing.expect_value(t, keys[1], "Print")
	}
	keys, ok = platform.dbusmenu_shortcut("Print")
	testing.expect(t, ok)
	testing.expect_value(t, len(keys), 1)
	if len(keys) == 1 { testing.expect_value(t, keys[0], "Print") }
}

// libdbusmenu's order, whatever the text's order; the key by its keysym name.
@(test)
the_modifiers_come_in_dbusmenu_order :: proc(t: ^testing.T) {
	keys, ok := platform.dbusmenu_shortcut("Win+Shift+Alt+Ctrl+Q")
	testing.expect(t, ok)
	want := []string{"Control", "Alt", "Shift", "Super", "q"}
	testing.expect_value(t, len(keys), len(want))
	if len(keys) == len(want) {
		for k, i in want { testing.expect_value(t, keys[i], k) }
	}
	keys, ok = platform.dbusmenu_shortcut("Shift+Page_Down")
	testing.expect(t, ok)
	if testing.expect_value(t, len(keys), 2) { testing.expect_value(t, keys[1], "Next") }
}

@(test)
no_shortcut_gives_no_keys :: proc(t: ^testing.T) {
	_, ok := platform.dbusmenu_shortcut("")
	testing.expect(t, !ok)
	_, ok = platform.dbusmenu_shortcut("Ctrl+Hyper+V")
	testing.expect(t, !ok, "a text hotkey_parse refuses is not shown")
}

@(test)
a_windows_menu_item_shows_its_shortcut_after_a_tab :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.tray_item_label({text = "Region", shortcut = "Ctrl+Print"}), "Region\tCtrl+Print")
	testing.expect_value(t, platform.tray_item_label({text = "Quit"}), "Quit")
}
