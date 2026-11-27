#+build !windows
package platform

// Non-Windows stub: no Win32 child-HWND input shield is needed.
set_native_input_shield :: proc(w: ^Window, rects: [][4]int) {
	_ = w
	_ = rects
}
