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
@(private) ZXDG_TOPLEVEL_DECORATION_DESTROY :: 0
@(private) WL_SURFACE_ATTACH :: 1
@(private) WL_SURFACE_FRAME :: 3
@(private) WL_SURFACE_SET_OPAQUE_REGION :: 4
@(private) WL_SURFACE_COMMIT :: 6
@(private) WL_SURFACE_SET_BUFFER_SCALE :: 8
@(private) WL_SEAT_GET_POINTER :: 0
@(private) WL_SEAT_GET_KEYBOARD :: 1
@(private) WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE :: 0
@(private) WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE :: 1
@(private) WL_REGION_ADD :: 1

// wl_data_source requests (wayland.xml): offer, destroy, set_actions. Events: target, send, cancelled,
// dnd_drop_performed, dnd_finished, action.
@(private) WL_DATA_SOURCE_OFFER :: 0
@(private) WL_DATA_SOURCE_DESTROY :: 1
@(private) WL_DATA_SOURCE_SET_ACTIONS :: 2
// wl_data_offer requests: accept, receive, destroy, finish, set_actions.
@(private) WL_DATA_OFFER_ACCEPT :: 0
@(private) WL_DATA_OFFER_RECEIVE :: 1
@(private) WL_DATA_OFFER_DESTROY :: 2
@(private) WL_DATA_OFFER_FINISH :: 3
@(private) WL_DATA_OFFER_SET_ACTIONS :: 4
// wl_data_device requests: start_drag, set_selection, release.
@(private) WL_DATA_DEVICE_START_DRAG :: 0
@(private) WL_DATA_DEVICE_SET_SELECTION :: 1
@(private) WL_DATA_DEVICE_RELEASE :: 2
// wl_data_device_manager.dnd_action bitmask.
@(private) WL_DND_ACTION_NONE :: 0
@(private) WL_DND_ACTION_COPY :: 1
@(private) WL_DND_ACTION_MOVE :: 2
@(private) WL_DND_ACTION_ASK :: 4

// xdg-decoration opcodes
@(private) ZXDG_DECORATION_MANAGER_GET_TOPLEVEL_DECORATION :: 1
@(private) ZXDG_TOPLEVEL_DECORATION_SET_MODE :: 1
@(private) ZXDG_TOPLEVEL_DECORATION_MODE_CLIENT_SIDE :: 1
@(private) ZXDG_TOPLEVEL_DECORATION_MODE_SERVER_SIDE :: 2

// zwp_text_input_v3 (the IME protocol): the manager makes a text-input per seat; enable / set_cursor_rectangle /
// commit are requests, preedit_string / commit_string / done are events. Not shipped by libwayland; tables by hand.
@(private) ZWP_TI_MANAGER_DESTROY :: 0
@(private) ZWP_TI_MANAGER_GET_TEXT_INPUT :: 1
@(private) ZWP_TI_DESTROY :: 0
@(private) ZWP_TI_ENABLE :: 1
@(private) ZWP_TI_DISABLE :: 2
@(private) ZWP_TI_SET_SURROUNDING_TEXT :: 3
@(private) ZWP_TI_SET_TEXT_CHANGE_CAUSE :: 4
@(private) ZWP_TI_SET_CONTENT_TYPE :: 5
@(private) ZWP_TI_SET_CURSOR_RECTANGLE :: 6
@(private) ZWP_TI_COMMIT :: 7

@(private) zwp_ti_manager_iface: Wl_Interface
@(private) zwp_ti_iface: Wl_Interface
@(private) zwp_ti_manager_methods: [2]Wl_Message
@(private) zwp_ti_methods: [8]Wl_Message
@(private) zwp_ti_events: [6]Wl_Message
@(private) t_ti_get: [2]^Wl_Interface

