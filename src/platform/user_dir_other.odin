#+build !windows
#+build !linux
package platform

@(private) USER_DIR_SEPARATOR :: "/"

// (No standard folders known on this system yet.)
@(private)
user_dir_base :: proc(kind: User_Dir) -> string { return "" }

@(private)
user_dir_leaf :: proc(kind: User_Dir) -> string { return "" }
