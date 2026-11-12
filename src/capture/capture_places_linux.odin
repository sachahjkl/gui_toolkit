#+build linux
package capture

// Where the windows are, from the Wayland protocols of the compositors that say it (the standard protocols do not):
//
//   zcosmic_toplevel_info_v1 (version 2 or more: COSMIC, ShojiWM)
//       for each window of ext_foreign_toplevel_list_v1: its rect on each output it is on, its states (minimized,
//       activated), and with ext_workspace_v1 (version 3) the workspaces it is on.
//   org_kde_plasma_window_management (version 13 or more: KWin)
//       every window: its rect on the desktop, its states, its virtual desktops, and the stacking order. KWin gives this
//       global only to a program whose .desktop file names it (X-KDE-Wayland-Interfaces=org_kde_plasma_window_management).
//
// A window is shown when it is not minimized and one of its workspaces (virtual desktops) is active, or when the
// compositor does not say its workspaces. COSMIC does not say the stacking order: the activated window is first, then the
// most recent first.
//
// The tables are written by hand from the XML (cosmic-protocols' cosmic-toplevel-info-unstable-v1 version 3,
// wayland-protocols' ext-workspace-v1 version 1, plasma-wayland-protocols' plasma-window-management version 16 and
// org-kde-plasma-virtual-desktop version 1), as capture_wl_linux.odin does for the others.

import "base:runtime"
import "core:strings"
import "wm"

@(private = "file") FLAG_DESTROY :: 1   // WL_MARSHAL_FLAG_DESTROY

// Request opcodes, in the XML's order.
@(private = "file") COSMIC_INFO_GET_TOPLEVEL :: 1
@(private = "file") COSMIC_HANDLE_DESTROY :: 0
@(private = "file") WS_GROUP_DESTROY :: 1
@(private = "file") WS_DESTROY :: 0
@(private = "file") KDE_WM_GET_WINDOW_BY_UUID :: 2
@(private = "file") KDE_VD_MANAGER_GET :: 0

// Enum values.
@(private = "file") COSMIC_STATE_MINIMIZED :: 1
@(private = "file") COSMIC_STATE_ACTIVATED :: 2
@(private = "file") WS_STATE_ACTIVE :: 1
@(private = "file") KDE_STATE_MINIMIZED :: 0x2
@(private = "file") KDE_STATE_ON_ALL_DESKTOPS :: 0x40

// The versions asked for. COSMIC's get_cosmic_toplevel and geometry come in 2; KDE's window_with_uuid in 13, and 17
// replaces the stacking order's string with an object this backend does not read.
@(private = "file") COSMIC_VERSION_MIN :: 2
@(private = "file") COSMIC_VERSION :: 3
@(private = "file") WS_VERSION :: 1
@(private = "file") KDE_WM_VERSION_MIN :: 13
@(private = "file") KDE_WM_VERSION :: 16
@(private = "file") KDE_VD_VERSION :: 1

// The places a window can be on at once (outputs, workspaces): more are not kept.
@(private = "file") MAX_PLACES :: 4

@(private)
Places :: struct {
	tables:     Places_Tables,
	listeners:  Places_Listeners,
	cosmic:     Wl_Proxy,   // zcosmic_toplevel_info_v1
	ws_manager: Wl_Proxy,   // ext_workspace_manager_v1
	groups:     [dynamic]Wl_Proxy,
	workspaces: [dynamic]^Places_Workspace,
	kde:        Wl_Proxy,   // org_kde_plasma_window_management
	kde_windows: [dynamic]^Kde_Window,
	kde_serial: u64,
	kde_stacking: string,   // the uuids, ';' between them, bottom to top
	kde_vd:     Wl_Proxy,   // org_kde_plasma_virtual_desktop_management
	kde_desktops: [dynamic]^Kde_Desktop,
}

// A workspace (ext_workspace_v1) or a virtual desktop (KDE): whether it is shown.
@(private)
Places_Workspace :: struct {
	st:     ^Wl_State,
	proxy:  Wl_Proxy,
	active: bool,
}

@(private)
Cosmic_Place :: struct {
	output: Wl_Proxy,   // the wl_output the rect is relative to
	rect:   Rect,
}

// A window's zcosmic_toplevel_handle_v1, beside its ext_foreign_toplevel_handle_v1 (Wl_Toplevel.cosmic).
@(private)
Cosmic_Toplevel :: struct {
	st:         ^Wl_State,
	proxy:      Wl_Proxy,
	places:     [MAX_PLACES]Cosmic_Place,
	place_count: int,
	workspaces: [MAX_PLACES]Wl_Proxy,
	ws_count:   int,
	minimized:  bool,
	activated:  bool,
}

@(private)
Kde_Window :: struct {
	st:       ^Wl_State,
	proxy:    Wl_Proxy,
	id:       u64,
	uuid:     string,   // (the session's allocator, as the strings below)
	title:    string,
	app_id:   string,
	rect:     Rect,
	has_rect: bool,
	state:    u32,
	desktops: [MAX_PLACES]string,
	desktop_count: int,
}

@(private)
Kde_Desktop :: struct {
	st:     ^Wl_State,
	proxy:  Wl_Proxy,
	id:     string,
	active: bool,
}

