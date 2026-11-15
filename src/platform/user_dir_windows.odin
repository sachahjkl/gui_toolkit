#+build windows
package platform

import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

@(private) USER_DIR_SEPARATOR :: "\\"

// %APPDATA% for the configuration, %LOCALAPPDATA% for the rest, when they are absolute paths (a test, a portable copy points them
// elsewhere, as XDG's variables are on Linux); else the known folder they name. The runtime folder is the system's temporary
// one (temp memory; "": the system would not give it).
@(private)
user_dir_base :: proc(kind: User_Dir) -> string {
	if kind == .Runtime { return system_temp_dir() }
	if v, ok := os.lookup_env(kind == .Config ? "APPDATA" : "LOCALAPPDATA", context.temp_allocator); ok && filepath.is_abs(v) { return v }
	id := kind == .Config ? win.FOLDERID_RoamingAppData : win.FOLDERID_LocalAppData
	path: win.LPWSTR
	if win.SHGetKnownFolderPath(&id, 0, nil, &path) < 0 || path == nil { return "" }
	defer win.CoTaskMemFree(path)
	n := 0
	for (cast([^]u16)path)[n] != 0 { n += 1 }
	s, err := win.utf16_to_utf8((cast([^]u16)path)[:n], context.temp_allocator)
	return err == nil ? s : ""
}

// The state and the cache share the local folder with the data: each has a folder of its own in the program's.
@(private)
user_dir_leaf :: proc(kind: User_Dir) -> string {
	#partial switch kind {
	case .State: return "state"
	case .Cache: return "cache"
	}
	return ""
}

// (Windows has no folder of a session that its services share: src/md/features/folders.md.)
session_runtime_dir :: proc(allocator := context.allocator, loc := #caller_location) -> (dir: string, ok: bool) {
	return "", false
}

// The system's temporary folder as Windows gives it to every program, without its last "\": GetTempPath2W where the system
// has it (a process of SYSTEM gets C:\Windows\SystemTemp, closed to the other accounts), else GetTempPathW (%TMP%, %TEMP%,
// %USERPROFILE%, then the Windows folder). Looked up at run time: an older Windows 10 has no GetTempPath2W (temp memory).
@(private = "file")
system_temp_dir :: proc() -> string {
	Get_Temp_Path :: #type proc "system" (n: win.DWORD, buffer: win.LPCWSTR) -> win.DWORD
	get: Get_Temp_Path = win.GetTempPathW
	if kernel := win.GetModuleHandleW(win.L("kernel32.dll")); kernel != nil {
		if p := win.GetProcAddress(kernel, "GetTempPath2W"); p != nil { get = auto_cast p }
	}
	buf := make([]u16, win.MAX_PATH + 1, context.temp_allocator)
	n := get(win.DWORD(len(buf)), win.wstring(&buf[0]))
	if int(n) > len(buf) {   // (too short: n is the length it needs, with its end)
		buf = make([]u16, int(n), context.temp_allocator)
		n = get(win.DWORD(len(buf)), win.wstring(&buf[0]))
	}
	if n == 0 || int(n) > len(buf) { return "" }
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return "" }
	return len(s) > 3 ? strings.trim_right(s, "\\") : s   // (a drive's root keeps its "\": C:\)
}
