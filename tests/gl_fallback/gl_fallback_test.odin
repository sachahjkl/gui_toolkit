#+build linux
// The renderer on wgpu's GL backend (src/md/infrastructure/no-graphics.md, "The GL fallback"), offscreen: EGL surfaceless,
// Mesa's llvmpipe where there is no GPU. TOOLKIT_WGPU_BACKEND=gl is set before the first renderer of the process (the
// switch is read once), so every renderer here is GL. A known frame is drawn and its pixels compared with what the
// Vulkan renderer gives for it (tests/blend_space: the same values). Where the system has no EGL, each test says so in
// the log and draws nothing.
//   odin run tools/run_tests -- gl_fallback
package gl_fallback_test

import "base:runtime"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "gt:draw"
import "gt:font"
import "gt:render"

SIZE :: [2]int{128, 64}

// GL forced, on Mesa's EGL alone where the dev shell names it (TOOLKIT_TEST_MESA_EGL, flake.nix): the driver a machine
// without Vulkan has. libglvnd reads the variable at the first EGL call, after this. (On NVIDIA's EGL, glvnd's first choice
// on a machine with that card, wgpu's GL backend gets a GLSL 330 context and refuses it.)
@(init)
force_gl :: proc "contextless" () {
	context = runtime.default_context()
	os.set_env("TOOLKIT_WGPU_BACKEND", "gl")
	if mesa := os.get_env("TOOLKIT_TEST_MESA_EGL", context.temp_allocator); mesa != "" {
		os.set_env("__EGL_VENDOR_LIBRARY_FILENAMES", mesa)
	}
}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

// False: no GL device here (the log says why), or it failed (the test fails). A GL adapter that exists but is refused
// ("OpenGL has ...": shaders it cannot compile, limits) is a failure, not a skip: that is what this package is for.
@(private = "file")
open :: proc(t: ^testing.T, f: ^Fx, space: render.Blend_Space) -> bool {
	if !render.init_offscreen(&f.r, SIZE, space = space) {
		error, detail := render.init_failure(&f.r)
		if error == .No_Driver && !strings.contains(detail, "OpenGL has") {
			log.warnf("SKIPPED: no OpenGL device on this system (EGL): %s", detail)
		} else {
			testing.expectf(t, false, "the GL renderer starts: %v: %s", error, detail)
		}
		return false
	}
	font.init(&f.fonts)
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
close :: proc(f: ^Fx) { draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts) }

@(private = "file")
px :: proc(img: []u8, x, y: int) -> [4]int {
	o := (y * SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
}

@(private = "file")
near :: proc(a: [4]int, r, g, b: int, tol := 2) -> bool {
	return abs(a[0] - r) <= tol && abs(a[1] - g) <= tol && abs(a[2] - b) <= tol
}

@(private = "file")
enc8 :: proc(l: f32) -> int { return int(math.round(render.linear_to_srgb(l) * 255)) }

// The renderer says what draws, from wgpu's adapter: OpenGL (a desktop context: Mesa's) or OpenGL ES (an ES one).
@(test)
the_renderer_reports_opengl_es :: proc(t: ^testing.T) {
	f: Fx
	if !open(t, &f, .Linear) { return }
	defer close(&f)
	info := render.adapter_info(&f.r)
	testing.expectf(t, info.api == "OpenGL" || info.api == "OpenGL ES", "the API: %q", info.api)
	testing.expect(t, info.name != "", "the adapter has a name")
}

// Opaque and translucent colours, an opacity group (a half-float layer: the target GLES draws into only with
// EXT_color_buffer_half_float) and a blur (the filter passes), in both blend spaces: the bytes Vulkan gives.
@(test)
a_known_frame_has_the_vulkan_pixels :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(t, &f, space) { return }
		defer close(&f)
		draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		draw.rect(&f.dc, {{0, 0}, {32, 32}}, {1, 0, 0, 1})
		draw.rect(&f.dc, {{32, 0}, {64, 32}}, {0, 0, 0, 0.5})
		// two overlapping blue rectangles at half opacity as one group: the overlap is no darker than the rest
		draw.push_layer(&f.dc, {{0, 32}, {64, 64}}, 0.5)
		draw.rect(&f.dc, {{0, 32}, {40, 64}}, {0, 0, 1, 1})
		draw.rect(&f.dc, {{24, 32}, {64, 64}}, {0, 0, 1, 1})
		draw.pop_layer(&f.dc)
		// a blurred green square much larger than its blur: its middle keeps its colour
		blur := [1]draw.Filter{draw.filter_blur(2)}
		_ = draw.push_effects(&f.dc, {{64, 0}, {128, 64}}, draw.Layer_Effects{alpha = 1, filters = blur[:]})
		draw.rect(&f.dc, {{72, 8}, {120, 56}}, {0, 1, 0, 1})
		draw.pop_layer(&f.dc)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		img := render.read_pixels(&f.r, context.temp_allocator)
		if !testing.expectf(t, len(img) == SIZE.x * SIZE.y * 4, "%v: the frame is read back", space) { return }
		h := space == .Srgb ? 128 : enc8(0.5)
		testing.expectf(t, near(px(img, 16, 16), 255, 0, 0), "%v: red: %v", space, px(img, 16, 16))
		testing.expectf(t, near(px(img, 48, 16), h, h, h), "%v: half black over white: %v, want %d", space, px(img, 48, 16), h)
		testing.expectf(t, near(px(img, 8, 48), h, h, 255), "%v: the group at half: %v", space, px(img, 8, 48))
		testing.expectf(t, near(px(img, 32, 48), h, h, 255), "%v: its overlap the same: %v", space, px(img, 32, 48))
		testing.expectf(t, near(px(img, 96, 32), 0, 255, 0), "%v: the blurred square's middle: %v", space, px(img, 96, 32))
		testing.expectf(t, near(px(img, 124, 60), 255, 255, 255), "%v: white past the blur: %v", space, px(img, 124, 60))
	}
}

