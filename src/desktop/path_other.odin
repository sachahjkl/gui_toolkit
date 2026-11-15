#+build !windows
package tk_desktop

// Paths are exact here.
@(private)
same_path_system :: proc(a, b: string) -> bool { return a == b }
