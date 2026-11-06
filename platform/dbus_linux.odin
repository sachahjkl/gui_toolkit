#+build linux
package platform

// The platform's session-bus connection, used by the tray, notifications, the file-chooser and appearance portals, the
// ScreenSaver inhibitor and the AT-SPI accessibility bridge. One connection per thread (a connection is driven by one thread,
// dbus.odin), opened on its first use and folded into that thread's window loop: its fd is poll(2)-ed alongside the window, and the loop calls
// dbus.dispatch to drain it (see platform_linux.odin's pump, which now watches the bus too).
//
// A service that needs the bus calls session_bus(); nil means there is no bus (a login without a session), and every
// service degrades gracefully (the tray reports no icon, the portal falls back to zenity, the theme reads the GTK
// files).

import "../dbus"

@(private) DBUS_QUICK_CALL_MS :: 3000   // a query the interface waits for: a missing service must not hold it long
@(private) DBUS_ALIGN_STRUCT :: 8       // the elements of an array of structs or dict entries
@(private) DBUS_ALIGN_STRING :: 4       // the elements of an array of strings

// This thread's session bus and what the services keep on it.
@(private)
Session_Bus :: struct {
	conn:          ^dbus.Conn,
	tried:         bool,              // connect_bus ran (conn nil: there is no bus)
	a11y_address:  string,            // the a11y bus's (a11y_bus_address), "" when there is none
	a11y:          A11y_Bus_State,
	a11y_sub:      u32,               // its PropertiesChanged: an assistive technology that comes or goes
	theme_changed: proc(dark: bool),  // watch_color_scheme's callback
	theme_sub:     u32,               // its subscription to SettingChanged
	idle_records:  [dynamic]Idle_Record,   // the live inhibitions (idle_inhibit_linux)
	idle_next:     u64,
}

@(private, thread_local) session: Session_Bus

// This thread's session bus (nil when unreachable, or gone: it ends with the login, and the services fall back as they do
// with none). Opened once per thread.
@(private)
session_bus :: proc() -> ^dbus.Conn {
	if !session.tried {
		session.tried = true
		session.conn = dbus.connect_bus(.Session)
	}
	return dbus.conn_alive(session.conn) ? session.conn : nil
}

// Drains the bus if it is open (called from the window loop after poll said its fd is readable, and once per pump so
// async replies and portal / theme signals are delivered promptly).
@(private)
dbus_pump :: proc() {
	if session.conn != nil { dbus.dispatch(session.conn) }
}

// The bus's socket fd for the window loop's poll set (-1 when there is no bus).
@(private)
dbus_fd :: proc() -> i32 {
	return session.conn != nil ? dbus.conn_fd(session.conn) : -1
}

