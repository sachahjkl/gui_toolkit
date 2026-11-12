package platform

// Notifications on Windows (notify.odin has the API): toast notifications through the Windows Runtime (package winrt,
// no projection), Windows 10 and later; on an older Windows notify_supported is false and notify does nothing.
//
//   * A program that is not packaged shows toasts under an AppUserModelID registered for the user:
//     HKCU\Software\Classes\AppUserModelId\<id> with DisplayName and IconUri (notify_set_app; written at a window's
//     first notification). ToastNotificationManager.CreateToastNotifierWithId(id) gives the notifier.
//   * A toast is toast_xml's document (ToastGeneric), its Tag the notification's id and its Group "gt": a toast with the
//     same Tag and Group replaces the earlier one in place (Notification.replace).
//   * The toast's Activated, Dismissed and Failed events come on a thread of the system's. Their handlers queue what
//     happened on the window's Notify_Sink and post NOTIFY_MESSAGE; the window procedure makes the events on the
//     window's thread. The sink is counted (the window and each handler hold it): a handler the system still runs after
//     the window went finds no window and drops what it heard.
//   * A toast that left the screen by itself (Dismissed, TimedOut) is still in the notification centre, where a click
//     still comes (while the program runs): no event for it. A click or a button ends the notification: its event, then
//     Notification_Closed (Dismissed). A click once the program has ended starts nothing (no COM activator).

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:sync"
import "core:time"
import win "core:sys/windows"
import winrt "../winrt"

@(private) NOTIFY_MESSAGE :: win.WM_APP + 0x3A3
@(private = "file") TOAST_GROUP :: "gt"
@(private = "file") FIRST_TOAST_BUILD :: 10240   // Windows 10: the ToastGeneric template and its buttons

// (windows.ui.notifications.h, windows.data.xml.dom.h)
@(private = "file") IID_IToastNotificationManagerStatics :: winrt.GUID{0x50ac103f, 0xd235, 0x4598, {0xbb, 0xef, 0x98, 0xfe, 0x4d, 0x1a, 0x3a, 0xd4}}
@(private = "file") IID_IToastNotificationFactory :: winrt.GUID{0x04124b20, 0x82c6, 0x4229, {0xb1, 0x09, 0xfd, 0x9e, 0xd4, 0x66, 0x2b, 0x53}}
@(private = "file") IID_IToastNotification :: winrt.GUID{0x997e2675, 0x059e, 0x4e60, {0x8b, 0x06, 0x17, 0x60, 0x91, 0x7c, 0x8b, 0x80}}
@(private = "file") IID_IToastNotification2 :: winrt.GUID{0x9dfb9fd1, 0x143a, 0x490e, {0x90, 0xbf, 0xb9, 0xfb, 0xa7, 0x13, 0x2d, 0xe7}}
@(private = "file") IID_IToastActivatedEventArgs :: winrt.GUID{0xe3bf92f3, 0xc197, 0x436f, {0x82, 0x65, 0x06, 0x25, 0x82, 0x4f, 0x8d, 0xac}}
@(private = "file") IID_IToastDismissedEventArgs :: winrt.GUID{0x3f89d935, 0xd9cb, 0x4538, {0xa0, 0xf0, 0xff, 0xe7, 0x65, 0x99, 0x38, 0xf8}}
@(private = "file") IID_IToastFailedEventArgs :: winrt.GUID{0x35176862, 0xcfd4, 0x44f8, {0xad, 0x64, 0xf5, 0x00, 0xfd, 0x89, 0x6c, 0x3b}}
@(private = "file") IID_IXmlDocument :: winrt.GUID{0xf7f3a506, 0x1e87, 0x42d6, {0xbc, 0xfb, 0xb8, 0xc8, 0x09, 0xfa, 0x54, 0x94}}
@(private = "file") IID_IXmlDocumentIO :: winrt.GUID{0x6cd0e74e, 0xee65, 0x4489, {0x9e, 0xbf, 0xca, 0x43, 0xe8, 0x7b, 0xa6, 0x37}}

