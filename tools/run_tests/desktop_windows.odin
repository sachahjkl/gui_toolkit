#+build windows
package run_tests

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

// The runner runs itself again on a Windows desktop of its own, which nobody looks at: everything it starts stays there. What a test opens cannot take the
// focus, the mouse or the keyboard of the person at the machine, whatever it does, and their clicks cannot reach it. (Real input of the machine goes nowhere
// there.) What the runner prints comes through a file: a console does not cross desktops.

@(private = "file") ON_DESKTOP_VAR :: "TOOLKIT_TEST_DESKTOP"
@(private = "file") DESKTOP_RIGHTS :: 0x10000000   // GENERIC_ALL
@(private = "file") POLL_MS :: 100                 // how often what it printed is passed on
@(private = "file") READ_BYTES :: 16 * 1024
@(private = "file") UOI_FLAGS :: 1
@(private = "file") UOI_NAME :: 2
@(private = "file") WSF_VISIBLE :: 0x0001

@(private = "file")
User_Object_Flags :: struct {
	inherit:  win.BOOL,
	reserved: win.BOOL,
	flags:    win.DWORD,
}

foreign import user32_desktop "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32_desktop {
	CreateDesktopW :: proc(name, device: win.LPCWSTR, mode: rawptr, flags, access: u32, attrs: rawptr) -> win.HANDLE ---
	CloseDesktop :: proc(desktop: win.HANDLE) -> win.BOOL ---
	GetProcessWindowStation :: proc() -> win.HANDLE ---
	GetUserObjectInformationW :: proc(obj: win.HANDLE, index: i32, info: rawptr, length: win.DWORD, needed: ^win.DWORD) -> win.BOOL ---
}

// Name of the process's window station when it is interactive (WSF_VISIBLE), else false.
// Under SSH or a service (Session 0), the window station is non-interactive: no user desktop exists to protect,
// and CreateDesktopW creates the desktop in that service station while a hardcoded "WinSta0\\..." fails child startup with 0xC0000142.
@(private = "file")
interactive_window_station :: proc(allocator := context.temp_allocator) -> (string, bool) {
	ws := GetProcessWindowStation()
	if ws == nil { return "", false }
	uof: User_Object_Flags
	needed: win.DWORD
	if !GetUserObjectInformationW(ws, UOI_FLAGS, &uof, size_of(uof), &needed) { return "", false }
	if (uof.flags & WSF_VISIBLE) == 0 { return "", false }
	buf: [128]u16
	if !GetUserObjectInformationW(ws, UOI_NAME, &buf[0], size_of(buf) - size_of(u16), &needed) { return "", false }
	count := min(int(needed) / size_of(u16), len(buf))
	for count > 0 && buf[count - 1] == 0 { count -= 1 }
	if count == 0 { return "", false }
	name, err := win.utf16_to_utf8(buf[:count], allocator)
	if err != nil || name == "" { return "", false }
	return name, true
}

// True: the run happened on the other desktop, and `code` is its exit code. False: this is the run (already there, non-interactive station, or no desktop can be made).
on_own_desktop :: proc(code: ^int) -> bool {
	if v, _ := os.lookup_env(ON_DESKTOP_VAR, context.temp_allocator); v != "" { return false }
	winsta, interactive := interactive_window_station()
	if !interactive { return false }
	name := fmt.tprintf("gui_toolkit_tests_%d", os.get_pid())
	desktop := CreateDesktopW(win.utf8_to_wstring(name, context.temp_allocator), nil, nil, 0, DESKTOP_RIGHTS, nil)
	if desktop == nil { return false }
	defer CloseDesktop(desktop)

	output := fmt.tprintf("%s/%s.txt", temp_dir(), name)
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	share := win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE
	file := win.CreateFileW(win.utf8_to_wstring(output, context.temp_allocator), win.GENERIC_WRITE, share, &sa, win.CREATE_ALWAYS, 0, nil)
	if file == win.INVALID_HANDLE_VALUE { return false }
	defer os.remove(output)

	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESTDHANDLES, hStdOutput = file, hStdError = file}
	where_ := fmt.tprintf("%s\\%s", winsta, name)
	si.lpDesktop = (^u16)(win.utf8_to_wstring(where_, context.temp_allocator))
	exe, _ := os.get_executable_path(context.temp_allocator)
	line := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&line, "\"%s\"", exe)
	for a in os.args[1:] { fmt.sbprintf(&line, " \"%s\"", a) }
	os.set_env(ON_DESKTOP_VAR, "1")
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(nil, win.utf8_to_wstring(strings.to_string(line), context.temp_allocator), nil, nil, true, 0, nil, nil, &si, &pi) {
		win.CloseHandle(file)
		fmt.eprintln("run_tests: no process on its own desktop")
		code^ = 2
		return true
	}
	win.CloseHandle(file)
	defer win.CloseHandle(pi.hProcess)
	defer win.CloseHandle(pi.hThread)

	reader, rerr := os.open(output)
	buf: [READ_BYTES]u8
	for {
		done := win.WaitForSingleObject(pi.hProcess, POLL_MS) == win.WAIT_OBJECT_0
		if rerr == nil {
			for {
				n, _ := os.read(reader, buf[:])
				if n <= 0 { break }
				os.write(os.stdout, buf[:n])
			}
		}
		if done { break }
	}
	if rerr == nil { os.close(reader) }
	exit: u32
	win.GetExitCodeProcess(pi.hProcess, &exit)
	code^ = int(exit)
	return true
}

@(private = "file")
temp_dir :: proc() -> string {
	d, _ := os.temp_directory(context.temp_allocator)
	return d
}

