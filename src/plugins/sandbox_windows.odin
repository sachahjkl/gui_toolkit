#+build windows
package tk_plugins

// A plugin's process isolated by Windows (plugins.md, "As built: the sandbox"): an AppContainer with no capability.
// Windows gives it when the process is made, so the parent's sandbox_spawn does the work and the child's
// sandbox_enter only checks that its token is a container's.
//
// What the container cannot reach: the person's files and folders (each object needs an entry for the container or for
// ALL APPLICATION PACKAGES), the network (no internetClient capability, and no loopback either), other processes'
// windows and objects. What it keeps: its pipes, inherited by handle, and what any packaged app reads (the system's
// DLLs). The program's executable must be readable and executable by the container: sandbox_spawn grants that to the
// container's SID on that one file, once per run (an entry kept in the file's access list, the same each time).

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "../fsx"

@(private = "file") PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: win.DWORD_PTR(0x00020002)
@(private = "file") PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES :: win.DWORD_PTR(0x00020009)
@(private = "file") HRESULT_ALREADY_EXISTS :: u32(0x800700B7)   // HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)
@(private = "file") SE_FILE_OBJECT :: u32(1)
@(private = "file") DACL_SECURITY_INFORMATION :: win.DWORD(0x00000004)
@(private = "file") GRANT_ACCESS :: u32(1)
@(private = "file") TRUSTEE_IS_SID :: u32(0)
@(private = "file") TRUSTEE_IS_UNKNOWN :: u32(0)
@(private = "file") FILE_READ_EXECUTE :: win.DWORD(0x80000000 | 0x20000000)   // GENERIC_READ | GENERIC_EXECUTE

@(private = "file")
SECURITY_CAPABILITIES :: struct {
	AppContainerSid: rawptr,
	Capabilities:    rawptr,
	CapabilityCount: win.DWORD,
	Reserved:        win.DWORD,
}

@(private = "file")
STARTUPINFOEXW :: struct {
	StartupInfo:     win.STARTUPINFOW,
	lpAttributeList: rawptr,
}

@(private = "file")
TRUSTEE_W :: struct {
	pMultipleTrustee:         rawptr,
	MultipleTrusteeOperation: u32,
	TrusteeForm:              u32,
	TrusteeType:              u32,
	ptstrName:                rawptr,
}

@(private = "file")
EXPLICIT_ACCESS_W :: struct {
	grfAccessPermissions: win.DWORD,
	grfAccessMode:        u32,
	grfInheritance:       win.DWORD,
	Trustee:              TRUSTEE_W,
}

foreign import kernel32 "system:Kernel32.lib"
foreign import userenv "system:Userenv.lib"
foreign import advapi32 "system:Advapi32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	InitializeProcThreadAttributeList :: proc(list: rawptr, count: win.DWORD, flags: win.DWORD, size: ^win.SIZE_T) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(list: rawptr, flags: win.DWORD, attribute: win.DWORD_PTR, value: rawptr, size: win.SIZE_T, previous: rawptr, return_size: ^win.SIZE_T) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(list: rawptr) ---
}

@(default_calling_convention = "system", private = "file")
foreign userenv {
	CreateAppContainerProfile :: proc(name, display, description: win.LPCWSTR, capabilities: rawptr, count: win.DWORD, sid: ^rawptr) -> u32 ---
	DeriveAppContainerSidFromAppContainerName :: proc(name: win.LPCWSTR, sid: ^rawptr) -> u32 ---
}

@(default_calling_convention = "system", private = "file")
foreign advapi32 {
	FreeSid :: proc(sid: rawptr) -> rawptr ---
	GetNamedSecurityInfoW :: proc(name: win.LPCWSTR, object: u32, info: win.DWORD, owner, group: ^rawptr, dacl, sacl: ^rawptr, descriptor: ^rawptr) -> win.DWORD ---
	SetEntriesInAclW :: proc(count: win.ULONG, entries: ^EXPLICIT_ACCESS_W, old_acl: rawptr, new_acl: ^rawptr) -> win.DWORD ---
	SetNamedSecurityInfoW :: proc(name: win.LPWSTR, object: u32, info: win.DWORD, owner, group: rawptr, dacl, sacl: rawptr) -> win.DWORD ---
}

