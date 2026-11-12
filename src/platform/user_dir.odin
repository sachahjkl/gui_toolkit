package platform

import "core:strings"

// The standard folders of a user, the same names on every system: where a program keeps its configuration, its data, its cache and
// its state (logs, crash reports, what it remembers between runs that is not a setting). Each program has its own folder in each.
//
//	Config   Linux $XDG_CONFIG_HOME/<program> (~/.config)        Windows %APPDATA%\<program>
//	Data     Linux $XDG_DATA_HOME/<program>   (~/.local/share)   Windows %LOCALAPPDATA%\<program>
//	State    Linux $XDG_STATE_HOME/<program>  (~/.local/state)   Windows %LOCALAPPDATA%\<program>\state
//	Cache    Linux $XDG_CACHE_HOME/<program>  (~/.cache)         Windows %LOCALAPPDATA%\<program>\cache
//
// An XDG variable counts only when it is an absolute path (the specification says a relative one is ignored). Windows' folders
// are the system's known folders (SHGetKnownFolderPath), not variables a process may have changed. Nothing is made: a program
// makes its folder when it writes there (fsx).
User_Dir :: enum u8 { Config, Data, State, Cache }

// The folder of `program` for `kind` ("": the folder every program's is in, as the system names it). "": the system has none
// (no home, a known folder it would not give).
user_dir :: proc(kind: User_Dir, program: string, allocator := context.allocator) -> string {
	base := user_dir_base(kind)
	if base == "" { return "" }
	if program == "" { return strings.clone(base, allocator) }
	return join_user_dir(base, program, user_dir_leaf(kind), allocator)
}

@(private)
join_user_dir :: proc(base, program, leaf: string, allocator := context.allocator) -> string {
	if leaf == "" { return strings.concatenate({base, USER_DIR_SEPARATOR, program}, allocator) }
	return strings.concatenate({base, USER_DIR_SEPARATOR, program, USER_DIR_SEPARATOR, leaf}, allocator)
}
