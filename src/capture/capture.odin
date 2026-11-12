// Package capture: the screens and the windows of the desktop, as pictures. What a screenshot or a screen recorder needs from
// the system: the outputs (monitors) and where they are, the windows and where they are (when the system says it), and a
// picture of an output or of a window.
//
// Every procedure here may block (a round trip to the compositor, a portal's dialog, a GPU readback): a program calls them
// on a worker, never on its interface's thread, and posts the result back (ui.post).
//
//   s, err := capture.open()                  // the system's capture, once per program
//   outs := capture.outputs(s)                // the screens, in desktop coordinates
//   wins := capture.windows(s)                // the windows, front to back; a rect when the system says where it is
//   f, err := capture.output(s, outs[0].id)   // one screen's picture
//   d, err := capture.desktop(s)              // every screen in one picture: what a region is cut from
//   capture.frame_free(&f)
//   capture.close(s)
//
// A screen recorder opens a stream instead (stream.odin): the source's capture kept open, a frame each time it changed.
//
// Coordinates: the desktop's, in logical pixels (what a window's size is given in), the outputs side by side as the system
// places them. A Frame is in physical pixels (`scale` of them per logical pixel) and says where on the desktop its first
// pixel is (`origin`, logical).
//
// Backends (Session.backend says which one runs):
//   Linux, Wayland  ext_image_copy_capture_v1 (outputs and windows, through ext_image_capture_source_v1 and
//                   ext_foreign_toplevel_list_v1), else zwlr_screencopy_v1 (outputs), else the portal
//                   (org.freedesktop.portal.Screenshot: a picture of the whole desktop, which may ask the user first).
//                   Where the windows are: the compositor's own IPC when it has one (Hyprland, sway); else none
//                   (windows_have_rects is false: a window is picked from a list, not framed under the pointer).
//   Linux, X11      XGetImage (with MIT-SHM when it is there) of the root window; the windows and their rects from
//                   _NET_CLIENT_LIST_STACKING.
//   Windows         DXGI Desktop Duplication per output (Windows.Graphics.Capture for a window); the windows from
//                   EnumWindows, framed by DWMWA_EXTENDED_FRAME_BOUNDS (no invisible resize borders, no shadow).
package capture

import "base:runtime"

Backend :: enum u8 {
	None,
	Wayland_Image_Copy,   // ext_image_copy_capture_v1
	Wayland_Screencopy,   // zwlr_screencopy_v1
	Portal,               // org.freedesktop.portal.Screenshot
	X11,
	Windows,
}

Error :: enum u8 {
	None,
	Unsupported,   // the system offers no way to do it (this backend cannot capture a window, say)
	Denied,        // the user or the system refused (a portal's dialog cancelled)
	Gone,          // the output or the window is no more
	Failed,        // anything else: the system said no
}

Rect :: struct { x, y, w, h: i32 }

Output :: struct {
	id:    u64,       // the backend's: stable while the output is there
	name:  string,    // "DP-1", "\\\\.\\DISPLAY1"
	rect:  Rect,      // logical, on the desktop
	scale: f32,       // physical pixels per logical one
}

Window :: struct {
	id:       u64,      // the backend's: stable while the window is there
	title:    string,
	app_id:   string,   // Wayland's app_id, X11's WM_CLASS, Windows' executable name
	rect:     Rect,     // logical, on the desktop: its visible frame (no shadow), when has_rect
	has_rect: bool,
	minimized: bool,
}

// A picture: BGRA, 8 bits a channel, straight alpha (opaque for a screen), rows top to bottom, `stride` bytes apart.
Frame :: struct {
	pixels: []u8,
	width, height, stride: i32,   // physical pixels
	scale:  f32,                  // physical pixels per logical one
	origin: [2]i32,               // where its first pixel is on the desktop, logical
	allocator: runtime.Allocator,
}

Session :: struct {
	backend:   Backend,
	allocator: runtime.Allocator,
	outputs:   [dynamic]Output,   // as last read (outputs)
	windows:   [dynamic]Window,   // as last read (windows)
	impl:      rawptr,            // the backend's own state
}

// The system's capture. Error .Unsupported: none of the backends of this system can run here (no compositor protocol, no
// portal, no display).
open :: proc(allocator := context.allocator) -> (s: ^Session, err: Error) {
	s = new(Session, allocator)
	s.allocator = allocator
	s.outputs.allocator = allocator
	s.windows.allocator = allocator
	if err = platform_open(s); err != .None {
		free(s, allocator)
		return nil, err
	}
	return s, .None
}

close :: proc(s: ^Session) {
	if s == nil { return }
	platform_close(s)
	strings_free(s)
	delete(s.outputs)
	delete(s.windows)
	free(s, s.allocator)
}

