#+build linux
package render

import "core:strings"
import "core:testing"
import "vendor:wgpu"
import "../platform"

// The GL fallback's decisions, as data (no-graphics.md, "The GL fallback"). tests/gl_fallback and tests/no_graphics draw
// with it.

// What wgpu's GL backend reports on llvmpipe (Mesa 26, GLES 3.2): everything the renderer binds.
@(private = "file")
llvmpipe_gl :: proc() -> wgpu.Limits {
	return {
		maxTextureDimension2D = 16384, maxBindGroups = 8, maxSampledTexturesPerShaderStage = 16, maxSamplersPerShaderStage = 16,
		maxStorageBuffersPerShaderStage = 16, maxStorageBufferBindingSize = 1 << 27, maxUniformBufferBindingSize = 65536,
		minUniformBufferOffsetAlignment = 16, maxDynamicUniformBuffersPerPipelineLayout = 8, maxInterStageShaderVariables = 31,
	}
}

@(test)
a_gl_adapter_below_what_the_renderer_binds_is_refused :: proc(t: ^testing.T) {
	testing.expect_value(t, wgpu_gl_lacks(llvmpipe_gl()), "")
	few := llvmpipe_gl()
	few.maxStorageBuffersPerShaderStage = 4   // (a GLES 3.1 driver at the specification's minimum for a fragment shader)
	testing.expect_value(t, wgpu_gl_lacks(few), "fewer than 8 storage buffers in a shader stage")
	none := llvmpipe_gl()
	none.maxStorageBufferBindingSize = 0   // (GLES 3.0: no storage buffers at all)
	testing.expect_value(t, wgpu_gl_lacks(none), "storage buffers smaller than 128 MiB")
	wide := llvmpipe_gl()
	wide.minUniformBufferOffsetAlignment = 512
	testing.expect_value(t, wgpu_gl_lacks(wide), "a uniform offset alignment over 256 bytes")
	narrow := llvmpipe_gl()
	narrow.maxInterStageShaderVariables = 13
	testing.expect_value(t, wgpu_gl_lacks(narrow), "fewer than 14 values between the shader stages")
}

@(test)
a_gl_instance_gets_the_windows_display :: proc(t: ^testing.T) {
	conn, wl, xlib := rawptr(uintptr(0x1000)), rawptr(uintptr(0x2000)), rawptr(uintptr(0x3000))
	// X11: the instance's own Xlib connection, never the toolkit's XCB one (wgpu-hal's EGL panics on XCB)
	x := wgpu_gl_display({backend = .X11, display = conn, window = 7}, xlib, 1)
	testing.expect_value(t, x.type, wgpu.NativeDisplayHandleType.Xlib)
	testing.expect_value(t, x.xlib.display, xlib)
	testing.expect_value(t, x.xlib.screen, i32(1))
	w := wgpu_gl_display({backend = .Wayland, display = wl}, nil, 0)
	testing.expect_value(t, w.type, wgpu.NativeDisplayHandleType.Wayland)
	testing.expect_value(t, w.wayland.display, wl)
	// (offscreen: none, EGL surfaceless)
	testing.expect_value(t, wgpu_gl_display(platform.Surface_Handles{}, nil, 0).type, wgpu.NativeDisplayHandleType.None)
}

// A GL instance makes no surface for another display connection than its own: its EGL display cannot present there.
@(test)
a_gl_instance_makes_no_surface_for_another_display :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	r.wg.instance, r.wg.adapter = wgpu.Instance(rawptr(uintptr(1))), wgpu.Adapter(rawptr(uintptr(1)))   // (never called: refused before)
	r.wg.gl, r.wg.gl_display = true, nil
	testing.expect(t, wgpu_make_surface(r, {backend = .Wayland, display = rawptr(uintptr(0x2000)), surface = rawptr(uintptr(0x3000))}) == nil)
}

// GL's WGSL: every module that holds rect.wgsl samples `image` through samp_image alone (GLSL: one sampler per texture);
// the others are compiled as they are.
@(test)
gl_wgsl_samples_the_image_through_one_sampler :: proc(t: ^testing.T) {
	for code in ([]string{WGSL_RECT, WGPU_SLUG_SOURCE, WGPU_SLUG_DUAL_SOURCE}) {
		src, owned := wgpu_gl_source(code, context.allocator)
		defer if owned { delete(src) }
		testing.expect(t, owned, "rect.wgsl is changed")
		testing.expect_value(t, strings.count(src, "var samp_image: sampler;"), 1)
		testing.expect(t, !strings.contains(src, "(image, samp_img,"), "no clamp sampler of its own left")
		testing.expect(t, !strings.contains(src, "(image, samp_wrap,"), "no repeat sampler of its own left")
		testing.expect(t, strings.count(src, "(image, samp_image,") >= 4, "the four samplings of `image` take it")
	}
	for code in ([]string{WGSL_FILTER, WGSL_MIP, WGSL_VIDEO}) {
		src, owned := wgpu_gl_source(code, context.allocator)
		testing.expect(t, !owned && src == code, "a module without rect.wgsl is as it is")
	}
	testing.expect(t, !image_wrap_splits_batches(nil), "no renderer: batches as they are")
}

@(test)
the_api_is_named_as_a_person_reads_it :: proc(t: ^testing.T) {
	testing.expect_value(t, wgpu_api_name(.OpenGLES), "OpenGL ES")
	testing.expect_value(t, wgpu_api_name(.Vulkan), "Vulkan")
}
