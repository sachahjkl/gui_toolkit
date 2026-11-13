package platform

import "core:strings"

// The AppUserModelID of a program: its publisher and its name, each in PascalCase of ASCII letters and digits, joined by a
// dot ("Froment Software", "opencode native": "FromentSoftware.OpencodeNative"). Derived, never written: the build's
// GT_AUMID (gt:toolbox's Project) and the shortcuts' (gt:desktop's Identity) come from this one rule, so the taskbar
// groups the windows with the shortcuts without two strings to keep equal. A word keeps its other letters ("OpenCode"
// stays); a character that is not an ASCII letter or digit ends a word and is left out. An empty publisher gives the name
// alone.
app_user_model_id :: proc(publisher, name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	pascal_write(&b, publisher)
	if strings.builder_len(b) > 0 { strings.write_byte(&b, '.') }
	before := strings.builder_len(b)
	pascal_write(&b, name)
	// (a publisher alone is no name: without one, there is no identity to derive)
	if strings.builder_len(b) == before { return "" }
	return strings.to_string(b)
}

@(private = "file")
pascal_write :: proc(b: ^strings.Builder, s: string) {
	word_start := true
	for i in 0 ..< len(s) {
		c := s[i]
		alnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !alnum {
			word_start = true
			continue
		}
		if word_start && c >= 'a' && c <= 'z' { c -= 'a' - 'A' }
		strings.write_byte(b, c)
		word_start = false
	}
}
