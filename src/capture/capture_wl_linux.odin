#+build linux
package capture

// The Wayland backends, on a connection of the session's own (wl_display_connect): the program's window connection
// belongs to its interface thread, a capture runs on a worker.
//
//   ext_image_copy_capture_v1   a session per source (an output through ext_output_image_capture_source_manager_v1, a
//                               window through ext_foreign_toplevel_image_capture_source_manager_v1), its buffer
//                               constraints (buffer_size, shm_format, done), then a frame into a wl_shm buffer.
//   zwlr_screencopy_v1          a frame per output: its buffer event(s), then copy into a wl_shm buffer.
//   ext_foreign_toplevel_list_v1  the windows: title, app_id, identifier (no position: COSMIC's or KDE's protocol
//                               adds it, capture_places_linux.odin, or the compositor's IPC, capture/wm).
//   wl_output, zxdg_output_v1   the outputs: logical position and size, mode, scale, name.
//
// A stream (the end of this file) keeps ext_image_copy_capture's session open and asks a frame per picture, or asks
// wlr-screencopy a frame per picture (copy_with_damage after the first), into two wl_shm buffers taken in turn.
//
// libwayland-client is opened by dlopen, as the platform package does (a program starts without it). The tables of the
// protocols the library does not ship are written by hand from the XML (wayland-protocols 1.49 staging and unstable,
// wlr-protocols' screencopy version 3) into the session's state: they point at the library's wl_output_interface and
// others, known at run time, and live as long as the session's proxies do. No global state.

import "base:runtime"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "wm"

@(private) Wl_Proxy :: distinct rawptr
@(private) Wl_Display :: distinct rawptr
@(private) Wl_Array :: struct { size: uint, alloc: uint, data: rawptr }

// struct wl_interface and struct wl_message (wayland-util.h).
@(private)
Wl_Interface :: struct {
	name:         cstring,
	version:      i32,
	method_count: i32,
	methods:      [^]Wl_Message,
	event_count:  i32,
	events:       [^]Wl_Message,
}

@(private)
Wl_Message :: struct {
	name:      cstring,
	signature: cstring,
	types:     [^]^Wl_Interface,
}

@(private = "file") WL_MARSHAL_FLAG_DESTROY :: 1
@(private = "file") WL_DISPLAY_GET_REGISTRY :: 1
@(private = "file") WL_REGISTRY_BIND :: 0
@(private = "file") WL_OUTPUT_RELEASE :: 0          // (since 3)
@(private = "file") WL_SHM_CREATE_POOL :: 0
@(private = "file") WL_SHM_POOL_CREATE_BUFFER :: 0
@(private = "file") WL_SHM_POOL_DESTROY :: 1
@(private = "file") WL_BUFFER_DESTROY :: 0
@(private = "file") WL_OUTPUT_MODE_CURRENT :: 1

// wl_shm.format: the four this backend reads.
@(private = "file") SHM_ARGB8888 :: 0
@(private = "file") SHM_XRGB8888 :: 1
@(private = "file") SHM_ABGR8888 :: 0x34324241
@(private = "file") SHM_XBGR8888 :: 0x34324258

// Request opcodes, in the XML's order.
@(private = "file") XDG_OUTPUT_MANAGER_GET :: 1
@(private = "file") XDG_OUTPUT_DESTROY :: 0
@(private = "file") SOURCE_DESTROY :: 0
@(private = "file") SOURCE_MANAGER_CREATE :: 0
@(private = "file") COPY_MANAGER_CREATE_SESSION :: 0
@(private = "file") COPY_SESSION_CREATE_FRAME :: 0
@(private = "file") COPY_SESSION_DESTROY :: 1
@(private = "file") COPY_FRAME_DESTROY :: 0
@(private = "file") COPY_FRAME_ATTACH_BUFFER :: 1
@(private = "file") COPY_FRAME_DAMAGE_BUFFER :: 2
@(private = "file") COPY_FRAME_CAPTURE :: 3
@(private = "file") TOPLEVEL_HANDLE_DESTROY :: 0
@(private = "file") SCREENCOPY_CAPTURE_OUTPUT :: 0
@(private = "file") SCREENCOPY_FRAME_COPY :: 0
@(private = "file") SCREENCOPY_FRAME_DESTROY :: 1
@(private = "file") SCREENCOPY_FRAME_COPY_WITH_DAMAGE :: 2   // (since 2)
@(private = "file") SCREENCOPY_COPY_WITH_DAMAGE_SINCE :: 2
@(private = "file") COPY_SESSION_PAINT_CURSORS :: 1          // create_session's options: the pointer drawn in

@(private = "file") COPY_FAILED_BUFFER_CONSTRAINTS :: 1
@(private = "file") COPY_FAILED_STOPPED :: 2
@(private = "file") SCREENCOPY_FLAG_Y_INVERT :: 1

// The versions asked for (no more than the compositor has, no more than the listeners below know).
@(private = "file") WL_OUTPUT_VERSION :: 4
@(private = "file") XDG_OUTPUT_MANAGER_VERSION :: 3
@(private = "file") SCREENCOPY_VERSION :: 3
@(private = "file") SCREENCOPY_BUFFER_DONE_SINCE :: 3

// How long a capture may take before it is given up: a compositor that never answers must not hold the worker.
@(private = "file") CAPTURE_TIMEOUT :: 5 * time.Second

