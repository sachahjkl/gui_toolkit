#+build linux
package platform

// Overlay windows on Wayland (overlay.odin): a zwlr_layer_shell_v1 surface on the overlay layer of one output, anchored
// to its four edges (its size is the output's, given by the layer surface's configure), with an exclusive zone of -1
// (the other windows do not move, and it covers the panels too) and the keyboard on demand (a click gives it the
// keyboard; it never takes it by itself). The output is the one whose logical place (zxdg_output_v1) is the overlay's
// area. Every wl_output is kept for that, with its place.

import "core:strings"

@(private)
Wl_Output_Info :: struct {
	name:         u32,        // the registry's
	proxy:        Wl_Proxy,
	xdg:          Wl_Proxy,   // its zxdg_output_v1 (nil: no xdg-output manager)
	position:     [2]i32,     // wl_output.geometry: compositor space, with no fractional scale in it
	mode:         [2]i32,     // the current mode's pixels
	scale:        i32,
	transform:    i32,
	logical_pos:  [2]i32,     // zxdg_output_v1's
	logical_size: [2]i32,
}

@(private)
Xdg_Output_Listener :: struct {
	logical_position: proc "c" (data: rawptr, o: Wl_Proxy, x, y: i32),
	logical_size:     proc "c" (data: rawptr, o: Wl_Proxy, w, h: i32),
	done:             proc "c" (data: rawptr, o: Wl_Proxy),
	name:             proc "c" (data: rawptr, o: Wl_Proxy, name: cstring),
	description:      proc "c" (data: rawptr, o: Wl_Proxy, description: cstring),
}
@(private) xdg_output_listener := Xdg_Output_Listener{xdg_output_position, xdg_output_size, xdg_output_done, xdg_output_name, xdg_output_description}

@(private) xdg_output_position :: proc "c" (data: rawptr, o: Wl_Proxy, x, y: i32) { (^Wl_Output_Info)(data).logical_pos = {x, y} }
@(private) xdg_output_size :: proc "c" (data: rawptr, o: Wl_Proxy, w, h: i32) { (^Wl_Output_Info)(data).logical_size = {w, h} }
@(private) xdg_output_done :: proc "c" (data: rawptr, o: Wl_Proxy) {}
@(private) xdg_output_name :: proc "c" (data: rawptr, o: Wl_Proxy, name: cstring) {}
@(private) xdg_output_description :: proc "c" (data: rawptr, o: Wl_Proxy, description: cstring) {}

// A wl_output the registry announced (bound by the caller): kept with its listener, and its xdg-output asked for.
@(private)
wl_output_add :: proc(name: u32, proxy: Wl_Proxy) -> ^Wl_Output_Info {
	if proxy == nil { return nil }
	o := new(Wl_Output_Info, wlc.outputs.allocator)
	o.name, o.proxy, o.scale = name, proxy, 1
	wl.proxy_add_listener(proxy, &output_listener, o)
	append(&wlc.outputs, o)
	wl_xdg_output_of(o)
	return o
}

@(private)
wl_xdg_output_of :: proc(o: ^Wl_Output_Info) {
	if wlc.xdg_output_manager == nil || o.xdg != nil { return }
	o.xdg = wl.proxy_marshal_flags(wlc.xdg_output_manager, ZXDG_OUTPUT_MANAGER_GET_XDG_OUTPUT, &zxdg_output_iface,
		wl.proxy_get_version(wlc.xdg_output_manager), 0, nil, o.proxy)
	if o.xdg != nil { wl.proxy_add_listener(o.xdg, &xdg_output_listener, o) }
}

// An output went (unplugged, turned off). The first one's proxy stays: the windows' scale and rate read it.
@(private)
wl_output_remove :: proc(name: u32) {
	for o, i in wlc.outputs {
		if o.name != name { continue }
		if o.xdg != nil { wl.proxy_marshal_flags(o.xdg, ZXDG_OUTPUT_DESTROY, nil, wl.proxy_get_version(o.xdg), WL_MARSHAL_FLAG_DESTROY) }
		if o.proxy == wlc.output {
			wl.proxy_set_user_data(o.proxy, nil)   // (its listener reads the info through it)
		} else {
			wl.proxy_destroy(o.proxy)
		}
		ordered_remove(&wlc.outputs, i)
		free(o, wlc.outputs.allocator)
		return
	}
}

