#+build !linux
package render

// No GL fallback off Linux (wgpu_gl_linux.odin): Windows draws on Direct3D 12 (or 11, with WARP behind it), and macOS has
// no window yet.

import "vendor:wgpu"
import "../platform"

WGPU_GL_FALLBACK :: false

@(private) wgpu_gl_forced :: proc() -> bool { return false }
@(private) wgpu_gl_display :: proc(h: platform.Surface_Handles, xlib: rawptr, screen: i32) -> wgpu.NativeDisplayHandle { return {} }
