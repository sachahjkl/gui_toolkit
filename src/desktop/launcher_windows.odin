package tk_desktop

import "core:strings"

// `<dir>\<stem>.com` for the executable `<dir>\<stem>.exe`; "" when `exe` has no extension. (cmd and PowerShell run the
// .com before the .exe of the same name: the launcher that waits for the program.)
launcher_file :: proc(exe: string, allocator := context.temp_allocator) -> string {
	slash := max(strings.last_index_byte(exe, '\\'), strings.last_index_byte(exe, '/'))
	dot := strings.last_index_byte(exe, '.')
	if dot <= slash + 1 { return "" }
	return strings.concatenate({exe[:dot], ".com"}, allocator)
}
