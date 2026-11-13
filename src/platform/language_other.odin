#+build !windows
#+build !linux
package platform

// macOS: not read yet (the port comes later): no language said, so the program shows English.
@(private)
system_language_read :: proc(allocator := context.allocator) -> string { return "" }
