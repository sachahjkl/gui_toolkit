package render

// The wgpu surface for a window on Windows: its HWND, or DirectComposition for a translucent window (wgpu_dcomp.odin).

import "core:fmt"
import win "core:sys/windows"
import "vendor:wgpu"
import "../platform"

wgpu_surface_from_handles :: proc(r: ^Renderer, h: platform.Surface_Handles) -> wgpu.Surface {
	hwnd := win.HWND(h.hwnd)
	if hwnd == nil { return nil }
	if r.transparent {
		s := fault_hit(.Composition) ? nil : wgpu_dcomp_surface(r, hwnd)
		if s != nil { return s }
		fmt.eprintln("render: wgpu: DirectComposition unavailable, the window is opaque")
		r.transparent = false
	}
	src := wgpu.SurfaceSourceWindowsHWND{chain = {sType = .SurfaceSourceWindowsHWND}, hinstance = h.hinstance != nil ? h.hinstance : rawptr(win.GetModuleHandleW(nil)), hwnd = rawptr(hwnd)}
	return wgpu.InstanceCreateSurface(r.wg.instance, &{nextInChain = &src.chain})
}
