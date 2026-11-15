#+build darwin
package platform

import "core:os"
import "core:path/filepath"
import "core:strings"

USER_DIR_SEPARATOR :: "/"   // (between a folder and the next: a program's folder written as vendor and name)

// macOS's folders of a user (Apple's File System Programming Guide): a program's settings, data and state in
// ~/Library/Application Support/<program> (its settings are its own files, not NSUserDefaults' plists of
// ~/Library/Preferences), its cache in ~/Library/Caches/<program>, its runtime files in the user's own $TMPDIR (macOS
// makes it per user, /var/folders/...). Its logs: ~/Library/Logs/<program> (log.default_dir). Temp memory; "": no home.
@(private)
user_dir_base :: proc(kind: User_Dir) -> string {
	if kind == .Runtime {
		if v, found := os.lookup_env("TMPDIR", context.temp_allocator); found && filepath.is_abs(v) { return strings.trim_right(v, "/") }
		return "/tmp"
	}
	home, found := os.lookup_env("HOME", context.temp_allocator)
	if !found || !filepath.is_abs(home) { return "" }
	switch kind {
	case .Config, .Data, .State: return strings.concatenate({home, "/Library/Application Support"}, context.temp_allocator)
	case .Cache:                 return strings.concatenate({home, "/Library/Caches"}, context.temp_allocator)
	case .Runtime:
	}
	return ""
}

// (settings and data share the program's folder of Application Support: its state goes in a folder of it, as on Windows)
@(private)
user_dir_leaf :: proc(kind: User_Dir) -> string { return kind == .State ? "state" : "" }

// macOS has no session runtime folder of the kind XDG names: user_dir(.Runtime) is the user's $TMPDIR.
session_runtime_dir :: proc(allocator := context.allocator, loc := #caller_location) -> (dir: string, ok: bool) {
	return "", false
}
