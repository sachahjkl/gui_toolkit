#+build windows
// The clipboard of a window with no HWND, in a window station of the test's own: a clipboard belongs to the station, so the
// person's clipboard is not touched. (Its own package: a window station is the whole process's.)
//   odin test tests/clipboard_station -vet
package clipboard_station_test

import "core:testing"
import win "core:sys/windows"
import "../../platform"

foreign import user32 "system:User32.lib"
@(default_calling_convention = "system")
foreign user32 {
	CreateWindowStationW :: proc(name: win.LPCWSTR, flags, access: u32, attrs: rawptr) -> win.HANDLE ---
	SetProcessWindowStation :: proc(station: win.HANDLE) -> win.BOOL ---
}
WINSTA_ALL_ACCESS :: 0x37F

@(test)
an_offscreen_window_writes_the_clipboard :: proc(t: ^testing.T) {
	station := CreateWindowStationW(nil, 0, WINSTA_ALL_ACCESS, nil)
	testing.expect(t, station != nil, "a window station of the test's own")
	if station == nil { return }
	testing.expect(t, bool(SetProcessWindowStation(station)))

	w := platform.open_window_offscreen("clipboard", {16, 16})
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)

	platform.set_clipboard(w, "plain text")
	testing.expect_value(t, platform.get_clipboard(w, context.temp_allocator), "plain text")

	testing.expect(t, platform.clipboard_set(w, {text = "second", html = "<b>x</b>"}), "every flavour written")
	testing.expect_value(t, platform.get_clipboard(w, context.temp_allocator), "second")
	testing.expect(t, .Html in platform.clipboard_formats())
	html, _, ok := platform.clipboard_get_html(w, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, html, "<b>x</b>")
}
