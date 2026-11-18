package platform

// Notifications on Windows (notify.odin has the API): toast notifications through the Windows Runtime (package winrt,
// no projection), Windows 10 and later; on an older Windows notify_supported is false and notify does nothing.
//
//   * A program that is not packaged shows toasts under an AppUserModelID registered for the user:
//     HKCU\Software\Classes\AppUserModelId\<id> with DisplayName and IconUri (notify_set_app; written at a window's
//     first notification). ToastNotificationManager.CreateToastNotifierWithId(id) gives the notifier.
//   * A toast is toast_xml's document (ToastGeneric), its Tag the notification's id and its Group "gt": a toast with the
//     same Tag and Group replaces the earlier one in place (Notification.replace).
//   * Every Windows Runtime call of the notifications runs on one thread of the process, the notification thread
//     (Toast_Thread), in the multithreaded apartment: the window's thread makes no system call for a notification, and
//     the notifier, the toasts and their handlers are made, used and released in the one apartment they belong to. The
//     window's thread hands it jobs (Toast_Job: show, hide, drop, detach) and never touches those objects; the thread
//     keeps them in the window's Toast_Host.
//   * The window's thread gives the ids (Notify_State.next_id), so a replace is decided without asking the thread. The
//     answer of a show comes back the way the toasts' events do: queued on the window's Notify_Sink, NOTIFY_MESSAGE
//     posted (an offscreen window's event signalled), and notify_window_message calls `done` on the window's thread.
//     One queue keeps the answer and the events in the order they happened.
//   * The toast's Activated, Dismissed and Failed events come on a thread of the system's. Their handlers find the
//     toast's id in the sink's keys (the toasts on the screen: the notification thread adds one before Show, removes it
//     when it drops the toast) and queue what happened. The window's thread takes a key out when it makes the toast's
//     last event or closes it (notify_close), so no event of a toast comes after its Notification_Closed. The sink is
//     counted (the window, the host and each handler hold it): what is heard after the window went is dropped.
//   * A toast that left the screen by itself (Dismissed, TimedOut) is still in the notification centre, where a click
//     still comes (while the program runs): no event for it. A click or a button ends the notification: its event, then
//     Notification_Closed (Dismissed). A click once the program has ended starts nothing (no COM activator).

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"
import winrt "../winrt"
import base "../base"

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
// (the progress bar's bound data: Windows 10 1607 and later)
@(private = "file") IID_INotificationData :: winrt.GUID{0x9ffd2312, 0x9d6a, 0x4aaf, {0xb6, 0xac, 0xff, 0x17, 0xf0, 0xc1, 0xf2, 0x80}}
@(private = "file") IID_IToastNotification4 :: winrt.GUID{0x15154935, 0x28ea, 0x4727, {0x88, 0xe9, 0xc5, 0x86, 0x80, 0xe2, 0xd1, 0x18}}
@(private = "file") IID_IToastNotifier2 :: winrt.GUID{0x354389c6, 0x7c01, 0x4bd5, {0x9c, 0x20, 0x60, 0x43, 0x40, 0xcd, 0x2b, 0x74}}

@(private = "file")
INotificationData_Vtbl :: struct {
	using base:         winrt.IInspectable_Vtbl,
	get_Values:         proc "system" (this: rawptr, values: ^rawptr) -> winrt.HRESULT,   // IMap<String, String>
	get_SequenceNumber: rawptr,
	put_SequenceNumber: proc "system" (this: rawptr, value: u32) -> winrt.HRESULT,
}

// IMap<String, String> (windows.foundation.h's __FIMap_2_HSTRING_HSTRING)
@(private = "file")
IMap_String_String_Vtbl :: struct {
	using base: winrt.IInspectable_Vtbl,
	Lookup:     rawptr,
	get_Size:   rawptr,
	HasKey:     rawptr,
	GetView:    rawptr,
	Insert:     proc "system" (this: rawptr, key, value: winrt.HSTRING, replaced: ^bool) -> winrt.HRESULT,
	Remove:     rawptr,
	Clear:      rawptr,
}

@(private = "file")
IToastNotification4_Vtbl :: struct {
	using base:   winrt.IInspectable_Vtbl,
	get_Data:     rawptr,
	put_Data:     proc "system" (this: rawptr, data: rawptr) -> winrt.HRESULT,
	get_Priority: rawptr,
	put_Priority: rawptr,
}