@(private)
Places_Tables :: struct {
	cosmic_info, cosmic_handle: Wl_Interface,
	ws_manager, ws_group, ws: Wl_Interface,
	kde_wm, kde_window, kde_vd_manager, kde_vd: Wl_Interface,

	ci_methods: [2]Wl_Message,
	ci_events: [3]Wl_Message,
	ch_methods: [1]Wl_Message,
	ch_events: [12]Wl_Message,
	wm_methods: [2]Wl_Message,
	wm_events: [4]Wl_Message,
	wg_methods: [2]Wl_Message,
	wg_events: [6]Wl_Message,
	ws_methods: [5]Wl_Message,
	ws_events: [6]Wl_Message,
	kw_methods: [3]Wl_Message,
	kw_events: [6]Wl_Message,
	kwin_methods: [9]Wl_Message,
	kwin_events: [19]Wl_Message,
	vm_methods: [3]Wl_Message,
	vm_events: [4]Wl_Message,
	vd_methods: [2]Wl_Message,
	vd_events: [8]Wl_Message,

	t_ci_toplevel: [1]^Wl_Interface,
	t_ci_get: [2]^Wl_Interface,
	t_output: [1]^Wl_Interface,
	t_ch_geometry: [5]^Wl_Interface,
	t_ws: [1]^Wl_Interface,
	t_ws_group: [1]^Wl_Interface,
	t_kw_get: [2]^Wl_Interface,
	t_kwin: [1]^Wl_Interface,
	t_vm_get: [2]^Wl_Interface,
	t_none: [5]^Wl_Interface,
}

@(private)
Places_Listeners :: struct {
	cosmic_info: struct {
		toplevel: proc "c" (data: rawptr, p: Wl_Proxy, handle: Wl_Proxy),
		finished: proc "c" (data: rawptr, p: Wl_Proxy),
		done:     proc "c" (data: rawptr, p: Wl_Proxy),
	},
	cosmic_handle: struct {
		closed:              proc "c" (data: rawptr, p: Wl_Proxy),
		done:                proc "c" (data: rawptr, p: Wl_Proxy),
		title:               proc "c" (data: rawptr, p: Wl_Proxy, s: cstring),
		app_id:              proc "c" (data: rawptr, p: Wl_Proxy, s: cstring),
		output_enter:        proc "c" (data: rawptr, p: Wl_Proxy, output: Wl_Proxy),
		output_leave:        proc "c" (data: rawptr, p: Wl_Proxy, output: Wl_Proxy),
		workspace_enter:     proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy),
		workspace_leave:     proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy),
		state:               proc "c" (data: rawptr, p: Wl_Proxy, state: ^Wl_Array),
		geometry:            proc "c" (data: rawptr, p: Wl_Proxy, output: Wl_Proxy, x, y, w, h: i32),
		ext_workspace_enter: proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy),
		ext_workspace_leave: proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy),
	},
	ws_manager: struct {
		workspace_group: proc "c" (data: rawptr, p: Wl_Proxy, group: Wl_Proxy),
		workspace:       proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy),
		done:            proc "c" (data: rawptr, p: Wl_Proxy),
		finished:        proc "c" (data: rawptr, p: Wl_Proxy),
	},
	ws_group: struct {
		capabilities:    proc "c" (data: rawptr, p: Wl_Proxy, caps: u32),
		output_enter:    proc "c" (data: rawptr, p: Wl_Proxy, output: Wl_Proxy),
		output_leave:    proc "c" (data: rawptr, p: Wl_Proxy, output: Wl_Proxy),
		workspace_enter: proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy),
		workspace_leave: proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy),
		removed:         proc "c" (data: rawptr, p: Wl_Proxy),
	},
	ws: struct {
		id:           proc "c" (data: rawptr, p: Wl_Proxy, s: cstring),
		name:         proc "c" (data: rawptr, p: Wl_Proxy, s: cstring),
		coordinates:  proc "c" (data: rawptr, p: Wl_Proxy, a: ^Wl_Array),
		state:        proc "c" (data: rawptr, p: Wl_Proxy, state: u32),
		capabilities: proc "c" (data: rawptr, p: Wl_Proxy, caps: u32),
		removed:      proc "c" (data: rawptr, p: Wl_Proxy),
	},
	kde_wm: struct {
		show_desktop_changed:        proc "c" (data: rawptr, p: Wl_Proxy, state: u32),
		window:                      proc "c" (data: rawptr, p: Wl_Proxy, id: u32),
		stacking_order_changed:      proc "c" (data: rawptr, p: Wl_Proxy, ids: ^Wl_Array),
		stacking_order_uuid_changed: proc "c" (data: rawptr, p: Wl_Proxy, uuids: cstring),
		window_with_uuid:            proc "c" (data: rawptr, p: Wl_Proxy, id: u32, uuid: cstring),
		stacking_order_changed_2:    proc "c" (data: rawptr, p: Wl_Proxy),
	},
	kde_window: struct {
		title_changed:            proc "c" (data: rawptr, p: Wl_Proxy, s: cstring),
		app_id_changed:           proc "c" (data: rawptr, p: Wl_Proxy, s: cstring),
		state_changed:            proc "c" (data: rawptr, p: Wl_Proxy, flags: u32),
		virtual_desktop_changed:  proc "c" (data: rawptr, p: Wl_Proxy, n: i32),
		themed_icon_name_changed: proc "c" (data: rawptr, p: Wl_Proxy, s: cstring),
		unmapped:                 proc "c" (data: rawptr, p: Wl_Proxy),
		initial_state:            proc "c" (data: rawptr, p: Wl_Proxy),
		parent_window:            proc "c" (data: rawptr, p: Wl_Proxy, parent: Wl_Proxy),
		geometry:                 proc "c" (data: rawptr, p: Wl_Proxy, x, y: i32, w, h: u32),
		icon_changed:             proc "c" (data: rawptr, p: Wl_Proxy),
		pid_changed:              proc "c" (data: rawptr, p: Wl_Proxy, pid: u32),
		virtual_desktop_entered:  proc "c" (data: rawptr, p: Wl_Proxy, id: cstring),
		virtual_desktop_left:     proc "c" (data: rawptr, p: Wl_Proxy, id: cstring),
		application_menu:         proc "c" (data: rawptr, p: Wl_Proxy, service, path: cstring),
		activity_entered:         proc "c" (data: rawptr, p: Wl_Proxy, id: cstring),
		activity_left:            proc "c" (data: rawptr, p: Wl_Proxy, id: cstring),
		resource_name_changed:    proc "c" (data: rawptr, p: Wl_Proxy, s: cstring),
		client_geometry:          proc "c" (data: rawptr, p: Wl_Proxy, x, y: i32, w, h: u32),
		mapped:                   proc "c" (data: rawptr, p: Wl_Proxy),
	},
	kde_vd_manager: struct {
		desktop_created: proc "c" (data: rawptr, p: Wl_Proxy, id: cstring, position: u32),
		desktop_removed: proc "c" (data: rawptr, p: Wl_Proxy, id: cstring),
		done:            proc "c" (data: rawptr, p: Wl_Proxy),
		rows:            proc "c" (data: rawptr, p: Wl_Proxy, rows: u32),
	},
	kde_vd: struct {
		desktop_id:     proc "c" (data: rawptr, p: Wl_Proxy, id: cstring),
		name:           proc "c" (data: rawptr, p: Wl_Proxy, name: cstring),
		activated:      proc "c" (data: rawptr, p: Wl_Proxy),
		deactivated:    proc "c" (data: rawptr, p: Wl_Proxy),
		done:           proc "c" (data: rawptr, p: Wl_Proxy),
		removed:        proc "c" (data: rawptr, p: Wl_Proxy),
		position:       proc "c" (data: rawptr, p: Wl_Proxy, index: u32),
		output_entered: proc "c" (data: rawptr, p: Wl_Proxy, name: cstring),
	},
}

