#+build linux, darwin, freebsd, openbsd, netbsd
package fsx

import "base:intrinsics"
import "base:runtime"
import "core:c/libc"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import base "../base"

@(private = "file") NS_PER_SECOND :: 1_000_000_000

// A Writer's temporary file, made anew. (An open file can be removed here: it goes when its last handle closes.)
@(private)
writer_temp_open :: proc(path: string, private: bool) -> (^os.File, bool) {
	perm := private ? os.Permissions{.Read_User, .Write_User} : os.Permissions_Default_File
	f, err := os.open(path, {.Write, .Create, .Trunc}, perm)
	return f, err == nil
}

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
	for p in parts { if ok { ok = write_fd(fd, p) } }
	if ok && flush { ok = posix.fsync(fd) == .OK }
	if posix.close(fd) != .OK { ok = false }
	return ok
}

// write_atomic's work: `tmp` made, written, given what `target` had, renamed over it.
@(private)
write_over :: proc(tmp, target: string, data: []byte, o: Write_Options, rep: ^Write_Report) -> bool {
	old: posix.stat_t
	rep.existed = posix.stat(cpath(target), &old) == .OK && posix.S_ISREG(old.st_mode)
	if rep.existed { rep.hard_links = max(int(old.st_nlink) - 1, 0) }
	keep := o.keep && rep.existed
	// (the user's alone while it is written: its final mode is given once it is whole, never wider meanwhile)
	mode := o.private || keep ? posix.mode_t{.IRUSR, .IWUSR} : posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH}
	// (a new file: one left by a crash keeps its mode through O_TRUNC, and a link planted at the name would be written
	// through. Its name is this process's and thread's: no live writer holds it)
	posix.unlink(cpath(tmp))
	fd := open_retry(tmp, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW}, mode)
	if fd < 0 { return false }
	ok := write_fd(fd, data)
	if ok && keep {
		// the owner first: a change of owner clears the set-user-ID bits that the mode then gives back. An owner this user
		// may not give (another user's file in a shared folder): the group alone, and the file is this user's.
		rep.kept = fchown(fd, old.st_uid, old.st_gid) == .OK
		if !rep.kept { _ = fchown(fd, ~posix.uid_t(0), old.st_gid) }
		// (private: 0600 whatever the file had; a mode refused leaves 0600, narrower, never the content lost)
		if !o.private && posix.fchmod(fd, transmute(posix.mode_t)(transmute(Mode_Bits)old.st_mode & MODE_BITS)) != .OK { rep.kept = false }
	}
	if ok && o.flush { ok = posix.fsync(fd) == .OK }
	if posix.close(fd) != .OK { ok = false }
	ok = ok && replace(tmp, target, o.flush)
	rep.flushed = o.flush && ok
	return ok
}

// The permission bits of a mode (with set-user-ID, set-group-ID and sticky), not its type.
@(private = "file") MODE_BITS :: 0o7777
// (mode_t's integer: u32 on Linux, u16 on macOS)
@(private = "file") Mode_Bits :: intrinsics.type_bit_set_underlying_type(posix.mode_t)

@(private = "file")
write_fd :: proc(fd: posix.FD, data: []byte) -> bool {
	at := 0
	for at < len(data) {
		n := posix.write(fd, raw_data(data[at:]), uint(min(len(data) - at, IO_CHUNK_MAX_BYTES)))
		if n < 0 && posix.errno() == .EINTR { continue }
		if n <= 0 { return false }
		at += int(n)
	}
	return true
}

foreign import libc_fchown "system:c"
@(private = "file", default_calling_convention = "c")
foreign libc_fchown {
	fchown :: proc(fd: posix.FD, owner: posix.uid_t, group: posix.gid_t) -> posix.result ---
}

// The temporary folder in the system's form (temp_dir): no disk read here.
@(private)
temp_form :: proc(named: string, allocator: runtime.Allocator, loc: runtime.Source_Code_Location) -> string {
	return system_form(named, allocator)
}

// A path as the system gives one: no "/" at its end (a root keeps its own).
@(private)
system_form :: proc(path: string, allocator: runtime.Allocator) -> string {
	p := strings.trim_right(path, "/")
	return strings.clone(p == "" ? path[:min(len(path), 1)] : p, allocator)
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

// The checks are made on the opened folder, not on its name: a name swapped for a link between the check and the
// change is never followed, and in a sticky folder (/tmp) no other user can rename or remove a folder of ours.
private_dir :: proc(dir: string, loc := #caller_location) -> bool {
	base.blocking("fsx.private_dir", loc)
	if parent := filepath.dir(dir); parent != "" && parent != dir { _ = os.make_directory_all(parent) }
	if posix.mkdir(cpath(dir), posix.S_IRWXU) != .OK && posix.errno() != .EEXIST { return false }
	fd := open_retry(dir, {.DIRECTORY, .NOFOLLOW})
	if fd < 0 { return false }   // (a link: O_NOFOLLOW refuses it)
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.geteuid() { return false }
	if st.st_mode & (posix.S_IRWXG + posix.S_IRWXO) == {} { return true }
	return posix.fchmod(fd, posix.S_IRWXU) == .OK
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

// (Unix has no hidden mark of its own: a name that starts with "." is the system's rule)
read_folder :: proc(dir: string, allocator := context.allocator, loc := #caller_location) -> ([]Folder_Entry, os.Error) {
	base.blocking("fsx.read_folder", loc)
	infos, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil { return nil, err }
	defer os.file_info_slice_delete(infos, allocator)
	out := make([]Folder_Entry, len(infos), allocator)
	for fi, i in infos {
		kind: Path_Kind = .File
		#partial switch fi.type {
		case .Directory: kind = .Directory
		case .Symlink:   kind = .Link
		}
		out[i] = {
			name     = strings.clone(fi.name, allocator),
			size     = fi.size,
			modified = time.to_unix_nanoseconds(fi.modification_time) / 1_000_000,
			kind     = kind,
			hidden   = len(fi.name) > 0 && fi.name[0] == '.',
		}
	}
	return out, nil
}

path_kind :: proc(path: string, loc := #caller_location) -> Path_Kind {
	base.blocking("fsx.path_kind", loc)
	st: posix.stat_t
	if posix.lstat(cpath(path), &st) != .OK { return .Absent }
	if posix.S_ISLNK(st.st_mode) { return .Link }
	return posix.S_ISDIR(st.st_mode) ? .Directory : .File
}

// The volume and the number of the entry `path` (a link itself, not followed): two paths with the same are one entry.
entry_identity :: proc(path: string, loc := #caller_location) -> (volume, index: u64, ok: bool) {
	base.blocking("fsx.entry_identity", loc)
	if path == "" { return }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	st: posix.stat_t
	if posix.lstat(cpath(path), &st) != .OK { return }
	return u64(st.st_dev), u64(st.st_ino), true
}

// What `path` reaches, links followed: .Directory (size 0), .File (its size), or .Absent.
stat_follow :: proc(path: string, loc := #caller_location) -> (kind: Path_Kind, size: i64) {
	base.blocking("fsx.stat_follow", loc)
	if path == "" { return .Absent, 0 }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	st: posix.stat_t
	if posix.stat(cpath(path), &st) != .OK { return .Absent, 0 }
	if posix.S_ISDIR(st.st_mode) { return .Directory, 0 }
	if posix.S_ISREG(st.st_mode) { return .File, i64(st.st_size) }
	return .Absent, 0
}
