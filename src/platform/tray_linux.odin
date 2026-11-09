#+build linux
package platform

// The notification area on Linux (tray.odin has the API): the StatusNotifierItem specification (KDE / freedesktop)
// over D-Bus, with its menu through com.canonical.dbusmenu, and notifications through org.freedesktop.Notifications.
// Both ride the platform's shared session bus (dbus_linux.odin); without a bus or a StatusNotifierWatcher (a bare X11
// session with no panel) tray_create returns nil, as the Win32 backend does when the shell refuses an icon.
//
//   * tray_create exports an object implementing org.kde.StatusNotifierItem at /StatusNotifierItem/<n> (each icon its
//     own object on the connection, named to the watcher by its path), registers it with the watcher, follows the
//     watcher's restarts, and serves its properties (Id, Title, Status, IconPixmap, ToolTip, Menu) through
//     org.freedesktop.DBus.Properties. The host (the panel) calls Activate / SecondaryActivate / ContextMenu / Scroll,
//     which become Tray_Events.
//   * tray_set_menu builds a com.canonical.dbusmenu tree the host renders; a chosen item comes back as an Event method
//     call and becomes a Menu_Item event.
//   * tray_notify shows a notification through notify_linux.odin (the toolkit's one Notify); its results become
//     Notify_* events of the icon.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "../dbus"

@(private) SNI_WATCHER :: "org.kde.StatusNotifierWatcher"
@(private) SNI_WATCHER_PATH :: "/StatusNotifierWatcher"
@(private) SNI_ITEM_IFACE :: "org.kde.StatusNotifierItem"
@(private) SNI_ITEM_PATH :: "/StatusNotifierItem"
@(private) DBUSMENU_IFACE :: "com.canonical.dbusmenu"
@(private) DBUSMENU_PATH :: "/MenuBar"
@(private) PROPS_IFACE :: "org.freedesktop.DBus.Properties"
@(private = "file") DBUS_SERVICE :: "org.freedesktop.DBus"
@(private = "file") DBUS_PATH :: "/org/freedesktop/DBus"

// What the Linux tray keeps beyond the shared Tray fields.
Native_Tray :: struct {
	conn:        ^dbus.Conn,
	path:        string,      // this icon's object (/StatusNotifierItem/<n>)
	menu_path:   string,      // its menu's (/MenuBar/<n>)
	icon_rgba:   []u8,        // the icon as RGBA (StatusNotifierItem wants ARGB pixmaps)
	icon_size:   [2]int,
	title:       string,
	menu_ids:    map[i32]int, // dbusmenu id -> the app's Tray_Menu_Item.id
	next_menu_id: i32,
	menu_revision: u32,       // of the layout, told with LayoutUpdated
	sub_watcher: u32,         // the watcher's owner changing (a panel that restarts)
	last_notify: u32,         // tray_notify's last notification, which the next replaces; 0 once it closed
}

@(private) tray_pid_counter: u32   // the process's icons so far, for their paths (atomic)

tray_create :: proc(w: ^Window, icon_png: []u8 = nil, tooltip := "") -> ^Tray {
	if w == nil || w.offscreen { return nil }
	conn := session_bus()
	if conn == nil { return nil }
	t := new(Tray)
	t.window = w
	t.auto_menu = true
	t.tooltip = clone_string(tooltip)
	t.conn = conn
	t.title = clone_string(tooltip)
	t.menu_ids = make(map[i32]int)
	t.menu_revision = 1
	n := sync.atomic_add(&tray_pid_counter, 1) + 1
	t.path = fmt.aprintf("%s/%d", SNI_ITEM_PATH, n)
	t.menu_path = fmt.aprintf("%s/%d", DBUSMENU_PATH, n)
	if icon_png != nil { tray_set_icon(t, icon_png) }   // decodes to RGBA through the hook if present
	// export the object and the menu, register with the watcher
	dbus.export_object(conn, t.path, sni_item_handler, t)
	dbus.export_object(conn, t.menu_path, dbusmenu_handler, t)
	if !sni_register(t) {
		dbus.export_remove(conn, t.path)
		dbus.export_remove(conn, t.menu_path)
		tray_free_native(t); tray_free(t); return nil
	}
	t.added = true
	t.sub_watcher = dbus.subscribe(conn, DBUS_SERVICE, DBUS_PATH, DBUS_SERVICE, "NameOwnerChanged", sni_watcher_changed, t)
	append(&w.trays, t)
	return t
}

