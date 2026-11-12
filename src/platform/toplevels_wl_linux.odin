package platform

// zwlr_foreign_toplevel_management_unstable_v1 (version 3): the compositor tells a client each toplevel of the session
// (a handle: its title, its app_id, its state, done after each change, closed when it goes) and lets it act on one
// (activate, with the seat). What toplevels.odin gives.

import "core:strings"

// A toplevel as the compositor tells it (the connection's: Wl_Conn.toplevels).
@(private)
Wl_Toplevel :: struct {
	handle:    Wl_Proxy,
	id:        u64,
	app_id:    string,   // owned
	title:     string,   // owned
	active:    bool,
	minimized: bool,
	closed:    bool,
}

@(private = "file") FTL_HANDLE_ACTIVATE :: 4
@(private = "file") FTL_HANDLE_DESTROY :: 7
// zwlr_foreign_toplevel_handle_v1.state's values
@(private = "file") FTL_STATE_MINIMIZED :: 1
@(private = "file") FTL_STATE_ACTIVATED :: 2

@(private) ftl_manager_iface: Wl_Interface
@(private) ftl_handle_iface: Wl_Interface
@(private = "file") ftl_manager_methods: [1]Wl_Message
@(private = "file") ftl_manager_events: [2]Wl_Message
@(private = "file") ftl_handle_methods: [10]Wl_Message
@(private = "file") ftl_handle_events: [8]Wl_Message
@(private = "file") t_ftl_new: [1]^Wl_Interface
@(private = "file") t_ftl_seat: [1]^Wl_Interface
@(private = "file") t_ftl_rect: [5]^Wl_Interface
@(private = "file") t_ftl_output: [1]^Wl_Interface
@(private = "file") t_ftl_parent: [1]^Wl_Interface

@(private)
foreign_toplevel_build_tables :: proc() {
	t_ftl_new[0] = &ftl_handle_iface
	ftl_manager_methods[0] = {"stop", "", nil}
	ftl_manager_events[0] = {"toplevel", "n", raw_types(t_ftl_new[:])}
	ftl_manager_events[1] = {"finished", "", nil}
	ftl_manager_iface = {"zwlr_foreign_toplevel_manager_v1", 3, 1, &ftl_manager_methods[0], 2, &ftl_manager_events[0]}

	t_ftl_seat[0] = wl.seat_interface
	t_ftl_rect[0] = wl.surface_interface
	t_ftl_output[0] = wl.output_interface
	t_ftl_parent[0] = &ftl_handle_iface
	ftl_handle_methods[0] = {"set_maximized", "", nil}
	ftl_handle_methods[1] = {"unset_maximized", "", nil}
	ftl_handle_methods[2] = {"set_minimized", "", nil}
	ftl_handle_methods[3] = {"unset_minimized", "", nil}
	ftl_handle_methods[4] = {"activate", "o", raw_types(t_ftl_seat[:])}
	ftl_handle_methods[5] = {"close", "", nil}
	ftl_handle_methods[6] = {"set_rectangle", "oiiii", raw_types(t_ftl_rect[:])}
	ftl_handle_methods[7] = {"destroy", "", nil}
	ftl_handle_methods[8] = {"set_fullscreen", "2?o", raw_types(t_ftl_output[:])}
	ftl_handle_methods[9] = {"unset_fullscreen", "2", nil}
	ftl_handle_events[0] = {"title", "s", nil}
	ftl_handle_events[1] = {"app_id", "s", nil}
	ftl_handle_events[2] = {"output_enter", "o", raw_types(t_ftl_output[:])}
	ftl_handle_events[3] = {"output_leave", "o", raw_types(t_ftl_output[:])}
	ftl_handle_events[4] = {"state", "a", nil}
	ftl_handle_events[5] = {"done", "", nil}
	ftl_handle_events[6] = {"closed", "", nil}
	ftl_handle_events[7] = {"parent", "3?o", raw_types(t_ftl_parent[:])}
	ftl_handle_iface = {"zwlr_foreign_toplevel_handle_v1", 3, 10, &ftl_handle_methods[0], 8, &ftl_handle_events[0]}
}

@(private = "file")
Ftl_Manager_Listener :: struct {
	toplevel: proc "c" (data: rawptr, manager: Wl_Proxy, handle: Wl_Proxy),
	finished: proc "c" (data: rawptr, manager: Wl_Proxy),
}

