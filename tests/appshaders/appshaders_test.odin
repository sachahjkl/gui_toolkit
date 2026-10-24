// Pixel tests of application shaders (draw.app_shader) on an offscreen renderer (WARP, the software rasterizer: no GPU or window
// needed), in both blend spaces.   odin test tests/appshaders -vet
// The shader is test.wgsl; its Direct3D 11 pixel shader (shaders/test.dxbc, shaders/test.sha256) is written by
//   odin run tools/shaders -- app test tests/appshaders/test.wgsl tests/appshaders/shaders
// (The same tests run on the WebGPU backend: tools\test_backends.ps1 -Backend wgpu -Only appshaders.)
package appshaders_test

import "core:math"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

SIZE :: [2]int{64, 64}

TEST_WGSL :: #load("test.wgsl", string)
TEST_DXBC :: #load("shaders/test.dxbc")
TEST_HASH :: #load("shaders/test.sha256", string)

Fx :: struct {
	r:      render.Renderer,
	fonts:  font.State,
	dc:     draw.Context,
	shader: render.App_Shader,
	space:  render.Blend_Space,
}

@(private = "file")
open :: proc(f: ^Fx, space: render.Blend_Space) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = space) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	f.space = space
	f.shader = render.create_app_shader(&f.r, {name = "test", wgsl = TEST_WGSL, dxbc = TEST_DXBC, hash = TEST_HASH})
	return f.shader != 0
}

@(private = "file")
close :: proc(f: ^Fx) {
	draw.destroy(&f.dc)
	render.destroy(&f.r)
}

@(private = "file")
begin :: proc(f: ^Fx, clear := draw.Color{1, 1, 1, 1}) {
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, clear)
}

@(private = "file")
finish :: proc(f: ^Fx) -> []u8 {
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
px :: proc(img: []u8, x, y: int) -> [4]int {
	o := (y * SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
}

// The 8-bit value `read_pixels` returns for a value held in the blend space (sRGB-encoded in both: Linear's view encodes).
@(private = "file")
level :: proc(v: f32, space: render.Blend_Space) -> int {
	e := space == .Linear ? render.linear_to_srgb(clamp(v, 0, 1)) : clamp(v, 0, 1)
	return int(math.round(e * 255))
}

// A value in the blend space from a linear one.
@(private = "file")
in_space :: proc(lin: f32, space: render.Blend_Space) -> f32 {
	return space == .Srgb ? render.linear_to_srgb(lin) : lin
}

@(private = "file")
near :: proc(got: [4]int, want: [3]int, tol := 2) -> bool {
	return abs(got[0] - want[0]) <= tol && abs(got[1] - want[1]) <= tol && abs(got[2] - want[2]) <= tol
}

BOX :: draw.Rect{{8, 8}, {40, 40}}

@(test)
solid_color_is_converted_to_the_blend_space :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
		defer close(&f)
		begin(&f)
		ok := draw.app_shader(&f.dc, f.shader, BOX, {{0, 0, 0, 0}, {0.2, 0.5, 0.05, 1}})
		img := finish(&f)
		testing.expect(t, ok)
		want := [3]int{level(0.2, .Linear), level(0.5, .Linear), level(0.05, .Linear)}   // the shader returns linear light
		testing.expectf(t, near(px(img, 20, 20), want), "%v: inside %v, want %v", space, px(img, 20, 20), want)
		testing.expectf(t, near(px(img, 4, 4), {255, 255, 255}), "%v: outside %v", space, px(img, 4, 4))
		testing.expectf(t, near(px(img, 44, 20), {255, 255, 255}), "%v: just right of the box %v", space, px(img, 44, 20))
	}
}

@(test)
uv_covers_the_rectangle :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
		defer close(&f)
		begin(&f)
		draw.app_shader(&f.dc, f.shader, BOX, {{1, 0, 0, 0}, {0, 0, 0.5, 1}})
		img := finish(&f)
		// the pixel x = 12 has its center at 12.5: uv.x = (12.5 - 8) / 32 ; the pixel y = 30: uv.y = (30.5 - 8) / 32
		want := [3]int{level((12.5 - 8) / 32, .Linear), level((30.5 - 8) / 32, .Linear), level(0.5, .Linear)}
		testing.expectf(t, near(px(img, 12, 30), want, 3), "%v: ramp %v, want %v", space, px(img, 12, 30), want)
		want2 := [3]int{level((35.5 - 8) / 32, .Linear), level((10.5 - 8) / 32, .Linear), level(0.5, .Linear)}
		testing.expectf(t, near(px(img, 35, 10), want2, 3), "%v: ramp %v, want %v", space, px(img, 35, 10), want2)
	}
}