@(private = "file")
ctx :: proc "contextless" () -> runtime.Context { return runtime.default_context() }

////////////////////////////////
// setting up and closing

// The tables and the listeners: before the registry is read (capture_wl_linux.odin's wl_open).
@(private)
places_init :: proc(st: ^Wl_State) {
	pl := &st.places
	pl.groups.allocator = st.allocator
	pl.workspaces.allocator = st.allocator
	pl.kde_windows.allocator = st.allocator
	pl.kde_desktops.allocator = st.allocator
	t := &pl.tables
	none := types(t.t_none[:])
	t.t_output = {st.lib.output_interface}

	// cosmic-toplevel-info-unstable-v1, version 3
	t.t_ci_toplevel = {&t.cosmic_handle}
	t.t_ci_get = {&t.cosmic_handle, &st.tables.toplevel_handle}
	t.ci_methods = {{"stop", "", nil}, {"get_cosmic_toplevel", "2no", types(t.t_ci_get[:])}}
	t.ci_events = {{"toplevel", "n", types(t.t_ci_toplevel[:])}, {"finished", "", nil}, {"done", "2", nil}}
	t.cosmic_info = {"zcosmic_toplevel_info_v1", COSMIC_VERSION, 2, &t.ci_methods[0], 3, &t.ci_events[0]}
	t.t_ch_geometry = {st.lib.output_interface, nil, nil, nil, nil}
	t.t_ws = {&t.ws}
	t.ch_methods = {{"destroy", "", nil}}
	t.ch_events = {
		{"closed", "", nil}, {"done", "", nil}, {"title", "s", none}, {"app_id", "s", none},
		{"output_enter", "o", types(t.t_output[:])}, {"output_leave", "o", types(t.t_output[:])},
		{"workspace_enter", "o", none}, {"workspace_leave", "o", none},   // (zcosmic_workspace_handle_v1: never bound here)
		{"state", "a", none}, {"geometry", "2oiiii", types(t.t_ch_geometry[:])},
		{"ext_workspace_enter", "3o", types(t.t_ws[:])}, {"ext_workspace_leave", "3o", types(t.t_ws[:])},
	}
	t.cosmic_handle = {"zcosmic_toplevel_handle_v1", COSMIC_VERSION, 1, &t.ch_methods[0], 12, &t.ch_events[0]}

	// ext-workspace-v1, version 1
	t.t_ws_group = {&t.ws_group}
	t.wm_methods = {{"commit", "", nil}, {"stop", "", nil}}
	t.wm_events = {{"workspace_group", "n", types(t.t_ws_group[:])}, {"workspace", "n", types(t.t_ws[:])}, {"done", "", nil}, {"finished", "", nil}}
	t.ws_manager = {"ext_workspace_manager_v1", WS_VERSION, 2, &t.wm_methods[0], 4, &t.wm_events[0]}
	t.wg_methods = {{"create_workspace", "s", none}, {"destroy", "", nil}}
	t.wg_events = {
		{"capabilities", "u", none}, {"output_enter", "o", types(t.t_output[:])}, {"output_leave", "o", types(t.t_output[:])},
		{"workspace_enter", "o", types(t.t_ws[:])}, {"workspace_leave", "o", types(t.t_ws[:])}, {"removed", "", nil},
	}
	t.ws_group = {"ext_workspace_group_handle_v1", WS_VERSION, 2, &t.wg_methods[0], 6, &t.wg_events[0]}
	t.ws_methods = {{"destroy", "", nil}, {"activate", "", nil}, {"deactivate", "", nil}, {"assign", "o", types(t.t_ws_group[:])}, {"remove", "", nil}}
	t.ws_events = {{"id", "s", none}, {"name", "s", none}, {"coordinates", "a", none}, {"state", "u", none}, {"capabilities", "u", none}, {"removed", "", nil}}
	t.ws = {"ext_workspace_handle_v1", WS_VERSION, 5, &t.ws_methods[0], 6, &t.ws_events[0]}

	// plasma-window-management, version 16
	t.t_kw_get = {&t.kde_window, nil}
	t.t_kwin = {&t.kde_window}
	t.kw_methods = {{"show_desktop", "u", none}, {"get_window", "nu", types(t.t_kw_get[:])}, {"get_window_by_uuid", "12ns", types(t.t_kw_get[:])}}
	t.kw_events = {
		{"show_desktop_changed", "u", none}, {"window", "u", none}, {"stacking_order_changed", "11a", none},
		{"stacking_order_uuid_changed", "12s", none}, {"window_with_uuid", "13us", none}, {"stacking_order_changed_2", "17", nil},
	}
	t.kde_wm = {"org_kde_plasma_window_management", KDE_WM_VERSION, 3, &t.kw_methods[0], 6, &t.kw_events[0]}
	t.kwin_methods = {
		{"set_state", "uu", none}, {"set_virtual_desktop", "u", none}, {"set_minimized_geometry", "ouuuu", none},
		{"unset_minimized_geometry", "o", none}, {"highlight", "", nil}, {"close", "", nil},
		{"request_move", "3", nil}, {"request_resize", "3", nil}, {"destroy", "4", nil},
	}
	t.kwin_events = {
		{"title_changed", "s", none}, {"app_id_changed", "s", none}, {"state_changed", "u", none},
		{"virtual_desktop_changed", "i", none}, {"themed_icon_name_changed", "s", none}, {"unmapped", "", nil},
		{"initial_state", "4", nil}, {"parent_window", "5?o", types(t.t_kwin[:])}, {"geometry", "6iiuu", none},
		{"icon_changed", "7", nil}, {"pid_changed", "8u", none}, {"virtual_desktop_entered", "8s", none},
		{"virtual_desktop_left", "8s", none}, {"application_menu", "10ss", none}, {"activity_entered", "14s", none},
		{"activity_left", "14s", none}, {"resource_name_changed", "16s", none}, {"client_geometry", "18iiuu", none},
		{"mapped", "21", nil},
	}
	t.kde_window = {"org_kde_plasma_window", KDE_WM_VERSION, 9, &t.kwin_methods[0], 19, &t.kwin_events[0]}

	// org-kde-plasma-virtual-desktop, version 1
	t.t_vm_get = {&t.kde_vd, nil}
	t.vm_methods = {{"get_virtual_desktop", "ns", types(t.t_vm_get[:])}, {"request_create_virtual_desktop", "su", none}, {"request_remove_virtual_desktop", "s", none}}
	t.vm_events = {{"desktop_created", "su", none}, {"desktop_removed", "s", none}, {"done", "", nil}, {"rows", "2u", none}}
	t.kde_vd_manager = {"org_kde_plasma_virtual_desktop_management", KDE_VD_VERSION, 3, &t.vm_methods[0], 4, &t.vm_events[0]}
	t.vd_methods = {{"request_activate", "", nil}, {"request_enter_output", "4s", none}}
	t.vd_events = {
		{"desktop_id", "s", none}, {"name", "s", none}, {"activated", "", nil}, {"deactivated", "", nil},
		{"done", "", nil}, {"removed", "", nil}, {"position", "3u", none}, {"output_entered", "4s", none},
	}
	t.kde_vd = {"org_kde_plasma_virtual_desktop", KDE_VD_VERSION, 2, &t.vd_methods[0], 8, &t.vd_events[0]}

	ls := &pl.listeners
	ls.cosmic_info = {cosmic_info_toplevel, cosmic_info_finished, cosmic_info_done}
	ls.cosmic_handle = {
		cosmic_closed, cosmic_done, cosmic_text, cosmic_text, cosmic_output, cosmic_output_leave, cosmic_output, cosmic_output,
		cosmic_state, cosmic_geometry, cosmic_ws_enter, cosmic_ws_leave,
	}
	ls.ws_manager = {ws_manager_group, ws_manager_workspace, ws_nothing, ws_manager_finished}
	ls.ws_group = {ws_group_caps, ws_group_object, ws_group_object, ws_group_object, ws_group_object, ws_group_removed}
	ls.ws = {ws_text, ws_text, ws_array, ws_state, ws_caps, ws_removed}
	ls.kde_wm = {kde_wm_u32, kde_wm_u32, kde_wm_array, kde_wm_stacking, kde_wm_window, kde_wm_nothing}
	ls.kde_window = {
		kde_title, kde_app_id, kde_state, kde_win_i32, kde_win_text, kde_unmapped, kde_win_nothing, kde_win_object,
		kde_geometry, kde_win_nothing, kde_win_u32, kde_desktop_entered, kde_desktop_left, kde_win_two_texts,
		kde_win_text, kde_win_text, kde_win_text, kde_win_geometry_ignored, kde_win_nothing,
	}
	ls.kde_vd_manager = {vd_created, vd_text, vd_nothing, vd_u32}
	ls.kde_vd = {vd_text, vd_text, vd_activated, vd_deactivated, vd_nothing, vd_removed, vd_u32, vd_text}
}

