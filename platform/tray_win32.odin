#+build windows
package platform

import "core:unicode/utf16"
import win "core:sys/windows"

// The icons of the notification area on Windows: Shell_NotifyIconW, version 4 (NOTIFYICON_VERSION_4: the anchor
// position in wParam, NIN_SELECT / NIN_KEYSELECT, WM_CONTEXTMENU, the notification events). The window given to
// tray_create receives the notifications (TRAY_MESSAGE) and TaskbarCreated (the shell restarted: the icons are added
// again). No NIF_GUID: a GUID ties the icon to the exe's path for good (an exe moved or copied fails to add it), the id
// per window is enough.

Native_Tray :: struct {
	icon:       win.HICON,
	icon_large: win.HICON,   // the notification's icon (Tray_Notify_Icon.App)
}

@(private) TRAY_MESSAGE :: win.WM_APP + 0x3A1
@(private) NOTIFYICON_VERSION_4 :: 4
@(private) NIN_SELECT :: 0x0400
@(private) NIN_KEYSELECT :: 0x0401
@(private) NIN_BALLOONSHOW :: 0x0402
@(private) NIN_BALLOONHIDE :: 0x0403
@(private) NIN_BALLOONTIMEOUT :: 0x0404
@(private) NIN_BALLOONUSERCLICK :: 0x0405
@(private) NIN_POPUPOPEN :: 0x0406
@(private) NIN_POPUPCLOSE :: 0x0407

@(private) taskbar_created_msg: u32
@(private) tray_next_id: u32

foreign import user32_tray "system:User32.lib"
@(default_calling_convention = "system", private)
foreign user32_tray {
	ChangeWindowMessageFilterEx :: proc(hwnd: win.HWND, message: win.UINT, action: win.DWORD, info: rawptr) -> win.BOOL ---
	CopyIcon :: proc(icon: win.HICON) -> win.HICON ---
}

// What a notification of the icon (the low word of lParam, version 4) is to the app. Pure.
tray_event_from_notify :: proc(code: u32) -> (kind: Tray_Event_Kind, keyboard: bool) {
	switch code {
	case NIN_SELECT:           return .Click, false
	case NIN_KEYSELECT:        return .Click, true
	case win.WM_LBUTTONDBLCLK: return .Double_Click, false
	case win.WM_CONTEXTMENU:   return .Right_Click, false
	case win.WM_MBUTTONUP:     return .Middle_Click, false
	case NIN_BALLOONSHOW:      return .Notify_Shown, false
	case NIN_BALLOONHIDE:      return .Notify_Hidden, false
	case NIN_BALLOONTIMEOUT:   return .Notify_Timeout, false
	case NIN_BALLOONUSERCLICK: return .Notify_Click, false
	case NIN_POPUPOPEN:        return .Hover_Open, false
	case NIN_POPUPCLOSE:       return .Hover_Close, false
	}
	return .None, false   // (the raw mouse messages that come with them: WM_LBUTTONDOWN / UP, WM_MOUSEMOVE...)
}

// Adds an icon to the notification area for `w` (which may stay hidden). `icon_png`: a PNG file's bytes (nil: the
// exe's icon). nil when the system refused it.
tray_create :: proc(w: ^Window, icon_png: []u8 = nil, tooltip := "") -> ^Tray {
	if w == nil || w.hwnd == nil { return nil }
	if taskbar_created_msg == 0 {
		taskbar_created_msg = win.RegisterWindowMessageW(win.L("TaskbarCreated"))
	}
	// an elevated process still hears the shell's restart
	ChangeWindowMessageFilterEx(w.hwnd, taskbar_created_msg, 1, nil)   // MSGFLT_ALLOW
	tray_next_id += 1
	t := new(Tray)
	t.window = w
	t.id = tray_next_id
	t.auto_menu = true
	t.tooltip = clone_string(tooltip)
	if !tray_load_icon(t, icon_png) || !tray_add(t) {
		tray_icons_free(t)
		tray_free(t)
		return nil
	}
	append(&w.trays, t)
	return t
}

// Removes the icon and frees the tray.
tray_destroy :: proc(t: ^Tray) {
	if t == nil { return }
	if t.added { tray_shell(.Delete, t) }
	if w := t.window; w != nil {
		for x, i in w.trays { if x == t { unordered_remove(&w.trays, i); break } }
	}
	tray_icons_free(t)
	tray_free(t)
}

