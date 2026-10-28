#+build linux
package platform

// The XDG desktop portals over D-Bus (dialogs_linux.odin chooses the portal first, then zenity / kdialog):
//   * org.freedesktop.portal.FileChooser — OpenFile / SaveFile / a folder, with filters, multiple selection, a
//     suggested name; the chosen paths arrive on a Response signal at the request object the call returns.
//   * org.freedesktop.portal.OpenURI — OpenURI / OpenFile, the portal's "open in the user's browser / handler".
//   * org.freedesktop.portal.Settings — Read / ReadOne of org.freedesktop.appearance color-scheme, and the
//     SettingChanged signal for a live light / dark switch (theme_linux.odin subscribes through the shared bus).
//
// The FileChooser call is blocking (the dialogs API is), so it runs on a dedicated short-lived connection on the
// calling worker thread (never the shared UI-thread bus), pumping it until the Response signal with the matching
// request path arrives.

import "core:strings"
import "../dbus"

@(private) PORTAL_SERVICE :: "org.freedesktop.portal.Desktop"
@(private) PORTAL_PATH :: "/org/freedesktop/portal/desktop"
@(private) FILECHOOSER_IFACE :: "org.freedesktop.portal.FileChooser"
@(private) OPENURI_IFACE :: "org.freedesktop.portal.OpenURI"
@(private) SETTINGS_IFACE :: "org.freedesktop.portal.Settings"
@(private) REQUEST_IFACE :: "org.freedesktop.portal.Request"

// Whether the desktop portal is present on the session bus.
@(private)
portal_available :: proc() -> bool {
	conn := session_bus()
	if conn == nil { return false }
	// a cheap existence probe: Settings.ReadOne of the appearance color-scheme (present on every modern portal)
	_, ok := portal_read_color_scheme(conn)
	return ok
}

////////////////////////////////
// FileChooser

// The state a blocking portal file dialog threads through its own connection while it waits for the Response signal.
@(private)
Portal_Dialog :: struct {
	done:   bool,
	code:   u32,          // the Response response code (0 success, 1 cancelled, 2 ended)
	paths:  [dynamic]string,
	filter: int,
}

// Runs a FileChooser portal dialog of `kind` (0 open, 1 save, 2 folder). Returns the portal result, or status
// Unsupported when the portal is absent so the caller falls back to zenity / kdialog.
@(private)
portal_file_dialog :: proc(kind: int, d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	conn := dbus.connect_bus(.Session)
	if conn == nil { return {status = .Unsupported} }
	defer dbus.conn_close(conn)
	token := portal_token()
	method := kind == 1 ? "SaveFile" : "OpenFile"
	w := dbus.body_writer()
	dbus.w_string(&w, "")                               // parent_window (x11 "x11:<xid>" / wl handle; "" is fine)
	dbus.w_string(&w, d.title != "" ? d.title : (kind == 1 ? "Save File" : "Open File"))
	// options a{sv}
	ol, oc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "handle_token"); dbus.arg_variant_string(&w, token)
	if kind == 0 && d.multiple { dbus.arg_dict_entry(&w, "multiple"); dbus.arg_variant_bool(&w, true) }
	if kind == 2 { dbus.arg_dict_entry(&w, "directory"); dbus.arg_variant_bool(&w, true) }
	if kind == 1 && d.suggested_name != "" {
		dbus.arg_dict_entry(&w, "current_name"); dbus.arg_variant_string(&w, d.suggested_name)
	}
	portal_write_filters(&w, d)
	dbus.arg_dict_end(&w, ol, oc)
	msg, ok := dbus.call(conn, PORTAL_SERVICE, PORTAL_PATH, FILECHOOSER_IFACE, method, "ssa{sv}", w.buf[:], 8000)
	if !ok { return {status = .Failed} }
	r := dbus.msg_reader(&msg)
	request_path := dbus.r_string(&r)
	// subscribe to the Response on the request object, then pump until it arrives (no timeout: the user takes their time)
	pd := Portal_Dialog{}
	sub := dbus.subscribe(conn, PORTAL_SERVICE, request_path, REQUEST_IFACE, "Response", portal_response_signal, &pd)
	for !pd.done {
		dbus.dispatch(conn)
		if !dbus.conn_alive(conn) { break }
		portal_wait_fd(dbus.conn_fd(conn), 200)
	}
	dbus.unsubscribe(conn, sub)
	if pd.code != 0 || len(pd.paths) == 0 {
		for p in pd.paths { delete(p) }
		delete(pd.paths)
		return {status = .Cancelled}
	}
	out := make([]string, len(pd.paths), allocator)
	for p, i in pd.paths { out[i] = strings.clone(p, allocator) }
	for p in pd.paths { delete(p) }
	delete(pd.paths)
	return {status = .Chosen, paths = out, filter = d.filter_index}
}

