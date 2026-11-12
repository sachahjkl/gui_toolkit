#+build !windows
#+build !linux
package platform

// No notifications on the systems that have no implementation (notify.odin has the API): notify_supported is false and
// notify shows nothing.

Notify_State :: struct {}

@(private) notify_app_declared :: proc() {}
@(private) notify_detach :: proc(w: ^Window) {}

notify_supported :: proc() -> bool { return false }
notify :: proc(w: ^Window, n: Notification) -> (id: Notification_Id, ok: bool) { return 0, false }
notify_async :: proc(w: ^Window, n: Notification, done: Notify_Done = nil, user: rawptr = nil) -> bool { return false }
notify_close :: proc(w: ^Window, id: Notification_Id) {}
notify_activation_token :: proc(w: ^Window) -> string { return "" }