// Another icon from a PNG file's bytes (nil: the exe's icon).
tray_set_icon :: proc(t: ^Tray, icon_png: []u8) -> bool {
	if t == nil { return false }
	old, old_large := t.icon, t.icon_large
	if !tray_load_icon(t, icon_png) { return false }
	ok := tray_shell(.Modify, t)
	destroy_icon(old)
	destroy_icon(old_large)
	return ok
}

// Another icon from straight RGBA pixels (size x size; the system scales it to the small icon size).
tray_set_icon_rgba :: proc(t: ^Tray, rgba: []u8, size: [2]int) -> bool {
	if t == nil { return false }
	icon := icon_from_rgba(rgba, size)
	if icon == nil { return false }
	old, old_large := t.icon, t.icon_large
	t.icon, t.icon_large = icon, nil
	ok := tray_shell(.Modify, t)
	destroy_icon(old)
	destroy_icon(old_large)
	return ok
}

// The tooltip (127 UTF-16 units at most: longer text is cut at a character's boundary).
tray_set_tooltip :: proc(t: ^Tray, text: string) -> bool {
	if t == nil { return false }
	delete(t.tooltip)
	t.tooltip = clone_string(text)
	return tray_shell(.Modify, t)
}

// Shows a notification from the icon (title: 63 UTF-16 units, body: 255; cut beyond). Its events come as Notify_*.
tray_notify :: proc(t: ^Tray, n: Tray_Notify) -> bool {
	if t == nil { return false }
	if tray_test_hook != nil { return tray_test_hook(.Notify, t) }
	nid := tray_nid(t)
	nid.uFlags = win.NIF_INFO
	utf16_fill(nid.szInfo[:], n.body == "" ? " " : n.body)   // (an empty text removes the notification)
	utf16_fill(nid.szInfoTitle[:], n.title)
	NIIF_INFO :: 0x1; NIIF_WARNING :: 0x2; NIIF_ERROR :: 0x3; NIIF_USER :: 0x4
	NIIF_NOSOUND :: 0x10; NIIF_LARGE_ICON :: 0x20; NIIF_RESPECT_QUIET_TIME :: 0x80
	switch n.icon {
	case .None:
	case .Info:    nid.dwInfoFlags = NIIF_INFO
	case .Warning: nid.dwInfoFlags = NIIF_WARNING
	case .Error:   nid.dwInfoFlags = NIIF_ERROR
	case .App:
		nid.dwInfoFlags = NIIF_USER
		nid.hBalloonIcon = t.icon
		if t.icon_large != nil { nid.hBalloonIcon = t.icon_large; nid.dwInfoFlags |= NIIF_LARGE_ICON }
	}
	if n.silent { nid.dwInfoFlags |= NIIF_NOSOUND }
	if n.respect_quiet_time { nid.dwInfoFlags |= NIIF_RESPECT_QUIET_TIME }
	return bool(win.Shell_NotifyIconW(win.NIM_MODIFY, &nid))
}

// Opens the menu at the pointer and waits for the user's choice: the item's id, ok = false when none was chosen. Call
// it between frames (it runs the system's menu loop; the window keeps drawing through its on_frame).
tray_show_menu :: proc(t: ^Tray) -> (id: int, ok: bool) {
	pt: win.POINT
	win.GetCursorPos(&pt)
	return tray_menu_at(t, {pt.x, pt.y})
}

// Sends the window a notification of the icon as the shell does (a code of version 4: NIN_SELECT, WM_CONTEXTMENU...),
// through the window procedure: tests and remote control.
tray_inject :: proc(t: ^Tray, code: u32, pos: [2]i32 = {}) {
	if t == nil || t.window == nil { return }
	wp := win.WPARAM(uintptr(u32(u16(i16(pos.x))) | u32(u16(i16(pos.y))) << 16))
	lp := win.LPARAM(uintptr(code & 0xFFFF | t.id << 16))
	win.SendMessageW(t.window.hwnd, TRAY_MESSAGE, wp, lp)
}

// Sends the window the shell's "TaskbarCreated" (the shell restarted): tests.
tray_inject_shell_restart :: proc(w: ^Window) {
	if taskbar_created_msg != 0 { win.SendMessageW(w.hwnd, taskbar_created_msg, 0, 0) }
}

////////////////////////////////
// window procedure (platform_win32.odin)

