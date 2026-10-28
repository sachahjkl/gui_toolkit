#+build linux
package platform

// The protocol pieces libwayland-client does not export: xdg-shell (xdg_wm_base, xdg_surface, xdg_toplevel) and the
// xdg-decoration manager. libwayland-client only ships the wl_* core interfaces as symbols; a protocol like xdg-shell
// is generated C in each client, so we build its wl_interface / wl_message tables here, by hand, matching the upstream
// xdg-shell.xml (stable). wl_proxy_marshal_flags reads these tables to pack a request: the signature string and the
// types array must match the protocol exactly, or the compositor drops the connection.
//
// Signatures (wayland-util.h): "i" int, "u" uint, "f" fixed, "s" string, "o" object, "n" new_id, "a" array, "h" fd,
// "?" nullable, a leading version number (e.g. "2") is the since-version. The `types` array has one entry per argument
// (nil for int/uint/string/fixed/fd/array; the interface for object/new_id).

// Opcodes we use (request index into each interface's methods, in xml order).
@(private) XDG_WM_BASE_DESTROY :: 0
@(private) XDG_WM_BASE_CREATE_POSITIONER :: 1
@(private) XDG_WM_BASE_GET_XDG_SURFACE :: 2
@(private) XDG_WM_BASE_PONG :: 3

@(private) XDG_SURFACE_DESTROY :: 0
@(private) XDG_SURFACE_GET_TOPLEVEL :: 1
@(private) XDG_SURFACE_GET_POPUP :: 2
@(private) XDG_SURFACE_SET_WINDOW_GEOMETRY :: 3
@(private) XDG_SURFACE_ACK_CONFIGURE :: 4

@(private) XDG_TOPLEVEL_DESTROY :: 0
@(private) XDG_TOPLEVEL_SET_PARENT :: 1
@(private) XDG_TOPLEVEL_SET_TITLE :: 2
@(private) XDG_TOPLEVEL_SET_APP_ID :: 3
@(private) XDG_TOPLEVEL_SHOW_WINDOW_MENU :: 4
@(private) XDG_TOPLEVEL_MOVE :: 5
@(private) XDG_TOPLEVEL_RESIZE :: 6
@(private) XDG_TOPLEVEL_SET_MAX_SIZE :: 7
@(private) XDG_TOPLEVEL_SET_MIN_SIZE :: 8
@(private) XDG_TOPLEVEL_SET_MAXIMIZED :: 9
@(private) XDG_TOPLEVEL_UNSET_MAXIMIZED :: 10
@(private) XDG_TOPLEVEL_SET_FULLSCREEN :: 11
@(private) XDG_TOPLEVEL_UNSET_FULLSCREEN :: 12
@(private) XDG_TOPLEVEL_SET_MINIMIZED :: 13

// event opcodes
@(private) XDG_WM_BASE_EV_PING :: 0
@(private) XDG_SURFACE_EV_CONFIGURE :: 0
@(private) XDG_TOPLEVEL_EV_CONFIGURE :: 0
@(private) XDG_TOPLEVEL_EV_CLOSE :: 1

// core wl opcodes we marshal (indices into the library's own interfaces)
@(private) WL_REGISTRY_BIND :: 0
@(private) WL_COMPOSITOR_CREATE_SURFACE :: 0
@(private) WL_COMPOSITOR_CREATE_REGION :: 1
@(private) WL_SURFACE_DESTROY :: 0
@(private) WL_SURFACE_ATTACH :: 1
@(private) WL_SURFACE_FRAME :: 3
@(private) WL_SURFACE_SET_OPAQUE_REGION :: 4
@(private) WL_SURFACE_COMMIT :: 6
@(private) WL_SURFACE_SET_BUFFER_SCALE :: 8
@(private) WL_SEAT_GET_POINTER :: 0
@(private) WL_SEAT_GET_KEYBOARD :: 1
@(private) WL_SEAT_GET_TOUCH :: 2
@(private) WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE :: 0
@(private) WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE :: 1
@(private) WL_REGION_ADD :: 1

