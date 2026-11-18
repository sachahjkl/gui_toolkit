package fsx

import "base:runtime"
import "core:io"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import base "../base"

@(private = "file")
wide :: proc(s: string) -> win.LPCWSTR { return win.utf8_to_wstring(s, context.temp_allocator) }

// `private` asks nothing more here: a file takes its folder's access list, and a program's own folder (under the profile)
// is its user's already.
write_parts :: proc(path: string, parts: [][]byte, flush: bool, private := false) -> bool {
	h := win.CreateFileW(wide(path), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return false }
	ok := true
	for p in parts {
		at := 0
		for at < len(p) && ok {
			n: win.DWORD
			chunk := win.DWORD(min(len(p) - at, IO_CHUNK_MAX_BYTES))
			if !win.WriteFile(h, raw_data(p[at:]), chunk, &n, nil) || n == 0 { ok = false; break }
			at += int(n)
		}
	}
	if ok && flush { ok = bool(win.FlushFileBuffers(h)) }
	win.CloseHandle(h)
	return ok
}

replace :: proc(from, to: string, durable: bool) -> bool {
	flags: win.DWORD = win.MOVEFILE_REPLACE_EXISTING
	if durable { flags |= win.MOVEFILE_WRITE_THROUGH }
	wfrom, wto := wide(from), wide(to)
	// (a reader that opened the file without sharing its deletion, an antivirus or the indexer, makes the move fail for
	// as long as it holds it: a few tries, a few milliseconds apart, before the write is said to fail)
	for try in 0 ..< REPLACE_TRIES {
		if win.MoveFileExW(wfrom, wto, flags) { return true }
		e := win.GetLastError()
		if e != win.ERROR_SHARING_VIOLATION && e != win.ERROR_ACCESS_DENIED || try == REPLACE_TRIES - 1 { break }
		win.Sleep(win.DWORD(REPLACE_WAIT_MS * (try + 1)))
	}
	return false
}

// How many times replace tries a file another holds, and the first wait between two tries (each wait longer).
@(private = "file") REPLACE_TRIES :: 6
@(private = "file") REPLACE_WAIT_MS :: 5

delete_file :: proc(path: string, loc := #caller_location) -> bool {
	base.blocking("fsx.delete_file", loc)
	if win.DeleteFileW(wide(path)) { return true }
	e := win.GetLastError()
	return e == win.ERROR_FILE_NOT_FOUND || e == win.ERROR_PATH_NOT_FOUND
}

// The stamp is the last write time (FILETIME, 100 ns since 1601).
stat :: proc(path: string, loc := #caller_location) -> (size: i64, stamp: i64, ok: bool) {
	base.blocking("fsx.stat", loc)
	data: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(wide(path), win.GetFileExInfoStandard, &data) { return 0, 0, false }
	if data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 { return 0, 0, false }
	size = i64(data.nFileSizeHigh) << 32 | i64(data.nFileSizeLow)
	stamp = i64(data.ftLastWriteTime.dwHighDateTime) << 32 | i64(data.ftLastWriteTime.dwLowDateTime)
	return size, stamp, true
}

// The whole file through one handle (read_all): its size and its bytes of one file, whatever replaces its name meanwhile
// (the handle shares delete: a rename over it goes through); .Changed when its size or its time moved while it was read.
@(private)
read_open :: proc(path: string, max_size: i64, allocator: runtime.Allocator) -> (buf: []byte, got: Read_Got) {
	h := win.CreateFileW(wide(path), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return nil, .No }
	defer win.CloseHandle(h)
	before, after: win.BY_HANDLE_FILE_INFORMATION
	if !win.GetFileInformationByHandle(h, &before) || before.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 { return nil, .No }
	size := i64(before.nFileSizeHigh) << 32 | i64(before.nFileSizeLow)
	if size > max_size { return nil, .No }
	buf = make([]byte, int(size), allocator)
	n := 0
	for n < len(buf) {
		ov: win.OVERLAPPED
		ov.Offset = win.DWORD(u64(n) & 0xFFFF_FFFF)
		ov.OffsetHigh = win.DWORD(u64(n) >> 32)
		r: win.DWORD
		if !win.ReadFile(h, raw_data(buf[n:]), win.DWORD(min(len(buf) - n, IO_CHUNK_MAX_BYTES)), &r, &ov) || r == 0 { break }
		n += int(r)
	}
	same := win.GetFileInformationByHandle(h, &after) && after.nFileSizeHigh == before.nFileSizeHigh && after.nFileSizeLow == before.nFileSizeLow && after.ftLastWriteTime == before.ftLastWriteTime
	if n == len(buf) && same { return buf, .Whole }
	delete(buf, allocator)
	return nil, .Changed
}