// A global of the registry this file binds. False: not one of its.
@(private)
places_global :: proc(st: ^Wl_State, name: u32, iface: string, version: u32) -> bool {
	pl := &st.places
	t := &pl.tables
	l := &st.lib
	switch iface {
	case "zcosmic_toplevel_info_v1":
		if version < COSMIC_VERSION_MIN || pl.cosmic != nil { return true }
		pl.cosmic = wl_bind(st, name, &t.cosmic_info, COSMIC_VERSION, version)
		if pl.cosmic == nil { return true }
		l.proxy_add_listener(pl.cosmic, &pl.listeners.cosmic_info, st)
		// (the windows the list told before: none on a first read of the registry, but the order is not promised)
		for tl in st.toplevels { places_toplevel_new(st, tl) }
	case "ext_workspace_manager_v1":
		if pl.ws_manager != nil { return true }
		pl.ws_manager = wl_bind(st, name, &t.ws_manager, WS_VERSION, version)
		if pl.ws_manager != nil { l.proxy_add_listener(pl.ws_manager, &pl.listeners.ws_manager, st) }
	case "org_kde_plasma_window_management":
		if version < KDE_WM_VERSION_MIN || pl.kde != nil { return true }
		pl.kde = wl_bind(st, name, &t.kde_wm, KDE_WM_VERSION, version)
		if pl.kde != nil { l.proxy_add_listener(pl.kde, &pl.listeners.kde_wm, st) }
	case "org_kde_plasma_virtual_desktop_management":
		if pl.kde_vd != nil { return true }
		pl.kde_vd = wl_bind(st, name, &t.kde_vd_manager, KDE_VD_VERSION, version)
		if pl.kde_vd != nil { l.proxy_add_listener(pl.kde_vd, &pl.listeners.kde_vd_manager, st) }
	case:
		return false
	}
	return true
}

