package tk_instance

// Windows: a named mutex (Local\<name>: this session's, not the machine's), a message-only window titled with the name,
// WM_COPYDATA between them. See instance.odin for the whole picture.

import "base:runtime"
import "core:strings"
import "core:time"
import win "core:sys/windows"

foreign import kernel32_inst "system:Kernel32.lib"
foreign import user32_inst "system:User32.lib"

@(default_calling_convention = "system", private)
foreign kernel32_inst {
	CreateMutexW :: proc(attributes: rawptr, initial_owner: win.BOOL, name: cstring16) -> win.HANDLE ---
}

@(default_calling_convention = "system", private)
foreign user32_inst {
	AllowSetForegroundWindow    :: proc(pid: win.DWORD) -> win.BOOL ---
	FlashWindowEx               :: proc(info: ^Flash_Info) -> win.BOOL ---
	SendMessageTimeoutW         :: proc(hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, flags: win.UINT, timeout: win.UINT, result: ^win.DWORD_PTR) -> win.LRESULT ---
	ChangeWindowMessageFilterEx :: proc(hwnd: win.HWND, message: win.UINT, action: win.DWORD, filter: rawptr) -> win.BOOL ---
}

// FLASHWINFO (winuser.h): the taskbar button flashes when the foreground cannot be taken.
@(private = "file")
Flash_Info :: struct { size: win.UINT, hwnd: win.HWND, flags: win.DWORD, count: win.UINT, timeout: win.DWORD }
@(private = "file") FLASHW_TRAY :: 0x2
@(private = "file") FLASHW_TIMERNOFG :: 0xC

@(private = "file") SMTO_ABORTIFHUNG :: 0x0002
@(private = "file") SMTO_BLOCK       :: 0x0001
@(private = "file") MSGFLT_ALLOW     :: 1
@(private = "file") CLASS_NAME       :: "TkInstanceWindow"
@(private = "file") MAGIC            :: 0x544B_494E   // "TKIN": the dwData of the WM_COPYDATA

// What the owner holds.
Owner :: struct {
	name:     string,        // owned
	mutex:    win.HANDLE,
	hwnd:     win.HWND,
	identity: string,        // owned: the token a sender must match to hand over ("" trusts any sender)
	closing:  bool,          // set before the window goes: later messages are refused
	handler:  Handler,
	user:     rawptr,
	class:    bool,          // the window class is registered
}

@(private = "file")
mutex_name :: proc(name: string) -> cstring16 {
	return win.utf8_to_wstring(strings.concatenate({"Local\\", name}, context.temp_allocator), context.temp_allocator)
}

// Creates or opens the mutex of `name`: existing = another process (or an earlier call) holds it.
@(private = "file")
claim :: proc(name: string) -> (mutex: win.HANDLE, existing: bool) {
	mutex = CreateMutexW(nil, false, mutex_name(name))
	existing = mutex != nil && win.GetLastError() == win.ERROR_ALREADY_EXISTS
	return
}

@(private)
Reply :: enum u8 { No_Window, Accepted, Other_Instance, Refused, Timeout }

// One attempt to hand `message` (under `identity`) to the owner of `name`.
@(private)
forward_once :: proc(name, identity: string, message: []byte, timeout_ms: int) -> Reply {
	hwnd := win.FindWindowExW(win.HWND_MESSAGE, nil, win.utf8_to_wstring(CLASS_NAME, context.temp_allocator), win.utf8_to_wstring(name, context.temp_allocator))
	if hwnd == nil { return .No_Window }
	pid: win.DWORD
	win.GetWindowThreadProcessId(hwnd, &pid)
	if pid != 0 { AllowSetForegroundWindow(pid) }   // (the owner may come to the front: this process was just started by the user's action)
	data := encode(identity, message)
	cds := win.COPYDATASTRUCT{dwData = MAGIC, cbData = win.DWORD(len(data)), lpData = raw_data(data)}
	result: win.DWORD_PTR
	r := SendMessageTimeoutW(hwnd, win.WM_COPYDATA, 0, win.LPARAM(uintptr(&cds)), SMTO_ABORTIFHUNG | SMTO_BLOCK, win.UINT(timeout_ms), &result)
	if r == 0 {
		if !win.IsWindow(hwnd) { return .No_Window }   // it closed while we asked
		return .Timeout
	}
	switch result {
	case 1: return .Accepted
	case 2: return .Other_Instance
	}
	return .Refused
}

// Hands `message` to the owner of `cfg.name` without trying to become the owner: a pure "ping the running copy". Returns
// Forwarded (taken), Other_Instance, or Unresponsive (no owner, a different identity refused, or no answer).
send :: proc(cfg: Config, message: []byte) -> Outcome {
	switch forward_once(cfg.name, cfg.identity, message, max(cfg.wait_ms, 200)) {
	case .Accepted:        return .Forwarded
	case .Other_Instance:  return .Other_Instance
	case .No_Window, .Refused, .Timeout: return .Unresponsive
	}
	return .Unresponsive
}

