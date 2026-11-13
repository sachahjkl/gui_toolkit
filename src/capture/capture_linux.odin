package capture

// Linux: the backend chosen at open, in the order of what gives the most. Wayland with ext_image_copy_capture (outputs and
// windows), else Wayland with zwlr_screencopy (outputs), else the portal (the whole desktop, which may ask the user), else
// X11. Where the windows are comes, on Wayland, from COSMIC's or KDE's protocol (capture_places_linux.odin) or the
// compositor's IPC (capture/wm), and from the X server on X11.

import "base:runtime"
import "core:os"
import "core:sys/posix"
import "core:time"
import "wm"

@(private = "file")
Linux_Impl :: struct {
	wl:       ^Wl_State,       // Wayland's connection, when there is one (also what lists the outputs for the portal)
	x11:      ^X11_State,
	portal:   Portal_State,
	provider: wm.Provider,     // who says where the windows are (Wayland)
}

@(private)
platform_open :: proc(s: ^Session) -> Error {
	impl := new(Linux_Impl, s.allocator)
	s.impl = impl
	if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" {
		if st, ok := wl_open(s.allocator); ok {
			impl.wl = st
			impl.provider = wm.detect()
			switch {
			case st.copy_manager != nil: s.backend = .Wayland_Image_Copy
			case st.screencopy != nil:   s.backend = .Wayland_Screencopy
			case portal_available():     s.backend = .Portal
			case:
				wl_close(st)
				impl.wl = nil
			}
			if s.backend != .None { return .None }
		}
		if portal_available() {
			s.backend = .Portal
			return .None
		}
	}
	if os.get_env("DISPLAY", context.temp_allocator) != "" {
		if st, ok := x11_open(s.allocator); ok {
			impl.x11 = st
			s.backend = .X11
			return .None
		}
	}
	free(impl, s.allocator)
	s.impl = nil
	return .Unsupported
}

@(private)
platform_close :: proc(s: ^Session) {
	impl := (^Linux_Impl)(s.impl)
	if impl == nil { return }
	if impl.wl != nil { wl_close(impl.wl) }
	if impl.x11 != nil { x11_close(impl.x11) }
	free(impl, s.allocator)
	s.impl = nil
}

// The connection to the display server has an error: every request on it fails from now on (revive opens another).
@(private)
platform_broken :: proc(s: ^Session) -> bool {
	impl := (^Linux_Impl)(s.impl)
	if impl.wl != nil && impl.wl.display != nil && impl.wl.lib.display_get_error(impl.wl.display) != 0 { return true }
	if impl.x11 != nil && impl.x11.c != nil && impl.x11.lib.connection_has_error(impl.x11.c) != 0 { return true }
	return false
}

@(private)
platform_outputs :: proc(s: ^Session) {
	impl := (^Linux_Impl)(s.impl)
	switch s.backend {
	case .Wayland_Image_Copy, .Wayland_Screencopy: wl_outputs(impl.wl, s)
	case .Portal:
		if impl.wl != nil { wl_outputs(impl.wl, s) } else { portal_outputs(&impl.portal, s) }
	case .X11: x11_outputs(impl.x11, s)
	case .None, .Windows:
	}
}

@(private)
platform_windows :: proc(s: ^Session) {
	impl := (^Linux_Impl)(s.impl)
	switch s.backend {
	case .Wayland_Image_Copy, .Wayland_Screencopy, .Portal: wl_windows(impl.wl, impl.provider, s)
	case .X11: x11_windows(impl.x11, s)
	case .None, .Windows:
	}
}

@(private)
platform_windows_have_rects :: proc(s: ^Session) -> bool {
	impl := (^Linux_Impl)(s.impl)
	if s.backend == .X11 { return true }
	return impl != nil && (impl.provider != .None || places_have_rects(impl.wl))
}

@(private)
platform_output :: proc(s: ^Session, id: u64, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	impl := (^Linux_Impl)(s.impl)
	if impl.wl != nil { impl.wl.order = s.order }
	switch s.backend {
	case .Wayland_Image_Copy, .Wayland_Screencopy: return wl_output_frame(impl.wl, id, allocator)
	case .Portal, .X11:
		// (one picture of the whole desktop, cut to the output)
		d := platform_desktop(s, allocator) or_return
		defer frame_free(&d)
		for o in outputs(s) {
			if o.id != id { continue }
			out, ok := crop(d, o.rect, allocator)
			return out, ok ? .None : .Failed
		}
		return {}, .Gone
	case .None, .Windows:
	}
	return {}, .Unsupported
}