@(private)
Wl_Lib :: struct {
	handle:                   posix.Symbol_Table,
	display_connect:          proc "c" (name: cstring) -> Wl_Display,
	display_disconnect:       proc "c" (d: Wl_Display),
	display_get_fd:           proc "c" (d: Wl_Display) -> i32,
	display_dispatch_pending: proc "c" (d: Wl_Display) -> i32,
	display_prepare_read:     proc "c" (d: Wl_Display) -> i32,
	display_read_events:      proc "c" (d: Wl_Display) -> i32,
	display_cancel_read:      proc "c" (d: Wl_Display),
	display_flush:            proc "c" (d: Wl_Display) -> i32,
	display_roundtrip:        proc "c" (d: Wl_Display) -> i32,
	display_get_error:        proc "c" (d: Wl_Display) -> i32,
	proxy_marshal_flags:      proc "c" (p: Wl_Proxy, opcode: u32, iface: ^Wl_Interface, version: u32, flags: u32, #c_vararg args: ..any) -> Wl_Proxy,
	proxy_add_listener:       proc "c" (p: Wl_Proxy, implementation: rawptr, data: rawptr) -> i32,
	proxy_destroy:            proc "c" (p: Wl_Proxy),
	proxy_get_version:        proc "c" (p: Wl_Proxy) -> u32,
	registry_interface:       ^Wl_Interface,
	output_interface:         ^Wl_Interface,
	shm_interface:            ^Wl_Interface,
	shm_pool_interface:       ^Wl_Interface,
	buffer_interface:         ^Wl_Interface,
	pointer_interface:        ^Wl_Interface,
}

// The interfaces the library does not ship, and their messages and types arrays (each array one entry per argument).
@(private)
Wl_Tables :: struct {
	xdg_output_manager, xdg_output: Wl_Interface,
	source, output_sources, toplevel_sources: Wl_Interface,
	copy_manager, copy_session, copy_frame, cursor_session: Wl_Interface,
	toplevel_list, toplevel_handle: Wl_Interface,
	screencopy_manager, screencopy_frame: Wl_Interface,

	xom_methods: [2]Wl_Message,
	xo_methods: [1]Wl_Message,
	xo_events: [5]Wl_Message,
	src_methods: [1]Wl_Message,
	osm_methods, tsm_methods: [2]Wl_Message,
	cm_methods: [3]Wl_Message,
	cs_methods: [2]Wl_Message,
	cs_events: [6]Wl_Message,
	cf_methods: [4]Wl_Message,
	cf_events: [5]Wl_Message,
	tl_methods: [2]Wl_Message,
	tl_events: [2]Wl_Message,
	th_methods: [1]Wl_Message,
	th_events: [5]Wl_Message,
	scm_methods: [3]Wl_Message,
	scf_methods: [3]Wl_Message,
	scf_events: [7]Wl_Message,

	t_xom_get: [2]^Wl_Interface,
	t_osm_create, t_tsm_create: [2]^Wl_Interface,
	t_cm_session: [3]^Wl_Interface,
	t_cm_cursor: [3]^Wl_Interface,
	t_cs_frame: [1]^Wl_Interface,
	t_cf_attach: [1]^Wl_Interface,
	t_tl_toplevel: [1]^Wl_Interface,
	t_scm_capture: [3]^Wl_Interface,
	t_scm_region: [7]^Wl_Interface,
	t_scf_copy: [1]^Wl_Interface,
	t_none: [7]^Wl_Interface,   // (nil for every argument that is not an object)
}

// The listeners: tables of the session's (their address is given to the library and must last as the proxies do).
@(private)
Wl_Listeners :: struct {
	registry: struct {
		global:        proc "c" (data: rawptr, registry: Wl_Proxy, name: u32, iface: cstring, version: u32),
		global_remove: proc "c" (data: rawptr, registry: Wl_Proxy, name: u32),
	},
	output: struct {
		geometry:    proc "c" (data: rawptr, o: Wl_Proxy, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32),
		mode:        proc "c" (data: rawptr, o: Wl_Proxy, flags: u32, w, h, refresh: i32),
		done:        proc "c" (data: rawptr, o: Wl_Proxy),
		scale:       proc "c" (data: rawptr, o: Wl_Proxy, factor: i32),
		name:        proc "c" (data: rawptr, o: Wl_Proxy, name: cstring),
		description: proc "c" (data: rawptr, o: Wl_Proxy, description: cstring),
	},
	xdg_output: struct {
		logical_position: proc "c" (data: rawptr, o: Wl_Proxy, x, y: i32),
		logical_size:     proc "c" (data: rawptr, o: Wl_Proxy, w, h: i32),
		done:             proc "c" (data: rawptr, o: Wl_Proxy),
		name:             proc "c" (data: rawptr, o: Wl_Proxy, name: cstring),
		description:      proc "c" (data: rawptr, o: Wl_Proxy, description: cstring),
	},
	toplevel_list: struct {
		toplevel: proc "c" (data: rawptr, list: Wl_Proxy, handle: Wl_Proxy),
		finished: proc "c" (data: rawptr, list: Wl_Proxy),
	},
	toplevel_handle: struct {
		closed:     proc "c" (data: rawptr, h: Wl_Proxy),
		done:       proc "c" (data: rawptr, h: Wl_Proxy),
		title:      proc "c" (data: rawptr, h: Wl_Proxy, title: cstring),
		app_id:     proc "c" (data: rawptr, h: Wl_Proxy, app_id: cstring),
		identifier: proc "c" (data: rawptr, h: Wl_Proxy, identifier: cstring),
	},
	copy_session: struct {
		buffer_size:   proc "c" (data: rawptr, s: Wl_Proxy, w, h: u32),
		shm_format:    proc "c" (data: rawptr, s: Wl_Proxy, format: u32),
		dmabuf_device: proc "c" (data: rawptr, s: Wl_Proxy, device: ^Wl_Array),
		dmabuf_format: proc "c" (data: rawptr, s: Wl_Proxy, format: u32, modifiers: ^Wl_Array),
		done:          proc "c" (data: rawptr, s: Wl_Proxy),
		stopped:       proc "c" (data: rawptr, s: Wl_Proxy),
	},
	copy_frame: struct {
		transform:         proc "c" (data: rawptr, f: Wl_Proxy, transform: u32),
		damage:            proc "c" (data: rawptr, f: Wl_Proxy, x, y, w, h: i32),
		presentation_time: proc "c" (data: rawptr, f: Wl_Proxy, sec_hi, sec_lo, nsec: u32),
		ready:             proc "c" (data: rawptr, f: Wl_Proxy),
		failed:            proc "c" (data: rawptr, f: Wl_Proxy, reason: u32),
	},
	screencopy_frame: struct {
		buffer:       proc "c" (data: rawptr, f: Wl_Proxy, format, w, h, stride: u32),
		flags:        proc "c" (data: rawptr, f: Wl_Proxy, flags: u32),
		ready:        proc "c" (data: rawptr, f: Wl_Proxy, sec_hi, sec_lo, nsec: u32),
		failed:       proc "c" (data: rawptr, f: Wl_Proxy),
		damage:       proc "c" (data: rawptr, f: Wl_Proxy, x, y, w, h: u32),
		linux_dmabuf: proc "c" (data: rawptr, f: Wl_Proxy, format, w, h: u32),
		buffer_done:  proc "c" (data: rawptr, f: Wl_Proxy),
	},
	// a stream's (data: its Wl_Stream), in the same shapes as the three above
	stream_session: struct {
		buffer_size:   proc "c" (data: rawptr, s: Wl_Proxy, w, h: u32),
		shm_format:    proc "c" (data: rawptr, s: Wl_Proxy, format: u32),
		dmabuf_device: proc "c" (data: rawptr, s: Wl_Proxy, device: ^Wl_Array),
		dmabuf_format: proc "c" (data: rawptr, s: Wl_Proxy, format: u32, modifiers: ^Wl_Array),
		done:          proc "c" (data: rawptr, s: Wl_Proxy),
		stopped:       proc "c" (data: rawptr, s: Wl_Proxy),
	},
	stream_frame: struct {
		transform:         proc "c" (data: rawptr, f: Wl_Proxy, transform: u32),
		damage:            proc "c" (data: rawptr, f: Wl_Proxy, x, y, w, h: i32),
		presentation_time: proc "c" (data: rawptr, f: Wl_Proxy, sec_hi, sec_lo, nsec: u32),
		ready:             proc "c" (data: rawptr, f: Wl_Proxy),
		failed:            proc "c" (data: rawptr, f: Wl_Proxy, reason: u32),
	},
	stream_screencopy: struct {
		buffer:       proc "c" (data: rawptr, f: Wl_Proxy, format, w, h, stride: u32),
		flags:        proc "c" (data: rawptr, f: Wl_Proxy, flags: u32),
		ready:        proc "c" (data: rawptr, f: Wl_Proxy, sec_hi, sec_lo, nsec: u32),
		failed:       proc "c" (data: rawptr, f: Wl_Proxy),
		damage:       proc "c" (data: rawptr, f: Wl_Proxy, x, y, w, h: u32),
		linux_dmabuf: proc "c" (data: rawptr, f: Wl_Proxy, format, w, h: u32),
		buffer_done:  proc "c" (data: rawptr, f: Wl_Proxy),
	},
}

// An output as the compositor tells it.
@(private)
Wl_Output :: struct {
	st:           ^Wl_State,
	global:       u32,          // the registry's name: the Output's id
	proxy, xdg:   Wl_Proxy,
	name:         string,       // (the session's allocator)
	position:     [2]i32,       // wl_output.geometry's: logical on most compositors, used without xdg-output only
	transform:    i32,
	mode:         [2]i32,       // the current mode, physical pixels, before the transform
	scale:        i32,          // wl_output.scale, an integer
	logical_pos:  [2]i32,       // zxdg_output_v1's
	logical_size: [2]i32,
}

// A window as ext_foreign_toplevel_list_v1 tells it.
@(private)
Wl_Toplevel :: struct {
	st:         ^Wl_State,
	handle:     Wl_Proxy,
	id:         u64,
	title:      string,   // (the session's allocator, as the two below)
	app_id:     string,
	identifier: string,
	rect:       Rect,     // as the compositor said at the last windows(), when has_rect
	has_rect:   bool,
	cosmic:     ^Cosmic_Toplevel,   // its zcosmic_toplevel_handle_v1, when the compositor has the protocol
}

// A capture's stages. Constraints: waiting for what the buffer must be (ext's session done, screencopy's buffer events).
// Copying: the buffer is attached and the copy asked for. Ready and Failed are final.
@(private)
Wl_Stage :: enum u8 { Constraints, Copying, Ready, Failed }

@(private)
Wl_Buffer :: struct {
	proxy: Wl_Proxy,
	mem:   rawptr,
	bytes: int,
}

// One picture being taken, of an output or of a window.
@(private)
Wl_Capture :: struct {
	st:         ^Wl_State,
	stage:      Wl_Stage,
	err:        Error,
	opaque:     bool,       // a screen: the alpha byte means nothing
	source:     Wl_Proxy,   // ext_image_capture_source_v1
	session:    Wl_Proxy,   // ext_image_copy_capture_session_v1
	frame:      Wl_Proxy,   // ext_image_copy_capture_frame_v1 or zwlr_screencopy_frame_v1
	screencopy: bool,
	size:       [2]i32,     // the buffer's, physical pixels before the turn
	stride:     i32,
	format:     u32,
	has_format: bool,
	turn:       Turn,
	y_invert:   bool,
	retried:    bool,       // a frame failed on the buffer's constraints once: the next one is the last try
	buffer:     Wl_Buffer,
}

@(private)
Wl_State :: struct {
	order:          Pixel_Order,   // the frames' (the session's, set before each capture)
	allocator:        runtime.Allocator,
	lib:              Wl_Lib,
	tables:           Wl_Tables,
	listeners:        Wl_Listeners,
	display:          Wl_Display,
	fd:               i32,
	registry:         Wl_Proxy,
	shm:              Wl_Proxy,
	xdg_output_manager: Wl_Proxy,
	copy_manager:     Wl_Proxy,   // ext_image_copy_capture_manager_v1
	output_sources:   Wl_Proxy,   // ext_output_image_capture_source_manager_v1
	toplevel_sources: Wl_Proxy,   // ext_foreign_toplevel_image_capture_source_manager_v1
	toplevel_list:    Wl_Proxy,   // ext_foreign_toplevel_list_v1
	screencopy:       Wl_Proxy,   // zwlr_screencopy_manager_v1
	screencopy_version: u32,
	outputs:          [dynamic]^Wl_Output,
	toplevels:        [dynamic]^Wl_Toplevel,
	toplevel_serial:  u64,
	places:           Places,     // where the windows are: COSMIC's and KDE's protocols (capture_places_linux.odin)
}

// The library's callbacks run inside our dispatch, on the caller's thread; they allocate with the session's allocator
// explicitly, so a default context is enough.
@(private = "file")
cb_ctx :: proc "contextless" () -> runtime.Context { return runtime.default_context() }

////////////////////////////////
// opening and closing

// The connection, its globals bound, the outputs described. ok is false without libwayland-client or a compositor.
@(private)
wl_open :: proc(allocator: runtime.Allocator) -> (st: ^Wl_State, ok: bool) {
	st = new(Wl_State, allocator)
	st.allocator = allocator
	st.outputs.allocator = allocator
	st.toplevels.allocator = allocator
	if !wl_lib_load(&st.lib) { free(st, allocator); return nil, false }
	wl_build_tables(st)
	wl_set_listeners(st)
	places_init(st)
	l := &st.lib
	st.display = l.display_connect(nil)
	if st.display == nil { wl_close(st); return nil, false }
	st.fd = l.display_get_fd(st.display)
	st.registry = l.proxy_marshal_flags(Wl_Proxy(st.display), WL_DISPLAY_GET_REGISTRY, l.registry_interface, l.proxy_get_version(Wl_Proxy(st.display)), 0, nil)
	if st.registry == nil { wl_close(st); return nil, false }
	l.proxy_add_listener(st.registry, &st.listeners.registry, st)
	// first: the globals; then what binding them made the compositor say (the outputs' modes, the toplevels)
	if l.display_roundtrip(st.display) < 0 { wl_close(st); return nil, false }
	wl_describe_outputs(st)
	if l.display_roundtrip(st.display) < 0 { wl_close(st); return nil, false }
	return st, true
}

@(private)
wl_close :: proc(st: ^Wl_State) {
	if st == nil { return }
	l := &st.lib
	if st.display != nil {
		// (destroyed here only: the connection's end frees the compositor's side of each)
		for o in st.outputs { wl_output_free(o, false) }
		for t in st.toplevels { wl_toplevel_free(t) }
		places_close(st)
		for p in ([?]Wl_Proxy{st.shm, st.xdg_output_manager, st.copy_manager, st.output_sources, st.toplevel_sources, st.toplevel_list, st.screencopy, st.registry}) {
			if p != nil { l.proxy_destroy(p) }
		}
		l.display_disconnect(st.display)
	} else {
		for o in st.outputs { free(o, st.allocator) }
	}
	delete(st.outputs)
	delete(st.toplevels)
	if st.lib.handle != nil { posix.dlclose(st.lib.handle) }
	free(st, st.allocator)
}

@(private = "file")
wl_lib_load :: proc(l: ^Wl_Lib) -> bool {
	h := posix.dlopen("libwayland-client.so.0", {.NOW})
	if h == nil { h = posix.dlopen("libwayland-client.so", {.NOW}) }
	if h == nil { return false }
	l.handle = h
	l.display_connect          = auto_cast posix.dlsym(h, "wl_display_connect")
	l.display_disconnect       = auto_cast posix.dlsym(h, "wl_display_disconnect")
	l.display_get_fd           = auto_cast posix.dlsym(h, "wl_display_get_fd")
	l.display_dispatch_pending = auto_cast posix.dlsym(h, "wl_display_dispatch_pending")
	l.display_prepare_read     = auto_cast posix.dlsym(h, "wl_display_prepare_read")
	l.display_read_events      = auto_cast posix.dlsym(h, "wl_display_read_events")
	l.display_cancel_read      = auto_cast posix.dlsym(h, "wl_display_cancel_read")
	l.display_flush            = auto_cast posix.dlsym(h, "wl_display_flush")
	l.display_roundtrip        = auto_cast posix.dlsym(h, "wl_display_roundtrip")
	l.display_get_error        = auto_cast posix.dlsym(h, "wl_display_get_error")
	l.proxy_marshal_flags      = auto_cast posix.dlsym(h, "wl_proxy_marshal_flags")
	l.proxy_add_listener       = auto_cast posix.dlsym(h, "wl_proxy_add_listener")
	l.proxy_destroy            = auto_cast posix.dlsym(h, "wl_proxy_destroy")
	l.proxy_get_version        = auto_cast posix.dlsym(h, "wl_proxy_get_version")
	l.registry_interface       = auto_cast posix.dlsym(h, "wl_registry_interface")
	l.output_interface         = auto_cast posix.dlsym(h, "wl_output_interface")
	l.shm_interface            = auto_cast posix.dlsym(h, "wl_shm_interface")
	l.shm_pool_interface       = auto_cast posix.dlsym(h, "wl_shm_pool_interface")
	l.buffer_interface         = auto_cast posix.dlsym(h, "wl_buffer_interface")
	l.pointer_interface        = auto_cast posix.dlsym(h, "wl_pointer_interface")
	return l.display_connect != nil && l.display_dispatch_pending != nil && l.display_prepare_read != nil &&
		l.display_read_events != nil && l.display_cancel_read != nil && l.display_roundtrip != nil &&
		l.proxy_marshal_flags != nil && l.proxy_add_listener != nil && l.proxy_destroy != nil && l.proxy_get_version != nil &&
		l.registry_interface != nil && l.output_interface != nil && l.shm_interface != nil && l.shm_pool_interface != nil &&
		l.buffer_interface != nil
}

@(private)
types :: proc(s: []^Wl_Interface) -> [^]^Wl_Interface { return len(s) > 0 ? raw_data(s) : nil }

// The tables, from the protocols' XML. Signatures: "i" int, "u" uint, "s" string, "o" object, "n" new_id, "a" array, a
// leading digit the version the message came in.
@(private = "file")
wl_build_tables :: proc(st: ^Wl_State) {
	t := &st.tables
	l := &st.lib
	none := types(t.t_none[:])

	// xdg-output-unstable-v1, version 3
	t.t_xom_get = {&t.xdg_output, l.output_interface}
	t.xom_methods = {{"destroy", "", nil}, {"get_xdg_output", "no", types(t.t_xom_get[:])}}
	t.xdg_output_manager = {"zxdg_output_manager_v1", 3, 2, &t.xom_methods[0], 0, nil}
	t.xo_methods = {{"destroy", "", nil}}
	t.xo_events = {{"logical_position", "ii", none}, {"logical_size", "ii", none}, {"done", "", nil}, {"name", "2s", none}, {"description", "2s", none}}
	t.xdg_output = {"zxdg_output_v1", 3, 1, &t.xo_methods[0], 5, &t.xo_events[0]}

	// ext-image-capture-source-v1, version 1
	t.src_methods = {{"destroy", "", nil}}
	t.source = {"ext_image_capture_source_v1", 1, 1, &t.src_methods[0], 0, nil}
	t.t_osm_create = {&t.source, l.output_interface}
	t.osm_methods = {{"create_source", "no", types(t.t_osm_create[:])}, {"destroy", "", nil}}
	t.output_sources = {"ext_output_image_capture_source_manager_v1", 1, 2, &t.osm_methods[0], 0, nil}
	t.t_tsm_create = {&t.source, &t.toplevel_handle}
	t.tsm_methods = {{"create_source", "no", types(t.t_tsm_create[:])}, {"destroy", "", nil}}
	t.toplevel_sources = {"ext_foreign_toplevel_image_capture_source_manager_v1", 1, 2, &t.tsm_methods[0], 0, nil}

	// ext-image-copy-capture-v1, version 1 (the cursor session is never made: its interface only names it)
	t.t_cm_session = {&t.copy_session, &t.source, nil}
	t.t_cm_cursor = {&t.cursor_session, &t.source, l.pointer_interface}
	t.cm_methods = {{"create_session", "nou", types(t.t_cm_session[:])}, {"create_pointer_cursor_session", "noo", types(t.t_cm_cursor[:])}, {"destroy", "", nil}}
	t.copy_manager = {"ext_image_copy_capture_manager_v1", 1, 3, &t.cm_methods[0], 0, nil}
	t.cursor_session = {"ext_image_copy_capture_cursor_session_v1", 1, 0, nil, 0, nil}
	t.t_cs_frame = {&t.copy_frame}
	t.cs_methods = {{"create_frame", "n", types(t.t_cs_frame[:])}, {"destroy", "", nil}}
	t.cs_events = {{"buffer_size", "uu", none}, {"shm_format", "u", none}, {"dmabuf_device", "a", none}, {"dmabuf_format", "ua", none}, {"done", "", nil}, {"stopped", "", nil}}
	t.copy_session = {"ext_image_copy_capture_session_v1", 1, 2, &t.cs_methods[0], 6, &t.cs_events[0]}
	t.t_cf_attach = {l.buffer_interface}
	t.cf_methods = {{"destroy", "", nil}, {"attach_buffer", "o", types(t.t_cf_attach[:])}, {"damage_buffer", "iiii", none}, {"capture", "", nil}}
	t.cf_events = {{"transform", "u", none}, {"damage", "iiii", none}, {"presentation_time", "uuu", none}, {"ready", "", nil}, {"failed", "u", none}}
	t.copy_frame = {"ext_image_copy_capture_frame_v1", 1, 4, &t.cf_methods[0], 5, &t.cf_events[0]}

	// ext-foreign-toplevel-list-v1, version 1
	t.t_tl_toplevel = {&t.toplevel_handle}
	t.tl_methods = {{"stop", "", nil}, {"destroy", "", nil}}
	t.tl_events = {{"toplevel", "n", types(t.t_tl_toplevel[:])}, {"finished", "", nil}}
	t.toplevel_list = {"ext_foreign_toplevel_list_v1", 1, 2, &t.tl_methods[0], 2, &t.tl_events[0]}
	t.th_methods = {{"destroy", "", nil}}
	t.th_events = {{"closed", "", nil}, {"done", "", nil}, {"title", "s", none}, {"app_id", "s", none}, {"identifier", "s", none}}
	t.toplevel_handle = {"ext_foreign_toplevel_handle_v1", 1, 1, &t.th_methods[0], 5, &t.th_events[0]}

	// wlr-screencopy-unstable-v1, version 3
	t.t_scm_capture = {&t.screencopy_frame, nil, l.output_interface}
	t.t_scm_region = {&t.screencopy_frame, nil, l.output_interface, nil, nil, nil, nil}
	t.scm_methods = {{"capture_output", "nio", types(t.t_scm_capture[:])}, {"capture_output_region", "nioiiii", types(t.t_scm_region[:])}, {"destroy", "", nil}}
	t.screencopy_manager = {"zwlr_screencopy_manager_v1", 3, 3, &t.scm_methods[0], 0, nil}
	t.t_scf_copy = {l.buffer_interface}
	t.scf_methods = {{"copy", "o", types(t.t_scf_copy[:])}, {"destroy", "", nil}, {"copy_with_damage", "2o", types(t.t_scf_copy[:])}}
	t.scf_events = {{"buffer", "uuuu", none}, {"flags", "u", none}, {"ready", "uuu", none}, {"failed", "", nil}, {"damage", "2uuuu", none}, {"linux_dmabuf", "3uuu", none}, {"buffer_done", "3", nil}}
	t.screencopy_frame = {"zwlr_screencopy_frame_v1", 3, 3, &t.scf_methods[0], 7, &t.scf_events[0]}
}

@(private = "file")
wl_set_listeners :: proc(st: ^Wl_State) {
	ls := &st.listeners
	ls.registry = {registry_global, registry_global_remove}
	ls.output = {output_geometry, output_mode, output_done, output_scale, output_name, output_description}
	ls.xdg_output = {xdg_output_position, xdg_output_size, xdg_output_done, xdg_output_name, xdg_output_description}
	ls.toplevel_list = {toplevel_new, toplevel_list_finished}
	ls.toplevel_handle = {toplevel_closed, toplevel_done, toplevel_title, toplevel_app_id, toplevel_identifier}
	ls.copy_session = {session_buffer_size, session_shm_format, session_dmabuf_device, session_dmabuf_format, session_done, session_stopped}
	ls.copy_frame = {frame_transform, frame_damage, frame_presentation_time, frame_ready, frame_failed}
	ls.screencopy_frame = {sc_buffer, sc_flags, sc_ready, sc_failed, sc_damage, sc_linux_dmabuf, sc_buffer_done}
	ls.stream_session = {ss_buffer_size, ss_shm_format, session_dmabuf_device, session_dmabuf_format, ss_done, ss_stopped}
	ls.stream_frame = {sf_transform, frame_damage, sf_presentation_time, sf_ready, sf_failed}
	ls.stream_screencopy = {ssc_buffer, ssc_flags, ssc_ready, ssc_failed, sc_damage, sc_linux_dmabuf, ssc_buffer_done}
}

////////////////////////////////
// the registry

@(private)
wl_bind :: proc(st: ^Wl_State, name: u32, iface: ^Wl_Interface, want, have: u32) -> Wl_Proxy {
	v := min(want, have)
	return st.lib.proxy_marshal_flags(st.registry, WL_REGISTRY_BIND, iface, v, 0, name, iface.name, v, nil)
}

@(private = "file")
registry_global :: proc "c" (data: rawptr, registry: Wl_Proxy, name: u32, iface: cstring, version: u32) {
	context = cb_ctx()
	st := (^Wl_State)(data)
	t := &st.tables
	switch string(iface) {
	case "wl_shm":
		if st.shm == nil { st.shm = wl_bind(st, name, st.lib.shm_interface, 1, version) }
	case "wl_output":
		o := new(Wl_Output, st.allocator)
		o^ = {st = st, global = name, scale = 1}
		o.proxy = wl_bind(st, name, st.lib.output_interface, WL_OUTPUT_VERSION, version)
		if o.proxy == nil { free(o, st.allocator); return }
		st.lib.proxy_add_listener(o.proxy, &st.listeners.output, o)
		append(&st.outputs, o)
		// (an output plugged in later: its logical rect is asked at once)
		if st.xdg_output_manager != nil { wl_xdg_output_of(st, o) }
	case "zxdg_output_manager_v1":
		st.xdg_output_manager = wl_bind(st, name, &t.xdg_output_manager, XDG_OUTPUT_MANAGER_VERSION, version)
	case "ext_image_copy_capture_manager_v1":
		st.copy_manager = wl_bind(st, name, &t.copy_manager, 1, version)
	case "ext_output_image_capture_source_manager_v1":
		st.output_sources = wl_bind(st, name, &t.output_sources, 1, version)
	case "ext_foreign_toplevel_image_capture_source_manager_v1":
		st.toplevel_sources = wl_bind(st, name, &t.toplevel_sources, 1, version)
	case "ext_foreign_toplevel_list_v1":
		st.toplevel_list = wl_bind(st, name, &t.toplevel_list, 1, version)
		if st.toplevel_list != nil { st.lib.proxy_add_listener(st.toplevel_list, &st.listeners.toplevel_list, st) }
	case "zwlr_screencopy_manager_v1":
		st.screencopy = wl_bind(st, name, &t.screencopy_manager, SCREENCOPY_VERSION, version)
		st.screencopy_version = min(u32(SCREENCOPY_VERSION), version)
	case:
		places_global(st, name, string(iface), version)
	}
}

// An output unplugged: it leaves the list (an output() of its id then says Gone).
@(private = "file")
registry_global_remove :: proc "c" (data: rawptr, registry: Wl_Proxy, name: u32) {
	context = cb_ctx()
	st := (^Wl_State)(data)
	for o, i in st.outputs {
		if o.global != name { continue }
		ordered_remove(&st.outputs, i)
		wl_output_free(o, true)
		return
	}
}

@(private = "file")
wl_xdg_output_of :: proc(st: ^Wl_State, o: ^Wl_Output) {
	l := &st.lib
	o.xdg = l.proxy_marshal_flags(st.xdg_output_manager, XDG_OUTPUT_MANAGER_GET, &st.tables.xdg_output, l.proxy_get_version(st.xdg_output_manager), 0, nil, o.proxy)
	if o.xdg != nil { l.proxy_add_listener(o.xdg, &st.listeners.xdg_output, o) }
}

// Every output without its xdg-output gets one (the manager may come after the outputs in the registry).
@(private = "file")
wl_describe_outputs :: proc(st: ^Wl_State) {
	if st.xdg_output_manager == nil { return }
	for o in st.outputs { if o.xdg == nil { wl_xdg_output_of(st, o) } }
}

// `release`: tell the compositor (the output is gone, the connection stays); otherwise only the proxies go.
@(private = "file")
wl_output_free :: proc(o: ^Wl_Output, release: bool) {
	st := o.st
	l := &st.lib
	if o.xdg != nil {
		if release { l.proxy_marshal_flags(o.xdg, XDG_OUTPUT_DESTROY, nil, l.proxy_get_version(o.xdg), WL_MARSHAL_FLAG_DESTROY) } else { l.proxy_destroy(o.xdg) }
	}
	if o.proxy != nil {
		if release && l.proxy_get_version(o.proxy) >= 3 {
			l.proxy_marshal_flags(o.proxy, WL_OUTPUT_RELEASE, nil, l.proxy_get_version(o.proxy), WL_MARSHAL_FLAG_DESTROY)
		} else {
			l.proxy_destroy(o.proxy)
		}
	}
	delete(o.name, st.allocator)
	free(o, st.allocator)
}

////////////////////////////////
// wl_output and zxdg_output_v1

@(private = "file")
output_geometry :: proc "c" (data: rawptr, p: Wl_Proxy, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {
	o := (^Wl_Output)(data)
	o.position = {x, y}
	o.transform = transform
}
@(private = "file")
output_mode :: proc "c" (data: rawptr, p: Wl_Proxy, flags: u32, w, h, refresh: i32) {
	if flags & WL_OUTPUT_MODE_CURRENT != 0 { (^Wl_Output)(data).mode = {w, h} }
}
@(private = "file")
output_done :: proc "c" (data: rawptr, p: Wl_Proxy) {}
@(private = "file")
output_scale :: proc "c" (data: rawptr, p: Wl_Proxy, factor: i32) {
	if factor > 0 { (^Wl_Output)(data).scale = factor }
}
@(private = "file")
output_name :: proc "c" (data: rawptr, p: Wl_Proxy, name: cstring) {
	context = cb_ctx()
	o := (^Wl_Output)(data)
	delete(o.name, o.st.allocator)
	o.name = strings.clone_from_cstring(name, o.st.allocator)
}
@(private = "file")
output_description :: proc "c" (data: rawptr, p: Wl_Proxy, description: cstring) {}

@(private = "file")
xdg_output_position :: proc "c" (data: rawptr, p: Wl_Proxy, x, y: i32) { (^Wl_Output)(data).logical_pos = {x, y} }
@(private = "file")
xdg_output_size :: proc "c" (data: rawptr, p: Wl_Proxy, w, h: i32) { (^Wl_Output)(data).logical_size = {w, h} }
@(private = "file")
xdg_output_done :: proc "c" (data: rawptr, p: Wl_Proxy) {}
// (wl_output's own name, version 4, is the one kept when both come)
@(private = "file")
xdg_output_name :: proc "c" (data: rawptr, p: Wl_Proxy, name: cstring) {
	context = cb_ctx()
	o := (^Wl_Output)(data)
	if o.name == "" { o.name = strings.clone_from_cstring(name, o.st.allocator) }
}
@(private = "file")
xdg_output_description :: proc "c" (data: rawptr, p: Wl_Proxy, description: cstring) {}

// An output's place on the desktop (logical) and its physical pixels per logical one. Without xdg-output: wl_output's
// position and its mode divided by its integer scale.
@(private)
wl_output_place :: proc(o: ^Wl_Output) -> (r: Rect, scale: f32) {
	px := o.mode
	if o.transform & 1 != 0 { px = {px.y, px.x} }   // (a quarter turn: the screen is the mode on its side)
	if o.logical_size.x > 0 && o.logical_size.y > 0 {
		r = {o.logical_pos.x, o.logical_pos.y, o.logical_size.x, o.logical_size.y}
		scale = px.x > 0 ? f32(px.x) / f32(o.logical_size.x) : f32(max(o.scale, 1))
		return
	}
	s := max(o.scale, 1)
	return {o.position.x, o.position.y, px.x / s, px.y / s}, f32(s)
}

// The outputs as the compositor says now.
@(private)
wl_outputs :: proc(st: ^Wl_State, s: ^Session) {
	l := &st.lib
	l.display_roundtrip(st.display)   // (what changed since: an output plugged in, its mode)
	missing := false
	for o in st.outputs { if o.xdg == nil && st.xdg_output_manager != nil { missing = true } }
	if missing {
		wl_describe_outputs(st)
		l.display_roundtrip(st.display)
	}
	for o in st.outputs {
		if o.mode.x <= 0 || o.mode.y <= 0 { continue }
		r, scale := wl_output_place(o)
		append(&s.outputs, Output{id = u64(o.global), name = strings.clone(o.name, s.allocator), rect = r, scale = scale})
	}
}

@(private = "file")
wl_output_by_id :: proc(st: ^Wl_State, id: u64) -> ^Wl_Output {
	for o in st.outputs { if u64(o.global) == id { return o } }
	return nil
}

////////////////////////////////
// ext_foreign_toplevel_list_v1

@(private = "file")
toplevel_new :: proc "c" (data: rawptr, list: Wl_Proxy, handle: Wl_Proxy) {
	context = cb_ctx()
	st := (^Wl_State)(data)
	st.toplevel_serial += 1
	t := new(Wl_Toplevel, st.allocator)
	t^ = {st = st, handle = handle, id = st.toplevel_serial}
	append(&st.toplevels, t)
	st.lib.proxy_add_listener(handle, &st.listeners.toplevel_handle, t)
	places_toplevel_new(st, t)
}

@(private = "file")
toplevel_list_finished :: proc "c" (data: rawptr, list: Wl_Proxy) {
	st := (^Wl_State)(data)
	st.lib.proxy_destroy(list)
	st.toplevel_list = nil
}

@(private = "file")
toplevel_closed :: proc "c" (data: rawptr, h: Wl_Proxy) {
	context = cb_ctx()
	t := (^Wl_Toplevel)(data)
	st := t.st
	for x, i in st.toplevels {
		if x != t { continue }
		ordered_remove(&st.toplevels, i)
		break
	}
	st.lib.proxy_marshal_flags(h, TOPLEVEL_HANDLE_DESTROY, nil, st.lib.proxy_get_version(h), WL_MARSHAL_FLAG_DESTROY)
	t.handle = nil
	wl_toplevel_free(t)
}

@(private = "file")
toplevel_done :: proc "c" (data: rawptr, h: Wl_Proxy) {}

@(private = "file")
toplevel_title :: proc "c" (data: rawptr, h: Wl_Proxy, title: cstring) {
	context = cb_ctx()
	t := (^Wl_Toplevel)(data)
	delete(t.title, t.st.allocator)
	t.title = strings.clone_from_cstring(title, t.st.allocator)
}

@(private = "file")
toplevel_app_id :: proc "c" (data: rawptr, h: Wl_Proxy, app_id: cstring) {
	context = cb_ctx()
	t := (^Wl_Toplevel)(data)
	delete(t.app_id, t.st.allocator)
	t.app_id = strings.clone_from_cstring(app_id, t.st.allocator)
}

@(private = "file")
toplevel_identifier :: proc "c" (data: rawptr, h: Wl_Proxy, identifier: cstring) {
	context = cb_ctx()
	t := (^Wl_Toplevel)(data)
	delete(t.identifier, t.st.allocator)
	t.identifier = strings.clone_from_cstring(identifier, t.st.allocator)
}

@(private = "file")
wl_toplevel_free :: proc(t: ^Wl_Toplevel) {
	st := t.st
	places_toplevel_free(t, t.handle == nil)   // (closed: the compositor is told; the connection's end: only the proxy)
	if t.handle != nil { st.lib.proxy_destroy(t.handle) }
	delete(t.title, st.allocator)
	delete(t.app_id, st.allocator)
	delete(t.identifier, st.allocator)
	free(t, st.allocator)
}

// The windows: the toplevel list's. COSMIC's protocol places each of them. Else the compositor's IPC, else KDE's
// protocol, gives the windows and their rects: the list's are matched to them by app_id and title, in their order (front
// to back), and the ones not matched follow, in the order the compositor made them. Without the list, those windows
// themselves.
@(private)
wl_windows :: proc(st: ^Wl_State, provider: wm.Provider, s: ^Session) {
	if st != nil { st.lib.display_roundtrip(st.display) }
	if st != nil && st.places.cosmic != nil && st.toplevel_list != nil {
		places_cosmic_windows(st, s)
		return
	}
	placed: []wm.Window
	if provider != .None {
		if list, ok := wm.windows(provider, s.allocator); ok { placed = list }
	} else if st != nil {
		placed = places_kde_windows(st, s.allocator)
	}
	defer wm.windows_free(placed, s.allocator)
	if st == nil || st.toplevel_list == nil {
		for p in placed {
			append(&s.windows, Window{id = p.id, title = strings.clone(p.title, s.allocator), app_id = strings.clone(p.app_id, s.allocator),
				rect = rect_of(p.rect), has_rect = p.visible})
		}
		return
	}
	for t in st.toplevels { t.has_rect = false }
	taken := make([]bool, len(st.toplevels), context.temp_allocator)
	for p in placed {
		for t, i in st.toplevels {
			if taken[i] || t.app_id != p.app_id || t.title != p.title { continue }
			taken[i] = true
			t.rect, t.has_rect = rect_of(p.rect), p.visible
			wl_window_append(s, t)
			break
		}
	}
	for t, i in st.toplevels { if !taken[i] { wl_window_append(s, t) } }
}

@(private = "file")
rect_of :: proc(r: [4]i32) -> Rect { return {r[0], r[1], r[2], r[3]} }

@(private)
wl_window_append :: proc(s: ^Session, t: ^Wl_Toplevel) {
	append(&s.windows, Window{id = t.id, title = strings.clone(t.title, s.allocator), app_id = strings.clone(t.app_id, s.allocator),
		rect = t.rect, has_rect = t.has_rect})
}

////////////////////////////////
// shared-memory buffers

foreign import libc_capture "system:c"
@(default_calling_convention = "c", private = "file")
foreign libc_capture {
	memfd_create :: proc(name: cstring, flags: u32) -> i32 ---
}
@(private = "file") MFD_CLOEXEC :: 1

@(private = "file")
wl_buffer_make :: proc(st: ^Wl_State, size: [2]i32, stride: i32, format: u32) -> (b: Wl_Buffer, ok: bool) {
	if st.shm == nil || size.x <= 0 || size.y <= 0 || stride < size.x * 4 { return {}, false }
	l := &st.lib
	bytes := int(stride) * int(size.y)
	fd := posix.FD(memfd_create("gt-capture", MFD_CLOEXEC))
	if fd < 0 { return {}, false }
	// (the mapping and the pool hold the memory: the descriptor is not needed past them)
	defer posix.close(fd)
	if posix.ftruncate(fd, posix.off_t(bytes)) != .OK { return {}, false }
	mem := posix.mmap(nil, uint(bytes), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if mem == posix.MAP_FAILED { return {}, false }
	pool := l.proxy_marshal_flags(st.shm, WL_SHM_CREATE_POOL, l.shm_pool_interface, l.proxy_get_version(st.shm), 0, nil, i32(fd), i32(bytes))
	if pool == nil { posix.munmap(mem, uint(bytes)); return {}, false }
	proxy := l.proxy_marshal_flags(pool, WL_SHM_POOL_CREATE_BUFFER, l.buffer_interface, l.proxy_get_version(pool), 0, nil, i32(0), size.x, size.y, stride, format)
	l.proxy_marshal_flags(pool, WL_SHM_POOL_DESTROY, nil, l.proxy_get_version(pool), WL_MARSHAL_FLAG_DESTROY)
	if proxy == nil { posix.munmap(mem, uint(bytes)); return {}, false }
	return {proxy = proxy, mem = mem, bytes = bytes}, true
}

@(private = "file")
wl_buffer_free :: proc(st: ^Wl_State, b: ^Wl_Buffer) {
	if b.proxy != nil {
		st.lib.proxy_marshal_flags(b.proxy, WL_BUFFER_DESTROY, nil, st.lib.proxy_get_version(b.proxy), WL_MARSHAL_FLAG_DESTROY)
	}
	if b.mem != nil { posix.munmap(b.mem, uint(b.bytes)) }
	b^ = {}
}

// The formats read, the ones in B, G, R, A order first (no swap).
@(private = "file")
format_rank :: proc(format: u32) -> int {
	switch format {
	case SHM_XRGB8888, SHM_ARGB8888: return 2
	case SHM_XBGR8888, SHM_ABGR8888: return 1
	}
	return 0
}

////////////////////////////////
// captures

@(private = "file")
capture_settled :: proc(c: ^Wl_Capture) -> bool { return c.stage == .Ready || c.stage == .Failed }

@(private = "file")
capture_fail :: proc(c: ^Wl_Capture, err: Error) {
	if capture_settled(c) { return }
	c.stage = .Failed
	c.err = err
}

// An output's capture started: ext_image_copy_capture when the compositor has it, else wlr-screencopy.
@(private = "file")
capture_output_start :: proc(st: ^Wl_State, o: ^Wl_Output, c: ^Wl_Capture) {
	c^ = {st = st, opaque = true}
	l := &st.lib
	if st.copy_manager != nil && st.output_sources != nil {
		c.source = l.proxy_marshal_flags(st.output_sources, SOURCE_MANAGER_CREATE, &st.tables.source, l.proxy_get_version(st.output_sources), 0, nil, o.proxy)
		capture_session_start(st, c)
		return
	}
	if st.screencopy == nil { capture_fail(c, .Unsupported); return }
	c.screencopy = true
	// (screencopy's buffer is the output's, before its transform: the output's own says how it is turned)
	c.turn = Turn(u8(clamp(o.transform, 0, 7)))
	c.frame = l.proxy_marshal_flags(st.screencopy, SCREENCOPY_CAPTURE_OUTPUT, &st.tables.screencopy_frame, l.proxy_get_version(st.screencopy), 0, nil, i32(0), o.proxy)
	if c.frame == nil { capture_fail(c, .Failed); return }
	l.proxy_add_listener(c.frame, &st.listeners.screencopy_frame, c)
}

@(private = "file")
capture_toplevel_start :: proc(st: ^Wl_State, t: ^Wl_Toplevel, c: ^Wl_Capture) {
	c^ = {st = st}
	if st.copy_manager == nil || st.toplevel_sources == nil { capture_fail(c, .Unsupported); return }
	l := &st.lib
	c.source = l.proxy_marshal_flags(st.toplevel_sources, SOURCE_MANAGER_CREATE, &st.tables.source, l.proxy_get_version(st.toplevel_sources), 0, nil, t.handle)
	capture_session_start(st, c)
}

@(private = "file")
capture_session_start :: proc(st: ^Wl_State, c: ^Wl_Capture) {
	l := &st.lib
	if c.source == nil { capture_fail(c, .Failed); return }
	// (options 0: no pointer drawn in the picture)
	c.session = l.proxy_marshal_flags(st.copy_manager, COPY_MANAGER_CREATE_SESSION, &st.tables.copy_session, l.proxy_get_version(st.copy_manager), 0, nil, c.source, u32(0))
	if c.session == nil { capture_fail(c, .Failed); return }
	l.proxy_add_listener(c.session, &st.listeners.copy_session, c)
}

// The constraints are known: a buffer to them, a frame into it.
@(private = "file")
capture_session_frame :: proc(c: ^Wl_Capture) {
	st := c.st
	l := &st.lib
	if !c.has_format { capture_fail(c, .Unsupported); return }   // (dmabuf only)
	c.stride = c.size.x * 4
	if c.buffer.proxy != nil { wl_buffer_free(st, &c.buffer) }
	b, ok := wl_buffer_make(st, c.size, c.stride, c.format)
	if !ok { capture_fail(c, .Failed); return }
	c.buffer = b
	c.frame = l.proxy_marshal_flags(c.session, COPY_SESSION_CREATE_FRAME, &st.tables.copy_frame, l.proxy_get_version(c.session), 0, nil)
	if c.frame == nil { capture_fail(c, .Failed); return }
	l.proxy_add_listener(c.frame, &st.listeners.copy_frame, c)
	v := l.proxy_get_version(c.frame)
	l.proxy_marshal_flags(c.frame, COPY_FRAME_ATTACH_BUFFER, nil, v, 0, c.buffer.proxy)
	l.proxy_marshal_flags(c.frame, COPY_FRAME_DAMAGE_BUFFER, nil, v, 0, i32(0), i32(0), c.size.x, c.size.y)
	l.proxy_marshal_flags(c.frame, COPY_FRAME_CAPTURE, nil, v, 0)
	c.stage = .Copying
}

@(private = "file")
capture_screencopy_copy :: proc(c: ^Wl_Capture) {
	st := c.st
	l := &st.lib
	if c.stage != .Constraints { return }
	if !c.has_format { capture_fail(c, .Unsupported); return }
	b, ok := wl_buffer_make(st, c.size, c.stride, c.format)
	if !ok { capture_fail(c, .Failed); return }
	c.buffer = b
	l.proxy_marshal_flags(c.frame, SCREENCOPY_FRAME_COPY, nil, l.proxy_get_version(c.frame), 0, c.buffer.proxy)
	c.stage = .Copying
}

// Everything of a capture given back to the compositor.
@(private = "file")
capture_end :: proc(c: ^Wl_Capture) {
	st := c.st
	if st == nil { return }
	l := &st.lib
	if c.frame != nil {
		op := u32(c.screencopy ? SCREENCOPY_FRAME_DESTROY : COPY_FRAME_DESTROY)
		l.proxy_marshal_flags(c.frame, op, nil, l.proxy_get_version(c.frame), WL_MARSHAL_FLAG_DESTROY)
	}
	if c.session != nil { l.proxy_marshal_flags(c.session, COPY_SESSION_DESTROY, nil, l.proxy_get_version(c.session), WL_MARSHAL_FLAG_DESTROY) }
	if c.source != nil { l.proxy_marshal_flags(c.source, SOURCE_DESTROY, nil, l.proxy_get_version(c.source), WL_MARSHAL_FLAG_DESTROY) }
	wl_buffer_free(st, &c.buffer)
	c.frame, c.session, c.source = nil, nil, nil
}

// The picture of a capture that is Ready, upright, at scale 1 (the caller places it).
@(private = "file")
capture_frame :: proc(c: ^Wl_Capture, allocator: runtime.Allocator) -> Frame {
	src := ([^]u8)(c.buffer.mem)[:c.buffer.bytes]
	order := Pixel_Order.BGRA
	if c.format == SHM_ABGR8888 || c.format == SHM_XBGR8888 { order = .RGBA }
	opaque := c.opaque || c.format == SHM_XRGB8888 || c.format == SHM_XBGR8888
	return frame_from_buffer(src, c.size.x, c.size.y, c.stride, order, c.turn, c.y_invert, opaque, allocator, c.st.order)
}

// Dispatches until every capture is Ready or Failed, bounded by CAPTURE_TIMEOUT (the late ones then Failed).
@(private = "file")
captures_wait :: proc(st: ^Wl_State, caps: []Wl_Capture) {
	l := &st.lib
	d := st.display
	start := time.tick_now()
	settled :: proc(caps: []Wl_Capture) -> bool {
		for &c in caps { if !capture_settled(&c) { return false } }
		return true
	}
	fail_all :: proc(caps: []Wl_Capture) { for &c in caps { capture_fail(&c, .Failed) } }
	for {
		if l.display_dispatch_pending(d) < 0 { fail_all(caps); return }
		if settled(caps) { l.display_flush(d); return }
		for l.display_prepare_read(d) != 0 {
			if l.display_dispatch_pending(d) < 0 { fail_all(caps); return }
		}
		if settled(caps) { l.display_cancel_read(d); l.display_flush(d); return }
		l.display_flush(d)
		left := CAPTURE_TIMEOUT - time.tick_since(start)
		if left <= 0 { l.display_cancel_read(d); fail_all(caps); return }
		p := posix.pollfd{fd = posix.FD(st.fd), events = {.IN}}
		if posix.poll(&p, 1, i32(max(time.duration_milliseconds(left), 1))) > 0 {
			if l.display_read_events(d) < 0 { fail_all(caps); return }
		} else {
			l.display_cancel_read(d)
		}
	}
}

// ext_image_copy_capture_session_v1's events

@(private = "file")
session_buffer_size :: proc "c" (data: rawptr, s: Wl_Proxy, w, h: u32) { (^Wl_Capture)(data).size = {i32(w), i32(h)} }

@(private = "file")
session_shm_format :: proc "c" (data: rawptr, s: Wl_Proxy, format: u32) {
	context = cb_ctx()
	c := (^Wl_Capture)(data)
	if format_rank(format) > (c.has_format ? format_rank(c.format) : 0) {
		c.format = format
		c.has_format = true
	}
}

@(private = "file")
session_dmabuf_device :: proc "c" (data: rawptr, s: Wl_Proxy, device: ^Wl_Array) {}
@(private = "file")
session_dmabuf_format :: proc "c" (data: rawptr, s: Wl_Proxy, format: u32, modifiers: ^Wl_Array) {}

// The constraints are all said: the frame goes now (each output's as soon as its own are known: they are taken together).
@(private = "file")
session_done :: proc "c" (data: rawptr, s: Wl_Proxy) {
	context = cb_ctx()
	c := (^Wl_Capture)(data)
	if c.stage == .Constraints { capture_session_frame(c) }
}

@(private = "file")
session_stopped :: proc "c" (data: rawptr, s: Wl_Proxy) {
	context = cb_ctx()
	capture_fail((^Wl_Capture)(data), .Gone)
}

// ext_image_copy_capture_frame_v1's events

@(private = "file")
frame_transform :: proc "c" (data: rawptr, f: Wl_Proxy, transform: u32) { (^Wl_Capture)(data).turn = Turn(u8(min(transform, 7))) }
@(private = "file")
frame_damage :: proc "c" (data: rawptr, f: Wl_Proxy, x, y, w, h: i32) {}
@(private = "file")
frame_presentation_time :: proc "c" (data: rawptr, f: Wl_Proxy, sec_hi, sec_lo, nsec: u32) {}
@(private = "file")
frame_ready :: proc "c" (data: rawptr, f: Wl_Proxy) {
	c := (^Wl_Capture)(data)
	if c.stage == .Copying { c.stage = .Ready }
}

// A frame that failed on the buffer's constraints is tried once more with the new ones (the session says them again).
@(private = "file")
frame_failed :: proc "c" (data: rawptr, f: Wl_Proxy, reason: u32) {
	context = cb_ctx()
	c := (^Wl_Capture)(data)
	switch reason {
	case COPY_FAILED_BUFFER_CONSTRAINTS:
		if c.retried { capture_fail(c, .Failed); return }
		c.retried = true
		l := &c.st.lib
		l.proxy_marshal_flags(c.frame, COPY_FRAME_DESTROY, nil, l.proxy_get_version(c.frame), WL_MARSHAL_FLAG_DESTROY)
		c.frame = nil
		c.has_format = false
		c.stage = .Constraints
	case COPY_FAILED_STOPPED:
		capture_fail(c, .Gone)
	case:
		capture_fail(c, .Failed)
	}
}

// zwlr_screencopy_frame_v1's events

@(private = "file")
sc_buffer :: proc "c" (data: rawptr, f: Wl_Proxy, format, w, h, stride: u32) {
	context = cb_ctx()
	c := (^Wl_Capture)(data)
	if format_rank(format) > (c.has_format ? format_rank(c.format) : 0) {
		c.format, c.has_format = format, true
		c.size, c.stride = {i32(w), i32(h)}, i32(stride)
	}
	// (before version 3 no buffer_done follows: the one buffer event is all)
	if c.st.screencopy_version < SCREENCOPY_BUFFER_DONE_SINCE { capture_screencopy_copy(c) }
}
@(private = "file")
sc_flags :: proc "c" (data: rawptr, f: Wl_Proxy, flags: u32) { (^Wl_Capture)(data).y_invert = flags & SCREENCOPY_FLAG_Y_INVERT != 0 }
@(private = "file")
sc_ready :: proc "c" (data: rawptr, f: Wl_Proxy, sec_hi, sec_lo, nsec: u32) {
	c := (^Wl_Capture)(data)
	if c.stage == .Copying { c.stage = .Ready }
}
@(private = "file")
sc_failed :: proc "c" (data: rawptr, f: Wl_Proxy) {
	context = cb_ctx()
	capture_fail((^Wl_Capture)(data), .Failed)
}
@(private = "file")
sc_damage :: proc "c" (data: rawptr, f: Wl_Proxy, x, y, w, h: u32) {}
@(private = "file")
sc_linux_dmabuf :: proc "c" (data: rawptr, f: Wl_Proxy, format, w, h: u32) {}
@(private = "file")
sc_buffer_done :: proc "c" (data: rawptr, f: Wl_Proxy) {
	context = cb_ctx()
	capture_screencopy_copy((^Wl_Capture)(data))
}

////////////////////////////////
// what capture.odin asks

// The outputs `ids` captured together (started all, then waited for), each placed on the desktop. On an error the
// frames already made are freed.
@(private)
wl_capture_outputs :: proc(st: ^Wl_State, ids: []u64, allocator: runtime.Allocator) -> (frames: []Frame, err: Error) {
	st.lib.display_roundtrip(st.display)   // (an output unplugged since outputs(): Gone, not a protocol error)
	caps := make([]Wl_Capture, len(ids), context.temp_allocator)
	places := make([]Rect, len(ids), context.temp_allocator)
	for id, i in ids {
		o := wl_output_by_id(st, id)
		if o == nil { caps[i] = {stage = .Failed, err = .Gone}; continue }
		places[i], _ = wl_output_place(o)
		capture_output_start(st, o, &caps[i])
	}
	st.lib.display_flush(st.display)
	captures_wait(st, caps)
	defer { for &c in caps { capture_end(&c) } }
	for c in caps { if c.stage != .Ready { return nil, c.err != .None ? c.err : .Failed } }
	frames = make([]Frame, len(ids), allocator)
	for &c, i in caps {
		f := capture_frame(&c, allocator)
		f.origin = {places[i].x, places[i].y}
		f.scale = places[i].w > 0 ? f32(f.width) / f32(places[i].w) : 1
		frames[i] = f
	}
	return frames, .None
}

@(private)
wl_output_frame :: proc(st: ^Wl_State, id: u64, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	ids := [1]u64{id}
	frames := wl_capture_outputs(st, ids[:], allocator) or_return
	defer delete(frames, allocator)
	return frames[0], .None
}

@(private)
wl_desktop :: proc(st: ^Wl_State, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	st.lib.display_roundtrip(st.display)
	ids := make([dynamic]u64, context.temp_allocator)
	for o in st.outputs { if o.mode.x > 0 && o.mode.y > 0 { append(&ids, u64(o.global)) } }
	if len(ids) == 0 { return {}, .Failed }
	frames := wl_capture_outputs(st, ids[:], allocator) or_return
	defer {
		for &p in frames { frame_free(&p) }
		delete(frames, allocator)
	}
	if len(frames) == 1 {
		f = frames[0]
		frames[0] = {}
		return f, .None
	}
	out, ok := compose(frames, allocator)
	return out, ok ? .None : .Failed
}

// A window's own picture. Placed where the compositor's IPC said it is; without that, at the desktop's origin and the
// outputs' highest scale (a guess: the protocol says neither).
@(private)
wl_window_frame :: proc(st: ^Wl_State, id: u64, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	if st.copy_manager == nil || st.toplevel_sources == nil { return {}, .Unsupported }
	st.lib.display_roundtrip(st.display)
	t: ^Wl_Toplevel
	for x in st.toplevels { if x.id == id { t = x } }
	if t == nil { return {}, .Gone }
	caps: [1]Wl_Capture
	capture_toplevel_start(st, t, &caps[0])
	st.lib.display_flush(st.display)
	captures_wait(st, caps[:])
	defer capture_end(&caps[0])
	if caps[0].stage != .Ready { return {}, caps[0].err != .None ? caps[0].err : .Failed }
	f = capture_frame(&caps[0], allocator)
	if t.has_rect && t.rect.w > 0 {
		f.origin = {t.rect.x, t.rect.y}
		f.scale = f32(f.width) / f32(t.rect.w)
	} else {
		scale: f32 = 1
		for o in st.outputs { _, s := wl_output_place(o); scale = max(scale, s) }
		f.scale = scale
	}
	return f, .None
}


////////////////////////////////
// streams

// A stream's capture, kept open from frame to frame. ext_image_copy_capture: one session for the source, its buffer
// constraints said again whenever they change, a frame asked per picture (the compositor answers once the source was
// damaged). wlr-screencopy: a frame object per picture, its buffer said each time, copy for the first and
// copy_with_damage after (it waits for a change). Either way two shm buffers are taken in turn: the compositor fills one
// while the other is read.
@(private)
Wl_Stream :: struct {
	st:            ^Wl_State,
	screencopy:    bool,
	is_window:     bool,
	output:        u64,        // the output's id (an output, a region), looked up each time: it may go
	toplevel:      u64,        // the window's id
	opaque:        bool,       // a screen: the alpha byte means nothing
	cursor:        bool,
	source:        Wl_Proxy,   // ext_image_capture_source_v1
	session:       Wl_Proxy,   // ext_image_copy_capture_session_v1
	stopped:       bool,       // the session ended: the source is gone

	// the session's constraints as said last, and the ones being said (taken at done)
	size:          [2]i32,
	format:        u32,
	has_format:    bool,
	known:         bool,
	pending_size:  [2]i32,
	pending_format: u32,
	pending_has_format: bool,
	done_since_start: bool,    // constraints were said since the frame in flight was asked

	buffers:       [2]Wl_Buffer,
	buffer_size:   [2]i32,     // what the buffers were made for
	buffer_stride: i32,
	buffer_format: u32,
	next_buffer:   int,
	copied:        bool,       // a screencopy frame was copied: the next ones wait for damage

	// the frame in flight (frame nil: none)
	frame:         Wl_Proxy,
	stage:         Wl_Stage,
	err:           Error,
	retry:         bool,       // it failed on the buffer's constraints: asked again with the new ones
	buffer:        int,        // the buffer it fills
	turn:          Turn,
	y_invert:      bool,
	present:       i64,        // when it was presented (ns, the compositor's monotonic clock); 0: not said
	sc_size:       [2]i32,     // screencopy's buffer, as this frame's events say
	sc_stride:     i32,
	sc_format:     u32,
	sc_has_format: bool,
}

// How long a stream's start waits for the compositor's constraints.
@(private = "file") STREAM_OPEN_TIMEOUT :: 2 * time.Second

@(private)
wl_stream_open :: proc(st: ^Wl_State, stream: ^Stream) -> (err: Error) {
	l := &st.lib
	l.display_roundtrip(st.display)   // (an output or a window gone since the lists: Gone, not a protocol error)
	ws := new(Wl_Stream, stream.allocator)
	ws^ = {st = st, cursor = stream.options.cursor}
	defer if err != .None {
		wl_stream_end(ws)
		free(ws, stream.allocator)
	}

	switch v in stream.source {
	case Stream_Output:
		ws.output = v.id
	case Stream_Region:
		outs := make([dynamic]Output, context.temp_allocator)
		for o in st.outputs {
			if o.mode.x <= 0 || o.mode.y <= 0 { continue }
			r, scale := wl_output_place(o)
			append(&outs, Output{id = u64(o.global), rect = r, scale = scale})
		}
		i := output_most_of(outs[:], v.rect)
		if i < 0 { return .Failed }
		ws.output = outs[i].id
	case Stream_Window:
		ws.is_window = true
		ws.toplevel = v.id
	case:
		return .Failed
	}

	if !ws.is_window {
		o := wl_output_by_id(st, ws.output)
		if o == nil { return .Gone }
		ws.opaque = true
		switch {
		case st.copy_manager != nil && st.output_sources != nil:
			ws.source = l.proxy_marshal_flags(st.output_sources, SOURCE_MANAGER_CREATE, &st.tables.source, l.proxy_get_version(st.output_sources), 0, nil, o.proxy)
		case st.screencopy != nil:
			// (no session to open: each frame says its buffer)
			ws.screencopy = true
			stream.cursor = ws.cursor
			stream.impl = ws
			return .None
		case:
			return .Unsupported
		}
	} else {
		if st.copy_manager == nil || st.toplevel_sources == nil { return .Unsupported }
		t: ^Wl_Toplevel
		for x in st.toplevels { if x.id == ws.toplevel { t = x } }
		if t == nil { return .Gone }
		ws.source = l.proxy_marshal_flags(st.toplevel_sources, SOURCE_MANAGER_CREATE, &st.tables.source, l.proxy_get_version(st.toplevel_sources), 0, nil, t.handle)
	}
	if ws.source == nil { return .Failed }
	options := u32(ws.cursor ? COPY_SESSION_PAINT_CURSORS : 0)
	ws.session = l.proxy_marshal_flags(st.copy_manager, COPY_MANAGER_CREATE_SESSION, &st.tables.copy_session, l.proxy_get_version(st.copy_manager), 0, nil, ws.source, options)
	if ws.session == nil { return .Failed }
	l.proxy_add_listener(ws.session, &st.listeners.stream_session, ws)

	// the constraints, before the first frame can be asked
	start := time.tick_now()
	for !ws.known && !ws.stopped {
		left := STREAM_OPEN_TIMEOUT - time.tick_since(start)
		if left <= 0 { return .Failed }
		if !wl_dispatch_wait(st, left, wl_stream_known, ws) { return .Failed }
	}
	if ws.stopped { return .Gone }
	if !ws.has_format { return .Unsupported }   // (dmabuf only)
	stream.cursor = ws.cursor
	stream.impl = ws
	return .None
}

@(private)
wl_stream_close :: proc(stream: ^Stream) {
	ws := (^Wl_Stream)(stream.impl)
	if ws == nil { return }
	wl_stream_end(ws)
	free(ws, stream.allocator)
	stream.impl = nil
}

// Everything of a stream given back to the compositor.
@(private = "file")
wl_stream_end :: proc(ws: ^Wl_Stream) {
	st := ws.st
	l := &st.lib
	wl_stream_frame_end(ws)
	if ws.session != nil { l.proxy_marshal_flags(ws.session, COPY_SESSION_DESTROY, nil, l.proxy_get_version(ws.session), WL_MARSHAL_FLAG_DESTROY) }
	if ws.source != nil { l.proxy_marshal_flags(ws.source, SOURCE_DESTROY, nil, l.proxy_get_version(ws.source), WL_MARSHAL_FLAG_DESTROY) }
	ws.session, ws.source = nil, nil
	for &b in ws.buffers { wl_buffer_free(st, &b) }
	l.display_flush(st.display)
}

@(private)
wl_stream_next :: proc(st: ^Wl_State, stream: ^Stream, timeout: time.Duration) -> (f: Stream_Frame, ok: bool, err: Error) {
	ws := (^Wl_Stream)(stream.impl)
	deadline := monotonic_ns() + i64(timeout)
	for {
		now := monotonic_ns()
		if ws.frame == nil {
			if ws.stopped { return {}, false, .Gone }
			due := stream_pacer_due(&stream.pacer)
			ready_to_ask := ws.screencopy || ws.known
			if now < due || !ready_to_ask {
				if now >= deadline { return {}, false, .None }
				// (the pace: only the end of the session cuts the wait short; the constraints: their done does)
				until := ready_to_ask ? min(due, deadline) : deadline
				done := ready_to_ask ? wl_stream_stopped : wl_stream_known
				if !wl_dispatch_wait(st, time.Duration(max(until - now, 0)), done, ws) { return {}, false, .Failed }
				continue
			}
			if e := wl_stream_frame_start(ws); e != .None { return {}, false, e }
		}
		if ws.stage == .Constraints || ws.stage == .Copying {
			// (the frame stays asked past the deadline: the next call waits for it)
			if now >= deadline { return {}, false, .None }
			if !wl_dispatch_wait(st, time.Duration(deadline - now), wl_stream_frame_settled, ws) { return {}, false, .Failed }
			continue
		}
		stage, frame_err, retry, filled := ws.stage, ws.err, ws.retry, ws.buffer
		wl_stream_frame_end(ws)
		if stage == .Failed {
			if retry { continue }
			return {}, false, frame_err != .None ? frame_err : .Failed
		}
		ws.next_buffer = 1 - filled
		ws.copied = true
		at := ws.present != 0 ? ws.present : monotonic_ns()
		f, ok = wl_stream_frame(ws, stream, filled, at)
		if !ok { return {}, false, .Gone }   // (the region is off its output: the output changed)
		// The next frame asked now when it is due already (the conversion took the interval): the compositor fills the
		// other buffer while the caller encodes this one.
		if monotonic_ns() >= stream_pacer_due(&stream.pacer) && !ws.stopped && (ws.screencopy || ws.known) {
			_ = wl_stream_frame_start(ws)
		}
		return f, true, .None
	}
}

// A frame asked into the next buffer.
@(private = "file")
wl_stream_frame_start :: proc(ws: ^Wl_Stream) -> Error {
	st := ws.st
	l := &st.lib
	ws.buffer = ws.next_buffer
	ws.err, ws.retry, ws.present, ws.y_invert, ws.turn = .None, false, 0, false, .Normal
	ws.done_since_start = false
	if ws.screencopy {
		o := wl_output_by_id(st, ws.output)
		if o == nil { return .Gone }
		// (screencopy's buffer is the output's, before its transform: the output's own says how it is turned)
		ws.turn = Turn(u8(clamp(o.transform, 0, 7)))
		ws.sc_has_format = false
		ws.frame = l.proxy_marshal_flags(st.screencopy, SCREENCOPY_CAPTURE_OUTPUT, &st.tables.screencopy_frame, l.proxy_get_version(st.screencopy), 0, nil, i32(ws.cursor ? 1 : 0), o.proxy)
		if ws.frame == nil { return .Failed }
		ws.stage = .Constraints
		l.proxy_add_listener(ws.frame, &st.listeners.stream_screencopy, ws)
	} else {
		if !wl_stream_buffers(ws, ws.size, ws.size.x * 4, ws.format) { return .Failed }
		ws.frame = l.proxy_marshal_flags(ws.session, COPY_SESSION_CREATE_FRAME, &st.tables.copy_frame, l.proxy_get_version(ws.session), 0, nil)
		if ws.frame == nil { return .Failed }
		l.proxy_add_listener(ws.frame, &st.listeners.stream_frame, ws)
		v := l.proxy_get_version(ws.frame)
		l.proxy_marshal_flags(ws.frame, COPY_FRAME_ATTACH_BUFFER, nil, v, 0, ws.buffers[ws.buffer].proxy)
		// (the whole buffer: what it holds is the frame two before, not the one the compositor last wrote in it)
		l.proxy_marshal_flags(ws.frame, COPY_FRAME_DAMAGE_BUFFER, nil, v, 0, i32(0), i32(0), ws.size.x, ws.size.y)
		l.proxy_marshal_flags(ws.frame, COPY_FRAME_CAPTURE, nil, v, 0)
		ws.stage = .Copying
	}
	l.display_flush(st.display)
	return .None
}

@(private = "file")
wl_stream_frame_end :: proc(ws: ^Wl_Stream) {
	if ws.frame == nil { return }
	l := &ws.st.lib
	op := u32(ws.screencopy ? SCREENCOPY_FRAME_DESTROY : COPY_FRAME_DESTROY)
	l.proxy_marshal_flags(ws.frame, op, nil, l.proxy_get_version(ws.frame), WL_MARSHAL_FLAG_DESTROY)
	ws.frame = nil
}

// Both buffers made for `size`, `stride` and `format`, unless they are already.
@(private = "file")
wl_stream_buffers :: proc(ws: ^Wl_Stream, size: [2]i32, stride: i32, format: u32) -> bool {
	if ws.buffers[0].proxy != nil && ws.buffer_size == size && ws.buffer_stride == stride && ws.buffer_format == format { return true }
	for &b in ws.buffers { wl_buffer_free(ws.st, &b) }
	for &b in ws.buffers {
		made, ok := wl_buffer_make(ws.st, size, stride, format)
		if !ok {
			for &x in ws.buffers { wl_buffer_free(ws.st, &x) }
			return false
		}
		b = made
	}
	ws.buffer_size, ws.buffer_stride, ws.buffer_format = size, stride, format
	return true
}

// screencopy's buffer is said: the copy asked (with damage after the first: the compositor waits for a change; the
// first is a plain copy, or a still screen would never give one).
@(private = "file")
wl_stream_sc_copy :: proc(ws: ^Wl_Stream) {
	if ws.stage != .Constraints { return }
	if !ws.sc_has_format { wl_stream_fail(ws, .Unsupported); return }
	if !wl_stream_buffers(ws, ws.sc_size, ws.sc_stride, ws.sc_format) { wl_stream_fail(ws, .Failed); return }
	l := &ws.st.lib
	op := u32(SCREENCOPY_FRAME_COPY)
	if ws.copied && ws.st.screencopy_version >= SCREENCOPY_COPY_WITH_DAMAGE_SINCE { op = SCREENCOPY_FRAME_COPY_WITH_DAMAGE }
	l.proxy_marshal_flags(ws.frame, op, nil, l.proxy_get_version(ws.frame), 0, ws.buffers[ws.buffer].proxy)
	ws.stage = .Copying
}

@(private = "file")
wl_stream_fail :: proc(ws: ^Wl_Stream, err: Error) {
	if ws.stage == .Ready || ws.stage == .Failed { return }
	ws.stage = .Failed
	ws.err = err
}

// The filled buffer as the stream's frame, placed on the desktop.
@(private = "file")
wl_stream_frame :: proc(ws: ^Wl_Stream, stream: ^Stream, filled: int, at: i64) -> (Stream_Frame, bool) {
	st := ws.st
	b := ws.buffers[filled]
	src := ([^]u8)(b.mem)[:b.bytes]
	order := Pixel_Order.BGRA
	if ws.buffer_format == SHM_ABGR8888 || ws.buffer_format == SHM_XBGR8888 { order = .RGBA }
	opaque := ws.opaque || ws.buffer_format == SHM_XRGB8888 || ws.buffer_format == SHM_XBGR8888
	w, h := turned_size(ws.buffer_size.x, ws.buffer_size.y, ws.turn)
	dst := stream_frame_target(stream, w, h)
	f := frame_from_buffer_into(dst, src, ws.buffer_size.x, ws.buffer_size.y, ws.buffer_stride, order, ws.turn, ws.y_invert, opaque)
	if !ws.is_window {
		if o := wl_output_by_id(st, ws.output); o != nil {
			r, _ := wl_output_place(o)
			f.origin = {r.x, r.y}
			f.scale = r.w > 0 ? f32(f.width) / f32(r.w) : 1
		}
	} else {
		t: ^Wl_Toplevel
		for x in st.toplevels { if x.id == ws.toplevel { t = x } }
		if t != nil && t.has_rect && t.rect.w > 0 {
			f.origin = {t.rect.x, t.rect.y}
			f.scale = f32(f.width) / f32(t.rect.w)
		} else {
			scale: f32 = 1
			for o in st.outputs { _, s := wl_output_place(o); scale = max(scale, s) }
			f.scale = scale
		}
	}
	return stream_frame_finish(stream, f, at)
}

@(private = "file")
wl_stream_known :: proc(data: rawptr) -> bool {
	ws := (^Wl_Stream)(data)
	return ws.known || ws.stopped
}

@(private = "file")
wl_stream_stopped :: proc(data: rawptr) -> bool { return (^Wl_Stream)(data).stopped }

@(private = "file")
wl_stream_frame_settled :: proc(data: rawptr) -> bool {
	ws := (^Wl_Stream)(data)
	return ws.stage == .Ready || ws.stage == .Failed
}

// Dispatches what came, waiting up to `wait` for more unless `done` says it is there already. False: the connection is
// broken.
@(private = "file")
wl_dispatch_wait :: proc(st: ^Wl_State, wait: time.Duration, done: proc(data: rawptr) -> bool, data: rawptr) -> bool {
	l := &st.lib
	d := st.display
	if l.display_dispatch_pending(d) < 0 { return false }
	if done(data) { l.display_flush(d); return true }
	for l.display_prepare_read(d) != 0 {
		if l.display_dispatch_pending(d) < 0 { return false }
	}
	if done(data) {
		l.display_cancel_read(d)
		l.display_flush(d)
		return true
	}
	l.display_flush(d)
	ms := i32(0)
	if wait > 0 { ms = i32(max(time.duration_milliseconds(wait), 1)) }
	p := posix.pollfd{fd = posix.FD(st.fd), events = {.IN}}
	if posix.poll(&p, 1, ms) > 0 {
		if l.display_read_events(d) < 0 { return false }
		return l.display_dispatch_pending(d) >= 0
	}
	l.display_cancel_read(d)
	return true
}

// a stream's ext_image_copy_capture_session_v1 events: the constraints, taken whole at done

@(private = "file")
ss_buffer_size :: proc "c" (data: rawptr, s: Wl_Proxy, w, h: u32) { (^Wl_Stream)(data).pending_size = {i32(w), i32(h)} }

@(private = "file")
ss_shm_format :: proc "c" (data: rawptr, s: Wl_Proxy, format: u32) {
	context = cb_ctx()
	ws := (^Wl_Stream)(data)
	if format_rank(format) > (ws.pending_has_format ? format_rank(ws.pending_format) : 0) {
		ws.pending_format = format
		ws.pending_has_format = true
	}
}

@(private = "file")
ss_done :: proc "c" (data: rawptr, s: Wl_Proxy) {
	ws := (^Wl_Stream)(data)
	ws.size, ws.format, ws.has_format = ws.pending_size, ws.pending_format, ws.pending_has_format
	ws.pending_has_format = false
	ws.known = ws.has_format && ws.size.x > 0 && ws.size.y > 0
	ws.done_since_start = true
}

@(private = "file")
ss_stopped :: proc "c" (data: rawptr, s: Wl_Proxy) {
	ws := (^Wl_Stream)(data)
	ws.stopped = true
	if ws.frame != nil && ws.stage != .Ready && ws.stage != .Failed {
		ws.stage = .Failed
		ws.err = .Gone
	}
}

// a stream's ext_image_copy_capture_frame_v1 events

@(private = "file")
sf_transform :: proc "c" (data: rawptr, f: Wl_Proxy, transform: u32) { (^Wl_Stream)(data).turn = Turn(u8(min(transform, 7))) }

@(private = "file")
sf_presentation_time :: proc "c" (data: rawptr, f: Wl_Proxy, sec_hi, sec_lo, nsec: u32) {
	(^Wl_Stream)(data).present = presentation_ns(sec_hi, sec_lo, nsec)
}

@(private = "file")
sf_ready :: proc "c" (data: rawptr, f: Wl_Proxy) {
	ws := (^Wl_Stream)(data)
	if ws.stage == .Copying { ws.stage = .Ready }
}

// A frame that failed on the buffer's constraints is asked again: at once when the new constraints were said already,
// else once they are (known goes false until the session's done).
@(private = "file")
sf_failed :: proc "c" (data: rawptr, f: Wl_Proxy, reason: u32) {
	ws := (^Wl_Stream)(data)
	if ws.stage == .Ready || ws.stage == .Failed { return }
	ws.stage = .Failed
	switch reason {
	case COPY_FAILED_BUFFER_CONSTRAINTS:
		ws.retry = true
		if !ws.done_since_start { ws.known = false }
	case COPY_FAILED_STOPPED:
		ws.err = .Gone
		ws.stopped = true
	case:
		ws.err = .Failed
	}
}

// a stream's zwlr_screencopy_frame_v1 events

@(private = "file")
ssc_buffer :: proc "c" (data: rawptr, f: Wl_Proxy, format, w, h, stride: u32) {
	context = cb_ctx()
	ws := (^Wl_Stream)(data)
	if format_rank(format) > (ws.sc_has_format ? format_rank(ws.sc_format) : 0) {
		ws.sc_format, ws.sc_has_format = format, true
		ws.sc_size, ws.sc_stride = {i32(w), i32(h)}, i32(stride)
	}
	// (before version 3 no buffer_done follows: the one buffer event is all)
	if ws.st.screencopy_version < SCREENCOPY_BUFFER_DONE_SINCE { wl_stream_sc_copy(ws) }
}

@(private = "file")
ssc_flags :: proc "c" (data: rawptr, f: Wl_Proxy, flags: u32) { (^Wl_Stream)(data).y_invert = flags & SCREENCOPY_FLAG_Y_INVERT != 0 }

@(private = "file")
ssc_ready :: proc "c" (data: rawptr, f: Wl_Proxy, sec_hi, sec_lo, nsec: u32) {
	ws := (^Wl_Stream)(data)
	ws.present = presentation_ns(sec_hi, sec_lo, nsec)
	if ws.stage == .Copying { ws.stage = .Ready }
}

@(private = "file")
ssc_failed :: proc "c" (data: rawptr, f: Wl_Proxy) {
	ws := (^Wl_Stream)(data)
	if ws.stage == .Ready || ws.stage == .Failed { return }
	ws.stage = .Failed
	ws.err = .Failed
}

@(private = "file")
ssc_buffer_done :: proc "c" (data: rawptr, f: Wl_Proxy) {
	context = cb_ctx()
	wl_stream_sc_copy((^Wl_Stream)(data))
}

// A presentation time (seconds in two halves, nanoseconds) in nanoseconds.
@(private = "file")
presentation_ns :: proc "contextless" (sec_hi, sec_lo, nsec: u32) -> i64 {
	return i64(u64(sec_hi) << 32 | u64(sec_lo)) * 1_000_000_000 + i64(nsec)
}
