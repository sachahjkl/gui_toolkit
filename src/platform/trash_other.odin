#+build !windows
#+build !linux
package platform

// The trash on the systems that have no implementation yet (trash_linux.odin, trash_windows.odin): nothing moves, so a
// program written for them builds and says the trash failed.

move_to_trash :: proc(path: string, allocator := context.allocator, loc := #caller_location) -> (in_trash: string, ok: bool) { return }

put_back :: proc(in_trash, to: string, loc := #caller_location) -> bool { return false }