// The proxies go with the connection (wl_close calls this before it ends it).
@(private)
places_close :: proc(st: ^Wl_State) {
	pl := &st.places
	l := &st.lib
	for w in pl.workspaces { l.proxy_destroy(w.proxy); free(w, st.allocator) }
	for g in pl.groups { l.proxy_destroy(g) }
	for w in pl.kde_windows { kde_window_free(w) }
	for d in pl.kde_desktops { l.proxy_destroy(d.proxy); delete(d.id, st.allocator); free(d, st.allocator) }
	for p in ([?]Wl_Proxy{pl.cosmic, pl.ws_manager, pl.kde, pl.kde_vd}) { if p != nil { l.proxy_destroy(p) } }
	delete(pl.workspaces)
	delete(pl.groups)
	delete(pl.kde_windows)
	delete(pl.kde_desktops)
	delete(pl.kde_stacking, st.allocator)
	pl^ = {}
}

// Whether a protocol of this file says where the windows are.
@(private)
places_have_rects :: proc(st: ^Wl_State) -> bool {
	return st != nil && ((st.places.cosmic != nil && st.toplevel_list != nil) || st.places.kde != nil)
}

////////////////////////////////
// COSMIC

// A window of ext_foreign_toplevel_list_v1: its cosmic handle asked for.
@(private)
places_toplevel_new :: proc(st: ^Wl_State, tl: ^Wl_Toplevel) {
	pl := &st.places
	if pl.cosmic == nil || tl.cosmic != nil || tl.handle == nil { return }
	l := &st.lib
	p := l.proxy_marshal_flags(pl.cosmic, COSMIC_INFO_GET_TOPLEVEL, &pl.tables.cosmic_handle, l.proxy_get_version(pl.cosmic), 0, nil, tl.handle)
	if p == nil { return }
	c := new(Cosmic_Toplevel, st.allocator)
	c^ = {st = st, proxy = p}
	tl.cosmic = c
	l.proxy_add_listener(p, &pl.listeners.cosmic_handle, c)
}

// `release`: the window is closed, the compositor is told; otherwise (the connection ends) only the proxy goes.
@(private)
places_toplevel_free :: proc(tl: ^Wl_Toplevel, release: bool) {
	c := tl.cosmic
	if c == nil { return }
	l := &c.st.lib
	if release { l.proxy_marshal_flags(c.proxy, COSMIC_HANDLE_DESTROY, nil, l.proxy_get_version(c.proxy), FLAG_DESTROY) } else { l.proxy_destroy(c.proxy) }
	free(c, c.st.allocator)
	tl.cosmic = nil
}

// The windows of the toplevel list placed by COSMIC's rects: the activated first, then the most recent first.
@(private)
places_cosmic_windows :: proc(st: ^Wl_State, s: ^Session) {
	order := make([dynamic]^Wl_Toplevel, 0, len(st.toplevels), context.temp_allocator)
	for i := len(st.toplevels) - 1; i >= 0; i -= 1 {
		tl := st.toplevels[i]
		if tl.cosmic != nil && tl.cosmic.activated { inject_at(&order, 0, tl) } else { append(&order, tl) }
	}
	for tl in order {
		tl.rect, tl.has_rect = cosmic_rect(st, tl.cosmic)
		wl_window_append(s, tl)
	}
}