@(private = "file")
IToastNotifier2_Vtbl :: struct {
	using base:            winrt.IInspectable_Vtbl,
	UpdateWithTagAndGroup: proc "system" (this: rawptr, data: rawptr, tag, group: winrt.HSTRING, result: ^i32) -> winrt.HRESULT,
	UpdateWithTag:         rawptr,
}

// NotificationUpdateResult
@(private = "file") NOTIFICATION_UPDATE_SUCCEEDED :: 0

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

// What comes back to the window's thread, and the toasts on the screen (locked: mutex). The handlers and the
// notification thread write it, the window's thread reads it. Counted (atomic): the window, its host and each handler
// hold one reference; freed with the last.
@(private)
Notify_Sink :: struct {
	refs:  i32,
	mutex: sync.Mutex,
	gone:  bool,                 // the window went: nothing more is queued
	hwnd:  win.HWND,             // NOTIFY_MESSAGE goes there (nil: an offscreen window)
	wake:  win.HANDLE,           // an offscreen window's event (off_event), signalled in place of the message
	keys:  [dynamic]Toast_Key,   // the toasts that can still have an event
	queue: [dynamic]Toast_Heard,
}

@(private)
Toast_Key :: struct {
	key: uintptr,   // the toast's identity (its IUnknown)
	id:  Notification_Id,
}

// A toast's event (kind a Notification_* one), or the answer of a show (kind None: ok, done, user).
@(private)
Toast_Heard :: struct {
	id:     Notification_Id,
	key:    uintptr,
	kind:   Event_Kind,
	action: int,
	reason: Notification_Reason,
	ok:     bool,
	done:   Notify_Done,
	user:   rawptr,
}

@(private)
Toast_Record :: struct {
	id:       Notification_Id,
	toast:    rawptr,           // IToastNotification
	key:      uintptr,          // its identity
	tokens:   [3]Event_Token,   // Activated, Dismissed, Failed
	shape:    u64,              // notification_shape of what it shows: the same shape updates its bar in place
	bound:    bool,             // its progress bar is bound to data (an update can move it)
	sequence: u32,              // its data's: each update one more (Windows drops an older one that comes late)
}

// What shows a window's toasts: the notification thread's alone (made by the window's thread at its first notification,
// then only read and written by the notification thread, which frees it at the Detach job).
@(private)
Toast_Host :: struct {
	sink:      ^Notify_Sink,
	offscreen: bool,       // no HWND: no toasts (the test hook still answers)
	tried:     bool,
	notifier:  rawptr,     // IToastNotifier (nil: no toasts)
	factory:   rawptr,     // IToastNotificationFactory
	handlers:  [3]^winrt.Event_Handler,   // Activated, Dismissed, Failed
	records:   [dynamic]Toast_Record,
}

// A window's notifications, as its thread sees them (Window.notify): no Windows Runtime object, only the host it hands
// jobs for, the sink it reads, and the next id.
Notify_State :: struct {
	host:    ^Toast_Host,
	sink:    ^Notify_Sink,
	next_id: u32,
}

// Test hook: when set, the notification thread calls it in place of the system to show a toast (no toast is made, so no
// toast's event comes; a hide does nothing), and an offscreen window takes notifications. The result stands for the
// system's answer. It runs on the notification thread.
notify_test_hook: proc(n: Notification, id: Notification_Id) -> bool

// The notification thread: started at the process's first notification, it lives as long as the process (it holds no
// window: each job names its host). Its jobs are a queue, so they run in the order they were given.
@(private = "file")
Toast_Thread :: struct {
	once:   sync.Once,
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	jobs:   [dynamic]Toast_Job,
	thread: ^thread.Thread,
}

@(private = "file") toasts: Toast_Thread

@(private = "file")
Toast_Job_Kind :: enum u8 {
	Show,     // n (owned), id; the answer to `answer` (notify) or to the sink (notify_async)
	Hide,     // id: notify_close
	Drop,     // key: its last event was made, the toast is released
	Detach,   // the window went: everything of the host is released, the host freed
}

@(private = "file")
Toast_Job :: struct {
	kind:   Toast_Job_Kind,
	host:   ^Toast_Host,
	n:      Notification,
	id:     Notification_Id,
	key:    uintptr,
	done:   Notify_Done,
	user:   rawptr,
	answer: ^Toast_Answer,
}

