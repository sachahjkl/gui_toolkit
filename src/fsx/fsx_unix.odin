#+build linux, darwin, freebsd, openbsd, netbsd
package fsx

import "base:runtime"
import "core:c/libc"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import base "../base"

@(private = "file") NS_PER_SECOND :: 1_000_000_000

@(private = "file")
cpath :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }

@(private = "file")
open_retry :: proc(path: string, flags: posix.O_Flags, mode := posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH}) -> posix.FD {
	for {
		fd := posix.open(cpath(path), flags + {.CLOEXEC}, mode)
		if fd >= 0 || posix.errno() != .EINTR { return fd }
	}
}

write_parts :: proc(path: string, parts: [][]byte, flush: bool, private := false) -> bool {
	// (private: readable by its user only, from its creation on: no moment where another user could open it)
	mode := private ? posix.mode_t{.IRUSR, .IWUSR} : posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH}
	fd := open_retry(path, {.WRONLY, .CREAT, .TRUNC}, mode)
	if fd < 0 { return false }
	ok := true
	for p in parts {
		at := 0
		for at < len(p) && ok {
			n := posix.write(fd, raw_data(p[at:]), uint(min(len(p) - at, IO_CHUNK_MAX_BYTES)))
			if n < 0 && posix.errno() == .EINTR { continue }
			if n <= 0 { ok = false; break }
			at += int(n)
		}
	}
	if ok && flush { ok = posix.fsync(fd) == .OK }
	posix.close(fd)
	return ok
}

replace :: proc(from, to: string, durable: bool) -> bool {
	if libc.rename(cpath(from), cpath(to)) != 0 { return false }
	if !durable { return true }
	dir := filepath.dir(to)
	return sync_dir(dir == "" ? "." : dir)   // (a bare name has none)
}

// A rename or a creation is on the disk once its directory is synced.
@(private = "file")
sync_dir :: proc(dir: string) -> bool {
	fd := open_retry(dir, {})
	if fd < 0 { return false }
	defer posix.close(fd)
	for {
		if posix.fsync(fd) == .OK { return true }
		#partial switch posix.errno() {
		case .EINTR:
			continue
		case .EINVAL:   // (a file system that syncs no directory: there is nothing more to do)
			return true
		}
		return false
	}
}

delete_file :: proc(path: string, loc := #caller_location) -> bool {
	base.blocking("fsx.delete_file", loc)
	return posix.unlink(cpath(path)) == .OK || posix.errno() == .ENOENT
}

// The stamp is the modification time in nanoseconds since the Unix epoch.
stat :: proc(path: string, loc := #caller_location) -> (size: i64, stamp: i64, ok: bool) {
	base.blocking("fsx.stat", loc)
	st: posix.stat_t
	if posix.stat(cpath(path), &st) != .OK || !posix.S_ISREG(st.st_mode) { return 0, 0, false }
	return i64(st.st_size), i64(st.st_mtim.tv_sec) * NS_PER_SECOND + i64(st.st_mtim.tv_nsec), true
}

// The whole file through one descriptor (read_all): its size and its bytes of one file; .Changed when its size or its
// time moved while it was read (a writer in place).
@(private)
read_open :: proc(path: string, max_size: i64, allocator: runtime.Allocator) -> (buf: []byte, got: Read_Got) {
	fd := open_retry(path, {})
	if fd < 0 { return nil, .No }
	defer posix.close(fd)
	before, after: posix.stat_t
	if posix.fstat(fd, &before) != .OK || !posix.S_ISREG(before.st_mode) || i64(before.st_size) > max_size { return nil, .No }
	buf = make([]byte, int(before.st_size), allocator)
	n := 0
	for n < len(buf) {
		r := posix.pread(fd, raw_data(buf[n:]), uint(min(len(buf) - n, IO_CHUNK_MAX_BYTES)), posix.off_t(n))
		if r < 0 && posix.errno() == .EINTR { continue }
		if r <= 0 { break }
		n += int(r)
	}
	same := posix.fstat(fd, &after) == .OK && after.st_size == before.st_size && after.st_mtim == before.st_mtim
	if n == len(buf) && same { return buf, .Whole }
	delete(buf, allocator)
	return nil, .Changed
}

read_at :: proc(path: string, offset: i64, buf: []byte, loc := #caller_location) -> (n: int, ok: bool) {
	base.blocking("fsx.read_at", loc)
	fd := open_retry(path, {})
	if fd < 0 { return 0, false }
	defer posix.close(fd)
	for n < len(buf) {
		got := posix.pread(fd, raw_data(buf[n:]), uint(min(len(buf) - n, IO_CHUNK_MAX_BYTES)), posix.off_t(offset + i64(n)))
		if got < 0 && posix.errno() == .EINTR { continue }
		if got < 0 { return n, false }
		if got == 0 { break }
		n += int(got)
	}
	return n, true
}

// The folder and its parents, those missing made. True when it is a folder now (one already there is no failure: Odin's
// make_directory_all says Exist for it).
make_dirs :: proc(dir: string, loc := #caller_location) -> bool {
	base.blocking("fsx.make_dirs", loc)
	_ = os.make_directory_all(dir)
	return os.is_dir(dir)
}

list_files :: proc(dir: string, allocator := context.temp_allocator, loc := #caller_location) -> []Dir_File {
	base.blocking("fsx.list_files", loc)
	out := make([dynamic]Dir_File, allocator)
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return out[:] }
	for fi in infos {
		if fi.type != .Regular { continue }
		append(&out, Dir_File{name = strings.clone(fi.name, allocator), size = fi.size})
	}
	return out[:]
}

path_kind :: proc(path: string, loc := #caller_location) -> Path_Kind {
	base.blocking("fsx.path_kind", loc)
	st: posix.stat_t
	if posix.lstat(cpath(path), &st) != .OK { return .Absent }
	if posix.S_ISLNK(st.st_mode) { return .Link }
	return posix.S_ISDIR(st.st_mode) ? .Directory : .File
}
