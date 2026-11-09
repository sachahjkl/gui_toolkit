#+build windows
package hotkey_test

import win "core:sys/windows"
import "core:testing"
import "../../src/platform"

// A combination no program of a runner holds: registered, its message is a Hotkey event with its id; unregistered, it
// can be registered again.
@(test)
a_registered_hotkey_reaches_its_window :: proc(t: ^testing.T) {
	w := platform.open_window("hotkey test", {200, 120})   // (never shown)
	defer platform.destroy_window(w)
	hk, _ := platform.hotkey_parse("Ctrl+Alt+Shift+F11")
	testing.expect(t, platform.hotkey_register(w, 7, hk))
	win.PostMessageW(w.hwnd, win.WM_HOTKEY, 7, 0)
	got := -1
	for _ in 0 ..< 10 {
		for e in platform.poll_events(w, true, 50) { if e.kind == .Hotkey { got = e.hotkey } }
		if got >= 0 { break }
	}
	testing.expect_value(t, got, 7)
	platform.hotkey_unregister(w, 7)
	testing.expect(t, platform.hotkey_register(w, 8, hk), "free again")
	platform.hotkey_unregister(w, 8)
}