@(private)
tray_window_message :: proc(w: ^Window, msg: u32, wparam: win.WPARAM, lparam: win.LPARAM) -> bool {
	if msg == TRAY_MESSAGE {
		code, id := u32(uintptr(lparam)) & 0xFFFF, (u32(uintptr(lparam)) >> 16) & 0xFFFF
		t: ^Tray
		for x in w.trays { if x.id & 0xFFFF == id { t = x; break } }
		if t == nil { return true }
		kind, keyboard := tray_event_from_notify(code)
		if kind == .None { return true }
		pos := [2]i32{i32(i16(u16(uintptr(wparam) & 0xFFFF))), i32(i16(u16((uintptr(wparam) >> 16) & 0xFFFF)))}
		tray_push(t, {kind = kind, pos = pos, keyboard = keyboard})
		if kind == .Right_Click && t.auto_menu && len(t.menu) > 0 {
			if item, chosen := tray_menu_at(t, pos); chosen { tray_push(t, {kind = .Menu_Item, item = item, pos = pos}) }
		}
		return true
	}
	if taskbar_created_msg != 0 && msg == taskbar_created_msg {
		for t in w.trays {
			t.added = false
			if tray_add(t) { tray_push(t, {kind = .Recreated}) }
		}
		return true
	}
	return false
}

@(private)
tray_destroy_all :: proc(w: ^Window) {
	for len(w.trays) > 0 { tray_destroy(w.trays[len(w.trays) - 1]) }
	delete(w.trays)
	w.trays = nil
}

////////////////////////////////
// internals

@(private = "file")
tray_nid :: proc(t: ^Tray) -> win.NOTIFYICONDATAW {
	return {cbSize = size_of(win.NOTIFYICONDATAW), hWnd = t.window.hwnd, uID = t.id}
}

@(private = "file")
tray_add :: proc(t: ^Tray) -> bool {
	if !tray_shell(.Add, t) { return false }
	t.added = true
	tray_shell(.Set_Version, t)
	return true
}

@(private = "file")
tray_shell :: proc(op: Tray_Op, t: ^Tray) -> bool {
	if tray_test_hook != nil { return tray_test_hook(op, t) }
	nid := tray_nid(t)
	NIF_SHOWTIP :: 0x80
	switch op {
	case .Add, .Modify:
		nid.uFlags = win.NIF_MESSAGE | win.NIF_ICON | win.NIF_TIP | NIF_SHOWTIP
		nid.uCallbackMessage = TRAY_MESSAGE
		nid.hIcon = t.icon
		utf16_fill(nid.szTip[:], t.tooltip)
		return bool(win.Shell_NotifyIconW(op == .Add ? win.NIM_ADD : win.NIM_MODIFY, &nid))
	case .Set_Version:
		nid.uVersion = NOTIFYICON_VERSION_4
		return bool(win.Shell_NotifyIconW(win.NIM_SETVERSION, &nid))
	case .Delete:
		return bool(win.Shell_NotifyIconW(win.NIM_DELETE, &nid))
	case .Notify:
	}
	return false
}

// The icons at the small and large icon sizes of the window's DPI, from a PNG or the exe's icon.
@(private = "file")
tray_load_icon :: proc(t: ^Tray, png: []u8) -> bool {
	dpi := win.GetDpiForWindow(t.window.hwnd)
	if dpi == 0 { dpi = 96 }
	small := win.GetSystemMetricsForDpi(win.SM_CXSMICON, dpi)
	large := win.GetSystemMetricsForDpi(win.SM_CXICON, dpi)
	load :: proc(png: []u8, size: i32) -> win.HICON {
		if len(png) > 0 {
			return win.CreateIconFromResourceEx((^win.BYTE)(&png[0]), u32(len(png)), true, 0x00030000, size, size, win.LR_DEFAULTCOLOR)
		}
		instance := win.HINSTANCE(win.GetModuleHandleW(nil))
		if h := win.HICON(win.LoadImageW(instance, transmute(win.LPCWSTR)uintptr(1), win.IMAGE_ICON, size, size, win.LR_DEFAULTCOLOR)); h != nil { return h }
		// an exe without an icon: the system's application icon (a copy: shared icons are not ours to destroy)
		return CopyIcon(win.LoadIconW(nil, transmute(win.LPCWSTR)uintptr(32512)))   // IDI_APPLICATION
	}
	icon := load(png, small)
	if icon == nil { return false }
	t.icon = icon
	t.icon_large = load(png, large)
	return true
}