// The outputs, read again from the system (the slice is the session's: valid until the next call).
outputs :: proc(s: ^Session) -> []Output {
	strings_free_outputs(s)
	clear(&s.outputs)
	platform_outputs(s)
	return s.outputs[:]
}

// The windows, front to back, read again from the system (the slice is the session's: valid until the next call).
windows :: proc(s: ^Session) -> []Window {
	strings_free_windows(s)
	clear(&s.windows)
	platform_windows(s)
	return s.windows[:]
}

// Whether `windows` says where each window is: a region can then be framed on the window under the pointer.
windows_have_rects :: proc(s: ^Session) -> bool { return platform_windows_have_rects(s) }

// One output's picture.
output :: proc(s: ^Session, id: u64, allocator := context.allocator) -> (f: Frame, err: Error) {
	return platform_output(s, id, allocator)
}

// One window's picture, its own content (what is over it is not in it). .Unsupported where the backend cannot.
window :: proc(s: ^Session, id: u64, allocator := context.allocator) -> (f: Frame, err: Error) {
	return platform_window(s, id, allocator)
}

// Every output in one picture, at the highest scale of them, the desktop's bounding rectangle (what is outside every
// output, transparent). What a region is cut from, and what a selection is drawn over.
desktop :: proc(s: ^Session, allocator := context.allocator) -> (f: Frame, err: Error) {
	return platform_desktop(s, allocator)
}

// `r` (logical, on the desktop) cut from `f`, in a new frame.
crop :: proc(f: Frame, r: Rect, allocator := context.allocator) -> (out: Frame, ok: bool) {
	_, _, w, h := crop_bounds(f, r) or_return
	pixels := make([]u8, int(w) * int(h) * 4, allocator)
	out, ok = crop_into(f, r, pixels)
	out.allocator = allocator
	return
}

// `r` (logical, on the desktop) cut from `f` into `pixels`, which must hold crop_size's bytes: no allocation, what a
// stream does with each frame of a region. The frame's pixels are `pixels`; it does not own them (no allocator).
crop_into :: proc(f: Frame, r: Rect, pixels: []u8) -> (out: Frame, ok: bool) {
	x0, y0, w, h := crop_bounds(f, r) or_return
	if len(pixels) < int(w) * int(h) * 4 { return {}, false }
	out = Frame{width = w, height = h, stride = w * 4, scale = f.scale, origin = {r.x, r.y}}
	out.pixels = pixels[:int(w) * int(h) * 4]
	for y in 0 ..< h {
		src := f.pixels[int((y0 + y) * f.stride + x0 * 4):][:int(w * 4)]
		copy(out.pixels[int(y * w * 4):], src)
	}
	return out, true
}

// The size in physical pixels of `r` cut from `f` (0, 0 when they do not meet).
crop_size :: proc(f: Frame, r: Rect) -> (w, h: i32) {
	_, _, w, h, _ = crop_bounds(f, r)
	return
}

@(private = "file")
crop_bounds :: proc(f: Frame, r: Rect) -> (x0, y0, w, h: i32, ok: bool) {
	x0 = i32(f32(r.x - f.origin.x) * f.scale)
	y0 = i32(f32(r.y - f.origin.y) * f.scale)
	w = i32(f32(r.w) * f.scale)
	h = i32(f32(r.h) * f.scale)
	x0, y0 = max(x0, 0), max(y0, 0)
	w, h = min(w, f.width - x0), min(h, f.height - y0)
	if w <= 0 || h <= 0 { return 0, 0, 0, 0, false }
	return x0, y0, w, h, true
}

frame_free :: proc(f: ^Frame) {
	if f.pixels != nil { delete(f.pixels, f.allocator) }
	f^ = {}
}

// The window whose rect holds `p` (logical, on the desktop), the frontmost; nil: none, or the backend does not say where
// windows are.
window_at :: proc(wins: []Window, p: [2]i32) -> ^Window {
	for &w in wins {
		if !w.has_rect || w.minimized { continue }
		if p.x >= w.rect.x && p.x < w.rect.x + w.rect.w && p.y >= w.rect.y && p.y < w.rect.y + w.rect.h { return &w }
	}
	return nil
}

@(private)
strings_free_outputs :: proc(s: ^Session) {
	for o in s.outputs { delete(o.name, s.allocator) }
}

@(private)
strings_free_windows :: proc(s: ^Session) {
	for w in s.windows {
		delete(w.title, s.allocator)
		delete(w.app_id, s.allocator)
	}
}

@(private)
strings_free :: proc(s: ^Session) {
	strings_free_outputs(s)
	strings_free_windows(s)
}
