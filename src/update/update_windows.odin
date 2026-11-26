package tk_update

import "core:fmt"
import "core:os"
import win "core:sys/windows"

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

// This process may create a file in `dir` (the program's folder): the folder opened for the right to add a file, which
// the system grants or refuses by its access list; nothing is written. False for an install for everyone (Program
// Files), where only an administrator adds files.
@(private)
folder_takes_files :: proc(dir: string) -> bool {
	if dir == "" { return false }
	name := win.utf8_to_wstring(dir, context.temp_allocator)
	h := win.CreateFileW(name, win.FILE_ADD_FILE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS, nil)
	if h == win.INVALID_HANDLE_VALUE { return false }
	win.CloseHandle(h)
	return true
}