@(private = "file")
IToastNotificationManagerStatics_Vtbl :: struct {
	using base:                winrt.IInspectable_Vtbl,
	CreateToastNotifier:       rawptr,
	CreateToastNotifierWithId: proc "system" (this: rawptr, id: winrt.HSTRING, notifier: ^rawptr) -> winrt.HRESULT,
	GetTemplateContent:        rawptr,
}

@(private = "file")
IToastNotifier_Vtbl :: struct {
	using base: winrt.IInspectable_Vtbl,
	Show:       proc "system" (this: rawptr, toast: rawptr) -> winrt.HRESULT,
	Hide:       proc "system" (this: rawptr, toast: rawptr) -> winrt.HRESULT,
	get_Setting: rawptr,
	AddToSchedule: rawptr,
	RemoveFromSchedule: rawptr,
	GetScheduledToastNotifications: rawptr,
}

@(private = "file")
IToastNotificationFactory_Vtbl :: struct {
	using base:              winrt.IInspectable_Vtbl,
	CreateToastNotification: proc "system" (this: rawptr, content: rawptr, toast: ^rawptr) -> winrt.HRESULT,
}

// An event's registration (EventRegistrationToken).
@(private = "file") Event_Token :: i64

@(private = "file")
IToastNotification_Vtbl :: struct {
	using base:         winrt.IInspectable_Vtbl,
	get_Content:        rawptr,
	put_ExpirationTime: rawptr,
	get_ExpirationTime: rawptr,
	add_Dismissed:      proc "system" (this: rawptr, handler: rawptr, token: ^Event_Token) -> winrt.HRESULT,
	remove_Dismissed:   proc "system" (this: rawptr, token: Event_Token) -> winrt.HRESULT,
	add_Activated:      proc "system" (this: rawptr, handler: rawptr, token: ^Event_Token) -> winrt.HRESULT,
	remove_Activated:   proc "system" (this: rawptr, token: Event_Token) -> winrt.HRESULT,
	add_Failed:         proc "system" (this: rawptr, handler: rawptr, token: ^Event_Token) -> winrt.HRESULT,
	remove_Failed:      proc "system" (this: rawptr, token: Event_Token) -> winrt.HRESULT,
}

@(private = "file")
IToastNotification2_Vtbl :: struct {
	using base:        winrt.IInspectable_Vtbl,
	put_Tag:           proc "system" (this: rawptr, value: winrt.HSTRING) -> winrt.HRESULT,
	get_Tag:           rawptr,
	put_Group:         proc "system" (this: rawptr, value: winrt.HSTRING) -> winrt.HRESULT,
	get_Group:         rawptr,
	put_SuppressPopup: proc "system" (this: rawptr, value: bool) -> winrt.HRESULT,
	get_SuppressPopup: rawptr,
}

@(private = "file")
IToastActivatedEventArgs_Vtbl :: struct {
	using base:    winrt.IInspectable_Vtbl,
	get_Arguments: proc "system" (this: rawptr, value: ^winrt.HSTRING) -> winrt.HRESULT,
}

@(private = "file")
IToastDismissedEventArgs_Vtbl :: struct {
	using base: winrt.IInspectable_Vtbl,
	get_Reason: proc "system" (this: rawptr, value: ^i32) -> winrt.HRESULT,
}

@(private = "file")
IXmlDocumentIO_Vtbl :: struct {
	using base:          winrt.IInspectable_Vtbl,
	LoadXml:             proc "system" (this: rawptr, xml: winrt.HSTRING) -> winrt.HRESULT,
	LoadXmlWithSettings: rawptr,
	SaveToFileAsync:     rawptr,
}

// ToastDismissalReason
@(private = "file") DISMISSED_USER_CANCELED :: 0
@(private = "file") DISMISSED_APPLICATION_HIDDEN :: 1

foreign import shell32_notify "system:Shell32.lib"
@(default_calling_convention = "system", private = "file")
foreign shell32_notify {
	SetCurrentProcessExplicitAppUserModelID :: proc(app_id: cstring16) -> win.HRESULT ---
	GetCurrentProcessExplicitAppUserModelID :: proc(app_id: ^cstring16) -> win.HRESULT ---
}

foreign import ole32_notify "system:Ole32.lib"
@(default_calling_convention = "system", private = "file")
foreign ole32_notify {
	CoTaskMemFree :: proc(p: rawptr) ---
}

