package capture

// The pointer in a still picture (set_cursor): which backends draw it, and the pure part of a backend that draws it
// itself (Windows: capture_cursor_windows.odin), tested without a desktop (tests/capture/capture_cursor_test.odin).
//
//   Wayland, ext_image_copy_capture   the compositor draws it (create_session's paint_cursors option)
//   Wayland, wlr-screencopy           the compositor draws it (capture_output's overlay_cursor)
//   Windows                           drawn here over an output's picture (GetCursorInfo, DrawIconEx); a window's
//                                     picture through Windows.Graphics.Capture asks the system for it
//                                     (IsCursorCaptureEnabled)
//   The portal                        no: org.freedesktop.portal.Screenshot has no option for it (the ScreenCast
//                                     portal's cursor_mode is a stream's, and the portal backend has no stream)
//   X11                               no: the root window's picture has no pointer, and XFixes' cursor image is not read

// Whether `b` draws the pointer in its pictures when the session asks it (set_cursor).
backend_draws_cursor :: proc(b: Backend) -> bool {
	switch b {
	case .Wayland_Image_Copy, .Wayland_Screencopy, .Windows: return true
	case .None, .Portal, .X11:                               return false
	}
	return false
}

// A patch of `patch` pixels put at `at` (it may stick out, or start before 0) in a picture of `size` pixels: the part
// they share, at `dst` in the picture and at `src` in the patch, `extent` wide and high. ok false: they do not meet.
patch_clip :: proc(size, at, patch: [2]i32) -> (dst, src, extent: [2]i32, ok: bool) {
	if size.x <= 0 || size.y <= 0 || patch.x <= 0 || patch.y <= 0 { return }
	x0, y0 := max(at.x, 0), max(at.y, 0)
	x1, y1 := min(at.x + patch.x, size.x), min(at.y + patch.y, size.y)
	if x1 <= x0 || y1 <= y0 { return }
	return {x0, y0}, {x0 - at.x, y0 - at.y}, {x1 - x0, y1 - y0}, true
}
