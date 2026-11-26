#+build linux
package platform

// The taskbar button on Linux (taskbar.odin has the API, src/md/features/taskbar.md the reasons). The progress, the count
// and the urgency go to the docks as the Unity launcher entry: an Update signal on the thread's session bus, one entry per
// program, named by its desktop file. The attention also goes to the window: X11's two hints, Wayland's activation token
// with no serial (the compositor that refuses it marks the window).

import "core:sys/posix"
import "../dbus"

// Sends what changed: the launcher entry for every part, the window's hints for the attention.
@(private)
taskbar_apply :: proc(w: ^Window, parts: Taskbar_Parts) {
	if !w.offscreen || w.taskbar_offscreen_entry { launcher_entry_send(w) }
	if .Attention not_in parts || w.offscreen { return }
	switch w.backend {
	case .X11: x11_attention(w, w.taskbar.attention)
	case .Wayland:
		// (nothing takes a mark back: the compositor clears it at the focus; a token not spent yet is dropped)
		if w.taskbar.attention { wl_attention(w) } else if st := wl_state(w); st != nil { wl_attention_drop(st) }
	case .None:
	}
}

// The window is going: the entry it decided is cleared (another window's is left).
@(private)
taskbar_detach :: proc(w: ^Window) {
	if session.launcher_owner != w { return }
	session.launcher_owner = nil
	conn := session_bus()
	if conn == nil { return }
	uri := launcher_entry_uri(app_id_or_exe())
	dbus.emit_signal(conn, launcher_entry_path(uri), LAUNCHER_ENTRY_INTERFACE, "Update", LAUNCHER_ENTRY_SIGNATURE, launcher_entry_body(uri, {}))
}

// The window's whole state as the program's entry (no reply: a signal).
@(private = "file")
launcher_entry_send :: proc(w: ^Window) {
	conn := session_bus()
	if conn == nil { return }
	session.launcher_owner = w
	uri := launcher_entry_uri(app_id_or_exe())
	dbus.emit_signal(conn, launcher_entry_path(uri), LAUNCHER_ENTRY_INTERFACE, "Update", LAUNCHER_ENTRY_SIGNATURE, launcher_entry_body(uri, w.taskbar))
}

@(private = "file") WM_HINTS_ATOM :: Xcb_Atom(35)        // the predefined atom WM_HINTS, also its type
@(private = "file") WM_HINTS_WORDS :: 9
@(private = "file") WM_HINTS_INPUT :: u32(1 << 0)        // InputHint: the window takes the keyboard (the field that follows)
@(private = "file") WM_HINTS_URGENCY :: u32(1 << 8)      // UrgencyHint

// ICCCM's UrgencyHint (the toolkit writes WM_HINTS nowhere else: no read before the write) and EWMH's
// _NET_WM_STATE_DEMANDS_ATTENTION.
@(private = "file")
x11_attention :: proc(w: ^Window, on: bool) {
	st := x11_state(w)
	if st == nil { return }
	hints: [WM_HINTS_WORDS]u32
	hints[0] = WM_HINTS_INPUT | (on ? WM_HINTS_URGENCY : 0)
	hints[1] = 1
	xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, WM_HINTS_ATOM, WM_HINTS_ATOM, X11_FORMAT_32, WM_HINTS_WORDS, &hints[0])
	x11_net_wm_state(w, on, x11c.net_wm_state_demands_attention, 0)
}

// A token asked with no input serial: the compositor does not grant it, and KWin, Mutter and sway mark the window as
// demanding attention when it is spent on it. A compositor that grants it focuses the window: the person's typing goes
// to it. So the token is asked only on a desktop known to mark (wayland_attention_marks). A window not presented yet is
// in no task bar: nothing is asked.
@(private = "file")
wl_attention :: proc(w: ^Window) {
	st := wl_state(w)
	if st == nil || st.surface == nil || wlc.activation == nil || !st.presented { return }
	if !wayland_attention_marks(string(posix.getenv("XDG_CURRENT_DESKTOP"))) { return }
	wl_attention_drop(st)
	token := wl.proxy_marshal_flags(wlc.activation, XDG_ACTIVATION_GET_TOKEN, &xdg_activation_token_iface, wl.proxy_get_version(wlc.activation), 0, nil)
	if token == nil { return }
	st.attention_token = token
	wl.proxy_add_listener(token, &attention_token_listener, st)
	wl.proxy_marshal_flags(token, XDG_ACTIVATION_TOKEN_SET_SURFACE, nil, wl.proxy_get_version(token), 0, st.surface)
	wl.proxy_marshal_flags(token, XDG_ACTIVATION_TOKEN_COMMIT, nil, wl.proxy_get_version(token), 0)
	wl.display_flush(wlc.display)
}

@(private)
wl_attention_drop :: proc(st: ^Wl_Window_State) {
	if st.attention_token == nil { return }
	wl.proxy_marshal_flags(st.attention_token, XDG_ACTIVATION_TOKEN_DESTROY, nil, wl.proxy_get_version(st.attention_token), WL_MARSHAL_FLAG_DESTROY)
	st.attention_token = nil
}

@(private = "file") attention_token_listener := Activation_Token_Listener{attention_token_done}

@(private = "file")
attention_token_done :: proc "c" (data: rawptr, t: Wl_Proxy, token: cstring) {
	context = wl_ctx_real()
	st := (^Wl_Window_State)(data)
	if st.attention_token != t { return }
	if st.surface != nil { wl.proxy_marshal_flags(wlc.activation, XDG_ACTIVATION_ACTIVATE, nil, wl.proxy_get_version(wlc.activation), 0, token, st.surface) }
	wl_attention_drop(st)
	wl.display_flush(wlc.display)
}
