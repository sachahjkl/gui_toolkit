package platform

// A key's text for a person to read, in the language in use: "Ctrl+Maj+Impr. écran" in French. One procedure for every
// form a key takes (a Key, a Hotkey, the English text a file or a program's table holds), so that a menu's line, a
// tooltip, the sheet of the keys, the palette and the settings' rows all name a key the same way. hotkey_text stays the
// English that hotkey_parse reads back: a file keeps that one, never this.
//
//   key_text(Key.Page_Down)               "Pg suiv"
//   key_text(Hotkey{key = .Print, mods = {.Shift}})   "Maj+Impr. écran"
//   key_text("Ctrl+K, Ctrl+Shift+P")      "Ctrl+K, Ctrl+Maj+P"   (each chord of a list, its separators kept)
//
// ui.chord_text gives a ui.Chord's with the same words.

import "core:strings"
import "../ascii"
import i18n "../i18n"

key_text :: proc{key_text_key, key_text_hotkey, key_text_written}

// A key's name as keyboards and menus print it ("" for .None).
key_text_key :: proc(k: Key) -> string {
	#partial switch k {
	case .A ..= .Z:
		letters := KEY_LETTERS
		return letters[int(k) - int(Key.A)]
	case .N0 ..= .N9:
		digits := KEY_DIGITS
		return digits[int(k) - int(Key.N0)]
	case .F1 ..= .F12:
		functions := KEY_FUNCTIONS
		return functions[int(k) - int(Key.F1)]
	case .Escape:       return i18n.tr("key", "Escape")
	case .Return:       return i18n.tr("key", "Enter")
	case .Tab:          return i18n.tr("key", "Tab")
	case .Space:        return i18n.tr("key", "Space")
	case .Backspace:    return i18n.tr("key", "Backspace")
	case .Delete:       return i18n.tr("key", "Delete")
	case .Insert:       return i18n.tr("key", "Insert")
	case .Left:         return i18n.tr("key", "Left")
	case .Right:        return i18n.tr("key", "Right")
	case .Up:           return i18n.tr("key", "Up")
	case .Down:         return i18n.tr("key", "Down")
	case .Home:         return i18n.tr("key", "Home")
	case .End:          return i18n.tr("key", "End")
	case .Page_Up:      return i18n.tr("key", "Page Up")
	case .Page_Down:    return i18n.tr("key", "Page Down")
	case .Shift:        return i18n.tr("key", "Shift")
	case .Ctrl:         return i18n.tr("key", "Ctrl")
	case .Alt:          return i18n.tr("key", "Alt")
	case .Menu:         return i18n.tr("key", "Menu")
	case .Print:        return i18n.tr("key", "Print")
	case .Comma:        return ","
	case .Period:       return "."
	case .Slash:        return "/"
	case .Minus:        return "-"
	case .Equal:        return "="
	case .Num_Add:      return "Num +"
	case .Num_Subtract: return "Num -"
	}
	return ""
}

// A combination: its modifiers in the order Ctrl, Shift, Alt, Win, then its key ("" with no key).
key_text_hotkey :: proc(hk: Hotkey, allocator := context.temp_allocator) -> string {
	if hk.key == .None && hk.char == 0 { return "" }
	b := strings.builder_make(allocator)
	if .Ctrl in hk.mods  { strings.write_string(&b, key_text_key(.Ctrl)); strings.write_byte(&b, '+') }
	if .Shift in hk.mods { strings.write_string(&b, key_text_key(.Shift)); strings.write_byte(&b, '+') }
	if .Alt in hk.mods   { strings.write_string(&b, key_text_key(.Alt)); strings.write_byte(&b, '+') }
	// (the logo key has no word of the language: keyboards print a logo, and "Win" is what hotkey_text writes)
	if hk.super          { strings.write_string(&b, "Win+") }
	if hk.key == .None { strings.write_rune(&b, hk.char) } else { strings.write_string(&b, key_text_key(hk.key)) }
	return strings.to_string(b)
}

// Keys written in English: hotkey_text's form ("Ctrl+Shift+Page_Up"), a portal's ("CTRL+SHIFT+a"), a program's table's
// ("Ctrl+Esc", "PageDown"), a list of them apart by commas. Each word that names a modifier or a key becomes its text; a
// word that names none (a sign, a character, "Click") stays as it is, and so do the separators and spaces.
key_text_written :: proc(text: string, allocator := context.temp_allocator) -> string {
	if text == "" { return "" }
	b := strings.builder_make(allocator)
	start := 0
	for i := 0; i <= len(text); i += 1 {
		// (a word ends at a "+" that is not itself the key, at a "," or at the end: "Ctrl++" is Ctrl and "+")
		if i < len(text) && !(text[i] == '+' && i > start) && text[i] != ',' { continue }
		word_text(&b, text[start:i])
		if i < len(text) { strings.write_byte(&b, text[i]) }
		start = i + 1
	}
	return strings.to_string(b)
}

// One word of a written key, the spaces around it kept (", " between the chords of a list).
@(private = "file")
word_text :: proc(b: ^strings.Builder, word: string) {
	w := strings.trim_left_space(word)
	strings.write_string(b, word[:len(word) - len(w)])
	core := strings.trim_right_space(w)
	strings.write_string(b, word_name(core))
	strings.write_string(b, w[len(core):])
}

@(private = "file")
word_name :: proc(word: string) -> string {
	switch {
	case word == "": return ""
	case ascii.equal_fold(word, "ctrl") || ascii.equal_fold(word, "control"): return key_text_key(.Ctrl)
	case ascii.equal_fold(word, "shift"): return key_text_key(.Shift)
	case ascii.equal_fold(word, "alt"):   return key_text_key(.Alt)
	case ascii.equal_fold(word, "win") || ascii.equal_fold(word, "super") || ascii.equal_fold(word, "logo"): return "Win"
	case ascii.equal_fold(word, "backspace"): return key_text_key(.Backspace)
	case ascii.equal_fold(word, "menu"):      return key_text_key(.Menu)
	}
	if k := hotkey_key_of(word); k != .None { return key_text_key(k) }
	return word
}

@(private = "file")
KEY_LETTERS :: [26]string{"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"}
@(private = "file")
KEY_DIGITS :: [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
@(private = "file")
KEY_FUNCTIONS :: [12]string{"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"}