@(test)
data_texture_is_read_raw :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
		defer close(&f)
		tex := render.create_texture_data(&f.r, 2, 2, .RGBA8, mips = false)
		testing.expect(t, tex != 0)
		texels := [16]u8{128, 64, 255, 255, 128, 64, 255, 255, 128, 64, 255, 255, 128, 64, 255, 255}
		render.update_texture_data(&f.r, tex, 0, 0, 2, 2, texels[:])
		begin(&f)
		draw.app_shader(&f.dc, f.shader, BOX, {{2, 0, 0, 0}}, {tex})
		img := finish(&f)
		// the texels are 0..1 values the shader returns as linear light: nothing decoded them from sRGB
		want := [3]int{level(128.0 / 255, .Linear), level(64.0 / 255, .Linear), 255}
		testing.expectf(t, near(px(img, 24, 24), want), "%v: %v, want %v", space, px(img, 24, 24), want)
		render.destroy_texture(&f.r, tex)
	}
}

@(test)
two_textures_and_empty_slots :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
	defer close(&f)
	a := render.create_texture_data(&f.r, 1, 1, .RGBA8, mips = false)
	b := render.create_texture_data(&f.r, 1, 1, .RGBA8, mips = false)
	ta := [4]u8{0, 255, 0, 255}
	tb := [4]u8{255, 0, 0, 255}
	render.update_texture_data(&f.r, a, 0, 0, 1, 1, ta[:])
	render.update_texture_data(&f.r, b, 0, 0, 1, 1, tb[:])
	begin(&f)
	draw.app_shader(&f.dc, f.shader, {{0, 0}, {20, 20}}, {{4, 0, 0, 0}}, {a, b})   // tex 1 is opaque: it wins
	draw.app_shader(&f.dc, f.shader, {{30, 0}, {50, 20}}, {{4, 0, 0, 0}}, {a})      // tex 1 is empty (transparent): tex 0 shows
	img := finish(&f)
	testing.expectf(t, near(px(img, 10, 10), {255, 0, 0}), "both: %v", px(img, 10, 10))
	testing.expectf(t, near(px(img, 40, 10), {0, 255, 0}), "empty slot: %v", px(img, 40, 10))
	render.destroy_texture(&f.r, a)
	render.destroy_texture(&f.r, b)
}

@(test)
blend_modes_mix_with_what_lies_under :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		modes := [render.App_Blend]struct { name: string, f: proc(d, s: f32) -> f32 }{
			.Normal   = {"normal", proc(d, s: f32) -> f32 { return s }},
			.Add      = {"add", proc(d, s: f32) -> f32 { return min(d + s, 1) }},
			.Screen   = {"screen", proc(d, s: f32) -> f32 { return s + d - s * d }},
			.Multiply = {"multiply", proc(d, s: f32) -> f32 { return s * d }},
		}
		for mode in render.App_Blend {
			f: Fx
			if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
			defer close(&f)
			begin(&f)
			base := draw.Color{0.25, 0.25, 0.25, 1}
			draw.rect(&f.dc, {{0, 0}, {64, 64}}, base)
			draw.app_shader(&f.dc, f.shader, BOX, {{0, 0, 0, 0}, {0.5, 0.5, 0.5, 1}}, nil, mode)
			img := finish(&f)
			// both operands as the blend space holds them; the result is what the formula gives there
			d, s := in_space(0.25, space), in_space(0.5, space)
			v := modes[mode].f(d, s)
			want, under := level(v, space), level(d, space)
			testing.expectf(t, near(px(img, 20, 20), {want, want, want}, 3), "%v %s: %v, want %d", space, modes[mode].name, px(img, 20, 20), want)
			testing.expectf(t, near(px(img, 4, 4), {under, under, under}, 3), "%v %s: outside the box is the base %v", space, modes[mode].name, px(img, 4, 4))
		}
	}
}

