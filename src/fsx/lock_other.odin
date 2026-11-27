#+build !linux
#+build !windows
package fsx

// (no lock here yet: a start alone is the common case)
@(private)
file_lock_try :: proc(path: string) -> (l: File_Lock, result: Lock_Result) { return {held = false}, .Locked }

file_unlock :: proc(l: ^File_Lock) { l^ = {} }
