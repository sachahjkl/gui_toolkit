#+build !windows
#+build !linux
package tk_desktop

import "base:runtime"

// No install for everyone here (supported_scopes).

@(private) system_refusal_here :: proc() -> System_Refusal { return .Unsupported }
@(private) no_elevation_words :: proc() -> string { return "" }
@(private) system_install_dir_here :: proc(o: ^Integration_Options, root: string, allocator: runtime.Allocator) -> string { return "" }
@(private) machine_prepare :: proc(o: ^Integration_Options, dir: string) -> Result { return {.Unsupported, error_text(.Unsupported)} }
@(private) self_image_place :: proc(exe: string) -> Result { return {.Unsupported, error_text(.Unsupported)} }
@(private) remove_at_restart :: proc(path: string) {}
machine_elevate :: proc(o: ^Integration_Options, exe: string, arguments: []string) -> Result { return {.Unsupported, error_text(.Unsupported)} }