// What the toasts' handlers heard, for the window's thread (locked: mutex). Counted (atomic): the window holds one
// reference, each handler one; freed with the last.
@(private)
Notify_Sink :: struct {
	refs:  i32,
	mutex: sync.Mutex,
	hwnd:  win.HWND,             // nil once the window went
	queue: [dynamic]Toast_Heard,
}

@(private)
Toast_Heard :: struct {
	toast:  uintptr,       // the toast's identity (its IUnknown)
	kind:   Event_Kind,
	action: int,
	reason: Notification_Reason,
}

@(private)
Toast_Record :: struct {
	id:     Notification_Id,
	toast:  rawptr,           // IToastNotification
	key:    uintptr,          // its identity
	tokens: [3]Event_Token,   // Activated, Dismissed, Failed
}

// The toasts a window showed and what shows them (Window.notify). Made at the window's first notification.
Notify_State :: struct {
	tried:    bool,
	joined:   bool,       // the window's thread joined an apartment for it (left at the window's end)
	notifier: rawptr,     // IToastNotifier (nil: no toasts)
	factory:  rawptr,     // IToastNotificationFactory
	sink:     ^Notify_Sink,
	handlers: [3]^winrt.Event_Handler,   // Activated, Dismissed, Failed
	records:  [dynamic]Toast_Record,
	next_id:  u32,
}

@(private)
notify_app_declared :: proc() {
	if notify_app.aumid == "" { return }
	current: cstring16
	if GetCurrentProcessExplicitAppUserModelID(&current) >= 0 && current != nil {
		CoTaskMemFree(rawptr(current))
		return
	}
	SetCurrentProcessExplicitAppUserModelID(win.utf8_to_wstring(notify_app.aumid))
}

notify_supported :: proc() -> bool {
	if windows_build() < FIRST_TOAST_BUILD { return false }
	hr := winrt.init(.Single)
	defer if winrt.ok(hr) { winrt.uninit() }
	statics, got := winrt.factory("Windows.UI.Notifications.ToastNotificationManager", IID_IToastNotificationManagerStatics)
	winrt.release(statics)
	return winrt.ok(got)
}

// The AppUserModelID the toasts are shown under: notify_set_app's, else the process's, else the executable's name.
@(private = "file")
notify_aumid :: proc() -> string {
	if notify_app.aumid != "" { return notify_app.aumid }
	current: cstring16
	if GetCurrentProcessExplicitAppUserModelID(&current) >= 0 && current != nil {
		s, _ := win.wstring_to_utf8(win.wstring(current), -1, context.temp_allocator)
		CoTaskMemFree(rawptr(current))
		if s != "" { return s }
	}
	return exe_stem()
}

@(private = "file")
exe_stem :: proc() -> string {
	buf: [win.MAX_PATH_WIDE]u16
	n := win.GetModuleFileNameW(nil, &buf[0], u32(len(buf)))
	path, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	start := 0
	for i in 0 ..< len(path) { if path[i] == '\\' || path[i] == '/' { start = i + 1 } }
	stem := path[start:]
	for i := len(stem) - 1; i > 0; i -= 1 { if stem[i] == '.' { stem = stem[:i]; break } }
	return stem != "" ? stem : "gui_toolkit"
}

// HKCU\Software\Classes\AppUserModelId\<aumid>: the name and the icon the notification centre shows for the id.
@(private = "file")
register_aumid :: proc(aumid: string) {
	key: win.HKEY
	sub := win.utf8_to_wstring(fmt.tprintf(`Software\Classes\AppUserModelId\%s`, aumid))
	if win.RegCreateKeyExW(win.HKEY_CURRENT_USER, sub, 0, nil, 0, win.KEY_WRITE, nil, &key, nil) != 0 { return }
	defer win.RegCloseKey(key)
	set :: proc(key: win.HKEY, name, value: string) {
		v := win.utf8_to_utf16(value, context.temp_allocator)
		data := make([]u16, len(v) + 1, context.temp_allocator)
		copy(data, v)
		win.RegSetValueExW(key, win.utf8_to_wstring(name), 0, win.REG_SZ, (^win.BYTE)(raw_data(data)), u32(len(data) * 2))
	}
	set(key, "DisplayName", notify_app.name != "" ? notify_app.name : exe_stem())
	if notify_app.icon_path != "" { set(key, "IconUri", notify_app.icon_path) }
}

