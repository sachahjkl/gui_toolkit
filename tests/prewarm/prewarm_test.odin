package prewarm_test

// An offscreen renderer (a test, an export) compiles a pipeline when it first draws with it, not every pipeline on a thread
// at its start: pre-warmed, every test session compiled eight and waited for them at its end, used or not (on WARP the
// slowest packages of the CI spent most of their time there). A window's renderer still pre-warms: its start hides it.

import "core:testing"
import "../../src/render"

@(test)
an_offscreen_renderer_does_not_prewarm :: proc(t: ^testing.T) {
	when render.USE_WGPU {
		r: render.Renderer
		if !testing.expect(t, render.init_offscreen(&r, {64, 64}, warp = true), "an offscreen renderer") { return }
		defer render.destroy(&r)
		testing.expect(t, r.wg.prewarm == nil, "no pre-warming thread")
		// and it draws: the pipeline is made at the first frame
		render.frame_begin(&r, {1, 0, 0, 1})
		render.frame_end(&r)
		px := render.read_pixels(&r, context.temp_allocator)
		testing.expect(t, len(px) >= 4 && px[0] > 200, "the frame is drawn")
	}
}
