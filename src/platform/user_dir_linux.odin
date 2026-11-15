#+build linux
package platform

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import base "../base"
import fsx "../fsx"

USER_DIR_SEPARATOR :: "/"   // (between a folder and the next: a program's folder written as vendor and name)

// $XDG_<kind>_HOME when it is absolute, else its default under the home (temp memory; "": no home). The runtime folder is
// the session's, else a folder of this user's in the temporary one (src/md/features/folders.md).
@(private)
user_dir_base :: proc(kind: User_Dir) -> string {
	name, fallback: string
	switch kind {
	case .Config: name, fallback = "XDG_CONFIG_HOME", "/.config"
	case .Data:   name, fallback = "XDG_DATA_HOME", "/.local/share"
	case .State:  name, fallback = "XDG_STATE_HOME", "/.local/state"
	case .Cache:  name, fallback = "XDG_CACHE_HOME", "/.cache"
	case .Runtime:
		if dir, ok := session_runtime_dir(context.temp_allocator); ok { return dir }
		return private_runtime_dir()
	}
	if v, ok := os.lookup_env(name, context.temp_allocator); ok && filepath.is_abs(v) { return v }
	home, ok := os.lookup_env("HOME", context.temp_allocator)
	if !ok || home == "" { return "" }
	return strings.concatenate({home, fallback}, context.temp_allocator)
}

// (Linux keeps each kind in a folder of its own: nothing under the program's.)
@(private)
user_dir_leaf :: proc(kind: User_Dir) -> string { return "" }

// $XDG_RUNTIME_DIR when it is absolute (the login manager made it the user's, as the basedir specification says: it is
// trusted as given), else /run/user/<uid> when it is a folder (not a link) of this user closed to the others: systemd-logind
// makes it, and the variable is missing under su, sudo, cron or ssh without pam_systemd while the folder is there.
session_runtime_dir :: proc(allocator := context.allocator, loc := #caller_location) -> (dir: string, ok: bool) {
	if v, found := os.lookup_env("XDG_RUNTIME_DIR", context.temp_allocator); found && filepath.is_abs(v) {
		return strings.clone(v, allocator), true
	}
	base.blocking("platform.session_runtime_dir", loc)
	uid := posix.getuid()
	run := fmt.tprintf("/run/user/%d", uid)
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(run, context.temp_allocator), &st) != .OK { return "", false }
	if !posix.S_ISDIR(st.st_mode) || st.st_uid != uid || st.st_mode & (posix.S_IRWXG + posix.S_IRWXO) != {} { return "", false }
	return strings.clone(run, allocator), true
}

// Without a session's runtime folder: runtime-<uid> in the temporary folder ($TMPDIR when absolute, else /tmp), made the
// user's alone (fsx.private_dir), Qt's fallback. "" when that name is another user's or a link: someone made it first, and
// nothing of this user's goes there (temp memory).
@(private)
private_runtime_dir :: proc() -> string {
	tmp := "/tmp"
	if v, ok := os.lookup_env("TMPDIR", context.temp_allocator); ok && filepath.is_abs(v) { tmp = v }
	dir := fmt.tprintf("%s/runtime-%d", strings.trim_right(tmp, "/"), posix.getuid())
	return fsx.private_dir(dir) ? dir : ""
}
