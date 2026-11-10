package tk_desktop

// An icon theme's SVG files rendered by librsvg, the library GTK and KDE render them with (so an icon looks as it does
// in the person's file manager), into a cairo image. Both are opened at run time (dlopen): a system without them shows
// the PNG icons only. librsvg renders separate documents on separate threads.

import "base:runtime"
import "core:sync"
import "core:sys/posix"

@(private = "file")
Rsvg_Rect :: struct { x, y, width, height: f64 }

@(private = "file")
CAIRO_FORMAT_ARGB32 :: 0

@(private = "file")
Rsvg :: struct {
	once:     sync.Once,
	ok:       bool,
	new_from_data:   proc "c" (data: [^]u8, len: uint, error: rawptr) -> rawptr,
	render_document: proc "c" (handle: rawptr, cr: rawptr, viewport: ^Rsvg_Rect, error: rawptr) -> i32,
	unref:           proc "c" (object: rawptr),
	surface_create:  proc "c" (format: i32, width, height: i32) -> rawptr,
	surface_flush:   proc "c" (surface: rawptr),
	surface_status:  proc "c" (surface: rawptr) -> i32,
	surface_data:    proc "c" (surface: rawptr) -> [^]u8,
	surface_stride:  proc "c" (surface: rawptr) -> i32,
	surface_destroy: proc "c" (surface: rawptr),
	create:          proc "c" (surface: rawptr) -> rawptr,
	destroy:         proc "c" (cr: rawptr),
}

@(private = "file") rsvg: Rsvg

@(private = "file")
rsvg_open :: proc() {
	open :: proc(names: []cstring) -> posix.Symbol_Table {
		for n in names { if h := posix.dlopen(n, posix.RTLD_LOCAL + {.NOW}); h != nil { return h } }
		return nil
	}
	lib := open({"librsvg-2.so.2", "librsvg-2.so"})
	cairo := open({"libcairo.so.2", "libcairo.so"})
	gobject := open({"libgobject-2.0.so.0", "libgobject-2.0.so"})
	if lib == nil || cairo == nil || gobject == nil { return }
	sym :: proc(h: posix.Symbol_Table, name: cstring, to: ^$T) -> bool {
		p := posix.dlsym(h, name)
		to^ = (T)(p)
		return p != nil
	}
	ok := sym(lib, "rsvg_handle_new_from_data", &rsvg.new_from_data)
	ok &= sym(lib, "rsvg_handle_render_document", &rsvg.render_document)
	ok &= sym(gobject, "g_object_unref", &rsvg.unref)
	ok &= sym(cairo, "cairo_image_surface_create", &rsvg.surface_create)
	ok &= sym(cairo, "cairo_surface_flush", &rsvg.surface_flush)
	ok &= sym(cairo, "cairo_surface_status", &rsvg.surface_status)
	ok &= sym(cairo, "cairo_image_surface_get_data", &rsvg.surface_data)
	ok &= sym(cairo, "cairo_image_surface_get_stride", &rsvg.surface_stride)
	ok &= sym(cairo, "cairo_surface_destroy", &rsvg.surface_destroy)
	ok &= sym(cairo, "cairo_create", &rsvg.create)
	ok &= sym(cairo, "cairo_destroy", &rsvg.destroy)
	rsvg.ok = ok
}

// Whether SVG files can be rendered here (librsvg and cairo were found).
svg_available :: proc() -> bool {
	sync.once_do(&rsvg.once, rsvg_open)
	return rsvg.ok
}

// An SVG document rendered into a square of `size` pixels (its viewport fitted, its ratio kept).
@(private)
svg_render :: proc(data: []u8, size: int, allocator: runtime.Allocator) -> (icon: File_Icon, ok: bool) {
	if !svg_available() || size <= 0 || len(data) == 0 { return }
	handle := rsvg.new_from_data(raw_data(data), uint(len(data)), nil)
	if handle == nil { return }
	defer rsvg.unref(handle)
	// (cairo gives an error surface, never nil: its status says)
	surface := rsvg.surface_create(CAIRO_FORMAT_ARGB32, i32(size), i32(size))
	if surface == nil { return }
	defer rsvg.surface_destroy(surface)
	if rsvg.surface_status(surface) != 0 { return }
	cr := rsvg.create(surface)
	viewport := Rsvg_Rect{0, 0, f64(size), f64(size)}
	drawn := rsvg.render_document(handle, cr, &viewport, nil) != 0
	rsvg.destroy(cr)
	if !drawn { return }
	rsvg.surface_flush(surface)
	src := rsvg.surface_data(surface)
	if src == nil { return }
	stride := int(rsvg.surface_stride(surface))
	// cairo's ARGB32: a native-endian word per pixel (B, G, R, A in memory here), premultiplied
	out := make([]u8, size * size * 4, allocator)
	for y in 0 ..< size {
		row := src[y * stride:]
		for x in 0 ..< size {
			b, g, r, a := row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]
			o := out[(y * size + x) * 4:]
			if a == 0 { continue }
			o[0] = u8(min(255, int(r) * 255 / int(a)))
			o[1] = u8(min(255, int(g) * 255 / int(a)))
			o[2] = u8(min(255, int(b) * 255 / int(a)))
			o[3] = a
		}
	}
	return File_Icon{out, {size, size}}, true
}
