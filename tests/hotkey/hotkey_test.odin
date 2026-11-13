// Hotkeys (platform/hotkey.odin): their text read and written; on Windows, one registered on a hidden window and its
// WM_HOTKEY made a Hotkey event with its id.
//   odin test tests/hotkey -vet -define:ODIN_TEST_THREADS=1
package hotkey_test

import "core:testing"
import i18n "../../src/i18n"
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

// The keysym names of the keys a hotkey names, as xkb reads them in a keymap.
@(test)
a_key_has_its_keysym_name :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.keysym_name_of(.V), "v")
	testing.expect_value(t, platform.keysym_name_of(.N7), "7")
	testing.expect_value(t, platform.keysym_name_of(.F12), "F12")
	testing.expect_value(t, platform.keysym_name_of(.Page_Up), "Prior")
	testing.expect_value(t, platform.keysym_name_of(.Insert), "Insert")
	testing.expect_value(t, platform.keysym_name_of(.Menu), "")
}

// A key named by the character it types (no Key for it: the French ù): read, written back, its keysym by its code point.
@(test)
a_key_named_by_its_character :: proc(t: ^testing.T) {
	hk, ok := platform.hotkey_parse("Ctrl+Shift+ù")
	testing.expect(t, ok)
	testing.expect_value(t, hk, platform.Hotkey{mods = {.Ctrl, .Shift}, char = 'ù'})
	testing.expect_value(t, platform.hotkey_text(hk), "Ctrl+Shift+ù")
	testing.expect_value(t, platform.keysym_of(hk), "U00F9")
	testing.expect_value(t, platform.keysym_of({key = .V}), "v")
	_, ok = platform.hotkey_parse("Ctrl+ùù")
	testing.expect(t, !ok, "one character")
}

// A key's text for a person, from each form a key takes, in English and in French (the toolkit's catalogue alone: a
// program adds no key's word). hotkey_text stays English whatever the language: a file keeps it.
@(test)
a_key_reads_in_the_language :: proc(t: ^testing.T) {
	texts :: proc() -> [10]string {
		return {
			platform.key_text(platform.Key.Page_Down),
			platform.key_text(platform.Key.Print),
			platform.key_text(platform.Hotkey{key = .Print, mods = {.Ctrl, .Shift}}),
			platform.key_text(platform.Hotkey{key = .Space, mods = {.Alt}, super = true}),
			platform.key_text(platform.Hotkey{mods = {.Ctrl}, char = 'ù'}),
			platform.key_text(platform.Hotkey{}),
			platform.key_text("Ctrl+K, Ctrl+Shift+P"),
			platform.key_text("CTRL+SHIFT+a"),
			platform.key_text("Ctrl+Esc, PageUp, Ctrl+,, Ctrl++"),
			platform.key_text("Shift+Insert, Delete, Return, Page_Down, Escape, Ctrl+Enter, Click"),
		}
	}
	EN :: [10]string{
		"Page Down", "Print", "Ctrl+Shift+Print", "Alt+Win+Space", "Ctrl+ù", "",
		"Ctrl+K, Ctrl+Shift+P", "Ctrl+Shift+A", "Ctrl+Escape, Page Up, Ctrl+,, Ctrl++",
		"Shift+Insert, Delete, Enter, Page Down, Escape, Ctrl+Enter, Click",
	}
	FR :: [10]string{
		"Pg suiv", "Impr. écran", "Ctrl+Maj+Impr. écran", "Alt+Win+Espace", "Ctrl+ù", "",
		"Ctrl+K, Ctrl+Maj+P", "Ctrl+Maj+A", "Ctrl+Échap, Pg préc, Ctrl+,, Ctrl++",
		"Maj+Inser, Suppr, Entrée, Pg suiv, Échap, Ctrl+Entrée, Click",
	}
	en, fr := EN, FR
	got := texts()
	for g, i in got { testing.expectf(t, g == en[i], "English %d: %q, want %q", i, g, en[i]) }

	l, bad := i18n.load("fr", nil)
	defer { i18n.use(nil); i18n.destroy(l) }
	testing.expect_value(t, len(bad), 0)
	i18n.use(l)
	got = texts()
	for g, i in got { testing.expectf(t, g == fr[i], "French %d: %q, want %q", i, g, fr[i]) }
	testing.expect_value(t, platform.hotkey_text({key = .Print, mods = {.Shift}}), "Shift+Print")
}