// One texture drawn clamped, then tiled, then clamped again: on GL its sampler is the batch's (render.Batch.image_wrap),
// so the three draws are three batches, and each samples as it would on Vulkan. The texture is two texels, red then
// blue, magnified: linear filtering mixes them between their centres; a clamped draw keeps pure red and blue at its
// ends; a tiled one wraps, so where one copy ends and the next begins blue mixes with red again (clamped there, it
// would stay blue).
@(test)
an_image_clamps_or_repeats_by_its_draw :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(t, &f, space) { return }
		defer close(&f)
		tex := render.create_texture_rgba(&f.r, 2, 1, mips = false)
		if !testing.expectf(t, tex != 0, "%v: the texture is made", space) { return }
		texels := [8]u8{255, 0, 0, 255, 0, 0, 255, 255}
		render.update_texture_rgba(&f.r, tex, 0, 0, 2, 1, texels[:])
		draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		draw.image(&f.dc, tex, {{0, 0}, {64, 32}})                            // clamped: 32 pixels a texel
		draw.image_tiled(&f.dc, tex, {{64, 0}, {128, 32}}, {{64, 0}, {80, 32}})   // repeated: a copy every 16 pixels
		draw.image(&f.dc, tex, {{0, 32}, {64, 64}})                           // clamped again, after the tiled one
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		img := render.read_pixels(&f.r, context.temp_allocator)
		if !testing.expectf(t, len(img) == SIZE.x * SIZE.y * 4, "%v: the frame is read back", space) { return }
		red :: proc(p: [4]int) -> bool { return p[0] > 200 && p[1] < 40 && p[2] < 40 }
		blue :: proc(p: [4]int) -> bool { return p[2] > 200 && p[0] < 40 && p[1] < 40 }
		mostly_red :: proc(p: [4]int) -> bool { return p[0] > 180 && p[2] < 110 }
		mostly_blue :: proc(p: [4]int) -> bool { return p[2] > 180 && p[0] < 110 }
		mixed :: proc(p: [4]int) -> bool { return p[0] > 60 && p[2] > 60 && p[1] < 40 }
		testing.expectf(t, red(px(img, 2, 16)), "%v: the clamped image starts red: %v", space, px(img, 2, 16))
		testing.expectf(t, mixed(px(img, 32, 16)), "%v: linear filtering between the texels: %v", space, px(img, 32, 16))
		testing.expectf(t, blue(px(img, 61, 16)), "%v: and ends blue: %v", space, px(img, 61, 16))
		testing.expectf(t, mostly_red(px(img, 84, 16)), "%v: the second copy's red texel: %v", space, px(img, 84, 16))
		testing.expectf(t, mostly_blue(px(img, 92, 16)), "%v: its blue texel: %v", space, px(img, 92, 16))
		testing.expectf(t, mixed(px(img, 80, 16)), "%v: the copies wrap (blue into red), not clamp: %v", space, px(img, 80, 16))
		testing.expectf(t, mixed(px(img, 112, 16)), "%v: at every seam: %v", space, px(img, 112, 16))
		testing.expectf(t, red(px(img, 2, 48)) && blue(px(img, 61, 48)), "%v: the clamped image after the tiled one: %v %v", space, px(img, 2, 48), px(img, 61, 48))
		render.destroy_texture(&f.r, tex)
	}
}