// The window's notifier, made at its first notification: false when the system has no toasts.
@(private = "file")
notify_open :: proc(w: ^Window) -> bool {
	s := &w.notify
	if s.tried { return s.notifier != nil }
	s.tried = true
	if w.hwnd == nil { return false }   // (an offscreen window has no queue the handlers could post to)
	if windows_build() < FIRST_TOAST_BUILD { return false }
	hr := winrt.init(.Single)
	s.joined = winrt.ok(hr)
	if !s.joined && hr != winrt.RPC_E_CHANGED_MODE { return false }   // (a thread of the other kind: its apartment does)
	aumid := notify_aumid()
	register_aumid(aumid)
	statics, got := winrt.factory("Windows.UI.Notifications.ToastNotificationManager", IID_IToastNotificationManagerStatics)
	if !winrt.ok(got) { return false }
	defer winrt.release(statics)
	haumid := winrt.string_make(aumid)
	defer winrt.string_delete(haumid)
	notifier: rawptr
	if !winrt.ok(winrt.vtable(statics, IToastNotificationManagerStatics_Vtbl).CreateToastNotifierWithId(statics, haumid, &notifier)) { return false }
	factory, fgot := winrt.factory("Windows.UI.Notifications.ToastNotification", IID_IToastNotificationFactory)
	if !winrt.ok(fgot) { winrt.release(notifier); return false }
	s.notifier, s.factory = notifier, factory
	sink := new(Notify_Sink, runtime.heap_allocator())
	sink.refs = 1 + len(s.handlers)
	sink.hwnd = w.hwnd
	sink.queue = make([dynamic]Toast_Heard, runtime.heap_allocator())
	s.sink = sink
	toast_sig := winrt.sig_class("Windows.UI.Notifications.ToastNotification", IID_IToastNotification)
	s.handlers[0] = winrt.event_handler_make(winrt.typed_event_handler_iid(toast_sig, winrt.SIG_INSPECTABLE), toast_activated, sink, sink_done)
	s.handlers[1] = winrt.event_handler_make(winrt.typed_event_handler_iid(toast_sig,
		winrt.sig_class("Windows.UI.Notifications.ToastDismissedEventArgs", IID_IToastDismissedEventArgs)), toast_dismissed, sink, sink_done)
	s.handlers[2] = winrt.event_handler_make(winrt.typed_event_handler_iid(toast_sig,
		winrt.sig_class("Windows.UI.Notifications.ToastFailedEventArgs", IID_IToastFailedEventArgs)), toast_failed, sink, sink_done)
	return true
}

// notify_linux.odin's notify_async: Windows shows a toast at once, so `done` runs before it returns.
notify_async :: proc(w: ^Window, n: Notification, done: Notify_Done = nil, user: rawptr = nil) -> bool {
	id, ok := notify(w, n)
	if done != nil { done(user, id, ok) }
	return true
}

