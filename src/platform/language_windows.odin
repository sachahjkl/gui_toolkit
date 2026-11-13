package platform

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	GetUserDefaultLocaleName :: proc(lpLocaleName: win.LPWSTR, cchLocaleName: i32) -> i32 ---
}

// The user's locale ("fr-FR"): Windows' names are language tags already.
@(private)
system_language_read :: proc(allocator := context.allocator) -> string {
	buf: [win.LOCALE_NAME_MAX_LENGTH]u16
	n := GetUserDefaultLocaleName(&buf[0], i32(len(buf)))
	if n <= 1 { return "" }
	s, _ := win.utf16_to_utf8(buf[:n - 1], allocator)
	return s
}
