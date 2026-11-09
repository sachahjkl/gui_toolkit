package platform

// Hotkeys: a key combination the system gives a window wherever the keyboard is (a launcher's, a clipboard history's).
// A Hotkey event with the hotkey's id reaches the window, shown or hidden.
//
//   hotkey_register(w, 1, hk)   true: it is the program's until hotkey_unregister or the window's end
//
// Windows: RegisterHotKey. Elsewhere none (false): on Linux the compositor binds shortcuts to commands, and a program
// takes them as a command line (instance.forward).
//
// send_hotkey(w, hk) is the other way: it presses `hk` as the user would, for whatever window has the keyboard (another
// program's: a clipboard history pastes into the program it was called from with Ctrl+V). Windows: SendInput. Wayland:
// a virtual keyboard (zwp_virtual_keyboard_v1; false when the compositor has none). X11, elsewhere: false. On Wayland it
// is the window's thread that calls it (its connection).

import "core:strings"
import "../ascii"

// A combination: a key and its modifiers. `super` is the logo key (Windows: the Windows key).
Hotkey :: struct {
	key:   Key,
	mods:  Modifiers,
	super: bool,
}

// The names a hotkey's text takes, "+" between them: Ctrl, Shift, Alt, Win (or Super), then the key: a letter, a digit,
// F1 to F12, Space, Tab, Return, Escape, Insert, Delete, Home, End, Page_Up, Page_Down, Left, Right, Up, Down. Case is
// ignored ("ctrl+shift+v").
hotkey_parse :: proc(text: string) -> (hk: Hotkey, ok: bool) {
	parts := strings.split(text, "+", context.temp_allocator)
	for p, i in parts {
		word := strings.trim_space(p)
		last := i == len(parts) - 1
		switch {
		case ascii.equal_fold(word, "ctrl") || ascii.equal_fold(word, "control"): hk.mods += {.Ctrl}
		case ascii.equal_fold(word, "shift"): hk.mods += {.Shift}
		case ascii.equal_fold(word, "alt"):   hk.mods += {.Alt}
		case ascii.equal_fold(word, "win") || ascii.equal_fold(word, "super") || ascii.equal_fold(word, "logo"): hk.super = true
		case last:
			hk.key = hotkey_key_of(word)
			if hk.key == .None { return {}, false }
		case:
			return {}, false
		}
	}
	// (a key, and a modifier: a lone letter would take that letter from every program)
	return hk, hk.key != .None && (hk.mods != {} || hk.super)
}

// The text of a hotkey, as hotkey_parse reads it ("Ctrl+Shift+V").
hotkey_text :: proc(hk: Hotkey, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if .Ctrl in hk.mods  { strings.write_string(&b, "Ctrl+") }
	if .Shift in hk.mods { strings.write_string(&b, "Shift+") }
	if .Alt in hk.mods   { strings.write_string(&b, "Alt+") }
	if hk.super          { strings.write_string(&b, "Win+") }
	for name, k in HOTKEY_KEY_NAMES { if k == hk.key { strings.write_string(&b, name) } }
	return strings.to_string(b)
}

@(private, rodata)
HOTKEY_KEY_NAMES := #partial [Key]string{
	.A = "A", .B = "B", .C = "C", .D = "D", .E = "E", .F = "F", .G = "G", .H = "H", .I = "I", .J = "J", .K = "K", .L = "L",
	.M = "M", .N = "N", .O = "O", .P = "P", .Q = "Q", .R = "R", .S = "S", .T = "T", .U = "U", .V = "V", .W = "W", .X = "X",
	.Y = "Y", .Z = "Z",
	.N0 = "0", .N1 = "1", .N2 = "2", .N3 = "3", .N4 = "4", .N5 = "5", .N6 = "6", .N7 = "7", .N8 = "8", .N9 = "9",
	.F1 = "F1", .F2 = "F2", .F3 = "F3", .F4 = "F4", .F5 = "F5", .F6 = "F6", .F7 = "F7", .F8 = "F8", .F9 = "F9",
	.F10 = "F10", .F11 = "F11", .F12 = "F12",
	.Space = "Space", .Tab = "Tab", .Return = "Return", .Escape = "Escape", .Insert = "Insert", .Delete = "Delete",
	.Home = "Home", .End = "End", .Page_Up = "Page_Up", .Page_Down = "Page_Down",
	.Left = "Left", .Right = "Right", .Up = "Up", .Down = "Down",
}

// The xkb name of a key's symbol ("v", "F5", "Insert"), for a keymap; "" for a key a hotkey cannot name.
keysym_name_of :: proc(k: Key) -> string { return KEYSYM_NAMES[k] }

@(private, rodata)
KEYSYM_NAMES := #partial [Key]string{
	.A = "a", .B = "b", .C = "c", .D = "d", .E = "e", .F = "f", .G = "g", .H = "h", .I = "i", .J = "j", .K = "k", .L = "l",
	.M = "m", .N = "n", .O = "o", .P = "p", .Q = "q", .R = "r", .S = "s", .T = "t", .U = "u", .V = "v", .W = "w", .X = "x",
	.Y = "y", .Z = "z",
	.N0 = "0", .N1 = "1", .N2 = "2", .N3 = "3", .N4 = "4", .N5 = "5", .N6 = "6", .N7 = "7", .N8 = "8", .N9 = "9",
	.F1 = "F1", .F2 = "F2", .F3 = "F3", .F4 = "F4", .F5 = "F5", .F6 = "F6", .F7 = "F7", .F8 = "F8", .F9 = "F9",
	.F10 = "F10", .F11 = "F11", .F12 = "F12",
	.Space = "space", .Tab = "Tab", .Return = "Return", .Escape = "Escape", .Insert = "Insert", .Delete = "Delete",
	.Home = "Home", .End = "End", .Page_Up = "Prior", .Page_Down = "Next",
	.Left = "Left", .Right = "Right", .Up = "Up", .Down = "Down",
}

@(private)
hotkey_key_of :: proc(word: string) -> Key {
	for name, k in HOTKEY_KEY_NAMES { if name != "" && ascii.equal_fold(name, word) { return k } }
	if ascii.equal_fold(word, "enter") { return .Return }
	if ascii.equal_fold(word, "esc") { return .Escape }
	return .None
}
