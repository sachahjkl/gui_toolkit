// Tests of the renderer's life cycle: teardown, device loss and recovery, captures, on an offscreen renderer (WARP; both render
// backends: -define:TOOLKIT_RENDER=wgpu).   odin test tests/lifecycle -vet
package lifecycle_test

import "core:mem"
import "core:testing"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"

SIZE :: [2]int{64, 64}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
make_window :: proc() -> platform.Surface_Handles {
	hwnd := win.CreateWindowExW(0, win.L("Static"), win.L("lifecycle"), win.WS_OVERLAPPEDWINDOW, 0, 0, 200, 200, nil, nil, nil, nil)
	return {backend = .Windows, hwnd = rawptr(hwnd)}
}

// One frame of a solid color on the window the renderer holds, captured: the pixel in the middle.
@(private = "file")
paint :: proc(f: ^Fx, color: draw.Color) -> (px: [3]int, ok: bool) {
	render.capture_request(&f.r)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {0, 0, 0, 1})
	draw.rect(&f.dc, {{0, 0}, {f32(SIZE.x), f32(SIZE.y)}}, color)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	for _ in 0 ..< 400 {
		pixels, size, status := render.capture_poll(&f.r, context.temp_allocator)
		#partial switch status {
		case .Ready:
			o := (size.y / 2 * size.x + size.x / 2) * 4
			return {int(pixels[o]), int(pixels[o + 1]), int(pixels[o + 2])}, true
		case .Failed:
			return {}, false
		}
		win.Sleep(5)
	}
	return {}, false
}

@(private = "file")
near :: proc(got: [3]int, want: [3]int) -> bool {
	return abs(got[0] - want[0]) <= 2 && abs(got[1] - want[1]) <= 2 && abs(got[2] - want[2]) <= 2
}

// Does the swap chain the renderer holds belong to the renderer's device?
@(private = "file")
chain_on_device :: proc(f: ^Fx) -> bool {
	dev: ^d3d11.IDevice
	f.r.swapchain->GetDevice(d3d11.IDevice_UUID, (^rawptr)(&dev))
	if dev == nil { return false }
	defer dev->Release()
	return dev == f.r.device
}

// Recovery remade only the window in use: the other one kept its swap chain and views from the old device.
@(test)
a_second_window_survives_a_device_loss :: proc(t: ^testing.T) {
	when render.RENDER_BACKEND != "d3d11" { return }   // second windows and captures: Direct3D 11 only
	f: Fx
	if !open(&f) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	a, ok_a := render.surface_create(&f.r, make_window(), SIZE)
	b, ok_b := render.surface_create(&f.r, make_window(), SIZE)
	testing.expect(t, ok_a && ok_b, "two surfaces")
	defer { render.surface_destroy(&f.r, &a); render.surface_destroy(&f.r, &b) }
	RED, BLUE :: draw.Color{1, 0, 0, 1}, draw.Color{0, 0, 1, 1}
	render.surface_use(&f.r, &a)
	p, ok := paint(&f, RED)
	testing.expectf(t, ok && near(p, {255, 0, 0}), "first window before the loss: %v", p)
	render.surface_use(&f.r, &a)
	render.surface_use(&f.r, &b)
	p, ok = paint(&f, BLUE)
	testing.expectf(t, ok && near(p, {0, 0, 255}), "second window before the loss: %v", p)
	render.surface_use(&f.r, &b)

	render.simulate_device_loss(&f.r)
	render.surface_use(&f.r, &a)   // the frame of this window recovers the device
	p, ok = paint(&f, RED)
	testing.expectf(t, ok && near(p, {255, 0, 0}), "first window after the loss: %v", p)
	testing.expect(t, chain_on_device(&f), "the first window's swap chain is on the new device")
	render.surface_use(&f.r, &a)
	render.surface_use(&f.r, &b)
	testing.expect(t, chain_on_device(&f), "the second window's swap chain is on the new device")
	p, ok = paint(&f, BLUE)
	testing.expectf(t, ok && near(p, {0, 0, 255}), "second window after the loss: %v", p)
	render.surface_use(&f.r, &b)
}

// set_blend_space changed the format of the view of the window in use only.
@(test)
a_second_window_follows_the_blend_space :: proc(t: ^testing.T) {
	when render.RENDER_BACKEND != "d3d11" { return }   // second windows and captures: Direct3D 11 only
	f: Fx
	if !open(&f) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	a, ok_a := render.surface_create(&f.r, make_window(), SIZE)
	testing.expect(t, ok_a, "a surface")
	defer render.surface_destroy(&f.r, &a)
	HALF :: draw.Color{0.5, 0.5, 0.5, 1}
	render.surface_use(&f.r, &a)
	p, ok := paint(&f, HALF)
	testing.expectf(t, ok && near(p, {188, 188, 188}), "linear: half is 188 in sRGB: %v", p)
	render.surface_use(&f.r, &a)
	render.set_blend_space(&f.r, .Srgb)
	render.surface_use(&f.r, &a)
	p, ok = paint(&f, HALF)
	testing.expectf(t, ok && near(p, {188, 188, 188}), "sRGB: the same color (a view that encodes again would give about 222): %v", p)
	render.surface_use(&f.r, &a)
}

