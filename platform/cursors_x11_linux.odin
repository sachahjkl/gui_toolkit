#+build linux
package platform

import "core:strings"
import "core:sys/posix"

// Cursors on X11. A named cursor comes from the user's theme through libxcb-cursor (by dlopen, optional); without it, or
// for a name the theme lacks, from the server's own cursor font, which every server has. A custom cursor (an RGBA image)
// goes through the RENDER extension (libxcb-render, optional); without it, its fallback shape shows. The window keeps
// what it was given: X applies a window's cursor whenever the pointer is over it.

@(private = "file") XCB_CW_CURSOR :: 1 << 14
@(private = "file") XCB_IMAGE_FORMAT_Z_PIXMAP :: 2
@(private = "file") CURSOR_FONT_NAME :: "cursor"
@(private = "file") PICT_TYPE_DIRECT :: 1
@(private = "file") ARGB_DEPTH :: 32
@(private = "file") COLOR_MAX :: 0xffff

@(private = "file")
Pictforminfo :: struct {
	id:        u32,
	type:      u8,
	depth:     u8,
	pad:       [2]u8,
	red_shift, red_mask, green_shift, green_mask, blue_shift, blue_mask, alpha_shift, alpha_mask: u16,
	colormap:  u32,
}
#assert(size_of(Pictforminfo) == 28)

@(private = "file") Cookie :: Xcb_Intern_Atom_Cookie

@(private = "file")
X11_Cursor_Lib :: struct {
	loaded:  bool,
	change_attributes: proc "c" (c: Xcb_Connection, w: Xcb_Window, mask: u32, values: rawptr) -> Xcb_Void_Cookie,
	open_font:    proc "c" (c: Xcb_Connection, fid: u32, name_len: u16, name: cstring) -> Xcb_Void_Cookie,
	glyph_cursor: proc "c" (c: Xcb_Connection, cid, source, mask: u32, source_char, mask_char: u16, fr, fg, fb, br, bg, bb: u16) -> Xcb_Void_Cookie,
	create_pixmap: proc "c" (c: Xcb_Connection, depth: u8, pid: u32, drawable: u32, w, h: u16) -> Xcb_Void_Cookie,
	free_pixmap:  proc "c" (c: Xcb_Connection, pid: u32) -> Xcb_Void_Cookie,
	create_cursor: proc "c" (c: Xcb_Connection, cid, source, mask: u32, fr, fg, fb, br, bg, bb, x, y: u16) -> Xcb_Void_Cookie,
	free_cursor:  proc "c" (c: Xcb_Connection, cid: u32) -> Xcb_Void_Cookie,
	create_gc:    proc "c" (c: Xcb_Connection, cid: u32, drawable: u32, mask: u32, values: rawptr) -> Xcb_Void_Cookie,
	free_gc:      proc "c" (c: Xcb_Connection, cid: u32) -> Xcb_Void_Cookie,
	put_image:    proc "c" (c: Xcb_Connection, format: u8, drawable, gc: u32, w, h: u16, x, y: i16, left_pad, depth: u8, len: u32, data: rawptr) -> Xcb_Void_Cookie,
	// libxcb-cursor
	theme_new:    proc "c" (c: Xcb_Connection, screen: ^Xcb_Screen, ctx: ^rawptr) -> i32,
	theme_load:   proc "c" (ctx: rawptr, name: cstring) -> u32,
	theme:        rawptr,
	// libxcb-render
	formats:      proc "c" (c: Xcb_Connection) -> Cookie,
	formats_reply: proc "c" (c: Xcb_Connection, cookie: Cookie, e: rawptr) -> rawptr,
	formats_list: proc "c" (r: rawptr) -> [^]Pictforminfo,
	formats_len:  proc "c" (r: rawptr) -> i32,
	create_picture: proc "c" (c: Xcb_Connection, pid, drawable, format, mask: u32, values: rawptr) -> Xcb_Void_Cookie,
	picture_cursor: proc "c" (c: Xcb_Connection, cid, source: u32, x, y: u16) -> Xcb_Void_Cookie,
	free_picture: proc "c" (c: Xcb_Connection, pid: u32) -> Xcb_Void_Cookie,
	argb_format:  u32,
	// what was made, once each: the connection lives as long as the process
	named:        [Cursor]u32,
	font:         u32,
}
@(private = "file") xc: X11_Cursor_Lib