@(test)
alpha_stack_and_tint_fade_the_result :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
		defer close(&f)
		begin(&f)
		draw.push_alpha(&f.dc, 0.5)
		draw.app_shader(&f.dc, f.shader, BOX, {{0, 0, 0, 0}, {1, 0, 0, 1}})
		draw.pop_alpha(&f.dc)
		draw.app_shader(&f.dc, f.shader, {{44, 8}, {60, 40}}, {{0, 0, 0, 0}, {1, 0, 0, 1}}, nil, .Normal, {}, draw.Color{1, 1, 1, 0.5})
		img := finish(&f)
		half := space == .Srgb ? 128 : 188   // 50 % red over white: the green and blue channel
		testing.expectf(t, near(px(img, 20, 20), {255, half, half}, 3), "%v alpha stack: %v", space, px(img, 20, 20))
		testing.expectf(t, near(px(img, 50, 20), {255, half, half}, 3), "%v tint: %v", space, px(img, 50, 20))
	}
}

@(test)
corners_and_clips_apply :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
		defer close(&f)
		begin(&f)
		draw.app_shader(&f.dc, f.shader, {{4, 4}, {36, 36}}, {{0, 0, 0, 0}, {0, 0, 0, 1}}, nil, .Normal, {16, 16, 16, 16})
		draw.push_clip_rounded(&f.dc, {{40, 4}, {60, 24}}, {10, 10, 10, 10})
		draw.app_shader(&f.dc, f.shader, {{36, 0}, {64, 40}}, {{0, 0, 0, 0}, {0, 0, 0, 1}})
		draw.pop_clip(&f.dc)
		img := finish(&f)
		testing.expectf(t, near(px(img, 20, 20), {0, 0, 0}), "%v: the middle of the rounded rect: %v", space, px(img, 20, 20))
		testing.expectf(t, near(px(img, 5, 5), {255, 255, 255}), "%v: the cut corner stays white: %v", space, px(img, 5, 5))
		testing.expectf(t, near(px(img, 50, 14), {0, 0, 0}), "%v: inside the clip: %v", space, px(img, 50, 14))
		testing.expectf(t, near(px(img, 41, 5), {255, 255, 255}), "%v: the rounded clip's corner: %v", space, px(img, 41, 5))
		testing.expectf(t, near(px(img, 50, 30), {255, 255, 255}), "%v: below the clip: %v", space, px(img, 50, 30))
	}
}

@(test)
rotated_rect_gets_its_local_size_and_scale :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
	defer close(&f)
	begin(&f)
	m := draw.affine_mul(draw.affine_translate({32, 32}), draw.affine_mul(draw.affine_rotate(math.PI / 2), draw.affine_scale({1.5, 1.5})))
	draw.push_transform(&f.dc, m)
	draw.app_shader(&f.dc, f.shader, {{-10, -15}, {10, 15}}, {{3, 0, 0, 0}})   // 20 x 30 local units, 1.5 pixels each
	draw.pop_transform(&f.dc)
	img := finish(&f)
	want := [3]int{level(0.2, .Linear), level(0.3, .Linear), level(0.15, .Linear)}
	testing.expectf(t, near(px(img, 32, 32), want, 3), "size and scale: %v, want %v", px(img, 32, 32), want)
	// the rect was 20 x 30 turned by 90 degrees and scaled by 1.5: 45 wide and 30 high on screen
	testing.expectf(t, near(px(img, 32 + 20, 32), want, 3), "inside the turned rect (wide): %v", px(img, 32 + 20, 32))
	testing.expectf(t, near(px(img, 32, 32 + 20), {255, 255, 255}), "outside the turned rect (it is only 30 high): %v", px(img, 32, 32 + 20))
}

@(test)
inside_a_layer_and_a_plane :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
		defer close(&f)
		begin(&f)
		draw.push_layer(&f.dc, {{0, 0}, {64, 64}}, 0.5)
		draw.app_shader(&f.dc, f.shader, {{0, 0}, {30, 30}}, {{0, 0, 0, 0}, {1, 0, 0, 1}})
		draw.pop_layer(&f.dc)
		draw.push_plane(&f.dc, {{0, 0}, {30, 30}}, 1)
		draw.app_shader(&f.dc, f.shader, {{0, 0}, {30, 30}}, {{0, 0, 0, 0}, {0, 0, 1, 1}})
		draw.pop_plane_draw(&f.dc, draw.mat4_from_affine(draw.affine_translate({34, 34})), 1)
		img := finish(&f)
		half := space == .Srgb ? 128 : 188
		testing.expectf(t, near(px(img, 15, 15), {255, half, half}, 3), "%v: in a half transparent layer %v", space, px(img, 15, 15))
		testing.expectf(t, near(px(img, 50, 50), {0, 0, 255}, 3), "%v: in a plane %v", space, px(img, 50, 50))
	}
}