tray_destroy :: proc(t: ^Tray) {
	if t == nil { return }
	if t.conn != nil {
		dbus.export_remove(t.conn, t.path)
		dbus.export_remove(t.conn, t.menu_path)
		if t.sub_watcher != 0 { dbus.unsubscribe(t.conn, t.sub_watcher) }
	}
	notify_tray_gone(t.window, t)
	if w := t.window; w != nil {
		for x, i in w.trays { if x == t { unordered_remove(&w.trays, i); break } }
	}
	tray_free_native(t)
	tray_free(t)
}

tray_set_icon :: proc(t: ^Tray, icon_png: []u8) -> bool {
	if t == nil { return false }
	delete(t.icon_rgba)
	t.icon_rgba, t.icon_size = nil, {}
	if len(icon_png) > 0 {
		if img, ok := png_decode(icon_png); ok {
			t.icon_rgba = img.rgba
			t.icon_size = img.size
		}
	}
	if t.added && t.conn != nil { dbus.emit_signal(t.conn, t.path, SNI_ITEM_IFACE, "NewIcon", "", nil) }
	return true
}

tray_set_icon_rgba :: proc(t: ^Tray, rgba: []u8, size: [2]int) -> bool {
	if t == nil || size.x <= 0 || size.y <= 0 || len(rgba) < size.x * size.y * 4 { return false }
	delete(t.icon_rgba)
	t.icon_rgba = make([]u8, len(rgba))
	copy(t.icon_rgba, rgba)
	t.icon_size = size
	if t.added && t.conn != nil { dbus.emit_signal(t.conn, t.path, SNI_ITEM_IFACE, "NewIcon", "", nil) }
	return true
}

tray_set_tooltip :: proc(t: ^Tray, text: string) -> bool {
	if t == nil { return false }
	delete(t.tooltip); t.tooltip = clone_string(text)
	delete(t.title); t.title = clone_string(text)
	if t.added && t.conn != nil { dbus.emit_signal(t.conn, t.path, SNI_ITEM_IFACE, "NewToolTip", "", nil) }
	return true
}

@(private = "file") TRAY_DBUS_CALL_MS :: 5000

// The notification goes through notify_linux.odin's Notify; its results become the icon's Notify_* events.
tray_notify :: proc(t: ^Tray, n: Tray_Notify) -> bool {
	if t == nil || t.window == nil { return false }
	urgency := Notification_Urgency.Normal
	#partial switch n.icon {
	case .Info:  urgency = .Low
	case .Error: urgency = .Critical
	}
	id, ok := notify_send(t.window, {title = n.title, body = n.body, urgency = urgency, silent = n.silent, replace = Notification_Id(t.last_notify)}, t)
	if !ok { return false }
	t.last_notify = u32(id)
	tray_push(t, {kind = .Notify_Shown})
	return true
}

// Opens the menu from the app (a left click): the StatusNotifierItem model has the host own the menu, so there is no
// client-driven popup; we ask the host to show the context menu through the item's ContextMenu, if the host supports
// it. Returns the default item when there is one (what a double click does), else nothing.
tray_show_menu :: proc(t: ^Tray) -> (id: int, ok: bool) {
	if t == nil { return 0, false }
	for it in t.menu { if it.default { return it.id, true } }
	return 0, false
}

tray_inject :: proc(t: ^Tray, code: u32, pos: [2]i32 = {}) {
	if t == nil { return }
	kind, keyboard := tray_event_from_code(code)
	if kind == .None { return }
	tray_push(t, {kind = kind, pos = pos, keyboard = keyboard})
}

