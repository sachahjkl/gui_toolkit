#+build linux
package platform

// Overlay windows on X11 (overlay.odin): an override-redirect window (no window manager frames, moves or lists it) with
// a 32-bit visual (a compositing manager blends its alpha; without one the transparent parts show black), over the
// monitor that holds the area (RandR; without it the whole root), raised above the others when it is mapped. The input
// region is XFIXES' region set as the SHAPE extension's input shape (libxcb-xfixes, loaded with the backend): no
// libXext, as the backend speaks XCB. X11 has no logical pixels: the area is in root pixels.

import "core:strings"

@(private = "file") XCB_CONFIG_WINDOW_STACK_MODE :: 1 << 6
@(private = "file") XCB_STACK_MODE_ABOVE :: 0
@(private = "file") XCB_INPUT_FOCUS_PARENT :: 2

@(private)
x11_open_overlay :: proc(w: ^Window, title: string, area: [4]int) -> bool {
	if !x11_connect() { report_missing("libxcb"); return false }
	x := &xcb
	root := x11c.screen.root
	place := [4]int{0, 0, int(x11c.screen.width_in_pixels), int(x11c.screen.height_in_pixels)}
	monitors := x11_monitor_rects()
	if i := overlay_output_index(monitors, area); i >= 0 { place = monitors[i] }

	st := new(X11_Window_State)
	st.transparent = true
	st.title = strings.clone(title)
	w.x11 = st
	append(&x11c.windows, w)
	w.dpi_scale = x11_dpi_scale()
	w.size = {max(place[2], 1), max(place[3], 1)}

	depth: u8 = XCB_COPY_FROM_PARENT
	visual := x11c.screen.root_visual
	colormap := u32(x11c.screen.default_colormap)
	if argb := x11_argb_visual(); argb != 0 {
		depth, visual = X11_ARGB_DEPTH, argb
		st.colormap = Xcb_Colormap(x.generate_id(x11c.c))
		x.create_colormap(x11c.c, 0, st.colormap, root, visual)
		colormap = u32(st.colormap)
	}
	id := Xcb_Window(x.generate_id(x11c.c))
	st.id = id
	ev_mask: u32 = XCB_EVENT_MASK_KEY_PRESS | XCB_EVENT_MASK_KEY_RELEASE | XCB_EVENT_MASK_BUTTON_PRESS |
		XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_POINTER_MOTION | XCB_EVENT_MASK_BUTTON_MOTION |
		XCB_EVENT_MASK_ENTER_WINDOW | XCB_EVENT_MASK_LEAVE_WINDOW | XCB_EVENT_MASK_STRUCTURE_NOTIFY |
		XCB_EVENT_MASK_FOCUS_CHANGE | XCB_EVENT_MASK_PROPERTY_CHANGE
	// in the order of their bits: background, border (a visual other than the parent's needs both), override
	// redirect, events, colormap
	values := [5]u32{0, 0, 1, ev_mask, colormap}
	mask: u32 = XCB_CW_BACK_PIXEL | XCB_CW_BORDER_PIXEL | XCB_CW_OVERRIDE_REDIRECT | XCB_CW_EVENT_MASK | XCB_CW_COLORMAP
	x.create_window(x11c.c, depth, id, root, i16(place[0]), i16(place[1]), u16(w.size.x), u16(w.size.y), 0,
		XCB_WINDOW_CLASS_INPUT_OUTPUT, visual, mask, &values[0])
	x11_set_title(w, title)
	app := app_id_or_exe()
	class := strings.concatenate({app, "\x00", app, "\x00"}, context.temp_allocator)
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, id, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING, X11_FORMAT_8, u32(len(class)), raw_data(class))
	x11_extensions_select(id)
	x.map_window(x11c.c, id)
	st.map_phase = .Asked
	above := [1]u32{XCB_STACK_MODE_ABOVE}
	x.configure_window(x11c.c, id, XCB_CONFIG_WINDOW_STACK_MODE, &above[0])
	x.flush(x11c.c)
	w.show = .Normal
	w.paint_requested = true
	return true
}

// A click on an overlay gives it the keyboard (Escape reaches it then).
@(private)
x11_overlay_focus :: proc(w: ^Window, time: u32) {
	st := x11_state(w)
	if st == nil || xcb.set_input_focus == nil { return }
	xcb.set_input_focus(x11c.c, XCB_INPUT_FOCUS_PARENT, st.id, time)
	xcb.flush(x11c.c)
}

// set_input_region / clear_input_region: the rects (logical) in the window's pixels. Without XFIXES the whole window
// keeps the pointer.
@(private)
x11_set_input_region :: proc(w: ^Window, rects: [][4]int, limited: bool) {
	st := x11_state(w)
	if st == nil { return }
	x11_window_input_rects(st.id, overlay_input_rects_px(rects, w.dpi_scale), limited)
	xcb.flush(x11c.c)
}