@(private)
zwp_ti_build_tables :: proc() {
	zwp_ti_manager_methods[0] = {"destroy", "", nil}
	t_ti_get[0] = &zwp_ti_iface
	t_ti_get[1] = wl.seat_interface
	zwp_ti_manager_methods[1] = {"get_text_input", "no", raw_types(t_ti_get[:])}
	zwp_ti_manager_iface = {"zwp_text_input_manager_v3", 1, 2, &zwp_ti_manager_methods[0], 0, nil}

	zwp_ti_methods[0] = {"destroy", "", nil}
	zwp_ti_methods[1] = {"enable", "", nil}
	zwp_ti_methods[2] = {"disable", "", nil}
	zwp_ti_methods[3] = {"set_surrounding_text", "sii", nil}
	zwp_ti_methods[4] = {"set_text_change_cause", "u", nil}
	zwp_ti_methods[5] = {"set_content_type", "uu", nil}
	zwp_ti_methods[6] = {"set_cursor_rectangle", "iiii", nil}
	zwp_ti_methods[7] = {"commit", "", nil}
	zwp_ti_events[0] = {"enter", "o", raw_types(t_ti_enter_types())}
	zwp_ti_events[1] = {"leave", "o", raw_types(t_ti_enter_types())}
	zwp_ti_events[2] = {"preedit_string", "?sii", nil}
	zwp_ti_events[3] = {"commit_string", "?s", nil}
	zwp_ti_events[4] = {"delete_surrounding_text", "uu", nil}
	zwp_ti_events[5] = {"done", "u", nil}
	zwp_ti_iface = {"zwp_text_input_v3", 1, 8, &zwp_ti_methods[0], 6, &zwp_ti_events[0]}
}

@(private) t_ti_surface: [1]^Wl_Interface
@(private)
t_ti_enter_types :: proc() -> []^Wl_Interface { t_ti_surface[0] = wl.surface_interface; return t_ti_surface[:] }

// wp_cursor_shape_v1: the compositor-drawn pointer shapes (so the toolkit never uploads cursor pixels). The manager
// makes a device from a wl_pointer; set_shape(serial, shape) names one of the CSS-like shapes. Tables by hand.
@(private) WP_CURSOR_SHAPE_MANAGER_DESTROY :: 0
@(private) WP_CURSOR_SHAPE_MANAGER_GET_POINTER :: 1
@(private) WP_CURSOR_SHAPE_DEVICE_DESTROY :: 0
@(private) WP_CURSOR_SHAPE_DEVICE_SET_SHAPE :: 1

@(private) wp_cursor_shape_manager_iface: Wl_Interface
@(private) wp_cursor_shape_device_iface: Wl_Interface
@(private) wp_csm_methods: [2]Wl_Message
@(private) wp_csd_methods: [2]Wl_Message
@(private) t_csm_get_pointer: [2]^Wl_Interface

@(private)
wp_cursor_shape_build_tables :: proc() {
	wp_csm_methods[0] = {"destroy", "", nil}
	t_csm_get_pointer[0] = &wp_cursor_shape_device_iface
	t_csm_get_pointer[1] = wl.pointer_interface
	wp_csm_methods[1] = {"get_pointer", "no", raw_types(t_csm_get_pointer[:])}
	wp_cursor_shape_manager_iface = {"wp_cursor_shape_manager_v1", 1, 2, &wp_csm_methods[0], 0, nil}
	wp_csd_methods[0] = {"destroy", "", nil}
	wp_csd_methods[1] = {"set_shape", "uu", nil}
	wp_cursor_shape_device_iface = {"wp_cursor_shape_device_v1", 1, 2, &wp_csd_methods[0], 0, nil}
}

// wp_fractional_scale_v1 (the scale the compositor would like the surface drawn at, in 120ths) and wp_viewporter (the
// surface's size on the output, whatever its buffer's).
@(private) WP_FRACTIONAL_MANAGER_GET :: 1
@(private) WP_VIEWPORTER_GET_VIEWPORT :: 1
@(private) WP_FRACTIONAL_DESTROY :: 0
@(private) WP_VIEWPORT_DESTROY :: 0
@(private) WP_VIEWPORT_SET_DESTINATION :: 2
@(private) wp_fractional_manager_iface: Wl_Interface
@(private) wp_fractional_iface: Wl_Interface
@(private) wp_viewporter_iface: Wl_Interface
@(private) wp_viewport_iface: Wl_Interface
@(private = "file") wp_fm_methods: [2]Wl_Message
@(private = "file") wp_f_methods: [1]Wl_Message
@(private = "file") wp_f_events: [1]Wl_Message
@(private = "file") wp_vr_methods: [2]Wl_Message
@(private = "file") wp_v_methods: [3]Wl_Message
@(private = "file") t_fm_get: [2]^Wl_Interface
@(private = "file") t_vr_get: [2]^Wl_Interface