// A window's rect on the desktop: its rect on each output it is on, moved by the output's place, together. Not shown:
// minimized, or on no active workspace.
@(private = "file")
cosmic_rect :: proc(st: ^Wl_State, c: ^Cosmic_Toplevel) -> (r: Rect, shown: bool) {
	if c == nil || c.minimized || c.place_count == 0 { return }
	if c.ws_count > 0 {
		active := false
		for p in c.workspaces[:c.ws_count] { if ws := workspace_of(st, p); ws != nil && ws.active { active = true } }
		if !active { return }
	}
	first := true
	for place in c.places[:c.place_count] {
		out: ^Wl_Output
		for o in st.outputs { if o.proxy == place.output { out = o } }
		if out == nil { continue }
		at, _ := wl_output_place(out)
		q := Rect{at.x + place.rect.x, at.y + place.rect.y, place.rect.w, place.rect.h}
		if first { r, first = q, false; continue }
		x0, y0 := min(r.x, q.x), min(r.y, q.y)
		x1, y1 := max(r.x + r.w, q.x + q.w), max(r.y + r.h, q.y + q.h)
		r = {x0, y0, x1 - x0, y1 - y0}
	}
	return r, !first && r.w > 0 && r.h > 0
}

@(private = "file")
cosmic_info_toplevel :: proc "c" (data: rawptr, p: Wl_Proxy, handle: Wl_Proxy) {
	// (version 1's event, not sent from version 2: a handle nobody asked for is let go)
	(^Wl_State)(data).lib.proxy_destroy(handle)
}
@(private = "file")
cosmic_info_finished :: proc "c" (data: rawptr, p: Wl_Proxy) {}
@(private = "file")
cosmic_info_done :: proc "c" (data: rawptr, p: Wl_Proxy) {}

@(private = "file")
cosmic_closed :: proc "c" (data: rawptr, p: Wl_Proxy) {}
@(private = "file")
cosmic_done :: proc "c" (data: rawptr, p: Wl_Proxy) {}
@(private = "file")
cosmic_text :: proc "c" (data: rawptr, p: Wl_Proxy, s: cstring) {}
@(private = "file")
cosmic_output :: proc "c" (data: rawptr, p: Wl_Proxy, o: Wl_Proxy) {}

@(private = "file")
cosmic_output_leave :: proc "c" (data: rawptr, p: Wl_Proxy, output: Wl_Proxy) {
	c := (^Cosmic_Toplevel)(data)
	for i := 0; i < c.place_count; i += 1 {
		if c.places[i].output != output { continue }
		c.places[i] = c.places[c.place_count - 1]
		c.place_count -= 1
		return
	}
}

@(private = "file")
cosmic_state :: proc "c" (data: rawptr, p: Wl_Proxy, state: ^Wl_Array) {
	c := (^Cosmic_Toplevel)(data)
	c.minimized, c.activated = false, false
	if state == nil || state.data == nil { return }
	values := ([^]u32)(state.data)[:state.size / size_of(u32)]
	for v in values {
		switch v {
		case COSMIC_STATE_MINIMIZED: c.minimized = true
		case COSMIC_STATE_ACTIVATED: c.activated = true
		}
	}
}

@(private = "file")
cosmic_geometry :: proc "c" (data: rawptr, p: Wl_Proxy, output: Wl_Proxy, x, y, w, h: i32) {
	c := (^Cosmic_Toplevel)(data)
	if output == nil { return }
	for i in 0 ..< c.place_count {
		if c.places[i].output == output { c.places[i].rect = {x, y, w, h}; return }
	}
	if c.place_count < MAX_PLACES {
		c.places[c.place_count] = {output, {x, y, w, h}}
		c.place_count += 1
	}
}

@(private = "file")
cosmic_ws_enter :: proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy) {
	c := (^Cosmic_Toplevel)(data)
	if ws == nil { return }
	for w in c.workspaces[:c.ws_count] { if w == ws { return } }
	if c.ws_count < MAX_PLACES {
		c.workspaces[c.ws_count] = ws
		c.ws_count += 1
	}
}

@(private = "file")
cosmic_ws_leave :: proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy) {
	c := (^Cosmic_Toplevel)(data)
	for i := 0; i < c.ws_count; i += 1 {
		if c.workspaces[i] != ws { continue }
		c.workspaces[i] = c.workspaces[c.ws_count - 1]
		c.ws_count -= 1
		return
	}
}

////////////////////////////////
// ext_workspace_v1

@(private = "file")
workspace_of :: proc "contextless" (st: ^Wl_State, p: Wl_Proxy) -> ^Places_Workspace {
	for w in st.places.workspaces { if w.proxy == p { return w } }
	return nil
}

@(private = "file")
ws_manager_group :: proc "c" (data: rawptr, p: Wl_Proxy, group: Wl_Proxy) {
	context = ctx()
	st := (^Wl_State)(data)
	append(&st.places.groups, group)
	st.lib.proxy_add_listener(group, &st.places.listeners.ws_group, st)
}

@(private = "file")
ws_manager_workspace :: proc "c" (data: rawptr, p: Wl_Proxy, ws: Wl_Proxy) {
	context = ctx()
	st := (^Wl_State)(data)
	w := new(Places_Workspace, st.allocator)
	w^ = {st = st, proxy = ws}
	append(&st.places.workspaces, w)
	st.lib.proxy_add_listener(ws, &st.places.listeners.ws, w)
}

@(private = "file")
ws_nothing :: proc "c" (data: rawptr, p: Wl_Proxy) {}

@(private = "file")
ws_manager_finished :: proc "c" (data: rawptr, p: Wl_Proxy) {
	st := (^Wl_State)(data)
	st.lib.proxy_destroy(p)
	st.places.ws_manager = nil
}

@(private = "file")
ws_group_caps :: proc "c" (data: rawptr, p: Wl_Proxy, caps: u32) {}
@(private = "file")
ws_group_object :: proc "c" (data: rawptr, p: Wl_Proxy, o: Wl_Proxy) {}

