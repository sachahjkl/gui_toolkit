#+build linux
package render

// The wgpu surface for a window on Linux, from the neutral native handles the platform package hands over
// (platform.Surface_Handles). Wayland uses SurfaceSourceWaylandSurface (wl_display + wl_surface); X11 uses
// SurfaceSourceXcbWindow (xcb_connection + xcb_window). This is the Linux counterpart of the SurfaceSourceWindowsHWND
// path in wgpu_surface.odin; the rest of the wgpu renderer (device, queue, pipelines, configure, present, resize,
// capture) is the same code on every system. wgpu-native must be built for Linux (libwgpu_native.a beside Odin's
// vendor:wgpu); the portability doc tracks that.
//
// The renderer calls wgpu_surface_from_handles with its instance and the handles; it returns a configured-ready
// wgpu.Surface (nil when the handles are empty — an offscreen window renders with init_offscreen instead).

import "vendor:wgpu"
import "toolkit:platform"

wgpu_surface_from_handles :: proc(instance: wgpu.Instance, h: platform.Surface_Handles) -> wgpu.Surface {
	switch h.backend {
	case .Wayland:
		src := wgpu.SurfaceSourceWaylandSurface{chain = {sType = .SurfaceSourceWaylandSurface}, display = h.display, surface = h.surface}
		return wgpu.InstanceCreateSurface(instance, &{nextInChain = &src.chain})
	case .X11:
		src := wgpu.SurfaceSourceXcbWindow{chain = {sType = .SurfaceSourceXCBWindow}, connection = h.display, window = u32(h.window)}
		return wgpu.InstanceCreateSurface(instance, &{nextInChain = &src.chain})
	case .Windows, .None:
	}
	return nil
}