@(private = "file")
x11_cursor_lib :: proc() -> ^X11_Cursor_Lib {
	if xc.loaded { return &xc }
	xc.loaded = true
	h := xcb.handle
	xc.change_attributes = auto_cast lib_sym(h, "xcb_change_window_attributes")
	xc.open_font     = auto_cast lib_sym(h, "xcb_open_font")
	xc.glyph_cursor  = auto_cast lib_sym(h, "xcb_create_glyph_cursor")
	xc.create_pixmap = auto_cast lib_sym(h, "xcb_create_pixmap")
	xc.free_pixmap   = auto_cast lib_sym(h, "xcb_free_pixmap")
	xc.create_cursor = auto_cast lib_sym(h, "xcb_create_cursor")
	xc.free_cursor   = auto_cast lib_sym(h, "xcb_free_cursor")
	xc.create_gc     = auto_cast lib_sym(h, "xcb_create_gc")
	xc.free_gc       = auto_cast lib_sym(h, "xcb_free_gc")
	xc.put_image     = auto_cast lib_sym(h, "xcb_put_image")
	if t := lib_open({"libxcb-cursor.so.0", "libxcb-cursor.so"}); t != nil {
		xc.theme_new  = auto_cast lib_sym(t, "xcb_cursor_context_new")
		xc.theme_load = auto_cast lib_sym(t, "xcb_cursor_load_cursor")
		if xc.theme_new != nil && xc.theme_load != nil && xc.theme_new(x11c.c, x11c.screen, &xc.theme) < 0 { xc.theme = nil }
	}
	if r := lib_open({"libxcb-render.so.0", "libxcb-render.so"}); r != nil {
		xc.formats        = auto_cast lib_sym(r, "xcb_render_query_pict_formats")
		xc.formats_reply  = auto_cast lib_sym(r, "xcb_render_query_pict_formats_reply")
		xc.formats_list   = auto_cast lib_sym(r, "xcb_render_query_pict_formats_formats")
		xc.formats_len    = auto_cast lib_sym(r, "xcb_render_query_pict_formats_formats_length")
		xc.create_picture = auto_cast lib_sym(r, "xcb_render_create_picture")
		xc.picture_cursor = auto_cast lib_sym(r, "xcb_render_create_cursor")
		xc.free_picture   = auto_cast lib_sym(r, "xcb_render_free_picture")
		if xc.formats != nil && xc.formats_reply != nil && xc.formats_list != nil && xc.formats_len != nil {
			if reply := xc.formats_reply(x11c.c, xc.formats(x11c.c), nil); reply != nil {
				defer posix.free(reply)
				list := xc.formats_list(reply)
				for f in list[:xc.formats_len(reply)] {
					if f.type == PICT_TYPE_DIRECT && f.depth == ARGB_DEPTH && f.alpha_mask == 0xff && f.red_shift == 16 && f.green_shift == 8 && f.blue_shift == 0 {
						xc.argb_format = f.id
						break
					}
				}
			}
		}
	}
	return &xc
}

// A cursor without a visible pixel.
@(private = "file")
x11_hidden_cursor :: proc() -> u32 {
	root := u32(x11c.screen.root)
	pix := xcb.generate_id(x11c.c)
	xc.create_pixmap(x11c.c, 1, pix, root, 1, 1)
	defer xc.free_pixmap(x11c.c, pix)
	gc := xcb.generate_id(x11c.c)
	xc.create_gc(x11c.c, gc, pix, 0, nil)
	defer xc.free_gc(x11c.c, gc)
	empty: u32
	xc.put_image(x11c.c, XCB_IMAGE_FORMAT_Z_PIXMAP, pix, gc, 1, 1, 0, 0, 0, 1, size_of(empty), &empty)
	cid := xcb.generate_id(x11c.c)
	xc.create_cursor(x11c.c, cid, pix, pix, 0, 0, 0, 0, 0, 0, 0, 0)
	return cid
}

