package fsx

import "core:strings"
import "core:sys/linux"

@(private)
file_lock_try :: proc(path: string) -> (l: File_Lock, result: Lock_Result) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(name, {.RDWR, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR})
	if err != .NONE { return {}, .Failed }
	if e := linux.flock(fd, {.EX, .NB}); e != .NONE {
		linux.close(fd)
		return {}, e == .EAGAIN || e == .EINTR ? .Busy : .Failed
	}
	return {handle = uintptr(fd), held = true}, .Locked
}

// Lets the lock go (closing the file does it); a lock not held: nothing.
file_unlock :: proc(l: ^File_Lock) {
	if l.held { linux.close(linux.Fd(l.handle)) }
	l^ = {}
}