read_at :: proc(path: string, offset: i64, buf: []byte, loc := #caller_location) -> (n: int, ok: bool) {
	base.blocking("fsx.read_at", loc)
	h := win.CreateFileW(wide(path), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return 0, false }
	defer win.CloseHandle(h)
	for n < len(buf) {
		ov: win.OVERLAPPED
		o := u64(offset) + u64(n)
		ov.Offset = win.DWORD(o & 0xFFFF_FFFF)
		ov.OffsetHigh = win.DWORD(o >> 32)
		got: win.DWORD
		chunk := win.DWORD(min(len(buf) - n, IO_CHUNK_MAX_BYTES))
		if !win.ReadFile(h, raw_data(buf[n:]), chunk, &got, &ov) {
			if win.GetLastError() == win.ERROR_HANDLE_EOF { break }
			return n, false
		}
		if got == 0 { break }
		n += int(got)
	}
	return n, true
}

// The folder and its parents, those missing made. True when it is a folder now.
make_dirs :: proc(dir: string, loc := #caller_location) -> bool {
	base.blocking("fsx.make_dirs", loc)
	// every level, from the root (CreateDirectory fails harmlessly on the ones that exist)
	for i in 0 ..< len(dir) {
		if (dir[i] == '\\' || dir[i] == '/') && i > 0 && dir[i - 1] != ':' { win.CreateDirectoryW(wide(dir[:i]), nil) }
	}
	win.CreateDirectoryW(wide(dir), nil)
	attrs := win.GetFileAttributesW(wide(dir))
	return attrs != win.INVALID_FILE_ATTRIBUTES && attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0
}

// A new folder takes its parent's access list, and the parents a program's folders are in (%TEMP%, %LOCALAPPDATA%) are
// in the user's profile, closed to the other users already: nothing to change. A junction or a link at the name is
// refused, as on POSIX.
private_dir :: proc(dir: string, loc := #caller_location) -> bool {
	base.blocking("fsx.private_dir", loc)
	return make_dirs(dir, loc) && path_kind(dir, loc) == .Directory
}

list_files :: proc(dir: string, allocator := context.temp_allocator, loc := #caller_location) -> []Dir_File {
	base.blocking("fsx.list_files", loc)
	out := make([dynamic]Dir_File, allocator)
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(wide(strings.concatenate({dir, "\\*"}, context.temp_allocator)), &fd)
	if h == win.INVALID_HANDLE_VALUE { return out[:] }
	defer win.FindClose(h)
	for {
		if fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 {
			n := 0
			for n < len(fd.cFileName) && fd.cFileName[n] != 0 { n += 1 }
			if name, err := win.utf16_to_utf8(fd.cFileName[:n], allocator); err == nil {
				append(&out, Dir_File{name = name, size = i64(fd.nFileSizeHigh) << 32 | i64(fd.nFileSizeLow)})
			}
		}
		if !win.FindNextFileW(h, &fd) { break }
	}
	return out[:]
}