@(private = "file")
tray_icons_free :: proc(t: ^Tray) {
	destroy_icon(t.icon)
	destroy_icon(t.icon_large)
	t.icon, t.icon_large = nil, nil
}

@(private = "file")
destroy_icon :: proc(h: win.HICON) { if h != nil { win.DestroyIcon(h) } }

// An icon from straight RGBA pixels: a 32-bit colour bitmap (BGRA) and an empty mask (the alpha is the shape).
@(private)
icon_from_rgba :: proc(rgba: []u8, size: [2]int) -> win.HICON {
	if size.x <= 0 || size.y <= 0 || len(rgba) < size.x * size.y * 4 { return nil }
	bmi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(size.x), biHeight = -i32(size.y), biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	bits: rawptr
	color := win.CreateDIBSection(nil, &bmi, win.DIB_RGB_COLORS, &bits, nil, 0)
	if color == nil { return nil }
	defer win.DeleteObject(win.HGDIOBJ(color))
	dst := ([^]u8)(bits)[:size.x * size.y * 4]
	for i := 0; i < len(dst); i += 4 { dst[i], dst[i + 1], dst[i + 2], dst[i + 3] = rgba[i + 2], rgba[i + 1], rgba[i], rgba[i + 3] }
	mask := win.CreateBitmap(i32(size.x), i32(size.y), 1, 1, nil)
	if mask == nil { return nil }
	defer win.DeleteObject(win.HGDIOBJ(mask))
	info := win.ICONINFO{fIcon = true, hbmMask = mask, hbmColor = color}
	return win.CreateIconIndirect(&info)
}

// The menu at `pos` (screen pixels): built from the tray's items, run, destroyed.
@(private = "file")
tray_menu_at :: proc(t: ^Tray, pos: [2]i32) -> (id: int, ok: bool) {
	if t == nil || len(t.menu) == 0 { return 0, false }
	ids := make([dynamic]int, context.temp_allocator)
	menu := build_menu(t.menu[:], &ids)
	if menu == nil { return 0, false }
	defer win.DestroyMenu(menu)
	hwnd := t.window.hwnd
	// (the menu closes when the user clicks elsewhere only if the window is in front; the null message after it is the
	// documented way to make the next click work)
	win.SetForegroundWindow(hwnd)
	TPM_NONOTIFY :: 0x0080
	cmd := win.TrackPopupMenu(menu, win.TPM_RETURNCMD | TPM_NONOTIFY | win.TPM_RIGHTBUTTON, pos.x, pos.y, 0, hwnd, nil)
	win.PostMessageW(hwnd, win.WM_NULL, 0, 0)
	if cmd <= 0 || int(cmd) > len(ids) { return 0, false }
	return ids[cmd - 1], true
}

@(private = "file")
build_menu :: proc(items: []Tray_Menu_Item, ids: ^[dynamic]int) -> win.HMENU {
	menu := win.CreatePopupMenu()
	if menu == nil { return nil }
	MFT_RADIOCHECK :: 0x200
	MF_DEFAULT :: 0x1000
	for it in items {
		text := win.utf8_to_wstring(it.text, context.temp_allocator)
		flags: u32 = it.disabled ? win.MF_GRAYED : win.MF_ENABLED
		if len(it.children) > 0 {
			sub := build_menu(it.children, ids)
			if sub == nil { continue }
			win.AppendMenuW(menu, flags | win.MF_POPUP | win.MF_STRING, uintptr(sub), text)
			continue
		}
		switch it.kind {
		case .Separator:
			win.AppendMenuW(menu, win.MF_SEPARATOR, 0, nil)
			continue
		case .Check:
			if it.checked { flags |= win.MF_CHECKED }
		case .Radio:
			flags |= MFT_RADIOCHECK
			if it.checked { flags |= win.MF_CHECKED }
		case .Item:
		}
		if it.default { flags |= MF_DEFAULT }
		append(ids, it.id)
		win.AppendMenuW(menu, flags | win.MF_STRING, uintptr(len(ids)), text)
	}
	return menu
}

// Copies `s` into a fixed UTF-16 buffer with its terminating zero, cut at a character's boundary when too long.
@(private)
utf16_fill :: proc(dst: []u16, s: string) {
	if len(dst) == 0 { return }
	n := 0
	for r in s {
		buf: [2]u16
		k := utf16.encode(buf[:], []rune{r})
		if n + k > len(dst) - 1 { break }
		for j in 0 ..< k { dst[n + j] = buf[j] }
		n += k
	}
	dst[n] = 0
}