// What notify waits on: the show's result.
@(private = "file")
Toast_Answer :: struct {
	sema: sync.Sema,
	ok:   bool,
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

////////////////////////////////
// The window's thread: ids, jobs, the answers

// notify, without waiting for the system: the notification (copied) goes to the notification thread, `done` runs from
// the window loop once the toast is shown or refused, with the notification's id, or ok false (no toasts on this
// system). `w` must outlive the answer (a program's long-lived window: its anchor, its main window); after
// destroy_window the answer is dropped. False: nothing was sent (no window, or an offscreen one): `done` will not run.
notify_async :: proc(w: ^Window, n: Notification, done: Notify_Done = nil, user: rawptr = nil) -> bool {
	if !notify_attach(w) { return false }
	toast_post({kind = .Show, host = w.notify.host, n = notification_clone(n, runtime.heap_allocator()), id = notify_next_id(w, n.replace), done = done, user = user})
	return true
}

// Shows `n` and waits for the notification thread's answer. Called on the window's thread (Window.notify is its), which it
// blocks: an interface calls notify_async.
notify :: proc(w: ^Window, n: Notification, loc := #caller_location) -> (id: Notification_Id, ok: bool) {
	base.blocking("platform.notify", loc)
	if !notify_attach(w) { return 0, false }
	id = notify_next_id(w, n.replace)
	// (in the heap, not on this stack: the notification thread holds it until it posts the answer we wait for)
	answer := new(Toast_Answer, runtime.heap_allocator())
	defer free(answer, runtime.heap_allocator())
	toast_post({kind = .Show, host = w.notify.host, n = notification_clone(n, runtime.heap_allocator()), id = id, answer = answer})
	sync.sema_wait(&answer.sema)
	if !answer.ok { return 0, false }
	return id, true
}

// The window's host and sink, made at its first notification (no system call: the notification thread opens the
// notifier at its first show). False when the window cannot show toasts.
@(private = "file")
notify_attach :: proc(w: ^Window) -> bool {
	if w == nil { return false }
	if w.hwnd == nil && notify_test_hook == nil { return false }   // (offscreen: a service, a CI runner, a program's test)
	s := &w.notify
	if s.sink != nil { return true }
	sink := new(Notify_Sink, runtime.heap_allocator())
	sink.refs = 2   // (the window and its host; the notification thread adds the handlers')
	sink.hwnd = w.hwnd
	sink.wake = w.off_event
	sink.keys = make([dynamic]Toast_Key, runtime.heap_allocator())
	sink.queue = make([dynamic]Toast_Heard, runtime.heap_allocator())
	host := new(Toast_Host, runtime.heap_allocator())
	host.sink = sink
	host.offscreen = w.hwnd == nil
	host.records = make([dynamic]Toast_Record, runtime.heap_allocator())
	s.sink, s.host = sink, host
	return true
}

// The id of a new notification: the one it replaces when the window gave it (the toast's Tag is the id, so the system
// swaps them), else a new one. Given here so that the caller's next replace needs no answer first.
@(private = "file")
notify_next_id :: proc(w: ^Window, replace: Notification_Id) -> Notification_Id {
	s := &w.notify
	if replace != 0 && u32(replace) <= s.next_id { return replace }
	s.next_id += 1
	return Notification_Id(s.next_id)
}

// Takes it off the screen and out of the notification centre: Notification_Closed (reason Closed) follows. Nothing
// when the notification has ended already.
notify_close :: proc(w: ^Window, id: Notification_Id) {
	if w == nil || w.notify.sink == nil || id == 0 { return }
	s := &w.notify
	if !sink_key_take_id(s.sink, id) { return }
	toast_post({kind = .Hide, host = s.host, id = id})
	append(&w.events, Event{kind = .Notification_Closed, notification = {id = id, reason = .Closed}, stamp = time.tick_now()})
}

// Windows gives no activation token: "".
notify_activation_token :: proc(w: ^Window) -> string { return "" }

// NOTIFY_MESSAGE (an offscreen window: its poll_events): the shows' answers run `done`, what the handlers heard becomes
// the window's events.
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
		if h.kind == .None {
			if h.done != nil { h.done(h.user, h.ok ? h.id : 0, h.ok) }
			continue
		}
		// (a toast closed or replaced since, or one whose last event was made: no event of it any more)
		if !sink_key_take(s.sink, h.key) { continue }
		append(&w.events, Event{kind = h.kind, notification = {id = h.id, action = h.action, reason = h.reason}, stamp = time.tick_now()})
		if h.kind != .Notification_Closed {
			// a click takes the toast away, from the notification centre too
			append(&w.events, Event{kind = .Notification_Closed, notification = {id = h.id, reason = .Dismissed}, stamp = time.tick_now()})
		}
		toast_post({kind = .Drop, host = s.host, key = h.key})
	}
}

