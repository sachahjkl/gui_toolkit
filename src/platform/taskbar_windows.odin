#+build windows
package platform

// The taskbar button on Windows (taskbar.odin has the API, src/md/features/taskbar.md the reasons): ITaskbarList3 for the
// progress and the count's overlay icon, FlashWindowEx for the attention. The list answers only once Explorer sent the
// window TaskbarButtonCreated; that message comes again after Explorer restarts, and the list is made again and given the
// whole state. Every call runs on the window's thread, which joins COM for it.

import "core:math"
import "core:sync"
import win "core:sys/windows"

// The process's: the TaskbarButtonCreated message (the same number for every caller: atomic).
@(private) taskbar_button_msg: u32

@(private = "file") FLASHW_STOP :: 0
@(private = "file") FLASHW_TRAY :: 0x2
@(private = "file") FLASHW_TIMERNOFG :: 0xC   // until the window comes to the foreground
@(private = "file") MSGFLT_ALLOW :: 1
@(private = "file") SM_CXSMICON :: 49         // the small icon's size: an overlay icon is drawn at it
@(private = "file") SMALL_ICON_PX :: 16       // at 96 dpi
@(private = "file") DPI_DEFAULT :: 96

@(private = "file")
Flash_Window_Info :: struct { size: win.UINT, hwnd: win.HWND, flags: win.DWORD, count: win.UINT, timeout: win.DWORD }

foreign import user32_taskbar "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32_taskbar {
	FlashWindowEx :: proc(info: ^Flash_Window_Info) -> win.BOOL ---
}

// The window hears TaskbarButtonCreated (open_window), even in a process run as administrator.
@(private)
taskbar_listen :: proc(w: ^Window) {
	ChangeWindowMessageFilterEx(w.hwnd, taskbar_button_message(), MSGFLT_ALLOW, nil)
}

@(private = "file")
taskbar_button_message :: proc() -> u32 {
	msg := sync.atomic_load(&taskbar_button_msg)
	if msg == 0 {
		msg = win.RegisterWindowMessageW(win.L("TaskbarButtonCreated"))
		sync.atomic_store(&taskbar_button_msg, msg)
	}
	return msg
}

// The window procedure's: true for TaskbarButtonCreated.
@(private)
taskbar_window_message :: proc(w: ^Window, msg: u32) -> bool {
	created := sync.atomic_load(&taskbar_button_msg)
	if created == 0 || msg != created { return false }
	taskbar_button_created(w)
	return true
}

// The button exists (again, after Explorer restarted): a new list, given the whole state.
@(private = "file")
taskbar_button_created :: proc(w: ^Window) {
	taskbar_list_release(w)
	if !w.taskbar_com {
		// (S_OK and S_FALSE are each balanced at the end; a thread already in the multithreaded apartment stays there)
		w.taskbar_com = win.CoInitializeEx(nil, .APARTMENTTHREADED) >= 0
	}
	list: ^win.ITaskbarList3
	if win.CoCreateInstance(win.CLSID_TaskbarList, nil, win.CLSCTX_INPROC_SERVER, win.IID_ITaskbarList3, cast(^rawptr)&list) < 0 || list == nil { return }
	if list->HrInit() < 0 { list->Release(); return }
	w.taskbar_list = list
	taskbar_apply(w, {.Progress, .Badge, .Attention})
}

@(private = "file")
taskbar_list_release :: proc(w: ^Window) {
	if w.taskbar_list != nil { w.taskbar_list->Release() }
	w.taskbar_list = nil
}

@(private)
taskbar_apply :: proc(w: ^Window, parts: Taskbar_Parts) {
	if w.offscreen || w.hwnd == nil { return }
	s := w.taskbar
	if .Attention in parts {
		info := Flash_Window_Info{size = size_of(Flash_Window_Info), hwnd = w.hwnd, flags = FLASHW_STOP}
		if s.attention {
			info.flags = FLASHW_TRAY | (s.flashes == 0 ? FLASHW_TIMERNOFG : 0)
			info.count = win.UINT(s.flashes)
		}
		FlashWindowEx(&info)
	}
	list := w.taskbar_list
	if list == nil { return }   // (TaskbarButtonCreated applies it)
	if .Progress in parts {
		switch s.progress {
		case .None:          list->SetProgressState(w.hwnd, .NOPROGRESS)
		case .Indeterminate: list->SetProgressState(w.hwnd, .INDETERMINATE)
		case .Normal, .Paused, .Error:
			// (the value first: it turns an empty or indeterminate bar into a normal one, which the state then colours)
			list->SetProgressValue(w.hwnd, u64(s.done), TASKBAR_STEPS)
			list->SetProgressState(w.hwnd, s.progress == .Paused ? .PAUSED : s.progress == .Error ? .ERROR : .NORMAL)
		}
	}
	if .Badge in parts {
		old := w.taskbar_icon
		w.taskbar_icon = nil
		if s.count > 0 {
			size := taskbar_badge_size(w)
			w.taskbar_icon = icon_from_rgba(taskbar_badge_pixels(s.count, size, s.accent, context.temp_allocator), {size, size})
		}
		words := taskbar_badge_words(s)
		list->SetOverlayIcon(w.hwnd, w.taskbar_icon, words != "" ? win.utf8_to_wstring(words, context.temp_allocator) : nil)
		if old != nil { win.DestroyIcon(old) }   // (the taskbar keeps its own copy)
	}
}

// The overlay's size in pixels: the small icon's at the window's dpi.
@(private = "file")
taskbar_badge_size :: proc(w: ^Window) -> int {
	if px := win.GetSystemMetricsForDpi(SM_CXSMICON, win.GetDpiForWindow(w.hwnd)); px > 0 { return int(px) }
	return int(math.round(SMALL_ICON_PX * max(w.dpi_scale, 1)))
}

@(private)
taskbar_detach :: proc(w: ^Window) {
	taskbar_list_release(w)
	if w.taskbar_icon != nil { win.DestroyIcon(w.taskbar_icon); w.taskbar_icon = nil }
	if w.taskbar_com { win.CoUninitialize(); w.taskbar_com = false }
}

// Sends the window TaskbarButtonCreated, as Explorer does when its button appears or when Explorer restarts: tests.
taskbar_inject_button_created :: proc(w: ^Window) {
	if w == nil || w.hwnd == nil { return }
	win.SendMessageW(w.hwnd, taskbar_button_message(), 0, 0)
}

// Whether the window has its taskbar list: Explorer said its button exists. Tests.
taskbar_button_known :: proc(w: ^Window) -> bool { return w != nil && w.taskbar_list != nil }

// Whether the button shows the count's picture. Tests.
taskbar_overlay_shown :: proc(w: ^Window) -> bool { return w != nil && w.taskbar_icon != nil }
