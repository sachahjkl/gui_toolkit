package fsx

import "base:runtime"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"
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

// A Writer's temporary file, made anew. Shared for deletion: a thread that removes it while the writer's thread still
// holds it open (a download cut at the program's end) marks it deleted, and it goes when that handle closes; without it
// the remove failed and the part stayed. (`private`: the folder's access list, as any file.)
@(private)
writer_temp_open :: proc(path: string, private: bool) -> (^os.File, bool) {
	h := win.CreateFileW(wide(path), win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_DELETE, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return nil, false }
	return os.new_file(uintptr(h), path), true
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

// write_atomic's work: `tmp` written, then renamed over `target`. With `keep`, ReplaceFileW: the file written over gives
// the new one its access list, attributes, creation time and short name (MoveFileExW leaves the new file the temporary
// file's: its folder's access list, its attributes).
@(private)
write_over :: proc(tmp, target: string, data: []byte, o: Write_Options, rep: ^Write_Report) -> bool {
	wtarget := wide(target)
	// (no access asked: its attributes and its links only, whatever another program holds it with)
	if h := win.CreateFileW(wtarget, 0, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil); h != win.INVALID_HANDLE_VALUE {
		info: win.BY_HANDLE_FILE_INFORMATION
		if win.GetFileInformationByHandle(h, &info) && info.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 {
			rep.existed = true
			rep.hard_links = max(int(info.nNumberOfLinks) - 1, 0)
		}
		win.CloseHandle(h)
	}
	parts := [1][]byte{data}
	if !write_parts(tmp, parts[:], o.flush, o.private) { return false }
	if !(o.keep && rep.existed) {
		ok := replace(tmp, target, o.flush)
		rep.flushed = o.flush && ok
		return ok
	}
	wtmp := wide(tmp)
	for try in 0 ..< REPLACE_TRIES {
		if ReplaceFileW(wtarget, wtmp, nil, REPLACEFILE_IGNORE_MERGE_ERRORS, nil, nil) {
			rep.kept = true
			// (ReplaceFileW has no write-through: the file's handle flushed puts its entry on the disk; its data was
			// flushed in the temporary file. A file this user may not write cannot be opened for it: the replace is done
			// all the same, and the report says the flush was not)
			rep.flushed = o.flush && flush_file(wtarget)
			return true
		}
		switch win.GetLastError() {
		case ERROR_UNABLE_TO_MOVE_REPLACEMENT, ERROR_UNABLE_TO_MOVE_REPLACEMENT_2:
			// (the new file kept its name and the target's is free or still the old file: the plain rename, what it had lost)
			ok := replace(tmp, target, o.flush)
			rep.flushed = o.flush && ok
			return ok
		case win.ERROR_SHARING_VIOLATION, win.ERROR_ACCESS_DENIED, ERROR_UNABLE_TO_REMOVE_REPLACED:
			if try < REPLACE_TRIES - 1 { win.Sleep(win.DWORD(REPLACE_WAIT_MS * (try + 1))) }
		case:
			return false
		}
	}
	return false
}

@(private = "file")
flush_file :: proc(path: win.LPCWSTR) -> bool {
	h := win.CreateFileW(path, win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return false }
	defer win.CloseHandle(h)
	return bool(win.FlushFileBuffers(h))
}

@(private = "file") REPLACEFILE_IGNORE_MERGE_ERRORS :: 0x00000002
@(private = "file") ERROR_UNABLE_TO_REMOVE_REPLACED :: 1175
@(private = "file") ERROR_UNABLE_TO_MOVE_REPLACEMENT :: 1176
@(private = "file") ERROR_UNABLE_TO_MOVE_REPLACEMENT_2 :: 1177

foreign import kernel32_replace "system:Kernel32.lib"
@(private = "file", default_calling_convention = "system")
foreign kernel32_replace {
	ReplaceFileW :: proc(lpReplacedFileName, lpReplacementFileName, lpBackupFileName: win.LPCWSTR, dwReplaceFlags: win.DWORD, lpExclude, lpReserved: rawptr) -> win.BOOL ---
}

// The system's form of the temporary folder, kept for the process: GetLongPathNameW reads the disk, so it is computed
// before main (temp_form_init) and again only when the folder's name changes (a test harness's TEMP). Heap memory: the
// process's, never freed.
@(private = "file") temp_lock: sync.Mutex
@(private = "file") temp_kept_named: string
@(private = "file") temp_kept_form: string

@(init, private = "file")
temp_form_init :: proc "contextless" () {
	context = runtime.default_context()
	if t := temp_named(); t != "" { _ = temp_form(t, context.temp_allocator, #location()) }
	free_all(context.temp_allocator)
}

// The temporary folder in the system's form (temp_dir): the one kept when its name has not changed, else read on the
// disk (a blocking call) and kept.
@(private)
temp_form :: proc(named: string, allocator: runtime.Allocator, loc: runtime.Source_Code_Location) -> string {
	{
		sync.guard(&temp_lock)
		if temp_kept_form != "" && named == temp_kept_named { return strings.clone(temp_kept_form, allocator) }
	}
	base.blocking("fsx.temp_dir", loc)   // (the long names are read on the disk)
	form := system_form(named, runtime.heap_allocator())
	sync.guard(&temp_lock)
	if temp_kept_form != "" {
		delete(temp_kept_named, runtime.heap_allocator())
		delete(temp_kept_form, runtime.heap_allocator())
	}
	temp_kept_named, temp_kept_form = strings.clone(named, runtime.heap_allocator()), form
	return strings.clone(form, allocator)
}

// A path as the system gives one: backslashes, the long name of each folder that exists (GetLongPathNameW: `RUNNER~1`
// becomes `runneradmin`), no separator at its end (a root such as `C:\` keeps its own).
@(private)
system_form :: proc(path: string, allocator: runtime.Allocator) -> string {
	p, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	if long := long_name(p); long != "" { p = long }
	trimmed := strings.trim_right(p, "\\")
	if trimmed == "" || strings.has_suffix(trimmed, ":") { return strings.clone(p, allocator) }
	return strings.clone(trimmed, allocator)
}

// The long form of a path that exists (temp memory); "" when the system gives none (a path that does not exist).
@(private = "file")
long_name :: proc(path: string) -> string {
	w := wide(path)
	n := win.GetLongPathNameW(w, nil, 0)
	if n == 0 { return "" }
	buf := make([]u16, n, context.temp_allocator)
	got := win.GetLongPathNameW(w, cast(win.LPCWSTR)raw_data(buf), n)   // (declared const; the system writes it)
	if got == 0 || got >= n { return "" }
	s, err := win.utf16_to_utf8(buf[:got], context.temp_allocator)
	return err == nil ? s : ""
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

// What `path` reaches, links followed: .Directory (size 0), .File (its size), or .Absent. Never calls core:os's
// os.stat, which aliases the caller's path string in File_Info.fullpath for every reparse point (junctions, symlinks,
// cloud files), making os.file_info_delete free the caller's path.
stat_follow :: proc(path: string, loc := #caller_location) -> (kind: Path_Kind, size: i64) {
	base.blocking("fsx.stat_follow", loc)
	if path == "" { return .Absent, 0 }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	w := wide(long_path(path))
	data: win.WIN32_FILE_ATTRIBUTE_DATA
	ok := bool(win.GetFileAttributesExW(w, win.GetFileExInfoStandard, &data))
	if ok && data.dwFileAttributes & win.FILE_ATTRIBUTE_REPARSE_POINT == 0 {
		if data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 { return .Directory, 0 }
		return .File, i64(data.nFileSizeHigh) << 32 | i64(data.nFileSizeLow)
	}
	h := win.CreateFileW(w, 0, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS, nil)
	if h == win.INVALID_HANDLE_VALUE {
		e := win.GetLastError()
		if ok && (e == win.ERROR_ACCESS_DENIED || e == win.ERROR_SHARING_VIOLATION) {
			if data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 { return .Directory, 0 }
			return .File, i64(data.nFileSizeHigh) << 32 | i64(data.nFileSizeLow)
		}
		return .Absent, 0
	}
	defer win.CloseHandle(h)
	d: win.BY_HANDLE_FILE_INFORMATION
	if !win.GetFileInformationByHandle(h, &d) { return .Absent, 0 }
	if d.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 { return .Directory, 0 }
	return .File, i64(d.nFileSizeHigh) << 32 | i64(d.nFileSizeLow)
}