// The window is going (destroy_window): its toasts stay on the screen, their events and the answers still to come go
// nowhere. The notification thread releases what the host holds.
@(private)
notify_detach :: proc(w: ^Window) {
	s := &w.notify
	if s.sink == nil { return }
	sync.mutex_lock(&s.sink.mutex)
	s.sink.gone = true
	s.sink.hwnd, s.sink.wake = nil, nil   // (the off_event is closed after this)
	sync.mutex_unlock(&s.sink.mutex)
	toast_post({kind = .Detach, host = s.host})
	sink_release(s.sink)
	s^ = {}
}

////////////////////////////////
// The sink: any thread

// Queues `h` for the window's thread and wakes it. False once the window went.
@(private = "file")
sink_post :: proc(sink: ^Notify_Sink, h: Toast_Heard) -> bool {
	sync.mutex_lock(&sink.mutex)
	defer sync.mutex_unlock(&sink.mutex)
	if sink.gone { return false }
	append(&sink.queue, h)
	if sink.hwnd != nil {
		win.PostMessageW(sink.hwnd, NOTIFY_MESSAGE, 0, 0)
	} else if sink.wake != nil {
		win.SetEvent(sink.wake)
	}
	return true
}

@(private = "file")
sink_key_add :: proc(sink: ^Notify_Sink, key: uintptr, id: Notification_Id) {
	sync.mutex_lock(&sink.mutex)
	defer sync.mutex_unlock(&sink.mutex)
	append(&sink.keys, Toast_Key{key = key, id = id})
}

// Takes the toast `key` out of the keys: true when it was there.
@(private = "file")
sink_key_take :: proc(sink: ^Notify_Sink, key: uintptr) -> bool {
	sync.mutex_lock(&sink.mutex)
	defer sync.mutex_unlock(&sink.mutex)
	for k, i in sink.keys {
		if k.key == key { unordered_remove(&sink.keys, i); return true }
	}
	return false
}

// Takes the toast of `id` out of the keys: true when one was there.
@(private = "file")
sink_key_take_id :: proc(sink: ^Notify_Sink, id: Notification_Id) -> bool {
	sync.mutex_lock(&sink.mutex)
	defer sync.mutex_unlock(&sink.mutex)
	for k, i in sink.keys {
		if k.id == id { unordered_remove(&sink.keys, i); return true }
	}
	return false
}

// The id of the toast `key`; ok false when no event of it is to come.
@(private = "file")
sink_key_id :: proc(sink: ^Notify_Sink, key: uintptr) -> (id: Notification_Id, ok: bool) {
	for k in sink.keys { if k.key == key { return k.id, true } }
	return 0, false
}

@(private = "file")
sink_done :: proc(user: rawptr) { sink_release((^Notify_Sink)(user)) }

@(private = "file")
sink_release :: proc(sink: ^Notify_Sink) {
	if sync.atomic_sub(&sink.refs, 1) - 1 > 0 { return }
	delete(sink.keys)
	delete(sink.queue)
	free(sink, runtime.heap_allocator())
}

////////////////////////////////
// The notification thread

@(private = "file")
toast_post :: proc(job: Toast_Job) {
	sync.once_do(&toasts.once, proc() {
		toasts.jobs = make([dynamic]Toast_Job, runtime.heap_allocator())
		toasts.thread = thread.create_and_start(toast_thread_run, runtime.default_context())
	})
	sync.mutex_lock(&toasts.mutex)
	append(&toasts.jobs, job)
	sync.mutex_unlock(&toasts.mutex)
	sync.cond_signal(&toasts.cond)
}

