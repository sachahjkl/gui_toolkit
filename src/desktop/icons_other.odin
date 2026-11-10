#+build !windows
#+build !linux
package tk_desktop

// Where the toolkit does not read the system's icons: none (the program draws its own).

import "base:runtime"
import "core:strings"

@(private)
icon_key_native :: proc(path: string, folder: bool, allocator: runtime.Allocator) -> string {
	return strings.clone(folder ? "folder" : "file", allocator)
}

@(private)
icon_of_path_native :: proc(path: string, folder: bool, size, choose: int, allocator: runtime.Allocator) -> (icon: File_Icon, ok: bool) { return }

@(private)
theme_icon_native :: proc(name: string, size: int, allocator: runtime.Allocator) -> (icon: File_Icon, ok: bool) { return }