tray_inject_shell_restart :: proc(w: ^Window) {
	// the StatusNotifierWatcher restarting is a StatusNotifierHostRegistered signal; re-register each item
	for t in w.trays { sni_register(t); tray_push(t, {kind = .Recreated}) }
}

// A synthetic code -> a Tray_Event_Kind (tray_inject): mirrors the Win32 codes so tests are portable.
@(private)
tray_event_from_code :: proc(code: u32) -> (Tray_Event_Kind, bool) {
	switch code {
	case 1: return .Click, false
	case 2: return .Double_Click, false
	case 3: return .Right_Click, false
	case 4: return .Middle_Click, false
	}
	return .None, false
}

@(private)
tray_destroy_all :: proc(w: ^Window) {
	for len(w.trays) > 0 { tray_destroy(w.trays[len(w.trays) - 1]) }
	delete(w.trays)
	w.trays = nil
}

@(private)
tray_free_native :: proc(t: ^Tray) {
	delete(t.path)
	delete(t.menu_path)
	delete(t.icon_rgba)
	delete(t.title)
	delete(t.menu_ids)
}

////////////////////////////////
// StatusNotifierItem registration and property serving

@(private)
sni_register :: proc(t: ^Tray) -> bool {
	w := dbus.body_writer()
	dbus.w_string(&w, t.path)   // (a path: the watcher takes the name from the sender, each icon has its object)
	_, ok := dbus.call(t.conn, SNI_WATCHER, SNI_WATCHER_PATH, SNI_WATCHER, "RegisterStatusNotifierItem", "s", w.buf[:], TRAY_DBUS_CALL_MS)
	return ok
}

// The name of the watcher changed hands: a panel left, or came (back). The icon goes to the new one.
@(private)
sni_watcher_changed :: proc(user: rawptr, msg: ^dbus.Message) {
	t := (^Tray)(user)
	r := dbus.msg_reader(msg)
	if dbus.r_string(&r) != SNI_WATCHER { return }
	_ = dbus.r_string(&r)
	t.added = dbus.r_string(&r) != "" && sni_register(t)
	if t.added { tray_push(t, {kind = .Recreated}) }
}

// The menu changed: the host reads it again.
@(private)
tray_menu_changed :: proc(t: ^Tray) {
	t.menu_revision += 1
	if !t.added || t.conn == nil { return }
	w := dbus.body_writer()
	dbus.w_u32(&w, t.menu_revision)
	dbus.w_i32(&w, 0)   // the root
	dbus.emit_signal(t.conn, t.menu_path, DBUSMENU_IFACE, "LayoutUpdated", "ui", w.buf[:])
}

// org.kde.StatusNotifierItem on our object: the host calls Activate / ContextMenu / Scroll and reads properties.
@(private)
sni_item_handler :: proc(user: rawptr, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	t := (^Tray)(user)
	if msg.iface == PROPS_IFACE {
		return sni_props(t, c, msg)
	}
	if msg.iface == SNI_ITEM_IFACE || msg.iface == "" {
		switch msg.member {
		case "Activate":
			tray_push(t, {kind = .Click, pos = sni_read_xy(msg)})
			dbus.reply_return(c, msg, "", nil)
			return true
		case "SecondaryActivate":
			tray_push(t, {kind = .Middle_Click, pos = sni_read_xy(msg)})
			dbus.reply_return(c, msg, "", nil)
			return true
		case "ContextMenu":
			tray_push(t, {kind = .Right_Click, pos = sni_read_xy(msg)})
			dbus.reply_return(c, msg, "", nil)
			return true
		case "Scroll":
			dbus.reply_return(c, msg, "", nil)
			return true
		}
	}
	return false
}

@(private)
sni_read_xy :: proc(msg: ^dbus.Message) -> [2]i32 {
	r := dbus.msg_reader(msg)
	x := dbus.r_i32(&r)
	y := dbus.r_i32(&r)
	return {x, y}
}

