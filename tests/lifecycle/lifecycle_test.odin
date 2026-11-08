// Tests of the renderer's life cycle: teardown, device loss and recovery, captures, on an offscreen renderer (WARP; both render
// backends: -define:TOOLKIT_RENDER=wgpu).   odin test tests/lifecycle -vet
package lifecycle_test

import "core:mem"
import "core:slice"
import "core:testing"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "../../src/draw"
import "../../src/font"
import "../../src/platform"
import "../../src/render"

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
	when !render.USE_WGPU { testing.expect(t, chain_on_device(&f), "the first window's swap chain is on the new device") }
	render.surface_use(&f.r, &a)
	render.surface_use(&f.r, &b)
	when !render.USE_WGPU { testing.expect(t, chain_on_device(&f), "the second window's swap chain is on the new device") }
	p, ok = paint(&f, BLUE)
	testing.expectf(t, ok && near(p, {0, 0, 255}), "second window after the loss: %v", p)
	render.surface_use(&f.r, &b)
}

// set_blend_space changed the format of the view of the window in use only.
@(test)
a_second_window_follows_the_blend_space :: proc(t: ^testing.T) {
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

// Partial redraw on a window. A swap chain does not keep what was drawn: a frame of a region starts from what the last one composed.
@(private = "file")
Win_Fx :: struct {
	using fx: Fx,
	surface:  render.Surface,
}

@(private = "file")
win_open :: proc(f: ^Win_Fx) -> bool {
	if !open(&f.fx) { return false }
	if !render.surface_init(&f.r, &f.surface, make_window(), SIZE) { return false }
	render.surface_use(&f.r, &f.surface)
	return true
}

@(private = "file")
win_close :: proc(f: ^Win_Fx) {
	render.surface_use(&f.r, &f.surface)
	render.surface_destroy(&f.r, &f.surface)
	draw.destroy(&f.dc)
	render.destroy(&f.r)
}

// One frame on the window, captured: `box` nil is a frame without damage_begin, a zero rect marks nothing; the pixels at
// (16, 16) and (40, 40).
@(private = "file")
win_frame :: proc(f: ^Win_Fx, box: Maybe(draw.Rect), color: Maybe(draw.Color), clear := [4]f32{1, 1, 1, 1}) -> (inside, outside: [3]int, ok: bool) {
	render.capture_request(&f.r)
	render.frame_begin(&f.r, clear)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	if b, has := box.?; has {
		draw.damage_begin(&f.dc)
		if b != {} { draw.damage(&f.dc, b) }
	}
	if c, has := color.?; has { draw.rect(&f.dc, {{0, 0}, {f32(SIZE.x), f32(SIZE.y)}}, c) }
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	for _ in 0 ..< 400 {
		pixels, size, status := render.capture_poll(&f.r, context.temp_allocator)
		#partial switch status {
		case .Ready:
			read :: proc(p: []u8, w, x, y: int) -> [3]int { o := (y * w + x) * 4; return {int(p[o]), int(p[o + 1]), int(p[o + 2])} }
			return read(pixels, size.x, 16, 16), read(pixels, size.x, 40, 40), true
		case .Failed:
			return
		}
		win.Sleep(5)
	}
	return
}

@(test)
a_region_works_on_a_window :: proc(t: ^testing.T) {
	f: Win_Fx
	if !win_open(&f) { testing.fail_now(t, "no window") }
	defer win_close(&f)
	render.set_partial_redraw(&f.r, true)
	BOX :: draw.Rect{{8, 8}, {24, 24}}
	RED, GREEN, BLUE :: draw.Color{1, 0, 0, 1}, draw.Color{0, 1, 0, 1}, draw.Color{0, 0, 1, 1}
	win_frame(&f, BOX, RED)
	inside, outside, ok := win_frame(&f, BOX, GREEN)
	testing.expect(t, ok)
	_, _, _, _, active := draw.damage_stats(&f.dc)
	testing.expect(t, active, "a region is in effect on a swap chain")
	testing.expectf(t, near(outside, {255, 0, 0}), "outside the region the last frame stays: %v", outside)
	testing.expectf(t, near(inside, {0, 255, 0}), "inside the new one: %v", inside)
	// a frame without a region, then a region: it starts from that frame
	win_frame(&f, nil, BLUE)
	inside, outside, ok = win_frame(&f, BOX, GREEN)
	testing.expect(t, ok)
	testing.expectf(t, !near(outside, {255, 0, 0}), "a stale frame outside the region: %v", outside)
	testing.expectf(t, near(inside, {0, 255, 0}), "inside the new one: %v", inside)
	// the region starts from the clear color
	win_frame(&f, BOX, RED)
	inside, outside, ok = win_frame(&f, BOX, nil)
	testing.expect(t, ok)
	testing.expectf(t, near(inside, {255, 255, 255}), "the region is cleared: %v", inside)
	testing.expectf(t, near(outside, {0, 255, 0}), "and only the region: %v", outside)
}