@(private = "file")
Ftl_Handle_Listener :: struct {
	title:        proc "c" (data: rawptr, handle: Wl_Proxy, title: cstring),
	app_id:       proc "c" (data: rawptr, handle: Wl_Proxy, app_id: cstring),
	output_enter: proc "c" (data: rawptr, handle: Wl_Proxy, output: Wl_Proxy),
	output_leave: proc "c" (data: rawptr, handle: Wl_Proxy, output: Wl_Proxy),
	state:        proc "c" (data: rawptr, handle: Wl_Proxy, state: ^Wl_Array),
	done:         proc "c" (data: rawptr, handle: Wl_Proxy),
	closed:       proc "c" (data: rawptr, handle: Wl_Proxy),
	parent:       proc "c" (data: rawptr, handle: Wl_Proxy, parent: Wl_Proxy),
}

@(private) ftl_manager_listener := Ftl_Manager_Listener{ftl_toplevel, ftl_finished}
@(private = "file") ftl_handle_listener := Ftl_Handle_Listener{ftl_title, ftl_app_id, ftl_output, ftl_output, ftl_state, ftl_done, ftl_closed, ftl_parent}

// The connection's toplevel of a handle (nil: none).
@(private = "file")
ftl_of :: proc(handle: Wl_Proxy) -> ^Wl_Toplevel {
	for &t in wlc.toplevels { if t.handle == handle { return &t } }
	return nil
}

@(private = "file")
ftl_toplevel :: proc "c" (data: rawptr, manager: Wl_Proxy, handle: Wl_Proxy) {
	context = wl_ctx_real()
	wlc.toplevel_serial += 1
	append(&wlc.toplevels, Wl_Toplevel{handle = handle, id = wlc.toplevel_serial})
	wl.proxy_add_listener(handle, &ftl_handle_listener, nil)
}

@(private = "file")
ftl_finished :: proc "c" (data: rawptr, manager: Wl_Proxy) {
	context = wl_ctx_real()
	wl.proxy_destroy(manager)
	wlc.toplevel_manager = nil
}

@(private = "file")
ftl_title :: proc "c" (data: rawptr, handle: Wl_Proxy, title: cstring) {
	context = wl_ctx_real()
	if t := ftl_of(handle); t != nil {
		delete(t.title)
		t.title = strings.clone_from_cstring(title)
	}
}

@(private = "file")
ftl_app_id :: proc "c" (data: rawptr, handle: Wl_Proxy, app_id: cstring) {
	context = wl_ctx_real()
	if t := ftl_of(handle); t != nil {
		delete(t.app_id)
		t.app_id = strings.clone_from_cstring(app_id)
	}
}

@(private = "file")
ftl_output :: proc "c" (data: rawptr, handle: Wl_Proxy, output: Wl_Proxy) {}

@(private = "file")
ftl_state :: proc "c" (data: rawptr, handle: Wl_Proxy, state: ^Wl_Array) {
	context = wl_ctx_real()
	t := ftl_of(handle)
	if t == nil || state == nil { return }
	t.active, t.minimized = false, false
	values := ([^]u32)(state.data)[:state.size / size_of(u32)]
	for v in values {
		switch v {
		case FTL_STATE_ACTIVATED: t.active = true
		case FTL_STATE_MINIMIZED: t.minimized = true
		}
	}
}

@(private = "file")
ftl_done :: proc "c" (data: rawptr, handle: Wl_Proxy) {}

@(private = "file")
ftl_parent :: proc "c" (data: rawptr, handle: Wl_Proxy, parent: Wl_Proxy) {}

// The toplevel went: its handle is destroyed and it leaves the list.
@(private = "file")
ftl_closed :: proc "c" (data: rawptr, handle: Wl_Proxy) {
	context = wl_ctx_real()
	for t, i in wlc.toplevels {
		if t.handle != handle { continue }
		delete(t.title)
		delete(t.app_id)
		ordered_remove(&wlc.toplevels, i)
		break
	}
	wl.proxy_marshal_flags(handle, FTL_HANDLE_DESTROY, nil, wl.proxy_get_version(handle), WL_MARSHAL_FLAG_DESTROY)
}

// (toplevels_linux.odin) Asks the compositor to activate the toplevel `id`, with the seat.
@(private)
wl_toplevel_activate :: proc(id: u64) -> bool {
	if wlc.seat == nil { return false }
	for t in wlc.toplevels {
		if t.id != id || t.closed { continue }
		wl.proxy_marshal_flags(t.handle, FTL_HANDLE_ACTIVATE, nil, wl.proxy_get_version(t.handle), 0, wlc.seat)
		wl.display_flush(wlc.display)
		return true
	}
	return false
}
