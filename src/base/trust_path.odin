package gt_base

// A segment ".." anywhere in a path (either slash): a path that climbs is never trusted as it is written.
@(private)
contains_dot_dot :: proc(path: string) -> bool {
	start := 0
	for i in 0 ..= len(path) {
		if i == len(path) || path[i] == '/' || path[i] == '\\' {
			if path[start:i] == ".." { return true }
			start = i + 1
		}
	}
	return false
}

// "C:\..." or "\\server\share\..." (a drive's root or a UNC path): the start of a full Windows path.
@(private)
windows_absolute :: proc(path: string) -> bool {
	if len(path) >= 3 && path[1] == ':' && (path[2] == '\\' || path[2] == '/') {
		c := path[0] | 0x20
		return c >= 'a' && c <= 'z'
	}
	return len(path) >= 3 && path[0] == '\\' && path[1] == '\\'
}