// The cursor of a name, from the theme under its CSS name or its older one, else from the server's cursor font.
@(private = "file")
x11_named_cursor :: proc(c: Cursor) -> u32 {
	if xc.named[c] != 0 { return xc.named[c] }
	id: u32
	if c == .None {
		id = x11_hidden_cursor()
	} else {
		older, glyph := cursor_older_name(c)
		if xc.theme != nil {
			id = xc.theme_load(xc.theme, strings.clone_to_cstring(cursor_css_name(c), context.temp_allocator))
			if id == 0 { id = xc.theme_load(xc.theme, strings.clone_to_cstring(older, context.temp_allocator)) }
		}
		if id == 0 {
			if xc.font == 0 {
				xc.font = xcb.generate_id(x11c.c)
				xc.open_font(x11c.c, xc.font, len(CURSOR_FONT_NAME), CURSOR_FONT_NAME)
			}
			id = xcb.generate_id(x11c.c)
			xc.glyph_cursor(x11c.c, id, xc.font, xc.font, glyph, glyph + 1, 0, 0, 0, COLOR_MAX, COLOR_MAX, COLOR_MAX)
		}
	}
	xc.named[c] = id
	return id
}

// A custom cursor at the window's scale (made once per scale); 0 when the server has no RENDER.
@(private = "file")
x11_custom_cursor :: proc(w: ^Window, e: ^Custom_Entry) -> u32 {
	if xc.argb_format == 0 || xc.create_picture == nil || xc.picture_cursor == nil { return 0 }
	if e.x11_cursor != 0 && e.made_scale == w.dpi_scale { return e.x11_cursor }
	x11_custom_release(e)
	px, size, hot := custom_cursor_bgra(e, w.dpi_scale, context.temp_allocator)
	root := u32(x11c.screen.root)
	pix := xcb.generate_id(x11c.c)
	xc.create_pixmap(x11c.c, ARGB_DEPTH, pix, root, u16(size.x), u16(size.y))
	defer xc.free_pixmap(x11c.c, pix)
	gc := xcb.generate_id(x11c.c)
	xc.create_gc(x11c.c, gc, pix, 0, nil)
	defer xc.free_gc(x11c.c, gc)
	xc.put_image(x11c.c, XCB_IMAGE_FORMAT_Z_PIXMAP, pix, gc, u16(size.x), u16(size.y), 0, 0, 0, ARGB_DEPTH, u32(len(px)), raw_data(px))
	pic := xcb.generate_id(x11c.c)
	xc.create_picture(x11c.c, pic, pix, xc.argb_format, 0, nil)
	defer xc.free_picture(x11c.c, pic)
	cid := xcb.generate_id(x11c.c)
	xc.picture_cursor(x11c.c, cid, pic, u16(hot.x), u16(hot.y))
	e.x11_cursor, e.made_scale = cid, w.dpi_scale
	return cid
}

@(private)
x11_custom_release :: proc(e: ^Custom_Entry) {
	if e.x11_cursor != 0 && xc.free_cursor != nil && x11c.c != nil { xc.free_cursor(x11c.c, e.x11_cursor) }
	e.x11_cursor = 0
}

@(private)
x11_apply_cursor :: proc(w: ^Window) {
	st := x11_state(w)
	if st == nil || x11c.c == nil { return }
	x11_cursor_lib()
	if xc.change_attributes == nil || xc.create_pixmap == nil { return }
	id: u32
	c := w.cursor
	if w.custom_cursor != 0 {
		c = w.custom_fallback
		if e := custom_entry(w, w.custom_cursor); e != nil { id = x11_custom_cursor(w, e) }
	}
	if id == 0 { id = x11_named_cursor(c) }
	xc.change_attributes(x11c.c, st.id, XCB_CW_CURSOR, &id)
	xcb.flush(x11c.c)
}
