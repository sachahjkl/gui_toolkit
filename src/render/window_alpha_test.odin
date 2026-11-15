package render

import "core:testing"
import "vendor:directx/dxgi"
import "vendor:wgpu"

// The alpha mode a window's frames are presented with, as data: no swap chain, no window.

@(test)
a_frame_is_opaque_when_its_ground_is :: proc(t: ^testing.T) {
	testing.expect(t, frame_opaque({0.05, 0.05, 0.06, 1}), "an opaque theme's page")
	testing.expect(t, !frame_opaque({0.04, 0.04, 0.05, 0.8}), "a translucent theme's page")
	testing.expect(t, !frame_opaque({}), "an overlay's clear (transparent)")
	testing.expect(t, frame_opaque({0, 0, 0, 1}), "black")
}

@(test)
an_opaque_frame_is_composed_with_its_alpha_ignored :: proc(t: ^testing.T) {
	testing.expect_value(t, composition_alpha_mode(true), dxgi.ALPHA_MODE.IGNORE)
	testing.expect_value(t, composition_alpha_mode(false), dxgi.ALPHA_MODE.PREMULTIPLIED)
	testing.expect_value(t, composition_alpha_mode(frame_opaque({0.1, 0.1, 0.1, 1})), dxgi.ALPHA_MODE.IGNORE)
	testing.expect_value(t, composition_alpha_mode(frame_opaque({0.1, 0.1, 0.1, 0.5})), dxgi.ALPHA_MODE.PREMULTIPLIED)
}

@(test)
an_opaque_frame_takes_an_opaque_surface_when_offered :: proc(t: ^testing.T) {
	both := []wgpu.CompositeAlphaMode{.Opaque, .Premultiplied}
	only := []wgpu.CompositeAlphaMode{.Premultiplied}
	testing.expect_value(t, wgpu_window_alpha(true, .Premultiplied, both), wgpu.CompositeAlphaMode.Opaque)
	testing.expect_value(t, wgpu_window_alpha(false, .Premultiplied, both), wgpu.CompositeAlphaMode.Premultiplied)
	// (a surface that cannot be opaque, or modes not known: the translucent mode stays)
	testing.expect_value(t, wgpu_window_alpha(true, .Premultiplied, only), wgpu.CompositeAlphaMode.Premultiplied)
	testing.expect_value(t, wgpu_window_alpha(true, .Premultiplied, nil), wgpu.CompositeAlphaMode.Premultiplied)
	// (a window composited opaque stays so, whatever its frames)
	testing.expect_value(t, wgpu_window_alpha(false, .Opaque, both), wgpu.CompositeAlphaMode.Opaque)
}