// The executable whose access list holds the container's entry in this run (one grant a run; under start_lock).
@(private = "file") granted_exe: string

// The process, in an AppContainer unless `mode` is Off; If_Available starts it as the program's when the container
// cannot be made (its log then says it is not isolated). Called under start_lock: the handles' inheritance is the
// process's.
@(private)
sandbox_spawn :: proc(exe: string, stdin, stdout: ^os.File, mode: Sandbox_Mode) -> (os.Process, os.Error) {
	plain :: proc(exe: string, stdin, stdout: ^os.File) -> (os.Process, os.Error) {
		return os.process_start({command = {exe, CHILD_ARG}, stdin = stdin, stdout = stdout, stderr = os.stderr})
	}
	if mode == .Off { return plain(exe, stdin, stdout) }
	child, why := container_start(exe, stdin, stdout)
	if why == "" { return child, nil }
	if mode == .Required {
		fmt.eprintfln("gt:plugins: a plugin's process cannot be isolated: %s", why)
		return {}, .Permission_Denied
	}
	// (If_Available: the child finds itself outside a container, and says so in its log)
	return plain(exe, stdin, stdout)
}

// Whether this system can isolate a plugin's process (an AppContainer: Windows 8 and later).
sandbox_available :: proc() -> (ok: bool, why: string) { return true, "" }

// The child: its token is an AppContainer's, or it is not isolated. One process-wide token: no thread to count.
@(private)
sandbox_enter :: proc(mode: Sandbox_Mode) -> (isolated: bool, said: string) {
	if mode == .Off { return false, "not isolated: the program turned its sandbox off (Host_Options.sandbox)" }
	token: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) {
		return false, fmt.tprintf("not isolated: its token cannot be read (error %d)", win.GetLastError())
	}
	defer win.CloseHandle(token)
	is_container: win.DWORD
	size: win.DWORD
	if !win.GetTokenInformation(token, .TokenIsAppContainer, &is_container, size_of(is_container), &size) {
		return false, fmt.tprintf("not isolated: its token says nothing of a container (error %d)", win.GetLastError())
	}
	if is_container == 0 { return false, "not isolated: its process is not in an AppContainer (the container could not be made)" }
	return true, "isolated: AppContainer, no capability (no file of the person's, no network)"
}

// What test_escape tries: a file read, a file made (a socket would need the network's package: the container has no
// network capability, which this test does not try).
@(private)
escape_try :: proc(read_path, create_dir: string) -> (read, create, socket: bool) {
	_, read = fsx.read_all(read_path, context.temp_allocator, 1 << 20)
	path := fsx.path_join(create_dir, "escape.txt")
	if fsx.write_atomic(path, {}) {
		create = true
		_ = fsx.delete_file(path)
	}
	return
}

