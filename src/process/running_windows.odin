package tk_process

import "core:os"
import "core:strings"
import win "core:sys/windows"

foreign import kernel32_running "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_running {
	QueryFullProcessImageNameW :: proc(process: win.HANDLE, flags: win.DWORD, name: win.LPWSTR, size: ^win.DWORD) -> win.BOOL ---
}

// A path of an executable, in UTF-16 units (a long path's limit).
@(private = "file") EXE_PATH_UNITS :: 32 * 1024

// The processes whose image (QueryFullProcessImageNameW) is `exe`, from a snapshot of the system's processes. A process
// this user cannot open (another user's, a protected one) is left out: it is not this user's program.
processes_of :: proc(exe: string, allocator := context.allocator) -> []Process_Ref {
	found := make([dynamic]Process_Ref, allocator)
	if exe == "" { return found[:] }
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snap == win.INVALID_HANDLE_VALUE { return found[:] }
	defer win.CloseHandle(snap)
	self := win.DWORD(os.get_pid())
	entry := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	buf := make([]u16, EXE_PATH_UNITS, context.temp_allocator)
	for more := win.Process32FirstW(snap, &entry); more; more = win.Process32NextW(snap, &entry) {
		pid := entry.th32ProcessID
		if pid == 0 || pid == self { continue }
		h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
		if h == nil { continue }
		size := win.DWORD(len(buf))
		image := ""
		if QueryFullProcessImageNameW(h, 0, raw_data(buf), &size) {
			image, _ = win.utf16_to_utf8(buf[:size], context.temp_allocator)
		}
		start, has_start := creation_time(h)
		win.CloseHandle(h)
		if has_start && same_executable(image, exe) { append(&found, Process_Ref{i32(pid), start}) }
	}
	return found[:]
}

same_executable :: proc(found, exe: string) -> bool {
	if found == "" || exe == "" { return false }
	a, _ := strings.replace_all(found, "/", "\\", context.temp_allocator)
	b, _ := strings.replace_all(exe, "/", "\\", context.temp_allocator)
	return strings.equal_fold(a, b)
}

// When the process of `h` started (a FILETIME: 100 ns since 1601), the second half of its name.
@(private)
creation_time :: proc(h: win.HANDLE) -> (start: u64, ok: bool) {
	created, exited, kernel, user: win.FILETIME
	if !win.GetProcessTimes(h, &created, &exited, &kernel, &user) { return }
	return u64(created.dwHighDateTime) << 32 | u64(created.dwLowDateTime), true
}