// The portal filters option: a(sa(us)) — for each filter a name and a list of (type, pattern), type 0 = glob.
@(private)
portal_write_filters :: proc(w: ^dbus.Writer, d: File_Dialog) {
	if len(d.filters) == 0 && !d.all_files { return }
	dbus.arg_dict_entry(w, "filters")
	dbus.w_signature(w, "a(sa(us))")
	al, ac := dbus.w_array_begin(w, 8)
	for f in d.filters {
		dbus.w_struct(w)
		dbus.w_string(w, f.name)
		pl, pc := dbus.w_array_begin(w, 8)
		pats := filter_patterns(f, context.temp_allocator)
		rest := pats
		for p in strings.split_iterator(&rest, ";") {
			dbus.w_struct(w)
			dbus.w_u32(w, 0)   // glob
			dbus.w_string(w, p)
		}
		dbus.w_array_end(w, pl, pc)
	}
	if d.all_files {
		dbus.w_struct(w)
		dbus.w_string(w, "All files")
		pl, pc := dbus.w_array_begin(w, 8)
		dbus.w_struct(w); dbus.w_u32(w, 0); dbus.w_string(w, "*")
		dbus.w_array_end(w, pl, pc)
	}
	dbus.w_array_end(w, al, ac)
}

// The Response signal (u response, a{sv} results): results["uris"] is an array of file:// URIs.
@(private)
portal_response_signal :: proc(user: rawptr, msg: ^dbus.Message) {
	pd := (^Portal_Dialog)(user)
	r := dbus.msg_reader(msg)
	pd.code = dbus.r_u32(&r)
	// results a{sv}
	end := dbus.r_array_begin(&r, "{sv}")
	for r.pos < end {
		dbus.r_align_entry(&r)
		key := dbus.r_string(&r)
		if key == "uris" {
			vs := dbus.r_variant_sig(&r)   // "as"
			if vs == "as" {
				aend := dbus.r_array_begin(&r, "s")
				for r.pos < aend {
					uri := dbus.r_string(&r)
					for p in uri_list_to_paths(uri, context.allocator) { append(&pd.paths, p) }
				}
			} else {
				dbus.r_skip(&r, vs)
			}
		} else {
			dbus.read_variant_skip(&r)
		}
	}
	pd.done = true
}

@(private)
portal_token :: proc() -> string {
	@(static) counter: int
	counter += 1
	return strings.concatenate({"gt", int_to_str(counter)}, context.temp_allocator)
}

////////////////////////////////
// OpenURI

// Opens a URL through the portal (the user's browser / handler). Returns whether the call was accepted.
@(private)
portal_open_uri :: proc(uri: string) -> bool {
	conn := session_bus()
	if conn == nil { return false }
	w := dbus.body_writer()
	dbus.w_string(&w, "")        // parent_window
	dbus.w_string(&w, uri)
	ol, oc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_end(&w, ol, oc)
	return dbus.call_noreply(conn, PORTAL_SERVICE, PORTAL_PATH, OPENURI_IFACE, "OpenURI", "ssa{sv}", w.buf[:])
}

////////////////////////////////
// Settings (appearance: live light / dark)

// Reads org.freedesktop.appearance color-scheme (0 no preference, 1 dark, 2 light). ok = false when the portal or the
// key is absent.
@(private)
portal_read_color_scheme :: proc(conn: ^dbus.Conn) -> (dark: bool, ok: bool) {
	w := dbus.body_writer()
	dbus.w_string(&w, "org.freedesktop.appearance")
	dbus.w_string(&w, "color-scheme")
	msg, got := dbus.call(conn, PORTAL_SERVICE, PORTAL_PATH, SETTINGS_IFACE, "ReadOne", "ss", w.buf[:], 3000)
	if !got || msg.type != .Method_Return { return false, false }
	r := dbus.msg_reader(&msg)
	// the reply is a variant holding a u (some portals double-wrap it: v(v(u))); read one variant, then a u
	scheme := dbus.read_variant_u32_nested(&r)
	return scheme == 1, true
}

// The live dark-mode read theme_linux.odin uses when the portal answers; falls back to the GTK heuristics otherwise.
@(private)
portal_dark_mode :: proc() -> (dark: bool, ok: bool) {
	conn := session_bus()
	if conn == nil { return false, false }
	return portal_read_color_scheme(conn)
}

@(private) theme_change_cb: proc(dark: bool)
@(private) theme_sub: u32

// Subscribes to SettingChanged so an app learns when the user flips light / dark at run time. `cb` runs from the bus
// dispatch (the UI thread, as the window loop pumps the bus). Call once; the toolkit's ui wires the repaint.
watch_color_scheme :: proc(cb: proc(dark: bool)) -> bool {
	conn := session_bus()
	if conn == nil { return false }
	theme_change_cb = cb
	if theme_sub == 0 {
		theme_sub = dbus.subscribe(conn, PORTAL_SERVICE, PORTAL_PATH, SETTINGS_IFACE, "SettingChanged", portal_setting_changed, nil)
	}
	return theme_sub != 0
}

@(private)
portal_setting_changed :: proc(user: rawptr, msg: ^dbus.Message) {
	// SettingChanged(namespace s, key s, value v)
	r := dbus.msg_reader(msg)
	ns := dbus.r_string(&r)
	key := dbus.r_string(&r)
	if ns == "org.freedesktop.appearance" && key == "color-scheme" {
		scheme := dbus.read_variant_u32_nested(&r)
		if theme_change_cb != nil { theme_change_cb(scheme == 1) }
	}
}

@(private)
portal_wait_fd :: proc(fd: i32, timeout_ms: int) {
	if fd < 0 { return }
	poll_fd_wait(fd, timeout_ms)
}

@(private)
int_to_str :: proc(v: int) -> string {
	if v == 0 { return "0" }
	buf: [20]u8
	i := len(buf)
	x := v
	for x > 0 { i -= 1; buf[i] = '0' + u8(x % 10); x /= 10 }
	return strings.clone(string(buf[i:]), context.temp_allocator)
}