@(private = "file")
ws_group_removed :: proc "c" (data: rawptr, p: Wl_Proxy) {
	context = ctx()
	st := (^Wl_State)(data)
	for g, i in st.places.groups {
		if g != p { continue }
		unordered_remove(&st.places.groups, i)
		break
	}
	st.lib.proxy_marshal_flags(p, WS_GROUP_DESTROY, nil, st.lib.proxy_get_version(p), FLAG_DESTROY)
}

@(private = "file")
ws_text :: proc "c" (data: rawptr, p: Wl_Proxy, s: cstring) {}
@(private = "file")
ws_array :: proc "c" (data: rawptr, p: Wl_Proxy, a: ^Wl_Array) {}
@(private = "file")
ws_caps :: proc "c" (data: rawptr, p: Wl_Proxy, caps: u32) {}

@(private = "file")
ws_state :: proc "c" (data: rawptr, p: Wl_Proxy, state: u32) {
	(^Places_Workspace)(data).active = state & WS_STATE_ACTIVE != 0
}

@(private = "file")
ws_removed :: proc "c" (data: rawptr, p: Wl_Proxy) {
	context = ctx()
	w := (^Places_Workspace)(data)
	st := w.st
	for x, i in st.places.workspaces {
		if x != w { continue }
		unordered_remove(&st.places.workspaces, i)
		break
	}
	// (a window still on it is then on no known workspace: cosmic_rect skips a proxy it does not find)
	for tl in st.toplevels {
		if tl.cosmic != nil { cosmic_ws_leave(tl.cosmic, nil, p) }
	}
	st.lib.proxy_marshal_flags(p, WS_DESTROY, nil, st.lib.proxy_get_version(p), FLAG_DESTROY)
	free(w, st.allocator)
}

////////////////////////////////
// KDE

// KDE's windows, front to back (the stacking order from the top, then the windows it does not name), as capture_wl
// matches the compositor IPC's.
@(private)
places_kde_windows :: proc(st: ^Wl_State, allocator: runtime.Allocator) -> []wm.Window {
	pl := &st.places
	if pl.kde == nil { return nil }
	n := len(pl.kde_windows)
	taken := make([]bool, n, context.temp_allocator)
	order := make([dynamic]^Kde_Window, 0, n, context.temp_allocator)
	uuids := strings.split(pl.kde_stacking, ";", context.temp_allocator)
	for i := len(uuids) - 1; i >= 0; i -= 1 {
		for w, j in pl.kde_windows {
			if taken[j] || w.uuid != uuids[i] { continue }
			taken[j] = true
			append(&order, w)
			break
		}
	}
	for w, j in pl.kde_windows { if !taken[j] { append(&order, w) } }
	list := make([]wm.Window, len(order), allocator)
	for w, i in order {
		list[i] = {
			id = w.id,
			title = strings.clone(w.title, allocator),
			app_id = strings.clone(w.app_id, allocator),
			rect = {w.rect.x, w.rect.y, w.rect.w, w.rect.h},
			visible = w.has_rect && kde_shown(st, w),
		}
	}
	return list
}

@(private = "file")
kde_shown :: proc(st: ^Wl_State, w: ^Kde_Window) -> bool {
	if w.state & KDE_STATE_MINIMIZED != 0 { return false }
	if w.state & KDE_STATE_ON_ALL_DESKTOPS != 0 || w.desktop_count == 0 || st.places.kde_vd == nil { return true }
	for id in w.desktops[:w.desktop_count] {
		for d in st.places.kde_desktops { if d.id == id && d.active { return true } }
	}
	return false
}

@(private = "file")
kde_window_free :: proc(w: ^Kde_Window) {
	st := w.st
	l := &st.lib
	l.proxy_destroy(w.proxy)
	delete(w.uuid, st.allocator)
	delete(w.title, st.allocator)
	delete(w.app_id, st.allocator)
	for d in w.desktops[:w.desktop_count] { delete(d, st.allocator) }
	free(w, st.allocator)
}

@(private = "file")
kde_wm_u32 :: proc "c" (data: rawptr, p: Wl_Proxy, v: u32) {}
@(private = "file")
kde_wm_array :: proc "c" (data: rawptr, p: Wl_Proxy, a: ^Wl_Array) {}
@(private = "file")
kde_wm_nothing :: proc "c" (data: rawptr, p: Wl_Proxy) {}

@(private = "file")
kde_wm_stacking :: proc "c" (data: rawptr, p: Wl_Proxy, uuids: cstring) {
	context = ctx()
	st := (^Wl_State)(data)
	delete(st.places.kde_stacking, st.allocator)
	st.places.kde_stacking = strings.clone_from_cstring(uuids, st.allocator)
}

@(private = "file")
kde_wm_window :: proc "c" (data: rawptr, p: Wl_Proxy, id: u32, uuid: cstring) {
	context = ctx()
	st := (^Wl_State)(data)
	pl := &st.places
	l := &st.lib
	for w in pl.kde_windows { if w.uuid == string(uuid) { return } }
	proxy := l.proxy_marshal_flags(p, KDE_WM_GET_WINDOW_BY_UUID, &pl.tables.kde_window, l.proxy_get_version(p), 0, nil, uuid)
	if proxy == nil { return }
	pl.kde_serial += 1
	w := new(Kde_Window, st.allocator)
	w^ = {st = st, proxy = proxy, id = pl.kde_serial, uuid = strings.clone_from_cstring(uuid, st.allocator)}
	append(&pl.kde_windows, w)
	l.proxy_add_listener(proxy, &pl.listeners.kde_window, w)
}