@(private)
platform_window :: proc(s: ^Session, id: u64, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	impl := (^Linux_Impl)(s.impl)
	if impl.wl != nil { impl.wl.order = s.order }
	switch s.backend {
	case .Wayland_Image_Copy: return wl_window_frame(impl.wl, id, allocator)
	case .X11:
		// (the desktop cut to the window's frame: what is over it shows)
		r, ok := x11_frame_rect(impl.x11, u32(id))
		if !ok { return {}, .Gone }
		return x11_grab(impl.x11, r, allocator)
	case .Wayland_Screencopy, .Portal, .None, .Windows:
	}
	return {}, .Unsupported
}

@(private)
platform_desktop :: proc(s: ^Session, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	impl := (^Linux_Impl)(s.impl)
	if impl.wl != nil { impl.wl.order = s.order }
	switch s.backend {
	case .Wayland_Image_Copy, .Wayland_Screencopy: return wl_desktop(impl.wl, allocator)
	case .Portal:
		places := make([dynamic]Rect, context.temp_allocator)
		if impl.wl != nil {
			for o in outputs(s) { append(&places, o.rect) }
		}
		return portal_desktop(&impl.portal, places[:], allocator)
	case .X11: return x11_desktop(impl.x11, allocator)
	case .None, .Windows:
	}
	return {}, .Unsupported
}

// Wayland's protocols capture each output: its own picture. The portal and X11 read the desktop as one picture: that one.
@(private)
platform_desktop_parts :: proc(s: ^Session, allocator: runtime.Allocator) -> (parts: []Frame, err: Error) {
	impl := (^Linux_Impl)(s.impl)
	if impl.wl != nil { impl.wl.order = s.order }
	switch s.backend {
	case .Wayland_Image_Copy, .Wayland_Screencopy: return wl_desktop_parts(impl.wl, allocator)
	case .Portal, .X11:
		d := platform_desktop(s, allocator) or_return
		parts = make([]Frame, 1, allocator)
		parts[0] = d
		return parts, .None
	case .None, .Windows:
	}
	return nil, .Unsupported
}

// Wayland: the compositor's cursor sessions, on the session's own connection (the portal backend keeps one to list
// the outputs). X11: QueryPointer.
@(private)
platform_pointer :: proc(s: ^Session) -> (at: [2]i32, output: u64, ok: bool) {
	impl := (^Linux_Impl)(s.impl)
	if impl == nil { return }
	switch s.backend {
	case .Wayland_Image_Copy, .Wayland_Screencopy, .Portal:
		if impl.wl != nil { return wl_pointer(impl.wl) }
	case .X11: return x11_pointer(impl.x11)
	case .None, .Windows:
	}
	return
}

// Streams: Wayland's protocols and X11. The portal backend has none: the ScreenCast portal hands a PipeWire stream, and
// reading one needs libpipewire's loop and SPA's pod buffers, not written yet.
@(private)
platform_stream_open :: proc(s: ^Session, st: ^Stream) -> Error {
	impl := (^Linux_Impl)(s.impl)
	switch s.backend {
	case .Wayland_Image_Copy, .Wayland_Screencopy: return wl_stream_open(impl.wl, st)
	case .X11:                                     return x11_stream_open(impl.x11, s, st)
	case .Portal, .None, .Windows:
	}
	return .Unsupported
}

@(private)
platform_stream_next :: proc(st: ^Stream, timeout: time.Duration) -> (f: Stream_Frame, ok: bool, err: Error) {
	impl := (^Linux_Impl)(st.session.impl)
	if impl == nil || st.impl == nil { return {}, false, .Failed }
	switch st.session.backend {
	case .Wayland_Image_Copy, .Wayland_Screencopy: return wl_stream_next(impl.wl, st, timeout)
	case .X11:                                     return x11_stream_next(impl.x11, st, timeout)
	case .Portal, .None, .Windows:
	}
	return {}, false, .Unsupported
}

@(private)
platform_stream_close :: proc(st: ^Stream) {
	switch st.session.backend {
	case .Wayland_Image_Copy, .Wayland_Screencopy: wl_stream_close(st)
	case .X11:                                     x11_stream_close(st)
	case .Portal, .None, .Windows:
	}
}

// CLOCK_MONOTONIC in nanoseconds: the clock of Wayland's presentation times, so a stream's own times and the
// compositor's are one.
@(private)
monotonic_ns :: proc() -> i64 {
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	return i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
}