// xdg-decoration opcodes
@(private) ZXDG_DECORATION_MANAGER_GET_TOPLEVEL_DECORATION :: 1
@(private) ZXDG_TOPLEVEL_DECORATION_SET_MODE :: 1
@(private) ZXDG_TOPLEVEL_DECORATION_MODE_CLIENT_SIDE :: 1
@(private) ZXDG_TOPLEVEL_DECORATION_MODE_SERVER_SIDE :: 2

// The static interface tables for the protocols the library does not provide. They are built once (xdg_build_tables)
// because the `types` arrays reference the library's own wl_surface_interface etc., known only at run time.
@(private) xdg_wm_base_iface: Wl_Interface
@(private) xdg_surface_iface: Wl_Interface
@(private) xdg_toplevel_iface: Wl_Interface
@(private) zxdg_decoration_manager_iface: Wl_Interface
@(private) zxdg_toplevel_decoration_iface: Wl_Interface
@(private) xdg_positioner_iface: Wl_Interface

@(private) xdg_wm_base_methods: [4]Wl_Message
@(private) xdg_wm_base_events: [1]Wl_Message
@(private) xdg_surface_methods: [5]Wl_Message
@(private) xdg_surface_events: [1]Wl_Message
@(private) xdg_toplevel_methods: [14]Wl_Message
@(private) xdg_toplevel_events: [4]Wl_Message
@(private) zxdg_decoration_manager_methods: [2]Wl_Message
@(private) zxdg_toplevel_decoration_methods: [2]Wl_Message
@(private) zxdg_toplevel_decoration_events: [1]Wl_Message

// The types arrays (one pointer per argument). Built pointing at the right interfaces in xdg_build_tables.
@(private) t_get_xdg_surface: [2]^Wl_Interface
@(private) t_create_positioner: [1]^Wl_Interface
@(private) t_get_toplevel: [1]^Wl_Interface
@(private) t_get_popup: [3]^Wl_Interface
@(private) t_set_parent: [1]^Wl_Interface
@(private) t_tl_configure: [0]^Wl_Interface
@(private) t_get_toplevel_decoration: [2]^Wl_Interface
@(private) t_nil3: [3]^Wl_Interface

@(private) xdg_tables_built: bool

