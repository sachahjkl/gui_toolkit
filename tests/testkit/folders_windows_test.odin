#+build windows
package testkit_test

import "core:strings"
import win "core:sys/windows"
import "core:testing"
import tk "gt:testkit"

// A test's folder is in the system's form, as a program has a path from the system (a file dialog, a drop): backslashes
// alone, and long names. The CI's TEMP is `C:\Users\RUNNER~1\AppData\Local\Temp`, and the folder was
// `...\Temp/gui_toolkit-...`: programs' tests that compared it with a path the system gave failed.
@(test)
a_test_folder_is_in_the_system_s_form :: proc(t: ^testing.T) {
	dir := tk.temp_folder(t, "form")
	testing.expectf(t, !strings.contains(dir, "/"), "backslashes alone: %s", dir)
	testing.expectf(t, !strings.has_suffix(dir, "\\"), "no separator at its end: %s", dir)
	w := win.utf8_to_wstring(dir, context.temp_allocator)
	n := win.GetLongPathNameW(w, nil, 0)
	if !testing.expectf(t, n > 0, "the folder exists: %s", dir) { return }
	buf := make([]u16, n, context.temp_allocator)
	got := win.GetLongPathNameW(w, cast(win.LPCWSTR)raw_data(buf), n)
	long, _ := win.utf16_to_utf8(buf[:got], context.temp_allocator)
	testing.expect_value(t, dir, long)
}
