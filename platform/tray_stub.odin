#+build !windows
#+build !linux
package platform

// The notification area on the systems that have no implementation yet (tray.odin has the API): no icon is made
// (tray_create returns nil); every other call accepts nil and does nothing. Windows (tray_win32.odin) and Linux
// (tray_linux.odin) have their own.

Native_Tray :: struct {}

tray_create :: proc(w: ^Window, icon_png: []u8 = nil, tooltip := "") -> ^Tray { return nil }
tray_destroy :: proc(t: ^Tray) {}
tray_set_icon :: proc(t: ^Tray, icon_png: []u8) -> bool { return false }
tray_set_icon_rgba :: proc(t: ^Tray, rgba: []u8, size: [2]int) -> bool { return false }
tray_set_tooltip :: proc(t: ^Tray, text: string) -> bool { return false }
tray_notify :: proc(t: ^Tray, n: Tray_Notify) -> bool { return false }
tray_show_menu :: proc(t: ^Tray) -> (id: int, ok: bool) { return 0, false }
tray_inject :: proc(t: ^Tray, code: u32, pos: [2]i32 = {}) {}
tray_inject_shell_restart :: proc(w: ^Window) {}
