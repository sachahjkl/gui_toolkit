package tk_update

import "core:fmt"
import "core:os"

// The platform of this program ("": none that updates itself).
PLATFORM :: PLATFORM_WINDOWS_X64 when ODIN_ARCH == .amd64 else ""

// `next` (the new program, checked) takes the place of `exe`, the running one. A running program can be renamed, not
// overwritten: it goes aside as <exe>.old (remove_leftovers deletes it at the next start), and if the new one cannot take
// its name it comes back.
@(private)
swap_in :: proc(exe, next: string) -> Error {
	old := fmt.tprintf("%s.old", exe)
	_ = os.remove(old)
	if os.rename(exe, old) != nil { _ = os.remove(next); return .Not_Moved_Aside }
	if os.rename(next, exe) != nil {
		_ = os.rename(old, exe)   // (back as it was)
		_ = os.remove(next)
		return .Not_Placed
	}
	return .None
}
