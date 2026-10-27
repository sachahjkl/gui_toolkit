// Package fsx: whole-file and positional file operations with the guarantees stores rely on, on every system
// (fsx_<os>.odin), plus directory helpers an application needs to manage its own files: a temporary directory, a
// recursive delete, and what a path names (file, directory or a link to one, links never followed).
//
// The design is platform-neutral: the public procedures take and return our own types (string paths, []byte, the
// opaque Path_Kind enum and an opaque modification stamp that is only ever compared to another stamp). No Windows or
// POSIX type leaks out, so another platform plugs in under fsx_<os>.odin without touching the callers.
//
//	write_parts    creates or truncates `path` and writes `parts` one after the other; `flush`: through to the disk
//	replace        renames `from` over `to` atomically (a reader sees the old file or the new one); `durable`: the
//	               new name is on the disk when it returns (MOVEFILE_WRITE_THROUGH; the directory synced on POSIX)
//	delete_file    removes a file (true when it is gone)
//	stat           size and the system's modification stamp (opaque: only compared with another stamp)
//	read_at        up to len(buf) bytes from `offset` (short at the end of the file). A file being replaced or
//	               deleted meanwhile is read as it was: readers never block a writer's rename or a deletion
//	make_dirs      the directory and every missing parent
//	list_files     the plain files of a directory (no subdirectory, no link to one), names and sizes
//	path_kind      what a path names, links never followed: a junction / symlink to a directory is a Link
//	remove_tree    a file, or a directory with everything in it, one entry at a time
//	temp_dir       the directory for temporary files
package fsx

import "base:runtime"
import "core:os"

// A plain file of a directory (list_files): its name (no path) and size.
Dir_File :: struct {
	name: string,
	size: i64,
}

// What a path names, links never followed: a junction or a symbolic link to a directory is a Link (fsx_<os>.odin).
Path_Kind :: enum u8 {
	Absent,
	File,
	Directory,
	Link,
}

// The whole file, at most `max_size` bytes (false when it is larger, missing or unreadable).
read_all :: proc(path: string, allocator := context.allocator, max_size: i64 = 1 << 40) -> ([]byte, bool) {
	size, _, ok := stat(path)
	if !ok || size < 0 || size > max_size { return nil, false }
	buf := make([]byte, int(size), allocator)
	n, rok := read_at(path, 0, buf)
	if !rok || n != len(buf) { delete(buf, allocator); return nil, false }
	return buf, true
}

// Writes `data` to `path` through `path`.tmp renamed over it: a reader sees the old file or the new one.
write_atomic :: proc(path: string, data: []byte, flush := false) -> bool {
	tmp := concat_temp(path, ".tmp")
	parts := [1][]byte{data}
	if !write_parts(tmp, parts[:], flush) { delete_file(tmp); return false }
	if !replace(tmp, path, flush) { delete_file(tmp); return false }
	return true
}

@(private)
concat_temp :: proc(a, b: string) -> string {
	out := make([]byte, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

// The directory for temporary files: TEMP when it is set (what a test harness points at a throwaway folder, on every
// system), otherwise the system's (TMPDIR or /tmp on Unix, GetTempPathW on Windows). "" if there is none.
temp_dir :: proc(allocator := context.allocator) -> string {
	if t := os.get_env("TEMP", allocator); t != "" { return t }
	d, err := os.temp_directory(allocator)
	return err == nil ? d : ""
}

// Removes a file, or a directory with everything in it, one entry at a time (what a program does when it cleans up
// after itself, the test directories of the unit tests). os.remove_all asks the Windows shell (SHFileOperationW) to do
// it for a directory that is not empty, and the shell does not survive being called from a process under
// AddressSanitizer once other threads have run. A junction or symbolic link to a directory is removed, never followed
// (path_kind tells it apart, so its target is left alone). Absent: nothing to do. True when nothing is left.
remove_tree :: proc(path: string) -> bool {
	if path == "" { return true }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if path_kind(path) == .Directory {
		entries, err := os.read_directory_by_path(path, -1, context.temp_allocator)
		if err == nil {
			for e in entries {
				if e.type == .Directory { remove_tree(e.fullpath) } else { os.remove(e.fullpath) }
			}
		}
	}
	err := os.remove(path)
	return err == nil || err == .Not_Exist
}
