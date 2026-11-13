#+build windows
package platform

// What every window of the program shows and groups under, with no code of the program's: the icon of its executable
// (resource 1, which gt:toolbox's build_windows writes from the Project) and the AppUserModelID its build gives
// (-define:GT_AUMID=<Project.aumid>, the same its shortcuts carry: desktop.Identity.aumid). window_class_register takes
// both, once, before the first window.

import win "core:sys/windows"

// The AppUserModelID of the build ("": none; the taskbar then groups the windows by the executable).
BUILD_AUMID :: #config(GT_AUMID, "")

foreign import shell32_identity "system:Shell32.lib"
@(default_calling_convention = "system", private = "file")
foreign shell32_identity {
	SetCurrentProcessExplicitAppUserModelID :: proc(app_id: cstring16) -> win.HRESULT ---
	GetCurrentProcessExplicitAppUserModelID :: proc(app_id: ^cstring16) -> win.HRESULT ---
}

// The executable's icon at `size` pixels (the size the .ico has nearest, not one scaled by the class); nil when it has
// none.
@(private)
app_icon_load :: proc(instance: win.HINSTANCE, size: i32) -> win.HICON {
	return win.HICON(win.LoadImageW(instance, transmute(win.LPCWSTR)uintptr(1), win.IMAGE_ICON, size, size, win.LR_DEFAULTCOLOR))
}

// The build's AppUserModelID for the process, unless the program set one already (desktop.set_process_identity,
// notify_set_app): before the first window, which the taskbar groups by it.
@(private)
app_identity_declare :: proc() {
	when BUILD_AUMID != "" {
		current: cstring16
		if GetCurrentProcessExplicitAppUserModelID(&current) >= 0 && current != nil {
			win.CoTaskMemFree(rawptr(current))
			return
		}
		SetCurrentProcessExplicitAppUserModelID(win.L(BUILD_AUMID))
	}
}
