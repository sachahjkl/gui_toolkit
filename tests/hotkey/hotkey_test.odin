// Hotkeys (platform/hotkey.odin): their text read and written; on Windows, one registered on a hidden window and its
// WM_HOTKEY made a Hotkey event with its id.
//   odin test tests/hotkey -vet -define:ODIN_TEST_THREADS=1
package hotkey_test

import "core:testing"
import "../../src/platform"

@(test)
a_hotkey_reads_from_its_text :: proc(t: ^testing.T) {
	hk, ok := platform.hotkey_parse("ctrl + Shift+v")
	testing.expect(t, ok)
	testing.expect_value(t, hk, platform.Hotkey{key = .V, mods = {.Ctrl, .Shift}})
	hk, ok = platform.hotkey_parse("Win+Alt+F9")
	testing.expect(t, ok)
	testing.expect_value(t, hk, platform.Hotkey{key = .F9, mods = {.Alt}, super = true})
	testing.expect_value(t, platform.hotkey_text(hk), "Alt+Win+F9")
	_, ok = platform.hotkey_parse("V")
	testing.expect(t, !ok, "a key alone would be taken from every program")
	_, ok = platform.hotkey_parse("Ctrl+Hyper+V")
	testing.expect(t, !ok, "a modifier it does not know")
	_, ok = platform.hotkey_parse("Ctrl+")
	testing.expect(t, !ok, "no key")
}
