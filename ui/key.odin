package ui

import "core:strings"

// Id strings follow raddebugger's rules:
//   "Label##hidden"   shows "Label", hashes the whole string
//   "Label###id"      shows "Label", hashes only "id" (stable key while the label changes)
//   "###id"           shows nothing, hashes "id"
hash_part :: proc(s: string) -> string {
	if i := strings.index(s, "###"); i >= 0 { return s[i + 3:] }
	return s
}

display_part :: proc(s: string) -> string {
	if i := strings.index(s, "##"); i >= 0 { return s[:i] }
	return s
}

key_from_string :: proc(seed: Key, s: string) -> Key {
	h := u64(seed)
	if h == 0 { h = 0xcbf29ce484222325 }
	for b in transmute([]u8)hash_part(s) {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	if h == 0 { h = 1 }
	return Key(h)
}

key_from_u64 :: proc(seed: Key, v: u64) -> Key {
	h := u64(seed)
	if h == 0 { h = 0xcbf29ce484222325 }
	for i in 0 ..< 8 { h = (h ~ ((v >> (u64(i) * 8)) & 0xff)) * 0x100000001b3 }
	if h == 0 { h = 1 }
	return Key(h)
}