// The child in the program's container ("" done; else the step that failed and Windows' error).
@(private = "file")
container_start :: proc(exe: string, stdin, stdout: ^os.File) -> (child: os.Process, why: string) {
	context.allocator = runtime.heap_allocator()
	// (one container for the program, named from its executable: the same at each run, so its grant stays valid)
	name := fmt.tprintf("gt.plugins.%16x", hash.fnv64a(transmute([]u8)exe))
	wname := win.utf8_to_wstring(name, context.temp_allocator)
	sid: rawptr
	if hr := CreateAppContainerProfile(wname, wname, wname, nil, 0, &sid); hr != 0 {
		if hr != HRESULT_ALREADY_EXISTS { return {}, fmt.tprintf("CreateAppContainerProfile: 0x%08x", hr) }
		if hr2 := DeriveAppContainerSidFromAppContainerName(wname, &sid); hr2 != 0 {
			return {}, fmt.tprintf("DeriveAppContainerSidFromAppContainerName: 0x%08x", hr2)
		}
	}
	defer FreeSid(sid)
	if granted_exe != exe {
		if why = grant_exe(exe, sid); why != "" { return }
		delete(granted_exe)
		granted_exe = strings.clone(exe)
	}

	// the handles the child gets, and only those
	handles := [3]win.HANDLE{win.HANDLE(os.fd(stdin)), win.HANDLE(os.fd(stdout)), win.GetStdHandle(win.STD_ERROR_HANDLE)}
	n_handles := handles[2] == nil || handles[2] == win.INVALID_HANDLE_VALUE ? 2 : 3
	for h in handles[:n_handles] { win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT) }
	defer for h in handles[:2] { win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, 0) }

	size: win.SIZE_T
	InitializeProcThreadAttributeList(nil, 2, 0, &size)
	list := make([]u8, int(size), context.temp_allocator)
	if !InitializeProcThreadAttributeList(raw_data(list), 2, 0, &size) {
		return {}, fmt.tprintf("InitializeProcThreadAttributeList: error %d", win.GetLastError())
	}
	defer DeleteProcThreadAttributeList(raw_data(list))
	caps := SECURITY_CAPABILITIES{AppContainerSid = sid}
	if !UpdateProcThreadAttribute(raw_data(list), 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &caps, size_of(caps), nil, nil) {
		return {}, fmt.tprintf("UpdateProcThreadAttribute (container): error %d", win.GetLastError())
	}
	if !UpdateProcThreadAttribute(raw_data(list), 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &handles[0], win.SIZE_T(n_handles * size_of(win.HANDLE)), nil, nil) {
		return {}, fmt.tprintf("UpdateProcThreadAttribute (handles): error %d", win.GetLastError())
	}
	si := STARTUPINFOEXW{lpAttributeList = raw_data(list)}
	si.StartupInfo.cb = size_of(STARTUPINFOEXW)
	si.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES
	si.StartupInfo.hStdInput, si.StartupInfo.hStdOutput = handles[0], handles[1]
	if n_handles == 3 { si.StartupInfo.hStdError = handles[2] }
	command := win.utf8_to_wstring(fmt.tprintf("\"%s\" %s", exe, CHILD_ARG), context.temp_allocator)
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(win.utf8_to_wstring(exe, context.temp_allocator), command, nil, nil, true,
		win.EXTENDED_STARTUPINFO_PRESENT | win.CREATE_NO_WINDOW, nil, nil, &si.StartupInfo, &pi) {
		return {}, fmt.tprintf("CreateProcessW in the container: error %d", win.GetLastError())
	}
	win.CloseHandle(pi.hThread)
	return {pid = int(pi.dwProcessId), handle = uintptr(pi.hProcess)}, ""
}

// Read and execute of the program's executable for the container's SID, added to the file's access list ("": done).
@(private = "file")
grant_exe :: proc(exe: string, sid: rawptr) -> string {
	wexe := win.utf8_to_wstring(exe, context.temp_allocator)
	old_dacl, descriptor: rawptr
	if e := GetNamedSecurityInfoW(wexe, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nil, nil, &old_dacl, nil, &descriptor); e != 0 {
		return fmt.tprintf("GetNamedSecurityInfoW on the executable: error %d", e)
	}
	defer win.LocalFree(descriptor)
	entry := EXPLICIT_ACCESS_W{
		grfAccessPermissions = FILE_READ_EXECUTE, grfAccessMode = GRANT_ACCESS,
		Trustee = {TrusteeForm = TRUSTEE_IS_SID, TrusteeType = TRUSTEE_IS_UNKNOWN, ptstrName = sid},
	}
	new_dacl: rawptr
	if e := SetEntriesInAclW(1, &entry, old_dacl, &new_dacl); e != 0 { return fmt.tprintf("SetEntriesInAclW: error %d", e) }
	defer win.LocalFree(new_dacl)
	if e := SetNamedSecurityInfoW(win.LPWSTR(rawptr(wexe)), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nil, nil, new_dacl, nil); e != 0 {
		return fmt.tprintf("SetNamedSecurityInfoW on the executable: error %d", e)
	}
	return ""
}