// org.freedesktop.DBus.Properties.Get / GetAll for the StatusNotifierItem.
@(private)
sni_props :: proc(t: ^Tray, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	switch msg.member {
	case "Get":
		r := dbus.msg_reader(msg)
		_ = dbus.r_string(&r)           // interface
		name := dbus.r_string(&r)       // property
		w := dbus.body_writer()
		if !sni_write_prop(t, &w, name) { dbus.reply_error(c, msg, "org.freedesktop.DBus.Error.InvalidArgs", "No such property"); return true }
		dbus.reply_return(c, msg, "v", w.buf[:])
		return true
	case "GetAll":
		w := dbus.body_writer()
		dlen, dcontent := dbus.arg_dict_begin(&w)
		for p in ([]string{"Category", "Id", "Title", "Status", "IconName", "IconPixmap", "ToolTip", "Menu", "ItemIsMenu"}) {
			dbus.arg_dict_entry(&w, p)
			sni_write_prop(t, &w, p)
		}
		dbus.arg_dict_end(&w, dlen, dcontent)
		dbus.reply_return(c, msg, "a{sv}", w.buf[:])
		return true
	}
	return false
}

// Writes one property's value as a variant. Returns false for an unknown name.
@(private)
sni_write_prop :: proc(t: ^Tray, w: ^dbus.Writer, name: string) -> bool {
	switch name {
	case "Category":   dbus.arg_variant_string(w, "ApplicationStatus"); return true
	case "Id":         dbus.arg_variant_string(w, "gui_toolkit"); return true
	case "Title":      dbus.arg_variant_string(w, t.title); return true
	case "Status":     dbus.arg_variant_string(w, "Active"); return true
	case "IconName":   dbus.arg_variant_string(w, ""); return true
	case "ItemIsMenu": dbus.arg_variant_bool(w, false); return true
	case "Menu":       dbus.arg_variant_object(w, t.menu_path); return true
	case "IconPixmap":
		sni_write_icon_pixmap(t, w)
		return true
	case "ToolTip":
		// (sa(iiay)ss): icon name, pixmaps, title, text. We give an empty icon, our title and tooltip.
		dbus.w_signature(w, "(sa(iiay)ss)")
		dbus.w_struct(w)
		dbus.w_string(w, "")
		al, ac := dbus.w_array_begin(w, DBUS_ALIGN_STRUCT)
		dbus.w_array_end(w, al, ac)
		dbus.w_string(w, t.title)
		dbus.w_string(w, t.tooltip)
		return true
	}
	return false
}

// IconPixmap is a(iiay): a list of (width, height, ARGB32 bytes) pixmaps. StatusNotifierItem wants network-order ARGB;
// our icon is straight RGBA, so swizzle. Only our one size is offered.
@(private)
sni_write_icon_pixmap :: proc(t: ^Tray, w: ^dbus.Writer) {
	dbus.w_signature(w, "a(iiay)")
	al, ac := dbus.w_array_begin(w, DBUS_ALIGN_STRUCT)
	if len(t.icon_rgba) >= t.icon_size.x * t.icon_size.y * 4 && t.icon_size.x > 0 {
		dbus.w_struct(w)
		dbus.w_i32(w, i32(t.icon_size.x))
		dbus.w_i32(w, i32(t.icon_size.y))
		n := t.icon_size.x * t.icon_size.y
		argb := make([]u8, n * 4, context.temp_allocator)
		for i in 0 ..< n {
			r, g, b, a := t.icon_rgba[i * 4], t.icon_rgba[i * 4 + 1], t.icon_rgba[i * 4 + 2], t.icon_rgba[i * 4 + 3]
			// ARGB in network byte order: A, R, G, B
			argb[i * 4], argb[i * 4 + 1], argb[i * 4 + 2], argb[i * 4 + 3] = a, r, g, b
		}
		bl, bc := dbus.w_array_begin(w, 1)
		dbus.w_bytes(w, argb)
		dbus.w_array_end(w, bl, bc)
	}
	dbus.w_array_end(w, al, ac)
}

_ :: runtime
_ :: strings
