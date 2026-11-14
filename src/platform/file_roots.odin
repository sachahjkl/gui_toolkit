package platform

// The roots of the computer's file system, as a file browser lists them among its places: the drives on Windows
// ("C:\", "D:\"), "/" elsewhere (file_roots_windows.odin, file_roots_other.odin). It asks the system: call it off the
// interface's thread. In `allocator`, each string and the slice.
file_roots :: proc(allocator := context.allocator) -> []string { return file_roots_read(allocator) }