// An output's place on the desktop (logical) and its physical pixels per logical one. Without xdg-output: wl_output's
// position and its mode divided by its integer scale.
@(private)
wl_output_info_place :: proc(o: ^Wl_Output_Info) -> (place: [4]int, scale: f32) {
	px := o.mode
	if o.transform & 1 != 0 { px = {px.y, px.x} }   // (a quarter turn: the screen is the mode on its side)
	if o.logical_size.x > 0 && o.logical_size.y > 0 {
		place = {int(o.logical_pos.x), int(o.logical_pos.y), int(o.logical_size.x), int(o.logical_size.y)}
		scale = px.x > 0 ? f32(px.x) / f32(o.logical_size.x) : f32(max(o.scale, 1))
		return
	}
	s := max(o.scale, 1)
	return {int(o.position.x), int(o.position.y), int(px.x / s), int(px.y / s)}, f32(s)
}

@(private)
Layer_Surface_Listener :: struct {
	configure: proc "c" (data: rawptr, ls: Wl_Proxy, serial, width, height: u32),
	closed:    proc "c" (data: rawptr, ls: Wl_Proxy),
}
@(private) layer_surface_listener := Layer_Surface_Listener{layer_surface_configure, layer_surface_closed}

// The size the compositor gives the surface (its output's, anchored to the four edges), acked before the next buffer.
@(private)
layer_surface_configure :: proc "c" (data: rawptr, ls: Wl_Proxy, serial, width, height: u32) {
	context = wl_ctx_real()
	wl.proxy_marshal_flags(ls, ZWLR_LAYER_SURFACE_ACK_CONFIGURE, nil, wl.proxy_get_version(ls), 0, serial)
	st := (^Wl_Window_State)(data)
	if st == nil || st.win == nil { return }
	st.acked = true
	if width > 0 && height > 0 { st.logical = {int(width), int(height)} }
	wl_size_from_logical(st.win, st)
	st.win.paint_requested = true
}

// The compositor took the surface away (its output went): what the user closing a window says.
@(private)
layer_surface_closed :: proc "c" (data: rawptr, ls: Wl_Proxy) {
	context = wl_ctx_real()
	st := (^Wl_Window_State)(data)
	if st != nil && st.win != nil { st.win.closed = true; wl_push(st.win, {kind = .Close}) }
}

@(private)
wl_open_overlay :: proc(w: ^Window, title: string, area: [4]int) -> bool {
	if !wl_connect() { report_missing("libwayland-client (or xdg-shell)"); return false }
	if wlc.layer_shell == nil { report_missing("zwlr_layer_shell_v1 (an overlay window)"); return false }
	st := new(Wl_Window_State)
	st.win = w
	st.transparent = true
	st.overlay = true
	st.title = strings.clone(title)
	st.toplevel = .Normal
	w.wl = st

	// the output, and the scale and size of the first picture until the compositor says them
	places := make([][4]int, len(wlc.outputs), context.temp_allocator)
	for o, i in wlc.outputs { places[i], _ = wl_output_info_place(o) }
	w.dpi_scale = f32(wlc.output_scale)
	st.logical = {1, 1}
	if i := overlay_output_index(places, area); i >= 0 {
		o := wlc.outputs[i]
		place, scale := wl_output_info_place(o)
		st.overlay_output = o.name
		st.logical = {max(place[2], 1), max(place[3], 1)}
		// (a fractional scale needs the viewport: without it the buffer has the output's integer scale)
		have_fractional := wlc.fractional_manager != nil && wlc.viewporter != nil
		w.dpi_scale = have_fractional ? scale : f32(max(o.scale, 1))
	}
	if !wl_surface_make(w, st, role = true) { delete(st.title); free(st); w.wl = nil; return false }
	append(&wlc.windows, w)
	wl_first_configure_wait(st)
	w.show = .Normal
	w.paint_requested = true
	return true
}

