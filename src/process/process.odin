// Package process: what a program knows of its own process, the same way on every system. Its arguments as UTF-8, its
// executable, and the output for the person or the script that started it, also for a Windows program with a window,
// which has no console of its own.
//
//	command_line_args   the arguments, without the program's name (Windows: from the UTF-16 command line)
//	console_write       the standard output; a Windows program with a window writes to its parent's console
//	console_error       the same on the standard error output
//	executable_path     the running executable ("" when the system cannot say)
//	parent_dir          the folder of a path ("" when it has none)
package tk_process

import "core:os"
import "core:strings"

// The path of the running executable ("" when the system cannot say).
executable_path :: proc(allocator := context.temp_allocator) -> string {
	p, err := os.get_executable_path(allocator)
	if err != nil { return "" }
	return p
}

// The folder of a path, without its last separator ("" when it has none). Both separators count on every system: a
// Windows path read on another system keeps its folder.
parent_dir :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '\\'), strings.last_index_byte(path, '/'))
	return i > 0 ? path[:i] : ""
}