notify :: proc(w: ^Window, n: Notification) -> (id: Notification_Id, ok: bool) {
	if w == nil || !notify_open(w) { return 0, false }
	s := &w.notify
	xml := toast_xml(n, notify_icon_uri(n.icon_png))
	doc, dgot := winrt.activate("Windows.Data.Xml.Dom.XmlDocument")
	if !winrt.ok(dgot) { return 0, false }
	defer winrt.release(doc)
	io := winrt.query(doc, IID_IXmlDocumentIO)
	if io == nil { return 0, false }
	hxml := winrt.string_make(xml)
	loaded := winrt.vtable(io, IXmlDocumentIO_Vtbl).LoadXml(io, hxml)
	winrt.string_delete(hxml)
	winrt.release(io)
	if !winrt.ok(loaded) { return 0, false }
	content := winrt.query(doc, IID_IXmlDocument)
	if content == nil { return 0, false }
	defer winrt.release(content)
	toast: rawptr
	if !winrt.ok(winrt.vtable(s.factory, IToastNotificationFactory_Vtbl).CreateToastNotification(s.factory, content, &toast)) { return 0, false }

	id = n.replace
	if id == 0 || toast_find(w, id) < 0 {
		s.next_id += 1
		id = Notification_Id(s.next_id)
	}
	if t2 := winrt.query(toast, IID_IToastNotification2); t2 != nil {
		v := winrt.vtable(t2, IToastNotification2_Vtbl)
		tag := winrt.string_make(fmt.tprintf("%d", id))
		group := winrt.string_make(TOAST_GROUP)
		v.put_Tag(t2, tag)
		v.put_Group(t2, group)
		if n.urgency == .Low { v.put_SuppressPopup(t2, true) }
		winrt.string_delete(tag)
		winrt.string_delete(group)
		winrt.release(t2)
	}
	rec := Toast_Record{id = id, toast = toast, key = identity_of(toast)}
	tv := winrt.vtable(toast, IToastNotification_Vtbl)
	tv.add_Activated(toast, s.handlers[0], &rec.tokens[0])
	tv.add_Dismissed(toast, s.handlers[1], &rec.tokens[1])
	tv.add_Failed(toast, s.handlers[2], &rec.tokens[2])
	// (the toast it replaces: its Tag is this one's, the system swaps them; its events end here)
	if i := toast_find(w, id); i >= 0 { toast_drop(w, i) }
	if !winrt.ok(winrt.vtable(s.notifier, IToastNotifier_Vtbl).Show(s.notifier, toast)) {
		toast_release(rec)
		return 0, false
	}
	append(&s.records, rec)
	return id, true
}

// Takes it off the screen and out of the notification centre: Notification_Closed (reason Closed) follows.
notify_close :: proc(w: ^Window, id: Notification_Id) {
	if w == nil || w.notify.notifier == nil { return }
	i := toast_find(w, id)
	if i < 0 { return }
	s := &w.notify
	winrt.vtable(s.notifier, IToastNotifier_Vtbl).Hide(s.notifier, s.records[i].toast)
	toast_drop(w, i)
	append(&w.events, Event{kind = .Notification_Closed, notification = {id = id, reason = .Closed}, stamp = time.tick_now()})
}

// Windows gives no activation token: "".
notify_activation_token :: proc(w: ^Window) -> string { return "" }

// A PNG of the notification as a file a toast can show: %TEMP%\gt_notify\<hash>.png ("" when it cannot be written).
// Named by its content, so that the same picture is one file, kept for the notification centre.
@(private = "file")
notify_icon_uri :: proc(icon_png: []u8) -> string {
	if len(icon_png) == 0 { return "" }
	temp := os.get_env("TEMP", context.temp_allocator)
	if temp == "" { return "" }
	dir := fmt.tprintf(`%s\gt_notify`, temp)
	os.make_directory(dir)
	path := fmt.tprintf(`%s\%016x.png`, dir, hash.fnv64a(icon_png))
	if os.write_entire_file(path, icon_png) != nil { return "" }
	return file_uri_of_path(path)
}

@(private = "file")
identity_of :: proc(object: rawptr) -> uintptr {
	u := winrt.query(object, winrt.IID_IUnknown)
	winrt.release(u)   // (the toast holds it: the pointer stays its identity)
	return uintptr(u)
}

@(private = "file")
toast_find :: proc(w: ^Window, id: Notification_Id) -> int {
	for r, i in w.notify.records { if r.id == id { return i } }
	return -1
}

@(private = "file")
toast_release :: proc(r: Toast_Record) {
	tv := winrt.vtable(r.toast, IToastNotification_Vtbl)
	tv.remove_Activated(r.toast, r.tokens[0])
	tv.remove_Dismissed(r.toast, r.tokens[1])
	tv.remove_Failed(r.toast, r.tokens[2])
	winrt.release(r.toast)
}

@(private = "file")
toast_drop :: proc(w: ^Window, i: int) {
	toast_release(w.notify.records[i])
	ordered_remove(&w.notify.records, i)
}

////////////////////////////////
// The handlers: on a thread of the system's