// The layer surface of an overlay's surface, committed without a buffer by the caller (the compositor answers with the
// first configure). (wl_surface_make, at the opening and at a show after a hide.)
@(private)
wl_layer_make :: proc(st: ^Wl_Window_State) {
	st.acked = false
	output: Wl_Proxy
	for o in wlc.outputs { if o.name == st.overlay_output { output = o.proxy } }   // (gone: the compositor's choice)
	namespace := strings.clone_to_cstring(st.title, context.temp_allocator)
	v := wl.proxy_get_version(wlc.layer_shell)
	st.layer_surface = wl.proxy_marshal_flags(wlc.layer_shell, ZWLR_LAYER_SHELL_GET_LAYER_SURFACE, &zwlr_layer_surface_iface, v, 0,
		nil, st.surface, output, u32(ZWLR_LAYER_OVERLAY), namespace)
	if st.layer_surface == nil { return }
	wl.proxy_add_listener(st.layer_surface, &layer_surface_listener, st)
	ls := st.layer_surface
	wl.proxy_marshal_flags(ls, ZWLR_LAYER_SURFACE_SET_ANCHOR, nil, v, 0, u32(ZWLR_ANCHOR_ALL))
	wl.proxy_marshal_flags(ls, ZWLR_LAYER_SURFACE_SET_EXCLUSIVE_ZONE, nil, v, 0, i32(-1))
	// (before version 4 the value was a bool, and 1 took the keyboard for good: none then)
	KEYBOARD_ON_DEMAND_SINCE :: 4
	interactivity: u32 = v >= KEYBOARD_ON_DEMAND_SINCE ? ZWLR_KEYBOARD_ON_DEMAND : 0
	wl.proxy_marshal_flags(ls, ZWLR_LAYER_SURFACE_SET_KEYBOARD_INTERACTIVITY, nil, v, 0, interactivity)
}

// set_input_region / clear_input_region. A wl_surface's input region is applied by a commit: the surface is committed
// now when it has had its configure (the commit keeps its picture), and a repaint is asked for as well.
@(private)
wl_set_input_region :: proc(w: ^Window, rects: [][4]int, limited: bool) {
	st := wl_state(w)
	if st == nil { return }
	clear(&st.input_rects)
	append(&st.input_rects, ..rects)
	st.input_limited = limited
	if st.surface == nil { return }   // (hidden: wl_surface_make applies it to the next surface)
	wl_input_region_apply(st)
	if st.acked { wl.proxy_marshal_flags(st.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(st.surface), 0) }
	wl.display_flush(wlc.display)
	w.paint_requested = true
}

// The input region of the surface from the rects kept (surface coordinates are logical): nil is the whole surface.
@(private)
wl_input_region_apply :: proc(st: ^Wl_Window_State) {
	if st.surface == nil { return }
	if !st.input_limited {
		wl.proxy_marshal_flags(st.surface, WL_SURFACE_SET_INPUT_REGION, nil, wl.proxy_get_version(st.surface), 0, Wl_Proxy(nil))
		return
	}
	region := wl.proxy_marshal_flags(wlc.compositor, WL_COMPOSITOR_CREATE_REGION, wl.region_interface, wl.proxy_get_version(wlc.compositor), 0, nil)
	if region == nil { return }
	for r in st.input_rects {
		if r[2] <= 0 || r[3] <= 0 { continue }
		wl.proxy_marshal_flags(region, WL_REGION_ADD, nil, wl.proxy_get_version(region), 0, i32(r[0]), i32(r[1]), i32(r[2]), i32(r[3]))
	}
	wl.proxy_marshal_flags(st.surface, WL_SURFACE_SET_INPUT_REGION, nil, wl.proxy_get_version(st.surface), 0, region)
	wl.proxy_marshal_flags(region, WL_REGION_DESTROY, nil, wl.proxy_get_version(region), WL_MARSHAL_FLAG_DESTROY)
}