// A capture is of the window whose frame comes next, not of whichever window ends a frame first.
@(test)
a_capture_belongs_to_its_window :: proc(t: ^testing.T) {
	when render.RENDER_BACKEND != "d3d11" { return }   // second windows and captures: Direct3D 11 only
	f: Fx
	if !open(&f) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	a, ok_a := render.surface_create(&f.r, make_window(), SIZE)
	testing.expect(t, ok_a, "a surface")
	defer render.surface_destroy(&f.r, &a)
	render.capture_request(&f.r)   // of the renderer's own (offscreen) window
	render.surface_use(&f.r, &a)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {0, 1, 0, 1})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	render.surface_use(&f.r, &a)
	testing.expect(t, render.capture_pending(&f.r), "the other window's frame did not take the capture")
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 0, 0, 1})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	pixels: []u8
	size: [2]int
	status: render.Capture_Status
	for _ in 0 ..< 400 {
		pixels, size, status = render.capture_poll(&f.r, context.temp_allocator)
		if status != .Pending { break }
		win.Sleep(5)
	}
	testing.expect(t, status == .Ready, "the capture is ready")
	if status == .Ready {
		o := (size.y / 2 * size.x + size.x / 2) * 4
		testing.expectf(t, near({int(pixels[o]), int(pixels[o + 1]), int(pixels[o + 2])}, {255, 0, 0}), "the capture shows the window it was asked of: %v", pixels[o:o + 3])
	}
}

// The copy a capture reads through was made on the device that is gone.
@(test)
capture_copy_does_not_outlive_the_device :: proc(t: ^testing.T) {
	when render.RENDER_BACKEND != "d3d11" { return }   // captures: Direct3D 11 only
	f: Fx
	if !open(&f) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	p, ok := paint(&f, draw.Color{0, 1, 0, 1})
	testing.expectf(t, ok && near(p, {0, 255, 0}), "a capture: %v", p)
	testing.expect(t, f.r.capture.staging != nil, "its copy is kept for the next one")
	render.simulate_device_loss(&f.r)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {0, 0, 0, 1})
	testing.expect(t, f.r.capture.staging == nil, "the copy of the old device is gone after the recovery")
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	p, ok = paint(&f, draw.Color{0, 0, 1, 1})
	testing.expectf(t, ok && near(p, {0, 0, 255}), "a capture after the recovery: %v", p)
}

// An upload to a handle that is not a texture, to a destroyed one, outside the texture or from too few pixels writes nothing (and does
// not crash).
@(test)
r8_upload_ignores_bad_arguments :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	tex := render.create_texture_r8(&f.r, 16)
	testing.expect(t, tex != 0, "an R8 texture")
	pixels := make([]u8, 16 * 16, context.temp_allocator)
	render.update_texture_r8(&f.r, tex, 0, 0, 16, 16, pixels, 16)   // fine
	render.update_texture_r8(&f.r, render.Texture(9999), 0, 0, 4, 4, pixels, 16)
	render.update_texture_r8(&f.r, render.Texture(0), 0, 0, 4, 4, pixels, 16)
	render.update_texture_r8(&f.r, tex, 10, 0, 10, 4, pixels, 16)   // outside
	render.update_texture_r8(&f.r, tex, -1, 0, 4, 4, pixels, 16)
	render.update_texture_r8(&f.r, tex, 0, 0, 16, 16, pixels[:100], 16)   // too short
	render.destroy_texture(&f.r, tex)
	render.update_texture_r8(&f.r, tex, 0, 0, 4, 4, pixels, 16)   // destroyed
}

// An allocator that fills what is freed with 0xAA first: a read of freed memory finds garbage handles (and crashes) instead of the old values.
Poison :: struct { inner: mem.Allocator }

@(private = "file")
poison_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, align: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	p := (^Poison)(data)
	if mode == .Free && old != nil && old_size > 0 { mem.set(old, 0xAA, old_size) }
	return p.inner.procedure(p.inner.data, mode, size, align, old, old_size, loc)
}

// destroy released the texture table, then walked it again to release the objects of the textures.
@(test)
destroy_does_not_read_the_freed_texture_table :: proc(t: ^testing.T) {
	p := Poison{context.allocator}
	context.allocator = mem.Allocator{poison_proc, &p}
	f: Fx
	if !open(&f) { testing.fail_now(t, "no device (WARP)") }
	tex := render.create_texture_rgba(&f.r, 16, 16)
	testing.expect(t, tex != 0)
	data := render.create_texture_data(&f.r, 8, 8)
	testing.expect(t, data != 0)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.image(&f.dc, tex, {{8, 8}, {24, 24}})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	draw.destroy(&f.dc)
	render.destroy(&f.r)
}