// Each entry is made from FindFirstFileW / FindNextFileW's WIN32_FIND_DATAW alone: core:os reads the same records but
// opens every entry to stat it, and drops the hidden attribute. A link is what core:os calls one (a symbolic link or a
// junction); another reparse point (a cloud placeholder) is the folder or the file it stands for.
read_folder :: proc(dir: string, allocator := context.allocator, loc := #caller_location) -> ([]Folder_Entry, os.Error) {
	base.blocking("fsx.read_folder", loc)
	out := make([dynamic]Folder_Entry, allocator)
	fd: win.WIN32_FIND_DATAW
	sep := len(dir) > 0 && (dir[len(dir) - 1] == '\\' || dir[len(dir) - 1] == '/') ? "" : "\\"
	h := win.FindFirstFileW(wide(long_path(strings.concatenate({dir, sep, "*"}, context.temp_allocator))), &fd)
	if h == win.INVALID_HANDLE_VALUE {
		e := win.GetLastError()
		// (a drive's root has no "." entry: an empty one finds nothing at all)
		attrs := win.GetFileAttributesW(wide(long_path(dir)))
		if e == win.ERROR_FILE_NOT_FOUND && attrs != win.INVALID_FILE_ATTRIBUTES && attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0 {
			return out[:], nil
		}
		delete(out)
		return nil, folder_error(e)
	}
	defer win.FindClose(h)
	for {
		n := 0
		for n < len(fd.cFileName) && fd.cFileName[n] != 0 { n += 1 }
		dot := (n == 1 && fd.cFileName[0] == '.') || (n == 2 && fd.cFileName[0] == '.' && fd.cFileName[1] == '.')
		if name, err := win.utf16_to_utf8(fd.cFileName[:n], allocator); dot && err == nil {
			delete(name, allocator)
		} else if err == nil {
			a := fd.dwFileAttributes
			kind: Path_Kind = .File
			tag := fd.dwReserved0
			switch {
			case a & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 && (tag == win.IO_REPARSE_TAG_SYMLINK || tag == win.IO_REPARSE_TAG_MOUNT_POINT): kind = .Link
			case a & win.FILE_ATTRIBUTE_DIRECTORY != 0: kind = .Directory
			}
			append(&out, Folder_Entry{
				name     = name,
				size     = kind == .File ? i64(fd.nFileSizeHigh) << 32 | i64(fd.nFileSizeLow) : 0,
				modified = win.FILETIME_as_unix_nanoseconds(fd.ftLastWriteTime) / 1_000_000,
				kind     = kind,
				hidden   = a & win.FILE_ATTRIBUTE_HIDDEN != 0,
			})
		}
		if !win.FindNextFileW(h, &fd) { break }
	}
	return out[:], nil
}

// The system's reason as core:os gives it, so a caller tells "refused" and "not there" apart as for its other errors.
@(private = "file")
folder_error :: proc(e: win.DWORD) -> os.Error {
	// (the name is a file's; core:sys/windows does not name this code)
	ERROR_DIRECTORY :: 267
	switch e {
	case win.ERROR_ACCESS_DENIED, win.ERROR_SHARING_VIOLATION: return io.Error.Permission_Denied
	case win.ERROR_FILE_NOT_FOUND, win.ERROR_PATH_NOT_FOUND:   return os.General_Error.Not_Exist
	case ERROR_DIRECTORY:                                      return os.General_Error.Invalid_Dir
	}
	return os.Platform_Error(e)
}

// A path past MAX_PATH with the "\\?\" prefix that lifts the limit (core:os does the same): a search in subfolders goes
// deep. The prefix turns off the system's clean-up of the path, so the separators are made '\' first.
@(private = "file")
long_path :: proc(path: string) -> string {
	if len(path) < win.MAX_PATH - 12 || strings.has_prefix(path, `\\?\`) { return path }
	p, _ := strings.replace_all(path, "/", `\`, context.temp_allocator)
	if strings.has_prefix(p, `\\`) { return strings.concatenate({`\\?\UNC\`, p[2:]}, context.temp_allocator) }
	if len(p) >= 3 && p[1] == ':' && p[2] == '\\' { return strings.concatenate({`\\?\`, p}, context.temp_allocator) }
	return path
}

path_kind :: proc(path: string, loc := #caller_location) -> Path_Kind {
	base.blocking("fsx.path_kind", loc)
	attrs := win.GetFileAttributesW(wide(path))
	if attrs == win.INVALID_FILE_ATTRIBUTES { return .Absent }
	if attrs & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 { return .Link }
	return attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0 ? .Directory : .File
}
