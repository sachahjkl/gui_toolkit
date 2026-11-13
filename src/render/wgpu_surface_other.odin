#+build !windows
#+build !linux
package render

// The wgpu surface for a window on the systems whose platform package opens no window yet (macOS: the port comes later
// and will make a surface from a CAMetalLayer). No handles arrive here (backend .None), so there is no surface: a
// renderer opens with init_offscreen only. Linux has its own (wgpu_surface_linux.odin); Windows is in wgpu_surface.odin.

import "vendor:wgpu"
import "../platform"

wgpu_surface_from_handles :: proc(instance: wgpu.Instance, h: platform.Surface_Handles) -> wgpu.Surface { return nil }
