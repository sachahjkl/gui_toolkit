package render

import "vendor:directx/dxgi"
import "vendor:wgpu"

// Whether a window's compositor reads the alpha of its frames (src/md/infrastructure/window-alpha.md). A window opened
// translucent reads it, so that a translucent theme shows the desktop's backdrop through its page. A frame whose ground
// is opaque needs no alpha: every blend of the renderer keeps alpha 1 over an opaque pixel, so its alpha says nothing
// and a stray value (a pass that wrote less than 1) would be a hole where the desktop shows. Such a frame is presented
// with its alpha ignored.

// Whether the frame cleared to `clear` (frame_begin's colour: linear, premultiplied) is opaque everywhere. The clear is
// the frame's ground: the interface paints none of its own, and a translucent theme's page is a clear of alpha < 1.
frame_opaque :: proc(clear: [4]f32) -> bool { return clear.a >= 1 }

// The alpha mode of a DirectComposition swap chain whose frames are `opaque` or not.
composition_alpha_mode :: proc(opaque: bool) -> dxgi.ALPHA_MODE { return opaque ? .IGNORE : .PREMULTIPLIED }

// The alpha mode of a wgpu surface: `translucent` is the one a translucent frame takes (wgpu_surface_alpha_translucent:
// .Opaque when the window is composited opaque anyway), `offered` the surface's modes. An opaque frame takes .Opaque
// when the surface offers it; else (or the modes not known) the translucent one, as before.
wgpu_window_alpha :: proc(opaque: bool, translucent: wgpu.CompositeAlphaMode, offered: []wgpu.CompositeAlphaMode) -> wgpu.CompositeAlphaMode {
	if !opaque || translucent == .Opaque { return translucent }
	for m in offered { if m == .Opaque { return .Opaque } }
	return translucent
}
