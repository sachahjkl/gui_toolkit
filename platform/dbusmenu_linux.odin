#+build linux
package platform

// com.canonical.dbusmenu for the tray's context menu (tray_linux.odin). The host (the panel) reads the menu layout
// with GetLayout, draws it, and reports a click with Event; we turn that into a Menu_Item Tray_Event. The layout is a
// recursive (ia{sv}av) structure: an id, a dictionary of properties (label, type, enabled, visible, toggle-type,
// toggle-state, children-display), and an array of child variants.
//
// dbusmenu ids are integers of our own (0 is the root); tray.menu_ids maps them to the app's Tray_Menu_Item.id.

import "../dbus"

@(private)
dbusmenu_handler :: proc(user: rawptr, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	t := (^Tray)(user)
	if msg.iface != DBUSMENU_IFACE && msg.iface != "" { return false }
	switch msg.member {
	case "GetLayout":
		return dbusmenu_get_layout(t, c, msg)
	case "Event":
		return dbusmenu_event(t, c, msg)
	case "AboutToShow":
		w := dbus.body_writer()
		dbus.w_bool(&w, false)   // nothing changed since the last layout
		dbus.reply_return(c, msg, "b", w.buf[:])
		return true
	case "GetGroupProperties":
		// a(ia{sv}): properties for a set of ids; an empty answer is acceptable (the host falls back to GetLayout)
		w := dbus.body_writer()
		al, ac := dbus.w_array_begin(&w, 8)
		dbus.w_array_end(&w, al, ac)
		dbus.reply_return(c, msg, "a(ia{sv})", w.buf[:])
		return true
	}
	return false
}

// GetLayout(parentId i, recursionDepth i, propertyNames as) -> (revision u, layout (ia{sv}av)). We return the whole
// tree from the requested parent.
@(private)
dbusmenu_get_layout :: proc(t: ^Tray, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	// rebuild the id map so Event can resolve a click
	clear(&t.menu_ids)
	t.next_menu_id = 1
	w := dbus.body_writer()
	dbus.w_u32(&w, 1)   // revision
	// the root item (id 0) with the menu's items as children
	dbusmenu_write_root(t, &w)
	dbus.reply_return(c, msg, "u(ia{sv}av)", w.buf[:])
	return true
}

@(private)
dbusmenu_write_root :: proc(t: ^Tray, w: ^dbus.Writer) {
	dbus.w_struct(w)
	dbus.w_i32(w, 0)   // root id
	// root properties: children-display = submenu
	pl, pc := dbus.arg_dict_begin(w)
	dbus.arg_dict_entry(w, "children-display")
	dbus.arg_variant_string(w, "submenu")
	dbus.arg_dict_end(w, pl, pc)
	// children: av, each a variant wrapping a (ia{sv}av)
	al, ac := dbus.w_array_begin(w, 1)   // variant alignment 1
	for &it in t.menu { dbusmenu_write_item(t, w, &it) }
	dbus.w_array_end(w, al, ac)
}

@(private)
dbusmenu_write_item :: proc(t: ^Tray, w: ^dbus.Writer, it: ^Tray_Menu_Item) {
	// a variant holding (ia{sv}av)
	dbus.w_signature(w, "(ia{sv}av)")
	dbus.w_struct(w)
	id := t.next_menu_id
	t.next_menu_id += 1
	t.menu_ids[id] = it.id
	dbus.w_i32(w, id)
	// properties
	pl, pc := dbus.arg_dict_begin(w)
	if it.kind == .Separator {
		dbus.arg_dict_entry(w, "type")
		dbus.arg_variant_string(w, "separator")
	} else {
		dbus.arg_dict_entry(w, "label")
		dbus.arg_variant_string(w, it.text)
		if it.disabled {
			dbus.arg_dict_entry(w, "enabled")
			dbus.arg_variant_bool(w, false)
		}
		switch it.kind {
		case .Check, .Radio:
			dbus.arg_dict_entry(w, "toggle-type")
			dbus.arg_variant_string(w, it.kind == .Check ? "checkmark" : "radio")
			dbus.arg_dict_entry(w, "toggle-state")
			dbus.arg_variant_i32(w, it.checked ? 1 : 0)
		case .Item, .Separator:
		}
		if len(it.children) > 0 {
			dbus.arg_dict_entry(w, "children-display")
			dbus.arg_variant_string(w, "submenu")
		}
	}
	dbus.arg_dict_end(w, pl, pc)
	// children
	al, ac := dbus.w_array_begin(w, 1)
	for &child in it.children { dbusmenu_write_item(t, w, &child) }
	dbus.w_array_end(w, al, ac)
}

// Event(id i, eventId s, data v, timestamp u): a "clicked" eventId on an item id becomes a Menu_Item Tray_Event.
@(private)
dbusmenu_event :: proc(t: ^Tray, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	r := dbus.msg_reader(msg)
	id := dbus.r_i32(&r)
	event := dbus.r_string(&r)
	dbus.reply_return(c, msg, "", nil)
	if event == "clicked" {
		if app_id, ok := t.menu_ids[id]; ok {
			tray_push(t, {kind = .Menu_Item, item = app_id})
		}
	}
	return true
}