@(private = "file")
sink_hear :: proc(sink: ^Notify_Sink, sender: rawptr, heard: Toast_Heard) {
	h := heard
	h.toast = identity_of(sender)
	sync.mutex_lock(&sink.mutex)
	defer sync.mutex_unlock(&sink.mutex)
	if sink.hwnd == nil { return }
	append(&sink.queue, h)
	win.PostMessageW(sink.hwnd, NOTIFY_MESSAGE, 0, 0)
}

@(private = "file")
sink_done :: proc(user: rawptr) { sink_release((^Notify_Sink)(user)) }

@(private = "file")
sink_release :: proc(sink: ^Notify_Sink) {
	if sync.atomic_sub(&sink.refs, 1) - 1 > 0 { return }
	delete(sink.queue)
	free(sink, runtime.heap_allocator())
}

@(private = "file")
toast_activated :: proc(user: rawptr, sender: rawptr, args: rawptr) {
	defer free_all(context.temp_allocator)
	heard := Toast_Heard{kind = .Notification_Click}
	if a := winrt.query(args, IID_IToastActivatedEventArgs); a != nil {
		text: winrt.HSTRING
		if winrt.ok(winrt.vtable(a, IToastActivatedEventArgs_Vtbl).get_Arguments(a, &text)) {
			if kind, action, ok := toast_activation_of(winrt.string_read(text, context.temp_allocator)); ok {
				heard.kind, heard.action = kind, action
			}
			winrt.string_delete(text)
		}
		winrt.release(a)
	}
	sink_hear((^Notify_Sink)(user), sender, heard)
}

@(private = "file")
toast_dismissed :: proc(user: rawptr, sender: rawptr, args: rawptr) {
	reason: i32 = -1
	if a := winrt.query(args, IID_IToastDismissedEventArgs); a != nil {
		winrt.vtable(a, IToastDismissedEventArgs_Vtbl).get_Reason(a, &reason)
		winrt.release(a)
	}
	switch reason {
	case DISMISSED_USER_CANCELED:      sink_hear((^Notify_Sink)(user), sender, {kind = .Notification_Closed, reason = .Dismissed})
	case DISMISSED_APPLICATION_HIDDEN: sink_hear((^Notify_Sink)(user), sender, {kind = .Notification_Closed, reason = .Closed})
	}
	// (TimedOut: it went to the notification centre, where it can still be clicked)
}

@(private = "file")
toast_failed :: proc(user: rawptr, sender: rawptr, args: rawptr) {
	sink_hear((^Notify_Sink)(user), sender, {kind = .Notification_Closed, reason = .Failed})
}

////////////////////////////////
// The window's thread

// NOTIFY_MESSAGE: what the handlers heard becomes the window's events.
@(private)
notify_window_message :: proc(w: ^Window) {
	s := &w.notify
	if s.sink == nil { return }
	sync.mutex_lock(&s.sink.mutex)
	heard := make([]Toast_Heard, len(s.sink.queue), context.temp_allocator)
	copy(heard, s.sink.queue[:])
	clear(&s.sink.queue)
	sync.mutex_unlock(&s.sink.mutex)
	for h in heard {
		i := -1
		for r, j in s.records { if r.key == h.toast { i = j; break } }
		if i < 0 { continue }   // (closed or replaced since)
		id := s.records[i].id
		append(&w.events, Event{kind = h.kind, notification = {id = id, action = h.action, reason = h.reason}, stamp = time.tick_now()})
		if h.kind != .Notification_Closed {
			// a click takes the toast away, from the notification centre too
			append(&w.events, Event{kind = .Notification_Closed, notification = {id = id, reason = .Dismissed}, stamp = time.tick_now()})
		}
		toast_drop(w, i)
	}
}

// The window is going (destroy_window): its toasts stay on the screen, their events go nowhere.
@(private)
notify_detach :: proc(w: ^Window) {
	s := &w.notify
	if s.sink != nil {
		sync.mutex_lock(&s.sink.mutex)
		s.sink.hwnd = nil
		sync.mutex_unlock(&s.sink.mutex)
	}
	for r in s.records { toast_release(r) }
	delete(s.records)
	for h in s.handlers { if h != nil { winrt.release(h) } }
	winrt.release(s.notifier)
	winrt.release(s.factory)
	if s.sink != nil { sink_release(s.sink) }
	if s.joined { winrt.uninit() }
	s^ = {}
}
