#+build !windows
#+build !linux
package tk_desktop

// "Open with" where the toolkit does not read the system's associations: no handler, nothing opened.

import "base:runtime"

@(private)
type_name_native :: proc(name: string, allocator: runtime.Allocator) -> string { return "" }

@(private)
handlers_for_file_native :: proc(path: string, allocator: runtime.Allocator) -> []Handler { return make([]Handler, 0, allocator) }

@(private)
open_with_native :: proc(path: string, id: string) -> bool { return false }
