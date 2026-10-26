package font

import "base:runtime"

// The system's fonts on a platform whose font service this package does not know (the BSDs...): none. Faces come from
// files and memory the application loads itself.
// TODO(bsd): fontconfig is there too: font_system_linux.odin would serve once its build tag includes them and it is tried.

_ :: runtime

when ODIN_OS != .Windows && ODIN_OS != .Linux && ODIN_OS != .Darwin {

@(private) SYSTEM_FONT_SERVICE :: "none"

@(private)
sys_find :: proc(family: string, weight: int, style: Font_Style, stretch: int) -> (path: string, index: int, ok: bool) { return }

@(private)
sys_find_for_char :: proc(family: string, weight: int, style: Font_Style, r: rune) -> (path: string, index: int, ok: bool) { return }

@(private)
sys_has_family :: proc(family: string) -> bool { return false }

@(private)
sys_families :: proc(allocator: runtime.Allocator) -> []string { return nil }

}
