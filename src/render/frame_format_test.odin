package render

import "core:testing"

// A transparent window's frame is in half floats only where its compositor takes it with its alpha: a surface composited
// opaque that offered them (Vulkan on Wayland, a recent Mesa) took them, its compositor read their alpha, and what the
// interface draws past [0, 1] showed bars of white, then of the desktop behind the window.
@(test)
half_floats_only_for_a_surface_composited_with_its_alpha :: proc(t: ^testing.T) {
	when USE_WGPU {
		testing.expect(t, !wgpu_wants_fp16(true, .Linear, false, true), "composited opaque (Linux): 8 bits")
		testing.expect(t, wgpu_wants_fp16(true, .Linear, true, true), "composited with its alpha (a DirectComposition panel)")
		testing.expect(t, !wgpu_wants_fp16(true, .Linear, true, false), "a surface without half floats")
		testing.expect(t, !wgpu_wants_fp16(false, .Linear, true, true), "an opaque window")
		testing.expect(t, !wgpu_wants_fp16(true, .Srgb, true, true), "blended in sRGB")
	}
}
