// The pure parts of gt:shortcuts and of the hotkeys it reads: the portal's trigger of a combination, Print Screen, what
// makes a combination complete. The portal itself and RegisterHotKey need a desktop: not here.
//   odin test tests/shortcuts -vet
package shortcuts_test

import "core:testing"
import "../../src/platform"
import shortcuts "../../src/shortcuts"

@(private = "file")
parse :: proc(t: ^testing.T, text: string, loc := #caller_location) -> platform.Hotkey {
	hk, ok := platform.hotkey_parse(text)
	testing.expectf(t, ok, "%q does not parse", text, loc = loc)
	return hk
}

@(test)
portal_triggers :: proc(t: ^testing.T) {
	cases := [?][2]string{
		{"Ctrl+Shift+4", "CTRL+SHIFT+4"},
		{"Print", "Print"},
		{"Shift+Print", "SHIFT+Print"},
		{"Ctrl+Alt+Q", "CTRL+ALT+q"},
		{"Win+Shift+S", "SHIFT+LOGO+s"},
		{"Alt+F5", "ALT+F5"},
		{"Ctrl+Page_Up", "CTRL+Prior"},
	}
	for c in cases {
		got := shortcuts.portal_trigger(parse(t, c[0]))
		testing.expectf(t, got == c[1], "%q: %q, want %q", c[0], got, c[1])
	}
	testing.expect_value(t, shortcuts.portal_trigger({}), "")
}

@(test)
print_screen_alone :: proc(t: ^testing.T) {
	hk := parse(t, "Print")
	testing.expect_value(t, hk.key, platform.Key.Print)
	testing.expect_value(t, platform.hotkey_text(hk), "Print")
	testing.expect_value(t, parse(t, "PrintScreen").key, platform.Key.Print)
	// (a key alone is no shortcut, Print Screen apart)
	_, ok := platform.hotkey_parse("Q")
	testing.expect(t, !ok)
	_, ok = platform.hotkey_parse("F5")
	testing.expect(t, !ok)
	testing.expect(t, platform.hotkey_complete({key = .Print}))
	testing.expect(t, platform.hotkey_complete({key = .A, super = true}))
	testing.expect(t, !platform.hotkey_complete({mods = {.Ctrl}}))
}

// Without a service: everything answers, nothing is held.
@(test)
no_service :: proc(t: ^testing.T) {
	testing.expect_value(t, shortcuts.backend(nil), shortcuts.Backend.None)
	testing.expect_value(t, shortcuts.status(nil, "x").state, shortcuts.State.Unavailable)
	testing.expect(t, len(shortcuts.take(nil)) == 0)
	testing.expect(t, !shortcuts.configure(nil))
}
