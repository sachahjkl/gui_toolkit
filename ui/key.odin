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

// FNV-1a, 64 bits (the algorithm's constants): the hash of keys, of the text caches and of the colour names.
@(private) FNV64_OFFSET_BASIS :: 0xcbf29ce484222325
@(private) FNV64_PRIME :: 0x100000001b3
// 2^64 / the golden ratio: spreads small numbers (a child's position, a key) over 64 bits.
@(private) HASH_GOLDEN_RATIO_64 :: 0x9e3779b97f4a7c15

key_from_string :: proc(seed: Key, s: string) -> Key {
	h := u64(seed)
	if h == 0 { h = FNV64_OFFSET_BASIS }
	for b in transmute([]u8)hash_part(s) {
		h = (h ~ u64(b)) * FNV64_PRIME
	}
	if h == 0 { h = 1 }
	return Key(h)
}

key_from_u64 :: proc(seed: Key, v: u64) -> Key {
	h := u64(seed)
	if h == 0 { h = FNV64_OFFSET_BASIS }
	for i in 0 ..< 8 { h = (h ~ ((v >> (u64(i) * 8)) & 0xff)) * FNV64_PRIME }
	if h == 0 { h = 1 }
	return Key(h)
}
