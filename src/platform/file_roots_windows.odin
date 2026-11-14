package platform

import "core:strings"

foreign import kernel32_roots "system:Kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32_roots {
	GetLogicalDrives :: proc() -> u32 ---
}

// The letters of the drives the system has, each "X:\".
@(private)
file_roots_read :: proc(allocator := context.allocator) -> []string {
	mask := GetLogicalDrives()
	out := make([dynamic]string, 0, 4, allocator)
	for i in 0 ..< 26 {
		if mask & (1 << u32(i)) == 0 { continue }
		letter := [3]u8{u8('A' + i), ':', '\\'}
		append(&out, strings.clone(string(letter[:]), allocator))
	}
	return out[:]
}
