package tk_secrets

// The Secret Service (org.freedesktop.secrets) over the session bus, through gt:dbus: no libsecret to link. Each call
// opens its own short-lived connection, so a worker never shares the interface thread's. The session is "plain": the
// bus is the user's own and local, as the reference client's default. A locked keyring asks for a prompt that this
// client does not show: a new secret is then Unavailable, a kept one Refused, until the user unlocks it.

import "core:mem"
import "core:strings"
import "../dbus"

@(private = "file") SERVICE_BUS        :: "org.freedesktop.secrets"
@(private = "file") SERVICE_PATH       :: "/org/freedesktop/secrets"
@(private = "file") DEFAULT_COLLECTION :: "/org/freedesktop/secrets/aliases/default"
@(private = "file") IFACE_SERVICE      :: "org.freedesktop.Secret.Service"
@(private = "file") IFACE_COLLECTION   :: "org.freedesktop.Secret.Collection"
@(private = "file") IFACE_ITEM         :: "org.freedesktop.Secret.Item"
// A service answers at once or is not there: a call never waits longer.
@(private = "file") CALL_MS            :: 3000
@(private = "file") DICT_ENTRY_ALIGN   :: 8
// The object path CreateItem gives back when it needs a prompt (a locked keyring).
@(private = "file") NO_OBJECT          :: "/"

// A connection and a session with the service. The session's path is in temp memory.
@(private = "file")
session_open :: proc() -> (conn: ^dbus.Conn, session: string, ok: bool) {
	conn = dbus.connect_bus(.Session)
	if conn == nil { return nil, "", false }
	w := dbus.body_writer()
	dbus.w_string(&w, "plain")
	dbus.arg_variant_string(&w, "")
	msg, called := dbus.call(conn, SERVICE_BUS, SERVICE_PATH, IFACE_SERVICE, "OpenSession", "sv", w.buf[:], CALL_MS)
	if !called { dbus.conn_close(conn); return nil, "", false }
	r := dbus.msg_reader(&msg)
	dbus.read_variant_skip(&r)
	session = strings.clone(dbus.r_string(&r), context.temp_allocator)
	if r.err { dbus.conn_close(conn); return nil, "", false }
	return conn, session, true
}

// The attributes that name a secret's item (a{ss}): the program and the secret's name in it.
@(private = "file")
write_attributes :: proc(w: ^dbus.Writer, app, name: string) {
	al, ac := dbus.w_array_begin(w, DICT_ENTRY_ALIGN)
	dbus.w_struct(w); dbus.w_string(w, "application"); dbus.w_string(w, app)
	dbus.w_struct(w); dbus.w_string(w, "name"); dbus.w_string(w, name)
	dbus.w_array_end(w, al, ac)
}

// The items of a secret: those unlocked, those locked (object paths, in temp memory).
@(private = "file")
items_of :: proc(conn: ^dbus.Conn, app, name: string) -> (unlocked, locked: []string, ok: bool) {
	w := dbus.body_writer()
	write_attributes(&w, app, name)
	msg, called := dbus.call(conn, SERVICE_BUS, SERVICE_PATH, IFACE_SERVICE, "SearchItems", "a{ss}", w.buf[:], CALL_MS)
	if !called { return nil, nil, false }
	r := dbus.msg_reader(&msg)
	read :: proc(r: ^dbus.Reader) -> []string {
		list := make([dynamic]string, context.temp_allocator)
		end := dbus.r_array_begin(r, "o")
		for r.pos < end && !r.err { append(&list, strings.clone(dbus.r_string(r), context.temp_allocator)) }
		return list[:]
	}
	unlocked = read(&r)
	locked = read(&r)
	return unlocked, locked, !r.err
}

// The name a field stands for ("" if the field is not the service's or names nothing).
@(private = "file")
name_of :: proc(field: string) -> string {
	if !strings.has_prefix(field, SERVICE_MARK) { return "" }
	return field[len(SERVICE_MARK):]
}

