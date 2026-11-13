package platform

import "core:os"
import "core:strings"

// The POSIX locale of messages: LC_ALL, else LC_MESSAGES, else LANG ("fr_FR.UTF-8" is "fr-FR"); "C" and "POSIX" are none.
@(private)
system_language_read :: proc(allocator := context.allocator) -> string {
	for name in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		v, ok := os.lookup_env(name, context.temp_allocator)
		if !ok || v == "" { continue }
		if v == "C" || v == "POSIX" || strings.has_prefix(v, "C.") { return "" }
		return locale_tag(v, allocator)
	}
	return ""
}

// "fr_FR.UTF-8@euro" as a language tag: "fr-FR".
@(private)
locale_tag :: proc(locale: string, allocator := context.allocator) -> string {
	s := locale
	if i := strings.index_any(s, ".@"); i >= 0 { s = s[:i] }
	t, _ := strings.replace_all(s, "_", "-", allocator)
	return t
}
