#+build windows
package platform

import win "core:sys/windows"

@(private) USER_DIR_SEPARATOR :: "\\"

// The known folder of `kind`: the roaming application data for the configuration, the local one for the rest (temp memory; "":
// the system would not give it).
@(private)
user_dir_base :: proc(kind: User_Dir) -> string {
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