@(private)
seal_system :: proc(app, name, secret: string, allocator := context.allocator) -> (field: string, result: Seal_Result) {
	if name == "" { return "", .Unavailable }   // (a field must name its item)
	conn, session, ok := session_open()
	if !ok { return "", .Unavailable }
	defer dbus.conn_close(conn)
	w := dbus.body_writer()
	pl, pc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "org.freedesktop.Secret.Item.Label")
	dbus.arg_variant_string(&w, strings.concatenate({app, ": ", name}, context.temp_allocator))
	dbus.arg_dict_entry(&w, "org.freedesktop.Secret.Item.Attributes")
	dbus.w_signature(&w, "a{ss}")
	write_attributes(&w, app, name)
	dbus.w_array_end(&w, pl, pc)
	dbus.w_struct(&w)
	dbus.w_string(&w, session)
	al, ac := dbus.w_array_begin(&w, 1)   // no parameters: the plain algorithm
	dbus.w_array_end(&w, al, ac)
	bl, bc := dbus.w_array_begin(&w, 1)
	dbus.w_bytes(&w, transmute([]u8)secret)
	dbus.w_array_end(&w, bl, bc)
	dbus.w_string(&w, "text/plain")
	dbus.w_bool(&w, true)   // replaces the item of the same attributes
	msg, called := dbus.call(conn, SERVICE_BUS, DEFAULT_COLLECTION, IFACE_COLLECTION, "CreateItem", "a{sv}(oayays)b", w.buf[:], CALL_MS)
	// (the body held the secret in clear: it goes back zeroed)
	mem.zero_slice(w.buf[:])
	if !called { return "", .Unavailable }
	r := dbus.msg_reader(&msg)
	item := dbus.r_string(&r)
	if r.err || item == NO_OBJECT { return "", .Unavailable }
	return strings.concatenate({SERVICE_MARK, name}, allocator), .Sealed
}

@(private)
open_system :: proc(app, field: string, allocator := context.allocator) -> (secret: string, result: Open_Result) {
	name := name_of(field)
	if name == "" { return "", .Refused }   // (DPAPI's: another system; or a mark that names nothing)
	conn, session, ok := session_open()
	if !ok { return "", .Refused }
	defer dbus.conn_close(conn)
	unlocked, _, found := items_of(conn, app, name)
	if !found || len(unlocked) == 0 { return "", .Refused }   // (locked, or gone)
	w := dbus.body_writer()
	dbus.w_string(&w, session)
	msg, called := dbus.call(conn, SERVICE_BUS, unlocked[0], IFACE_ITEM, "GetSecret", "o", w.buf[:], CALL_MS)
	if !called { return "", .Refused }
	r := dbus.msg_reader(&msg)
	dbus.r_align_entry(&r)
	_ = dbus.r_string(&r)
	r.pos = dbus.r_array_begin(&r, "y")   // (the parameters: none with the plain algorithm)
	end := dbus.r_array_begin(&r, "y")
	if r.err || end > len(r.buf) { return "", .Refused }
	value := r.buf[r.pos:end]
	secret = strings.clone(string(value), allocator)
	// (the reply stays in the connection's memory until it closes: no copy of the secret is left there)
	mem.zero_slice(value)
	return secret, .Opened
}

@(private)
forget_system :: proc(app, field: string) {
	name := name_of(field)
	if name == "" { return }
	conn, _, ok := session_open()
	if !ok { return }
	defer dbus.conn_close(conn)
	unlocked, locked, found := items_of(conn, app, name)
	if !found { return }
	for list in ([][]string{unlocked, locked}) {
		for item in list { dbus.call(conn, SERVICE_BUS, item, IFACE_ITEM, "Delete", "", nil, CALL_MS) }
	}
}

@(private)
available_system :: proc() -> bool {
	conn, _, ok := session_open()
	if ok { dbus.conn_close(conn) }
	return ok
}
