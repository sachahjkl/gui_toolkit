package capture

// The decisions of the Windows backend that need no system call: which windows a screenshot tool lists, how a rotated
// output's picture is read, an executable's name from its path. Pure, so that tests/capture checks them on every system;
// capture_windows.odin gathers the facts and calls them.

// What the Windows backend reads about a top-level window before it decides to list it.
Win32_Window_Facts :: struct {
	visible:    bool,     // IsWindowVisible
	cloaked:    bool,     // DWMWA_CLOAKED: on another virtual desktop, a suspended UWP app, a hidden shell surface
	minimized:  bool,     // IsIconic
	has_owner:  bool,     // GetWindow(GW_OWNER): a dialog or a palette of another window
	ex_style:   u32,      // GWL_EXSTYLE
	class_name: string,
	title:      string,
	frame:      Rect,     // DWMWA_EXTENDED_FRAME_BOUNDS, physical
}

WIN32_WS_EX_TOOLWINDOW :: 0x0000_0080
WIN32_WS_EX_APPWINDOW  :: 0x0004_0000
WIN32_WS_EX_NOACTIVATE :: 0x0800_0000

// The shell's own surfaces: the wallpaper (Progman, WorkerW) and the taskbars. Visible, uncloaked, sometimes titled
// ("Program Manager"), never what a user means by a window.
WIN32_SHELL_CLASSES :: [?]string{"Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"}

// Whether a screenshot tool lists the window: what Alt+Tab shows, plus titled owned windows (a dialog is worth a
// screenshot). In order:
//   - not visible, or cloaked: not on screen;
//   - a class of the shell (WIN32_SHELL_CLASSES): not a window to the user;
//   - a tool window or a no-activate window (tooltips, menus, notifications, floating toolbars) unless it says it is an
//     app window (WS_EX_APPWINDOW wins over both, as for the taskbar);
//   - no area on screen and not minimized: an invisible helper;
//   - then: listed when it has a title, or when it is an owner-less app window (WS_EX_APPWINDOW, no owner) with none.
win32_window_listed :: proc(f: Win32_Window_Facts) -> bool {
	if !f.visible || f.cloaked { return false }
	shell := WIN32_SHELL_CLASSES
	for c in shell { if f.class_name == c { return false } }
	app_window := f.ex_style & WIN32_WS_EX_APPWINDOW != 0
	if !app_window && f.ex_style & (WIN32_WS_EX_TOOLWINDOW | WIN32_WS_EX_NOACTIVATE) != 0 { return false }
	if !f.minimized && (f.frame.w <= 0 || f.frame.h <= 0) { return false }
	if f.title != "" { return true }
	return app_window && !f.has_owner
}

// DXGI_MODE_ROTATION, as IDXGIOutputDuplication::GetDesc says it.
Win32_Rotation :: enum i32 { Unspecified = 0, Identity = 1, Rotate90 = 2, Rotate180 = 3, Rotate270 = 4 }

// Where pixel (x, y) of an output's picture, upright and `w` x `h`, is in the duplicated surface, which Desktop
// Duplication gives in the monitor's own orientation (not rotated: `h` x `w` for 90 and 270 degrees). Rotate90 means the
// desktop is turned 90 degrees clockwise onto the surface: its top-left pixel is the surface's top-right one.
win32_rotated_source :: proc(rotation: Win32_Rotation, x, y, w, h: i32) -> (sx, sy: i32) {
	switch rotation {
	case .Rotate90:            return h - 1 - y, x
	case .Rotate180:           return w - 1 - x, h - 1 - y
	case .Rotate270:           return y, w - 1 - x
	case .Identity, .Unspecified:
	}
	return x, y
}

// The file name of an executable's full path ("C:\\Windows\\notepad.exe": "notepad.exe"), what Window.app_id is on
// Windows.
win32_executable_name :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '\\' || path[i] == '/' { return path[i + 1:] }
	}
	return path
}