@(private)
wp_scale_build_tables :: proc() {
	wp_fm_methods[0] = {"destroy", "", nil}
	t_fm_get[0], t_fm_get[1] = &wp_fractional_iface, wl.surface_interface
	wp_fm_methods[1] = {"get_fractional_scale", "no", raw_types(t_fm_get[:])}
	wp_fractional_manager_iface = {"wp_fractional_scale_manager_v1", 1, 2, &wp_fm_methods[0], 0, nil}
	wp_f_methods[0] = {"destroy", "", nil}
	wp_f_events[0] = {"preferred_scale", "u", nil}
	wp_fractional_iface = {"wp_fractional_scale_v1", 1, 1, &wp_f_methods[0], 1, &wp_f_events[0]}
	wp_vr_methods[0] = {"destroy", "", nil}
	t_vr_get[0], t_vr_get[1] = &wp_viewport_iface, wl.surface_interface
	wp_vr_methods[1] = {"get_viewport", "no", raw_types(t_vr_get[:])}
	wp_viewporter_iface = {"wp_viewporter", 1, 2, &wp_vr_methods[0], 0, nil}
	wp_v_methods[0] = {"destroy", "", nil}
	wp_v_methods[1] = {"set_source", "ffff", nil}
	wp_v_methods[2] = {"set_destination", "ii", nil}
	wp_viewport_iface = {"wp_viewport", 1, 3, &wp_v_methods[0], 0, nil}
}

// xdg_activation_v1: a client asks the compositor to give a surface the focus. A token names the request (a serial of
// the seat's input, the surface); `done` gives the token, which `activate` spends on a surface.
@(private) XDG_ACTIVATION_GET_TOKEN :: 1
@(private) XDG_ACTIVATION_ACTIVATE :: 2
@(private) XDG_ACTIVATION_TOKEN_SET_SERIAL :: 0
@(private) XDG_ACTIVATION_TOKEN_SET_SURFACE :: 2
@(private) XDG_ACTIVATION_TOKEN_COMMIT :: 3
@(private) XDG_ACTIVATION_TOKEN_DESTROY :: 4
@(private) xdg_activation_iface: Wl_Interface
@(private) xdg_activation_token_iface: Wl_Interface
@(private = "file") xa_methods: [3]Wl_Message
@(private = "file") xat_methods: [5]Wl_Message
@(private = "file") xat_events: [1]Wl_Message
@(private = "file") t_xa_get: [1]^Wl_Interface
@(private = "file") t_xa_activate: [2]^Wl_Interface
@(private = "file") t_xat_serial: [2]^Wl_Interface
@(private = "file") t_xat_surface: [1]^Wl_Interface

@(private)
xdg_activation_build_tables :: proc() {
	xa_methods[0] = {"destroy", "", nil}
	t_xa_get[0] = &xdg_activation_token_iface
	xa_methods[1] = {"get_activation_token", "n", raw_types(t_xa_get[:])}
	t_xa_activate[0], t_xa_activate[1] = nil, wl.surface_interface
	xa_methods[2] = {"activate", "so", raw_types(t_xa_activate[:])}
	xdg_activation_iface = {"xdg_activation_v1", 1, 3, &xa_methods[0], 0, nil}
	t_xat_serial[0], t_xat_serial[1] = nil, wl.seat_interface
	xat_methods[0] = {"set_serial", "uo", raw_types(t_xat_serial[:])}
	xat_methods[1] = {"set_app_id", "s", nil}
	t_xat_surface[0] = wl.surface_interface
	xat_methods[2] = {"set_surface", "o", raw_types(t_xat_surface[:])}
	xat_methods[3] = {"commit", "", nil}
	xat_methods[4] = {"destroy", "", nil}
	xat_events[0] = {"done", "s", nil}
	xdg_activation_token_iface = {"xdg_activation_token_v1", 1, 5, &xat_methods[0], 1, &xat_events[0]}
}

// The static interface tables for the protocols the library does not provide. They are built once (wayland_lib)
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


@(private)
xdg_build_tables :: proc() {

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