// Takes the name of `cfg.name` or hands `message` to the copy that has it. Tries for up to `cfg.wait_ms` while the owner is
// starting or closing; a silent owner ends the wait at once (it is busy or hung: not worth waiting for).
acquire :: proc(cfg: Config, message: []byte) -> (Outcome, Owner) {
	deadline := time.tick_add(time.tick_now(), time.Duration(cfg.wait_ms) * time.Millisecond)
	for {
		mutex, existing := claim(cfg.name)
		if mutex == nil { return .Unresponsive, {} }   // (no kernel object: carry on as if it was not asked)
		if !existing { return .First, Owner{name = strings.clone(cfg.name), mutex = mutex, identity = strings.clone(cfg.identity)} }
		win.CloseHandle(mutex)
		left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
		switch forward_once(cfg.name, cfg.identity, message, max(left, 200)) {
		case .Accepted:        return .Forwarded, {}
		case .Other_Instance:  return .Other_Instance, {}
		case .Timeout:         return .Unresponsive, {}
		case .No_Window, .Refused:
		}
		if left <= 0 { return .Unresponsive, {} }
		time.sleep(40 * time.Millisecond)
	}
}

// Makes the owner's window (on this thread, which must go on pumping messages) and the handler that takes the messages.
owner_start :: proc(o: ^Owner, handler: Handler, user: rawptr) -> bool {
	if o.mutex == nil { return false }
	o.handler, o.user = handler, user
	inst := win.HINSTANCE(win.GetModuleHandleW(nil))
	class := win.utf8_to_wstring(CLASS_NAME, context.temp_allocator)
	wc := win.WNDCLASSEXW{cbSize = size_of(win.WNDCLASSEXW), lpfnWndProc = owner_proc, hInstance = inst, lpszClassName = class}
	if win.RegisterClassExW(&wc) != 0 { o.class = true }
	o.hwnd = win.CreateWindowExW(0, class, win.utf8_to_wstring(o.name, context.temp_allocator), 0, 0, 0, 0, 0, win.HWND_MESSAGE, nil, inst, nil)
	if o.hwnd == nil { return false }
	win.SetWindowLongPtrW(o.hwnd, win.GWLP_USERDATA, win.LONG_PTR(uintptr(o)))
	// An elevated owner takes the message from a normal sender (a link clicked in a normal program) only if it lets the
	// message through (UIPI); a normal owner leaves the default, which keeps it from processes of a lower integrity.
	if is_elevated() { ChangeWindowMessageFilterEx(o.hwnd, win.WM_COPYDATA, MSGFLT_ALLOW, nil) }
	return true
}

// Does this process run with an elevated token (as administrator)?
is_elevated :: proc() -> bool {
	token: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) { return false }
	defer win.CloseHandle(token)
	elevation: u32   // TOKEN_ELEVATION { TokenIsElevated }
	size: win.DWORD
	if !win.GetTokenInformation(token, .TokenElevation, &elevation, size_of(elevation), &size) { return false }
	return elevation != 0
}

@(private = "file")
owner_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	if msg != win.WM_COPYDATA { return win.DefWindowProcW(hwnd, msg, wparam, lparam) }
	context = runtime.default_context()
	o := (^Owner)(uintptr(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA)))
	cds := (^win.COPYDATASTRUCT)(uintptr(lparam))
	if o == nil || cds == nil || cds.dwData != MAGIC || o.closing || o.handler == nil { return 0 }
	if cds.cbData == 0 || cds.cbData > ENVELOPE_MAX || cds.lpData == nil { return 0 }
	identity, message, ok := decode((cast([^]byte)cds.lpData)[:cds.cbData])
	if !ok { return 0 }
	if !same_identity(o.identity, identity) { return 2 }
	o.handler(o.user, message)
	return 1
}

// The owner is ending: later messages are refused and the window goes. The name is still its own (the mutex is held):
// a start that comes now waits, and takes the name once owner_stop has released it.
owner_closing :: proc(o: ^Owner) {
	o.closing = true
	if o.hwnd != nil { win.DestroyWindow(o.hwnd); o.hwnd = nil }
}

// The owner is done with the name: the mutex is released (a start that was waiting becomes the owner).
owner_stop :: proc(o: ^Owner) {
	owner_closing(o)
	if o.mutex != nil { win.CloseHandle(o.mutex); o.mutex = nil }
	delete(o.name); delete(o.identity)
	o.name, o.identity = "", ""
}

// Brings a window to the front: restored when minimized, then raised and given the foreground (the owner was allowed to by
// the sender's AllowSetForegroundWindow); without that permission the taskbar button flashes instead. `handle` is an
// opaque window handle (a HWND on Windows): an application calls this from its handler to bring its own window forward.
raise_window :: proc(handle: rawptr) {
	hwnd := win.HWND(handle)
	if hwnd == nil { return }
	if win.IsIconic(hwnd) { win.ShowWindow(hwnd, win.SW_RESTORE) }
	win.BringWindowToTop(hwnd)
	if !win.SetForegroundWindow(hwnd) {
		flash := Flash_Info{size = size_of(Flash_Info), hwnd = hwnd, flags = FLASHW_TRAY | FLASHW_TIMERNOFG, count = 3}
		FlashWindowEx(&flash)
	}
}

// Pumps this thread's messages (the owner's window gets its WM_COPYDATA here); for tests that stand for the application's loop.
pump_messages :: proc() {
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}