@(test)
several_draws_keep_their_own_parameters :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
	defer close(&f)
	begin(&f)
	for k in 0 ..< 8 {
		x := f32(k * 8)
		c := draw.Color{f32(k) / 7, 1 - f32(k) / 7, 0, 1}
		draw.app_shader(&f.dc, f.shader, {{x, 0}, {x + 8, 64}}, {{0, 0, 0, 0}, c})
	}
	img := finish(&f)
	for k in 0 ..< 8 {
		r, g := f32(k) / 7, 1 - f32(k) / 7
		want := [3]int{level(r, .Linear), level(g, .Linear), 0}
		testing.expectf(t, near(px(img, k * 8 + 4, 30), want), "draw %d: %v, want %v", k, px(img, k * 8 + 4, 30), want)
	}
}

@(test)
refusals :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
	defer close(&f)
	begin(&f)
	testing.expect(t, !draw.app_shader(&f.dc, 0, BOX, {{0, 0, 0, 0}}), "shader 0")
	too_many := make([]draw.Vec4, render.MAX_APP_PARAMS + 1, context.temp_allocator)
	testing.expect(t, !draw.app_shader(&f.dc, f.shader, BOX, too_many), "too many parameters")
	five := [5]render.Texture{}
	testing.expect(t, !draw.app_shader(&f.dc, f.shader, BOX, {{0, 0, 0, 0}}, five[:]), "too many textures")
	pic: draw.Picture
	draw.picture_begin(&f.dc, &pic)
	testing.expect(t, !draw.app_shader(&f.dc, f.shader, BOX, {{0, 0, 0, 0}}), "recording a picture")
	draw.rect(&f.dc, BOX, draw.Color{0, 0, 0, 1})
	draw.picture_end(&f.dc)
	draw.picture_destroy(&f.dc, &pic)
	img := finish(&f)
	testing.expectf(t, near(px(img, 20, 20), {255, 255, 255}), "nothing was drawn: %v", px(img, 20, 20))

	when render.RENDER_BACKEND == "d3d11" {
		// a blob built from other sources is refused, not drawn
		bad := render.create_app_shader(&f.r, {name = "stale", wgsl = TEST_WGSL, dxbc = TEST_DXBC, hash = "0000"})
		testing.expect(t, bad == 0, "a stale blob is refused")
		none := render.create_app_shader(&f.r, {name = "no blob", wgsl = TEST_WGSL, hash = TEST_HASH})
		testing.expect(t, none == 0, "no blob")
	}
}

@(test)
shader_and_texture_survive_a_device_loss :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
	defer close(&f)
	tex := render.create_texture_data(&f.r, 1, 1, .RGBA8, mips = false)
	texel := [4]u8{255, 128, 0, 255}
	render.update_texture_data(&f.r, tex, 0, 0, 1, 1, texel[:])
	render.simulate_device_loss(&f.r)
	begin(&f)
	render.update_texture_data(&f.r, tex, 0, 0, 1, 1, texel[:])   // contents are gone: the owner uploads them again
	draw.app_shader(&f.dc, f.shader, BOX, {{2, 0, 0, 0}}, {tex})
	img := finish(&f)
	want := [3]int{255, level(128.0 / 255, .Linear), 0}
	testing.expectf(t, near(px(img, 20, 20), want), "after the loss: %v, want %v", px(img, 20, 20), want)
	render.destroy_texture(&f.r, tex)
}

@(test)
mipmapped_data_texture_averages :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no D3D11 device (WARP) or the app shader was refused") }
	defer close(&f)
	tex := render.create_texture_data(&f.r, 8, 8, .RGBA8, mips = true)
	texels: [8 * 8 * 4]u8
	for i in 0 ..< 64 {
		v := u8(i % 2 == 0 ? 0 : 200)   // columns alternate 0 and 200
		texels[i * 4], texels[i * 4 + 1], texels[i * 4 + 2], texels[i * 4 + 3] = v, v, v, 255
	}
	render.update_texture_data(&f.r, tex, 0, 0, 8, 8, texels[:])
	begin(&f)
	draw.app_shader(&f.dc, f.shader, {{0, 0}, {2, 2}}, {{2, 0, 0, 0}}, {tex})   // 8 texels onto 2 pixels: the small levels show
	img := finish(&f)
	got := px(img, 0, 0)
	want := level(100.0 / 255, .Linear)
	testing.expectf(t, abs(got[0] - want) <= 12, "a minified data texture is filtered through its mips: %v, want about %d", got, want)
	render.destroy_texture(&f.r, tex)
}
