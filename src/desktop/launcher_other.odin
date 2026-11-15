#+build !windows
package tk_desktop

// No console launcher off Windows: a program run from a shell is in its terminal already.
launcher_file :: proc(exe: string, allocator := context.temp_allocator) -> string { return "" }