@(private = "file")
toast_thread_run :: proc() {
	// (the multithreaded apartment: a thread that pumps no messages, and the toasts' handlers are called on the system's
	// threads anyway. Joined for the life of the process: the thread never ends)
	winrt.init(.Multi)
	for {
		sync.mutex_lock(&toasts.mutex)
		for len(toasts.jobs) == 0 { sync.cond_wait(&toasts.cond, &toasts.mutex) }
		job := pop_front(&toasts.jobs)
		sync.mutex_unlock(&toasts.mutex)
		toast_job_run(job)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
toast_job_run :: proc(job: Toast_Job) {
	job := job
	host := job.host
	switch job.kind {
	case .Show:
		ok: bool
		if notify_test_hook != nil {
			ok = notify_test_hook(job.n, job.id)
			// (a key that stands for the toast, so that notify_close and a replace behave as with a real one)
			sink_key_take_id(host.sink, job.id)
			if ok { sink_key_add(host.sink, uintptr(job.id), job.id) }
		} else if i := toast_find(host, job.id); i >= 0 && toast_update(host, &host.records[i], job.n) {
			// (the same toast, its bar moved: no popup again, no sound; its key and events stay)
			ok = true
		} else {
			ok = toast_show(host, job.n, job.id)
		}
		notification_destroy(&job.n, runtime.heap_allocator())
		if job.answer != nil {
			job.answer.ok = ok
			sync.sema_post(&job.answer.sema)
			return
		}
		sink_post(host.sink, {kind = .None, id = job.id, ok = ok, done = job.done, user = job.user})
	case .Hide:
		if i := toast_find(host, job.id); i >= 0 {
			winrt.vtable(host.notifier, IToastNotifier_Vtbl).Hide(host.notifier, host.records[i].toast)
			toast_drop(host, i)
		}
	case .Drop:
		for r, i in host.records { if r.key == job.key { toast_drop(host, i); break } }
	case .Detach:
		for r in host.records { toast_release(r) }
		delete(host.records)
		for h in host.handlers { if h != nil { winrt.release(h) } }
		winrt.release(host.notifier)
		winrt.release(host.factory)
		sink_release(host.sink)
		free(host, runtime.heap_allocator())
	}
}

// The host's notifier, made at its first show: false when the system has no toasts.
@(private = "file")
host_open :: proc(host: ^Toast_Host) -> bool {
	if host.tried { return host.notifier != nil }
	host.tried = true
	if host.offscreen { return false }   // (an offscreen window shows no toasts: a service, a CI runner, a test)
	if windows_build() < FIRST_TOAST_BUILD { return false }
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
	host.notifier, host.factory = notifier, factory
	sink := host.sink
	sync.atomic_add(&sink.refs, i32(len(host.handlers)))
	toast_sig := winrt.sig_class("Windows.UI.Notifications.ToastNotification", IID_IToastNotification)
	host.handlers[0] = winrt.event_handler_make(winrt.typed_event_handler_iid(toast_sig, winrt.SIG_INSPECTABLE), toast_activated, sink, sink_done)
	host.handlers[1] = winrt.event_handler_make(winrt.typed_event_handler_iid(toast_sig,
		winrt.sig_class("Windows.UI.Notifications.ToastDismissedEventArgs", IID_IToastDismissedEventArgs)), toast_dismissed, sink, sink_done)
	host.handlers[2] = winrt.event_handler_make(winrt.typed_event_handler_iid(toast_sig,
		winrt.sig_class("Windows.UI.Notifications.ToastFailedEventArgs", IID_IToastFailedEventArgs)), toast_failed, sink, sink_done)
	return true
}

@(private = "file")
toast_show :: proc(host: ^Toast_Host, n: Notification, id: Notification_Id) -> bool {
	if !host_open(host) { return false }
	xml := toast_xml(n, notify_icon_uri(n.icon_png))
	doc, dgot := winrt.activate("Windows.Data.Xml.Dom.XmlDocument")
	if !winrt.ok(dgot) { return false }
	defer winrt.release(doc)
	io := winrt.query(doc, IID_IXmlDocumentIO)
	if io == nil { return false }
	hxml := winrt.string_make(xml)
	loaded := winrt.vtable(io, IXmlDocumentIO_Vtbl).LoadXml(io, hxml)
	winrt.string_delete(hxml)
	winrt.release(io)
	if !winrt.ok(loaded) { return false }
	content := winrt.query(doc, IID_IXmlDocument)
	if content == nil { return false }
	defer winrt.release(content)
	toast: rawptr
	if !winrt.ok(winrt.vtable(host.factory, IToastNotificationFactory_Vtbl).CreateToastNotification(host.factory, content, &toast)) { return false }

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
	rec := Toast_Record{id = id, toast = toast, key = identity_of(toast), shape = notification_shape(n)}
	if n.progress.shown {
		// (without data the bar's bindings show nothing; a system without them shows the toast without its bar)
		if t4 := winrt.query(toast, IID_IToastNotification4); t4 != nil {
			if data := toast_data_make(n.progress, 1); data != nil {
				rec.bound = winrt.ok(winrt.vtable(t4, IToastNotification4_Vtbl).put_Data(t4, data))
				rec.sequence = 1
				winrt.release(data)
			}
			winrt.release(t4)
		}
	}
	tv := winrt.vtable(toast, IToastNotification_Vtbl)
	tv.add_Activated(toast, host.handlers[0], &rec.tokens[0])
	tv.add_Dismissed(toast, host.handlers[1], &rec.tokens[1])
	tv.add_Failed(toast, host.handlers[2], &rec.tokens[2])
	// (the toast it replaces: its Tag is this one's, the system swaps them; its events end here)
	if i := toast_find(host, id); i >= 0 { toast_drop(host, i) }
	// (its key before Show: a toast can fail, or be clicked, before Show returns)
	sink_key_add(host.sink, rec.key, id)
	if !winrt.ok(winrt.vtable(host.notifier, IToastNotifier_Vtbl).Show(host.notifier, toast)) {
		sink_key_take(host.sink, rec.key)
		toast_release(rec)
		return false
	}
	append(&host.records, rec)
	return true
}

// The data a toast's progress bar is bound to (toast_xml: {progressValue}, {progressStatus}), at `sequence`; nil when
// the system has none (before Windows 10 1607). The caller releases it.
@(private = "file")
toast_data_make :: proc(p: Notification_Progress, sequence: u32) -> rawptr {
	object, got := winrt.activate("Windows.UI.Notifications.NotificationData")
	if !winrt.ok(got) { return nil }
	data := winrt.query(object, IID_INotificationData)
	winrt.release(object)
	if data == nil { return nil }
	v := winrt.vtable(data, INotificationData_Vtbl)
	values: rawptr
	if !winrt.ok(v.get_Values(data, &values)) || values == nil {
		winrt.release(data)
		return nil
	}
	defer winrt.release(values)
	value, status := toast_progress_values(p)
	pairs := [2][2]string{{TOAST_PROGRESS_VALUE, value}, {TOAST_PROGRESS_STATUS, status}}
	for pair in pairs {
		key, text := winrt.string_make(pair[0]), winrt.string_make(pair[1])
		replaced: bool
		inserted := winrt.vtable(values, IMap_String_String_Vtbl).Insert(values, key, text, &replaced)
		winrt.string_delete(key)
		winrt.string_delete(text)
		if !winrt.ok(inserted) {
			winrt.release(data)
			return nil
		}
	}
	v.put_SequenceNumber(data, sequence)
	return data
}

// Moves the bar of the toast `rec` in place: true when the system did (the same shape, a bar bound to data, the toast
// still there). False: the caller shows it again (another shape, no IToastNotifier2, the person closed it).
@(private = "file")
toast_update :: proc(host: ^Toast_Host, rec: ^Toast_Record, n: Notification) -> bool {
	if !n.progress.shown || !rec.bound || rec.shape != notification_shape(n) { return false }
	notifier2 := winrt.query(host.notifier, IID_IToastNotifier2)
	if notifier2 == nil { return false }
	defer winrt.release(notifier2)
	data := toast_data_make(n.progress, rec.sequence + 1)
	if data == nil { return false }
	defer winrt.release(data)
	tag := winrt.string_make(fmt.tprintf("%d", rec.id))
	group := winrt.string_make(TOAST_GROUP)
	defer { winrt.string_delete(tag); winrt.string_delete(group) }
	result: i32 = -1
	if !winrt.ok(winrt.vtable(notifier2, IToastNotifier2_Vtbl).UpdateWithTagAndGroup(notifier2, data, tag, group, &result)) { return false }
	if result != NOTIFICATION_UPDATE_SUCCEEDED { return false }
	rec.sequence += 1
	return true
}

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
toast_find :: proc(host: ^Toast_Host, id: Notification_Id) -> int {
	for r, i in host.records { if r.id == id { return i } }
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
toast_drop :: proc(host: ^Toast_Host, i: int) {
	r := host.records[i]
	sink_key_take(host.sink, r.key)   // (no event of it any more)
	toast_release(r)
	ordered_remove(&host.records, i)
}

////////////////////////////////
// The handlers: on a thread of the system's

// Queues what a toast's handler heard, with the toast's id: nothing for a toast that has no event to come (closed,
// replaced, dropped).
@(private = "file")
sink_hear :: proc(sink: ^Notify_Sink, sender: rawptr, heard: Toast_Heard) {
	h := heard
	h.key = identity_of(sender)
	sync.mutex_lock(&sink.mutex)
	id, known := sink_key_id(sink, h.key)
	sync.mutex_unlock(&sink.mutex)
	if !known { return }
	h.id = id
	sink_post(sink, h)
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
