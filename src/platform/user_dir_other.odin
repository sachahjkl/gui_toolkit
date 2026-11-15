#+build !windows
#+build !linux
#+build !darwin
package platform

USER_DIR_SEPARATOR :: "/"   // (between a folder and the next: a program's folder written as vendor and name)

// (No standard folders known on this system yet.)
@(private)
user_dir_base :: proc(kind: User_Dir) -> string { return "" }

@(private)
user_dir_leaf :: proc(kind: User_Dir) -> string { return "" }

session_runtime_dir :: proc(allocator := context.allocator, loc := #caller_location) -> (dir: string, ok: bool) {
	return "", false
}