@(private = "file")
kde_title :: proc "c" (data: rawptr, p: Wl_Proxy, s: cstring) {
	context = ctx()
	w := (^Kde_Window)(data)
	delete(w.title, w.st.allocator)
	w.title = strings.clone_from_cstring(s, w.st.allocator)
}

@(private = "file")
kde_app_id :: proc "c" (data: rawptr, p: Wl_Proxy, s: cstring) {
	context = ctx()
	w := (^Kde_Window)(data)
	delete(w.app_id, w.st.allocator)
	w.app_id = strings.clone_from_cstring(s, w.st.allocator)
}

@(private = "file")
kde_state :: proc "c" (data: rawptr, p: Wl_Proxy, flags: u32) { (^Kde_Window)(data).state = flags }

@(private = "file")
kde_geometry :: proc "c" (data: rawptr, p: Wl_Proxy, x, y: i32, w, h: u32) {
	k := (^Kde_Window)(data)
	k.rect = {x, y, i32(w), i32(h)}
	k.has_rect = w > 0 && h > 0
}

@(private = "file")
kde_unmapped :: proc "c" (data: rawptr, p: Wl_Proxy) {
	context = ctx()
	w := (^Kde_Window)(data)
	pl := &w.st.places
	for x, i in pl.kde_windows {
		if x != w { continue }
		ordered_remove(&pl.kde_windows, i)
		break
	}
	// (the proxy only: ShojiWM's server reads this destroy as get_icon and ends the connection; a window that is gone
	// sends nothing more, and the server frees its object with the connection)
	kde_window_free(w)
}

@(private = "file")
kde_desktop_entered :: proc "c" (data: rawptr, p: Wl_Proxy, id: cstring) {
	context = ctx()
	w := (^Kde_Window)(data)
	for d in w.desktops[:w.desktop_count] { if d == string(id) { return } }
	if w.desktop_count == MAX_PLACES { return }
	w.desktops[w.desktop_count] = strings.clone_from_cstring(id, w.st.allocator)
	w.desktop_count += 1
}

@(private = "file")
kde_desktop_left :: proc "c" (data: rawptr, p: Wl_Proxy, id: cstring) {
	context = ctx()
	w := (^Kde_Window)(data)
	for i := 0; i < w.desktop_count; i += 1 {
		if w.desktops[i] != string(id) { continue }
		delete(w.desktops[i], w.st.allocator)
		w.desktops[i] = w.desktops[w.desktop_count - 1]
		w.desktop_count -= 1
		return
	}
}

@(private = "file")
kde_win_nothing :: proc "c" (data: rawptr, p: Wl_Proxy) {}
@(private = "file")
kde_win_text :: proc "c" (data: rawptr, p: Wl_Proxy, s: cstring) {}
@(private = "file")
kde_win_two_texts :: proc "c" (data: rawptr, p: Wl_Proxy, a, b: cstring) {}
@(private = "file")
kde_win_i32 :: proc "c" (data: rawptr, p: Wl_Proxy, v: i32) {}
@(private = "file")
kde_win_u32 :: proc "c" (data: rawptr, p: Wl_Proxy, v: u32) {}
@(private = "file")
kde_win_object :: proc "c" (data: rawptr, p: Wl_Proxy, o: Wl_Proxy) {}
// (the client's rect, without the frame: the frame is what a screenshot of a window shows)
@(private = "file")
kde_win_geometry_ignored :: proc "c" (data: rawptr, p: Wl_Proxy, x, y: i32, w, h: u32) {}

@(private = "file")
vd_created :: proc "c" (data: rawptr, p: Wl_Proxy, id: cstring, position: u32) {
	context = ctx()
	st := (^Wl_State)(data)
	pl := &st.places
	l := &st.lib
	proxy := l.proxy_marshal_flags(p, KDE_VD_MANAGER_GET, &pl.tables.kde_vd, l.proxy_get_version(p), 0, nil, id)
	if proxy == nil { return }
	d := new(Kde_Desktop, st.allocator)
	d^ = {st = st, proxy = proxy, id = strings.clone_from_cstring(id, st.allocator)}
	append(&pl.kde_desktops, d)
	l.proxy_add_listener(proxy, &pl.listeners.kde_vd, d)
}

@(private = "file")
vd_text :: proc "c" (data: rawptr, p: Wl_Proxy, s: cstring) {}
@(private = "file")
vd_nothing :: proc "c" (data: rawptr, p: Wl_Proxy) {}
@(private = "file")
vd_u32 :: proc "c" (data: rawptr, p: Wl_Proxy, v: u32) {}
@(private = "file")
vd_activated :: proc "c" (data: rawptr, p: Wl_Proxy) { (^Kde_Desktop)(data).active = true }
@(private = "file")
vd_deactivated :: proc "c" (data: rawptr, p: Wl_Proxy) { (^Kde_Desktop)(data).active = false }

// (the desktop's object has no destructor request in version 1: only the proxy goes)
@(private = "file")
vd_removed :: proc "c" (data: rawptr, p: Wl_Proxy) {
	context = ctx()
	d := (^Kde_Desktop)(data)
	st := d.st
	for x, i in st.places.kde_desktops {
		if x != d { continue }
		unordered_remove(&st.places.kde_desktops, i)
		break
	}
	st.lib.proxy_destroy(p)
	delete(d.id, st.allocator)
	free(d, st.allocator)
}