@(private)
xdg_build_tables :: proc() {
	if xdg_tables_built { return }
	xdg_tables_built = true

	// xdg_wm_base
	xdg_wm_base_methods[0] = {"destroy", "", nil}
	t_create_positioner[0] = &xdg_positioner_iface
	xdg_wm_base_methods[1] = {"create_positioner", "n", raw_types(t_create_positioner[:])}
	t_get_xdg_surface[0] = &xdg_surface_iface
	t_get_xdg_surface[1] = wl.surface_interface
	xdg_wm_base_methods[2] = {"get_xdg_surface", "no", raw_types(t_get_xdg_surface[:])}
	xdg_wm_base_methods[3] = {"pong", "u", nil}
	xdg_wm_base_events[0] = {"ping", "u", nil}
	xdg_wm_base_iface = {"xdg_wm_base", 6, 4, &xdg_wm_base_methods[0], 1, &xdg_wm_base_events[0]}

	// xdg_positioner (only enough to exist for the types reference; we never create one)
	xdg_positioner_iface = {"xdg_positioner", 6, 0, nil, 0, nil}

	// xdg_surface
	xdg_surface_methods[0] = {"destroy", "", nil}
	t_get_toplevel[0] = &xdg_toplevel_iface
	xdg_surface_methods[1] = {"get_toplevel", "n", raw_types(t_get_toplevel[:])}
	t_get_popup[0] = &xdg_toplevel_iface   // (we never call get_popup; a valid non-nil pointer keeps the table sound)
	t_get_popup[1] = &xdg_surface_iface
	t_get_popup[2] = &xdg_positioner_iface
	xdg_surface_methods[2] = {"get_popup", "n?oo", raw_types(t_get_popup[:])}
	xdg_surface_methods[3] = {"set_window_geometry", "iiii", nil}
	xdg_surface_methods[4] = {"ack_configure", "u", nil}
	xdg_surface_events[0] = {"configure", "u", nil}
	xdg_surface_iface = {"xdg_surface", 6, 5, &xdg_surface_methods[0], 1, &xdg_surface_events[0]}

	// xdg_toplevel
	xdg_toplevel_methods[0] = {"destroy", "", nil}
	t_set_parent[0] = &xdg_toplevel_iface
	xdg_toplevel_methods[1] = {"set_parent", "?o", raw_types(t_set_parent[:])}
	xdg_toplevel_methods[2] = {"set_title", "s", nil}
	xdg_toplevel_methods[3] = {"set_app_id", "s", nil}
	xdg_toplevel_methods[4] = {"show_window_menu", "ouii", raw_types(t_show_menu_types())}
	xdg_toplevel_methods[5] = {"move", "ou", raw_types(t_move_types())}
	xdg_toplevel_methods[6] = {"resize", "ouu", raw_types(t_resize_types())}
	xdg_toplevel_methods[7] = {"set_max_size", "ii", nil}
	xdg_toplevel_methods[8] = {"set_min_size", "ii", nil}
	xdg_toplevel_methods[9] = {"set_maximized", "", nil}
	xdg_toplevel_methods[10] = {"unset_maximized", "", nil}
	xdg_toplevel_methods[11] = {"set_fullscreen", "?o", raw_types(t_fullscreen_types())}
	xdg_toplevel_methods[12] = {"unset_fullscreen", "", nil}
	xdg_toplevel_methods[13] = {"set_minimized", "", nil}
	xdg_toplevel_events[0] = {"configure", "iia", nil}
	xdg_toplevel_events[1] = {"close", "", nil}
	xdg_toplevel_events[2] = {"configure_bounds", "ii", nil}
	xdg_toplevel_events[3] = {"wm_capabilities", "a", nil}
	xdg_toplevel_iface = {"xdg_toplevel", 6, 14, &xdg_toplevel_methods[0], 4, &xdg_toplevel_events[0]}

	// zxdg_decoration_manager_v1
	zxdg_decoration_manager_methods[0] = {"destroy", "", nil}
	t_get_toplevel_decoration[0] = &zxdg_toplevel_decoration_iface
	t_get_toplevel_decoration[1] = &xdg_toplevel_iface
	zxdg_decoration_manager_methods[1] = {"get_toplevel_decoration", "no", raw_types(t_get_toplevel_decoration[:])}
	zxdg_decoration_manager_iface = {"zxdg_decoration_manager_v1", 1, 2, &zxdg_decoration_manager_methods[0], 0, nil}

	zxdg_toplevel_decoration_methods[0] = {"destroy", "", nil}
	zxdg_toplevel_decoration_methods[1] = {"set_mode", "u", nil}
	zxdg_toplevel_decoration_events[0] = {"configure", "u", nil}
	zxdg_toplevel_decoration_iface = {"zxdg_toplevel_decoration_v1", 1, 2, &zxdg_toplevel_decoration_methods[0], 1, &zxdg_toplevel_decoration_events[0]}
}

// Small helpers returning a stable pointer to a types array with the seat interface at [0] (the first arg of
// show_window_menu / move / resize is the seat object).
@(private) t_seat1: [4]^Wl_Interface
@(private) t_seat_move: [2]^Wl_Interface
@(private) t_seat_resize: [3]^Wl_Interface
@(private) t_output_opt: [1]^Wl_Interface

@(private)
t_show_menu_types :: proc() -> []^Wl_Interface { t_seat1[0] = wl.seat_interface; return t_seat1[:] }
@(private)
t_move_types :: proc() -> []^Wl_Interface { t_seat_move[0] = wl.seat_interface; return t_seat_move[:] }
@(private)
t_resize_types :: proc() -> []^Wl_Interface { t_seat_resize[0] = wl.seat_interface; return t_seat_resize[:] }
@(private)
t_fullscreen_types :: proc() -> []^Wl_Interface { t_output_opt[0] = wl.output_interface; return t_output_opt[:] }

@(private)
raw_types :: proc(s: []^Wl_Interface) -> [^]^Wl_Interface { return len(s) > 0 ? ([^]^Wl_Interface)(&s[0]) : nil }
