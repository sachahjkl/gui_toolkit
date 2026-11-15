package platform

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The standard folders of a user, the same names on every system: where a program keeps its configuration, its data, its cache and
// its state (logs, crash reports, what it remembers between runs that is not a setting). Each program has its own folder in each.
//
//	Config   Linux $XDG_CONFIG_HOME/<program> (~/.config)        Windows %APPDATA%\<program>
//	Data     Linux $XDG_DATA_HOME/<program>   (~/.local/share)   Windows %LOCALAPPDATA%\<program>
//	State    Linux $XDG_STATE_HOME/<program>  (~/.local/state)   Windows %LOCALAPPDATA%\<program>\state
//	Cache    Linux $XDG_CACHE_HOME/<program>  (~/.cache)         Windows %LOCALAPPDATA%\<program>\cache
//	Runtime  Linux the session's (session_runtime_dir), else <TMPDIR or /tmp>/runtime-<uid>, made the user's alone
//	         Windows the system's temporary folder (GetTempPath2W, else GetTempPathW)\<program>
//	         (sockets, pipes, files that last a session: the system may empty it at each start)
//
// A variable counts only when it is an absolute path (the XDG specification says a relative one is ignored), on Windows too
// (%APPDATA%, %LOCALAPPDATA%): a test or a portable copy points them elsewhere. Without them, Windows' known folders
// (SHGetKnownFolderPath). The program's folder is not made: a program makes it when it writes there (fsx.make_dirs).
//
// The runtime folder is never one another user can enter or make first (src/md/features/folders.md): on Linux without a
// session's runtime folder, user_dir makes runtime-<uid> closed to the others (fsx.private_dir), and gives "" when another
// user made that name first. So a program's folder in it needs no check of its own. It may ask the system (a stat, a mkdir;
// Windows: a known folder): call it from a task.
User_Dir :: enum u8 { Config, Data, State, Cache, Runtime }

// A program's folder is its vendor's, then its own, on every system ("FromentSoftware" + USER_DIR_SEPARATOR + "Papier":
// %APPDATA%\FromentSoftware\Papier, ~/.config/FromentSoftware/Papier): a vendor's programs sit together, under the names a
// person reads. The program gives it as a constant and passes it wherever it names its folders.

// Moves a program's folders from an older name to `to`, once: for each kind (Runtime aside: it lasts a session), the
// folder of `from` becomes the folder of `to` when `to`'s is not there yet and `from`'s is. A folder that holds another
// kind's (Windows: %LOCALAPPDATA%\<program> holds state and cache) moves once, with them. Call it at start, before
// anything reads the folders and before any window: it waits on the system. `moved`: how many folders moved; `why`: the
// first that could not ("": none), the others still tried.
user_dirs_move :: proc(from, to: string) -> (moved: int, why: string) {
	done := make([dynamic]string, context.temp_allocator)
	for kind in User_Dir {
		if kind == .Runtime { continue }
		base := user_dir_base(kind)
		if base == "" { continue }
		old := strings.concatenate({base, USER_DIR_SEPARATOR, from}, context.temp_allocator)
		new := strings.concatenate({base, USER_DIR_SEPARATOR, to}, context.temp_allocator)
		seen := false
		for d in done { seen ||= d == old }
		if seen { continue }
		append(&done, old)
		if !os.is_dir(old) || os.exists(new) { continue }
		if parent := filepath.dir(new); !os.exists(parent) {
			if err := os.make_directory_all(parent); err != nil {
				if why == "" { why = fmt.tprintf("%s cannot be made: %v", parent, err) }
				continue
			}
		}
		if err := os.rename(old, new); err != nil {
			if why == "" { why = fmt.tprintf("%s cannot move to %s: %v", old, new, err) }
			continue
		}
		moved += 1
	}
	return
}

// The folder of `program` for `kind` ("": the folder every program's is in, as the system names it). "": the system has none
// (no home, a known folder it would not give).
user_dir :: proc(kind: User_Dir, program: string, allocator := context.allocator) -> string {
	base := user_dir_base(kind)
	if base == "" { return "" }
	if program == "" { return strings.clone(base, allocator) }
	return join_user_dir(base, program, user_dir_leaf(kind), allocator)
}

// session_runtime_dir(allocator) -> (dir, ok) (user_dir_<os>.odin): the session's own runtime folder, the one its services
// (gvfs, the portals, D-Bus) use. Linux: $XDG_RUNTIME_DIR when it is absolute, else /run/user/<uid> when it is a folder of
// this user closed to the others. ok = false: the session has none (Windows, a Linux session without a login manager), and
// nothing of the session's services is there; user_dir(.Runtime) still gives a private folder then.

@(private)
join_user_dir :: proc(base, program, leaf: string, allocator := context.allocator) -> string {
	if leaf == "" { return strings.concatenate({base, USER_DIR_SEPARATOR, program}, allocator) }
	return strings.concatenate({base, USER_DIR_SEPARATOR, program, USER_DIR_SEPARATOR, leaf}, allocator)
}
