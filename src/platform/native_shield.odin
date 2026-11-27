package platform

// Invisible input shield for interactive toolkit overlays drawn above native child windows
// (src/md/features/popup-over-native.md).
//
// On Windows, DirectComposition's topmost=TRUE visual draws tooltips, menus, toasts, dialogs,
// and floating views above child HWNDs (such as WebView2) with full premultiplied alpha and
// unclipped drop shadows, but does not intercept mouse messages headed for a cross-process
// child HWND. `set_native_input_shield` maintains an invisible owned WS_POPUP window clipped
// by SetWindowRgn to `rects` (physical client pixels) so clicks/moves/wheel over interactive
// overlays route back to the owner window while everything else passes straight to the child.
// Non-Windows platforms have no Win32 child-HWND input inversion: `set_native_input_shield` is
// a no-op there.

// Clamps physical client rectangles `{x, y, w, h}` to `size`, dropping empty rectangles.
native_shield_clamp_rects :: proc(rects: [][4]int, size: [2]int, allocator := context.temp_allocator) -> [][4]int {
	if size.x <= 0 || size.y <= 0 || len(rects) == 0 { return nil }
	out := make([dynamic][4]int, 0, len(rects), allocator)
	for r in rects {
		x0 := clamp(r[0], 0, size.x)
		y0 := clamp(r[1], 0, size.y)
		x1 := clamp(r[0] + r[2], 0, size.x)
		y1 := clamp(r[1] + r[3], 0, size.y)
		if x1 > x0 && y1 > y0 {
			append(&out, [4]int{x0, y0, x1 - x0, y1 - y0})
		}
	}
	return out[:]
}

// Whether two rectangle lists are identical in count and coordinates.
native_shield_rects_equal :: proc(a, b: [][4]int) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] { return false }
	}
	return true
}
