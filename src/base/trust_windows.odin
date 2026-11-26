package gt_base

import "core:strings"
import win "core:sys/windows"

// (winnt.h)
@(private = "file") SECURITY_MANDATORY_HIGH_RID :: 0x3000

foreign import advapi32_trust "system:Advapi32.lib"
foreign import kernel32_trust "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign advapi32_trust {
	GetSidSubAuthorityCount :: proc(sid: win.PSID) -> ^u8 ---
	GetSidSubAuthority :: proc(sid: win.PSID, n: win.DWORD) -> ^win.DWORD ---
}

@(private = "file", default_calling_convention = "system")
foreign kernel32_trust {
	SetDefaultDllDirectories :: proc(flags: win.DWORD) -> win.BOOL ---
}

// (libloaderapi.h)
@(private = "file") LOAD_LIBRARY_SEARCH_APPLICATION_DIR :: 0x0200
@(private = "file") LOAD_LIBRARY_SEARCH_SYSTEM32 :: 0x0800

// A library loaded later by its name (LoadLibrary: a GPU's driver library, a codec) is looked for in the program's
// folder and System32 only: never in the working folder nor the PATH, where another program can put one of that name.
// The program's folder stays: a program that ships a library beside it finds it (that folder is as writable as the
// program itself). host.program_start and setup.command_run call it first.
dll_search_restrict :: proc() {
	_ = SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32)
}

// TokenElevation, then the integrity level: an administrator with UAC off has a full token that may not say
// "elevated", and SYSTEM's integrity is above high. Any failure: elevated (fail closed).
@(private)
elevation_query :: proc() -> bool {
	token: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) { return true }
	defer win.CloseHandle(token)
	elevation: u32   // TOKEN_ELEVATION { TokenIsElevated }
	size: win.DWORD
	if !win.GetTokenInformation(token, .TokenElevation, &elevation, size_of(elevation), &size) { return true }
	if elevation != 0 { return true }
	buf: [64]u8   // TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES { PSID, DWORD } } and the SID
	if !win.GetTokenInformation(token, .TokenIntegrityLevel, &buf[0], size_of(buf), &size) { return true }
	sid := (^win.PSID)(&buf[0])^
	count := GetSidSubAuthorityCount(sid)
	if count == nil || count^ == 0 { return true }
	rid := GetSidSubAuthority(sid, win.DWORD(count^ - 1))^
	return rid >= SECURITY_MANDATORY_HIGH_RID
}

// A program by its full path in a folder that only an administrator writes: a file directly in System32 or SysWOW64,
// or in System32's WindowsPowerShell\v1.0, anything under Program Files and Program Files (x86). A bare
// name is never one: the search for it goes through the working folder and the user's PATH.
// - Not a folder of System32 or SysWOW64: some are the users' to write (spool\drivers\color, Tasks, com\dmp, FxsTmp,
//   Microsoft\Crypto\RSA\MachineKeys...), and a list of them is bypassed by their 8.3 names (TASKS_~1) or a stream
//   (Tasks::$INDEX_ALLOCATION). No user can create a file directly in either folder.
// - No ':' after the drive: an alternate data stream is not the file that its name shows.
// - The system's folders come from the kernel (GetSystemDirectoryW), not from a variable of the environment.
// (A folder of Program Files that an installer opened to users is the installer's mistake: it cannot be seen from the
// path: src/md/features/elevated-process.md.)
trusted_program :: proc(program: string) -> bool {
	full := full_path(program)
	if full == "" || strings.contains_rune(full[2:], ':') { return false }
	for dir in ([]string{system_dir(.System), system_dir(.Wow64), system_dir(.Power_Shell)}) {
		if dir == "" || !has_prefix_fold(full, dir) { continue }
		if !strings.contains_any(full[len(dir):], "\\/") { return true }
	}
	for k in ([]Known_Dir{.Program_Files, .Program_Files_X86}) {
		if d := known_dir(k); d != "" && has_prefix_fold(full, strings.concatenate({d, "\\"}, context.temp_allocator)) { return true }
	}
	return false
}

@(private = "file")
System_Dir :: enum u8 { System, Wow64, Power_Shell }

// A folder of the system, from the kernel, with its last backslash ("" when Windows does not say: then nothing in it
// is trusted).
@(private = "file")
system_dir :: proc(k: System_Dir) -> string {
	buf: [1024]u16
	n: u32
	switch k {
	case .System, .Power_Shell: n = win.GetSystemDirectoryW(&buf[0], len(buf))
	case .Wow64:       n = win.GetSystemWow64DirectoryW(&buf[0], len(buf))
	}
	if n == 0 || int(n) >= len(buf) { return "" }
	out, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil || out == "" { return "" }
	out = strings.trim_right(out, "\\")
	if k == .Power_Shell { return strings.concatenate({out, "\\WindowsPowerShell\\v1.0\\"}, context.temp_allocator) }
	return strings.concatenate({out, "\\"}, context.temp_allocator)
}

// The path made whole by the system (".." and "." gone, slashes turned), "" for a relative path or a bare name.
@(private = "file")
full_path :: proc(path: string) -> string {
	if !windows_absolute(path) { return "" }
	w := win.utf8_to_wstring(path, context.temp_allocator)
	n := win.GetFullPathNameW(w, 0, nil, nil)
	if n == 0 { return "" }
	buf := make([]u16, n, context.temp_allocator)
	got := win.GetFullPathNameW(w, n, cstring16(raw_data(buf)), nil)
	if got == 0 || got >= n { return "" }
	out, err := win.utf16_to_utf8(buf[:got], context.temp_allocator)
	return err == nil ? out : ""
}

@(private = "file")
Known_Dir :: enum u8 { Program_Files, Program_Files_X86 }

@(private = "file")
known_dir :: proc(k: Known_Dir) -> string {
	id: win.GUID
	switch k {
	case .Program_Files:     id = win.FOLDERID_ProgramFiles
	case .Program_Files_X86: id = win.FOLDERID_ProgramFilesX86
	}
	p: win.LPWSTR
	if win.SHGetKnownFolderPath(&id, 0, nil, &p) < 0 || p == nil { return "" }
	defer win.CoTaskMemFree(p)
	n := 0
	for (cast([^]u16)p)[n] != 0 { n += 1 }
	out, err := win.utf16_to_utf8((cast([^]u16)p)[:n], context.temp_allocator)
	return err == nil ? strings.trim_right(out, "\\") : ""
}

// (a path's case folds by Unicode on Windows' file systems: strings.equal_fold, listed in tools/unicode_case_allowed.txt)
@(private = "file")
has_prefix_fold :: proc(s, prefix: string) -> bool { return len(s) >= len(prefix) && strings.equal_fold(s[:len(prefix)], prefix) }
