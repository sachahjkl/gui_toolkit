#+build linux
package platform

// The platform's shared session-bus connection, used by the tray, notifications, the file-chooser and appearance
// portals, the ScreenSaver inhibitor and the AT-SPI accessibility bridge. One connection for the process, opened on
// first use and folded into the window loop: its fd is poll(2)-ed alongside the window, and the loop calls
// dbus.dispatch to drain it (see platform_linux.odin's pump, which now watches the bus too).
//
// A service that needs the bus calls session_bus(); nil means there is no bus (a login without a session), and every
// service degrades gracefully (the tray reports no icon, the portal falls back to zenity, the theme reads the GTK
// files).

import "../dbus"

@(private) session_conn: ^dbus.Conn
@(private) session_tried: bool

// The process's session bus (nil when unreachable). Opened once.
@(private)
session_bus :: proc() -> ^dbus.Conn {
	if session_tried { return session_conn }
	session_tried = true
	session_conn = dbus.connect_bus(.Session)
	return session_conn
}

// Drains the bus if it is open (called from the window loop after poll said its fd is readable, and once per pump so
// async replies and portal / theme signals are delivered promptly).
@(private)
dbus_pump :: proc() {
	if session_conn != nil { dbus.dispatch(session_conn) }
}

// The bus's socket fd for the window loop's poll set (-1 when there is no bus).
@(private)
dbus_fd :: proc() -> i32 {
	return session_conn != nil ? dbus.conn_fd(session_conn) : -1
}

@(private)
dbus_shutdown :: proc() {
	if session_conn != nil { dbus.conn_close(session_conn); session_conn = nil }
	session_tried = false
}