// Nothing marked: no present, and the slot of the swap chain is still there for the next frame.
@(test)
a_region_of_nothing_presents_nothing :: proc(t: ^testing.T) {
	f: Win_Fx
	if !win_open(&f) { testing.fail_now(t, "no window") }
	defer win_close(&f)
	render.set_partial_redraw(&f.r, true)
	BOX :: draw.Rect{{8, 8}, {24, 24}}
	RED, GREEN :: draw.Color{1, 0, 0, 1}, draw.Color{0, 1, 0, 1}
	win_frame(&f, BOX, RED)
	presents, _, _ := render.present_totals(&f.r)
	render.wait_for_frame(&f.r)
	inside, outside, ok := win_frame(&f, draw.Rect{}, GREEN)
	testing.expect(t, ok)
	testing.expectf(t, near(inside, {255, 0, 0}) && near(outside, {255, 0, 0}), "nothing changed: %v %v", inside, outside)
	after, _, _ := render.present_totals(&f.r)
	testing.expect_value(t, after, presents)
	testing.expect(t, render.wait_for_frame(&f.r, 2000), "the slot waited for and not used")
	win_frame(&f, BOX, GREEN)
	final, _, _ := render.present_totals(&f.r)
	testing.expect_value(t, final, presents + 1)
}

// The GPU profile's first touch of the back buffer leaves the frame's clear color where it was.
@(test)
the_gpu_profile_keeps_the_clear_color :: proc(t: ^testing.T) {
	f: Win_Fx
	if !win_open(&f) { testing.fail_now(t, "no window") }
	defer win_close(&f)
	render.set_gpu_profile(&f.r, true)
	render.capture_request(&f.r)
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	draw.rect(&f.dc, {{0, 0}, {4, 4}}, {1, 0, 0, 1})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	for _ in 0 ..< 400 {
		pixels, size, status := render.capture_poll(&f.r, context.temp_allocator)
		if status == .Ready {
			o := (40 * size.x + 40) * 4
			testing.expectf(t, near({int(pixels[o]), int(pixels[o + 1]), int(pixels[o + 2])}, {255, 255, 255}), "the clear color is gone: %v", pixels[o:o + 3])
			return
		}
		win.Sleep(5)
	}
	testing.expect(t, false, "no capture")
}

// A capture cancelled while its buffer is being mapped says nothing about the next one.
@(test)
a_cancelled_capture_leaves_the_next_alone :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	one_frame :: proc(f: ^Fx) {
		draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
		render.frame_begin(&f.r, {1, 0, 0, 1})
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
	}
	render.capture_request(&f.r)
	one_frame(&f)
	_, _, first := render.capture_poll(&f.r, context.temp_allocator)   // asks for the map
	if first == .Ready { return }                                     // (the backend had it at once: nothing to cancel)
	render.capture_cancel(&f.r)
	render.capture_request(&f.r)
	one_frame(&f)
	for _ in 0 ..< 400 {
		_, _, status := render.capture_poll(&f.r, context.temp_allocator)
		testing.expect(t, status != .Failed, "the cancelled map failed the next capture")
		if status != .Pending { return }
		win.Sleep(5)
	}
	testing.expect(t, false, "no capture")
}

// The rows of a capture and the picture made of them later, on any thread: what capture_poll gives, byte for byte.
@(test)
capture_raw_finish_makes_the_picture :: proc(t: ^testing.T) {
	bgra := [8]u8{10, 20, 30, 40, 50, 60, 70, 80}
	out := render.capture_raw_finish({pixels = bgra[:], size = {2, 1}, format = .BGRA8})
	testing.expectf(t, slice.equal(out, []u8{30, 20, 10, 255, 70, 60, 50, 255}), "BGRA: %v", out)
	rgba := [8]u8{10, 20, 30, 40, 50, 60, 70, 80}
	out = render.capture_raw_finish({pixels = rgba[:], size = {2, 1}, format = .RGBA8})
	testing.expectf(t, slice.equal(out, []u8{10, 20, 30, 255, 50, 60, 70, 255}), "RGBA: %v", out)
	// halves 1.0, 0.0, 0.5, then 0.5, 2.0 (clamped), -1.0 (clamped); their alpha does not count
	halves := [8]f16{1, 0, 0.5, 0.25, 0.5, 2, -1, 0}
	out = render.capture_raw_finish({pixels = mem.slice_to_bytes(halves[:]), size = {2, 1}, format = .Half})
	testing.expectf(t, slice.equal(out, []u8{255, 0, 188, 255, 188, 255, 0, 255}), "halves: %v", out)
}
