package render

import "core:testing"
import "core:time"
import "vendor:wgpu"
_ :: wgpu

@(private = "file") PRELOAD_TEST_SIZE :: [2]int{8, 8}
@(private = "file") PRELOAD_TEST_LIMIT :: 30 * time.Second
@(private = "file") PRELOAD_TEST_RED :: [4]f32{1, 0, 0, 1}
@(private = "file") BYTE_MAX :: 255

// The device the thread made, once it has (nil: it failed or the limit passed).
@(private = "file")
made_device :: proc() -> rawptr {
	end := time.tick_add(time.tick_now(), PRELOAD_TEST_LIMIT)
	for device_preload_state() == .Creating && time.tick_diff(time.tick_now(), end) > 0 { time.sleep(time.Millisecond) }
	if device_preload_state() != .Ready { return nil }
	when USE_WGPU { return rawptr(preload.held.wg.device) } else { return rawptr(preload.held.device) }
}

@(private = "file")
device_of :: proc(r: ^Renderer) -> rawptr {
	when USE_WGPU { return rawptr(r.wg.device) } else { return rawptr(r.device) }
}

// One test (the preload is the process's): the init of the kind asked for takes the device and draws with it, the other
// kind makes its own, and a device nobody takes can be let go.
@(test)
a_device_made_early_goes_to_the_init_of_its_kind :: proc(t: ^testing.T) {
	testing.expect_value(t, device_preload_state(), Device_Preload_State.Not_Started)
	testing.expect(t, preload_device(warp = true), "the thread starts")
	testing.expect(t, !preload_device(warp = true), "a second one while the first waits is refused")
	early := made_device()
	testing.expect(t, early != nil, "the thread made a WARP device")
	when USE_WGPU {
		// the device's thread made the shaders, and started the first frame's two pipelines in the format of a host's
		// window (transparent, linear light; no half floats known before the surface) where compiles run side by side
		testing.expect(t, preload.held.wg.bgl0 != nil && preload.held.wg.module_rect != nil, "the shaders made early")
		e := preload.held.wg.early
		when COMPILES_SERIAL {
			testing.expect(t, e == nil, "no early pipeline where it would queue in front of the window's own")
		} else {
			testing.expect(t, e != nil && e.format == .BGRA8UnormSrgb, "the first frame's pipelines started")
		}
	}

	r: Renderer
	testing.expect(t, init_offscreen(&r, PRELOAD_TEST_SIZE, warp = true), "init_offscreen")
	testing.expect_value(t, device_preload_state(), Device_Preload_State.Not_Started)
	testing.expect(t, device_of(&r) == early, "init_offscreen took the device made early")
	when USE_WGPU && !COMPILES_SERIAL {
		held := r.wg.early
		if testing.expect(t, held != nil, "the renderer holds them") {
			// a pipeline of another format never waits for them; one of theirs is theirs
			testing.expect(t, wgpu_pipeline(&r, .RGBA16Float, false) != nil, "another format's pipeline")
			testing.expect(t, !held.adopted, "made without them")
			rect := wgpu_pipeline(&r, r.wg.view_format, false)
			testing.expect(t, held.adopted && rect != nil && rect == held.rect, "the frame's pipeline is the one made early")
			testing.expect(t, wgpu_slug_pipeline(&r, r.wg.view_format, false) == held.slug, "the text's too")
		}
	}
	frame_begin(&r, PRELOAD_TEST_RED)
	frame_end(&r)
	px := read_pixels(&r)
	testing.expect(t, len(px) == PRELOAD_TEST_SIZE.x * PRELOAD_TEST_SIZE.y * 4 && px[0] == BYTE_MAX && px[1] == 0 && px[2] == 0, "it draws")
	delete(px)
	destroy(&r)

	// another kind: the device made early is released, the init makes its own
	testing.expect(t, preload_device(warp = true), "the thread starts again")
	testing.expect(t, made_device() != nil, "the thread made a WARP device again")
	testing.expect(t, init_offscreen(&r, PRELOAD_TEST_SIZE, warp = false), "init_offscreen of the hardware (WARP where there is none)")
	testing.expect_value(t, device_preload_state(), Device_Preload_State.Not_Started)
	testing.expect(t, device_of(&r) != nil, "a device of its own")
	destroy(&r)

	// nobody takes it
	testing.expect(t, preload_device(warp = true), "the thread starts a third time")
	release_preloaded_device()
	testing.expect_value(t, device_preload_state(), Device_Preload_State.Not_Started)
}

// The format of the pipelines made early is the one the renderer will choose for the window (wgpu_frame_formats), and
// none is made where compiles run one at a time.
@(test)
early_pipelines_are_made_in_the_window_s_format :: proc(t: ^testing.T) {
	when USE_WGPU {
		F :: struct { format: wgpu.TextureFormat, make: bool }
		choose :: proc(transparent: bool, space: Blend_Space, offer: Half_Float_Offer, serial: bool) -> F {
			f, m := early_pipeline_format(transparent, space, offer, serial)
			return {f, m}
		}
		testing.expect_value(t, choose(true, .Linear, .Yes, false), F{.RGBA16Float, true})
		testing.expect_value(t, choose(true, .Linear, .No, false), F{.BGRA8UnormSrgb, true})
		testing.expect_value(t, choose(true, .Linear, .Unknown, false), F{.BGRA8UnormSrgb, true})
		testing.expect_value(t, choose(false, .Linear, .Yes, false), F{.BGRA8UnormSrgb, true})
		testing.expect_value(t, choose(true, .Srgb, .Yes, false), F{.BGRA8Unorm, true})
		testing.expect_value(t, choose(true, .Linear, .Yes, true).make, false)
	}
}
