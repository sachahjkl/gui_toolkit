// What the renderer's states allow, on both backends: a device lost and not had back, a window set aside, a frame that did not run.
//   odin test tests/lifecycle -vet
//   odin test tests/lifecycle -vet -define:TOOLKIT_RENDER=wgpu
// With what the system does not fail on demand (render/faults.odin): -define:TOOLKIT_RENDER_FAULTS=true
package lifecycle_test

import "core:testing"
import win "core:sys/windows"
import "vendor:wgpu"
import "../../draw"
import "../../platform"
import "../../render"

@(private = "file") MSIZE :: [2]int{64, 64}
@(private = "file") MWHOLE :: draw.Rect{{0, 0}, {64, 64}}
@(private = "file") MBOX :: draw.Rect{{8, 8}, {24, 24}}
@(private = "file") MRED :: draw.Color{1, 0, 0, 1}
@(private = "file") MGREEN :: draw.Color{0, 1, 0, 1}
@(private = "file") MBLUE :: draw.Color{0, 0, 1, 1}
// How many frames a device gone may take to be noticed: the frame that finds out, the one that recovers, and some.
@(private = "file") LOSS_FRAMES_MAX :: 8
// Polls of a capture or a read-back, a few milliseconds apart.
@(private = "file") POLLS_MAX :: 400
@(private = "file") POLL_MS :: 5
// More failures than a test can ask for: disarmed by hand.
@(private = "file") FAULT_ALWAYS :: 1 << 20

@(private = "file")
mopen :: proc(f: ^Fx) -> bool {
	if !render.init_offscreen(&f.r, MSIZE, warp = true) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
mclose :: proc(f: ^Fx) {
	draw.destroy(&f.dc)
	render.destroy(&f.r)
}

@(private = "file")
mwindow :: proc() -> platform.Surface_Handles {
	hwnd := win.CreateWindowExW(0, win.L("Static"), win.L("machines"), win.WS_OVERLAPPEDWINDOW, 0, 0, 200, 200, nil, nil, nil, nil)
	return {backend = .Windows, hwnd = rawptr(hwnd)}
}

// A frame of one color over the whole target. `region`: a frame with a region of that rectangle.
@(private = "file")
mframe :: proc(f: ^Fx, color: draw.Color, region: Maybe(draw.Rect) = nil) {
	render.frame_begin(&f.r, {0, 0, 0, 1})
	draw.begin_frame(&f.dc, {f32(MSIZE.x), f32(MSIZE.y)})
	if b, has := region.?; has {
		draw.damage_begin(&f.dc)
		draw.damage(&f.dc, b)
	}
	draw.rect(&f.dc, MWHOLE, color)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
}

@(private = "file")
mcenter :: proc(pixels: []u8, size: [2]int, x := 32, y := 32) -> [3]int {
	if len(pixels) == 0 { return {-1, -1, -1} }
	o := (y * size.x + x) * 4
	return {int(pixels[o]), int(pixels[o + 1]), int(pixels[o + 2])}
}

// What the next frame of `color` shows, captured.
@(private = "file")
mcaptured :: proc(f: ^Fx, color: draw.Color, region: Maybe(draw.Rect) = nil, x := 32, y := 32) -> [3]int {
	render.capture_request(&f.r)
	mframe(f, color, region)
	for _ in 0 ..< POLLS_MAX {
		pixels, size, status := render.capture_poll(&f.r, context.temp_allocator)
		#partial switch status {
		case .Ready: return mcenter(pixels, size, x, y)
		case .Failed: return {-1, -1, -1}
		}
		win.Sleep(POLL_MS)
	}
	return {-1, -1, -1}
}

@(private = "file")
mclose_to :: proc(got, want: [3]int) -> bool {
	return abs(got[0] - want[0]) <= 2 && abs(got[1] - want[1]) <= 2 && abs(got[2] - want[2]) <= 2
}

// A Surface destroyed while it is the one in use: the renderer goes back to its own window first.
@(test)
a_surface_destroyed_in_use_gives_the_renderer_back :: proc(t: ^testing.T) {
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	s: render.Surface
	testing.expect(t, render.surface_init(&f.r, &s, mwindow(), MSIZE), "a surface")
	render.surface_use(&f.r, &s)
	render.surface_destroy(&f.r, &s)
	testing.expect(t, render.is_offscreen(&f.r), "the renderer holds its own offscreen target again")
	mframe(&f, MRED)
	testing.expectf(t, mclose_to(mcenter(render.read_pixels(&f.r, context.temp_allocator), MSIZE), {255, 0, 0}), "its frame is drawn")
}

// A read-back whose frame never ran its steps ends: it does not stay Pending for good.
@(test)
a_read_back_of_a_frame_that_did_not_run_says_so :: proc(t: ^testing.T) {
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	render.frame_begin(&f.r, {0, 0, 0, 1})
	draw.begin_frame(&f.dc, {f32(MSIZE.x), f32(MSIZE.y)})
	testing.expect(t, draw.offscreen_begin(&f.dc, {8, 8}), "an offscreen target")
	draw.rect(&f.dc, {{0, 0}, {8, 8}}, MRED)
	id := draw.offscreen_end(&f.dc)
	render.simulate_device_loss(&f.r)   // (the frame_submit of end_frame draws nothing)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	_, _, status := render.readback_poll(&f.r, id, context.temp_allocator)
	testing.expect_value(t, status, render.Capture_Status.Failed)
}

// The slots of a renderer go with it: a later renderer finds nothing, and the table holds nothing of the device.
@(test)
read_backs_end_with_their_renderer :: proc(t: ^testing.T) {
	a, b: Fx
	if !mopen(&a) { testing.fail_now(t, "no device (WARP)") }
	id := render.readback_new(&a.r)
	mclose(&a)
	if !mopen(&b) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&b)
	_, _, status := render.readback_poll(&b.r, id, context.temp_allocator)
	testing.expect_value(t, status, render.Capture_Status.Failed)
}

// An id of one renderer polled on another reads nothing of it, and its own renderer still has it.
@(test)
a_read_back_is_of_its_renderer :: proc(t: ^testing.T) {
	a, b: Fx
	if !mopen(&a) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&a)
	if !mopen(&b) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&b)
	render.frame_begin(&a.r, {0, 0, 0, 1})
	draw.begin_frame(&a.dc, {f32(MSIZE.x), f32(MSIZE.y)})
	testing.expect(t, draw.offscreen_begin(&a.dc, {8, 8}), "an offscreen target")
	draw.rect(&a.dc, {{0, 0}, {8, 8}}, MRED)
	id := draw.offscreen_end(&a.dc)
	draw.end_frame(&a.dc)
	render.frame_end(&a.r)
	_, _, other := render.readback_poll(&b.r, id, context.temp_allocator)
	testing.expect_value(t, other, render.Capture_Status.Failed)
	for _ in 0 ..< POLLS_MAX {
		_, _, status := render.readback_poll(&a.r, id, context.temp_allocator)
		if status == .Ready { return }
		testing.expect_value(t, status, render.Capture_Status.Pending)
		win.Sleep(POLL_MS)
	}
	testing.expect(t, false, "no read-back")
}

// wgpu-native reports a device gone with the reason Destroyed, whatever the cause: it is noticed, offscreen too, where no acquire can say so.
@(test)
a_device_gone_is_noticed :: proc(t: ^testing.T) {
	when !render.USE_WGPU { return }
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	mframe(&f, MRED)
	generation := f.r.device_generation
	wgpu.DeviceDestroy(f.r.wg.device)
	for _ in 0 ..< LOSS_FRAMES_MAX {
		mframe(&f, MBLUE)
		if f.r.device_generation != generation { break }
	}
	testing.expect(t, f.r.device_generation != generation, "the device was made again")
	mframe(&f, MBLUE)
	testing.expectf(t, mclose_to(mcenter(render.read_pixels(&f.r, context.temp_allocator), MSIZE), {0, 0, 255}), "and draws")
}

// The device the renderer releases itself says nothing: no loss comes out of a recovery or a release.
@(test)
a_recovery_is_not_a_loss :: proc(t: ^testing.T) {
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	mframe(&f, MRED)
	render.simulate_device_loss(&f.r)
	mframe(&f, MBLUE)
	generation := f.r.device_generation
	for _ in 0 ..< LOSS_FRAMES_MAX { mframe(&f, MBLUE) }
	testing.expect_value(t, f.r.device_generation, generation)
	testing.expect(t, !render.device_lost(&f.r), "no loss after the recovery")
}

// The clear of a frame begun on one window stays that window's when surface_use goes to another between frame_begin and frame_end.
@(test)
a_clear_stays_with_its_window :: proc(t: ^testing.T) {
	when !render.USE_WGPU { return }   // (Direct3D 11: have_clear is in Damage_State, which goes with the window)
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	s: render.Surface
	testing.expect(t, render.surface_init(&f.r, &s, mwindow(), MSIZE), "a surface")
	defer render.surface_destroy(&f.r, &s)
	render.frame_begin(&f.r, {1, 0, 0, 1})
	render.surface_use(&f.r, &s)
	testing.expect(t, !f.r.wg.clear_pending, "the other window has no clear of its own to do")
	render.surface_use(&f.r, &s)
	testing.expect(t, f.r.wg.clear_pending, "this one still has")
	render.frame_end(&f.r)
}

// An offscreen frame presents nothing: "first present" waits for one.
@(test)
no_present_is_no_first_present :: proc(t: ^testing.T) {
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	mframe(&f, MRED)
	testing.expect(t, !f.r.first_present_noted, "noted with nothing presented")
}

// The times of the old device say nothing of the new one: gpu_ms is not held back until the count of frames catches up.
@(test)
gpu_times_start_over_with_the_device :: proc(t: ^testing.T) {
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	LATE_FRAME :: 1000
	f.r.gpu_last_frame = LATE_FRAME
	render.simulate_device_loss(&f.r)
	mframe(&f, MRED)
	testing.expect_value(t, f.r.gpu_last_frame, 0)
}

// A chain made again keeps set_fixed_surface: buffers of that size, not of the window's.
@(test)
a_fixed_surface_survives_a_device_loss :: proc(t: ^testing.T) {
	when render.USE_WGPU { return }   // (Direct3D 11's: wgpu reconfigures on a resize)
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	FIXED :: [2]int{300, 200}
	s: render.Surface
	testing.expect(t, render.surface_init(&f.r, &s, mwindow(), MSIZE, transparent = true, fixed_size = FIXED), "a surface")
	render.surface_use(&f.r, &s)
	defer { render.surface_use(&f.r, &s); render.surface_destroy(&f.r, &s) }
	if !render.is_transparent(&f.r) { return }   // (no DirectComposition here)
	testing.expect_value(t, render.buffer_size(&f.r), FIXED)
	render.simulate_device_loss(&f.r)
	mframe(&f, MRED)
	testing.expect_value(t, render.buffer_size(&f.r), FIXED)
	render.resize(&f.r, {280, 180})
	testing.expect_value(t, render.buffer_size(&f.r), FIXED)
	testing.expect(t, mclose_to(mcaptured(&f, MRED), {255, 0, 0}), "a frame after it")
}

when render.RENDER_FAULTS {

// DirectComposition that failed once, during a recovery: the next window made tries again what the program asked.
@(test)
a_translucent_window_comes_back :: proc(t: ^testing.T) {
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	s: render.Surface
	testing.expect(t, render.surface_init(&f.r, &s, mwindow(), MSIZE, transparent = true), "a surface")
	render.surface_use(&f.r, &s)
	defer { render.surface_use(&f.r, &s); render.surface_destroy(&f.r, &s) }
	if !render.is_transparent(&f.r) { return }   // (no DirectComposition here)
	render.fault_arm(.Composition)
	render.simulate_device_loss(&f.r)
	mframe(&f, MRED)
	testing.expect_value(t, render.fault_fired(.Composition), 1)
	testing.expect(t, !render.is_transparent(&f.r), "opaque for now")
	render.simulate_device_loss(&f.r)
	mframe(&f, MRED)
	testing.expect(t, render.is_transparent(&f.r), "translucent again")
}

// The texture that clears a region refused: the region was drawn over what it had, the next frame does not start from that.
@(test)
a_region_not_cleared_is_not_kept :: proc(t: ^testing.T) {
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	render.set_partial_redraw(&f.r, true)
	mframe(&f, MRED, MWHOLE)
	render.fault_arm(.Damage_Clear)
	mframe(&f, MRED, MBOX)
	testing.expect_value(t, render.fault_fired(.Damage_Clear), 1)
	mframe(&f, MRED, MBOX)
	_, _, _, _, active := draw.damage_stats(&f.dc)
	testing.expect(t, !active, "the frame after it is whole")
}

// ResizeBuffers that says the device is gone is a loss like any other.
@(test)
a_resize_can_find_the_device_gone :: proc(t: ^testing.T) {
	when render.USE_WGPU { return }
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	s: render.Surface
	testing.expect(t, render.surface_init(&f.r, &s, mwindow(), MSIZE), "a surface")
	render.surface_use(&f.r, &s)
	defer { render.surface_use(&f.r, &s); render.surface_destroy(&f.r, &s) }
	render.set_resize_slack(&f.r, 0)
	render.fault_arm(.Resize_Buffers)
	render.resize(&f.r, {100, 90})
	testing.expect(t, render.device_lost(&f.r), "lost")
	testing.expectf(t, mclose_to(mcaptured(&f, MBLUE), {0, 0, 255}), "the next frame recovers")
}

// A size asked while the swap chain could not be made is the size of the one made later.
@(test)
a_resize_without_a_chain_is_kept :: proc(t: ^testing.T) {
	when render.USE_WGPU { return }
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	s: render.Surface
	testing.expect(t, render.surface_init(&f.r, &s, mwindow(), MSIZE), "a surface")
	render.surface_use(&f.r, &s)
	defer { render.surface_use(&f.r, &s); render.surface_destroy(&f.r, &s) }
	render.fault_arm(.Create_Swapchain, 0, FAULT_ALWAYS)
	render.simulate_device_loss(&f.r)
	mframe(&f, MRED)   // recovers, without a chain
	testing.expect(t, render.device_lost(&f.r), "half recovered")
	BIGGER :: [2]int{96, 80}
	render.resize(&f.r, BIGGER)
	testing.expect_value(t, f.r.size, BIGGER)
	render.fault_arm(.Create_Swapchain, 0, 0)
}

// No device to be had: frames, textures, resizes and read-backs go on doing nothing, and the next recovery that finds one has it all back.
@(test)
frames_go_on_without_a_device :: proc(t: ^testing.T) {
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	mframe(&f, MRED)
	render.fault_arm(.Create_Device, 0, FAULT_ALWAYS)
	when render.USE_WGPU { wgpu.DeviceDestroy(f.r.wg.device) }   // (really gone: what is called on it must answer nothing)
	render.simulate_device_loss(&f.r)
	generation := f.r.device_generation
	for _ in 0 ..< 3 {
		render.capture_request(&f.r)
		mframe(&f, MBLUE)
		render.capture_cancel(&f.r)
		render.update_texture_r8(&f.r, render.create_texture_r8(&f.r, 16), 0, 0, 1, 1, {0}, 1)
		pixels := []u8{255, 0, 0, 255}
		render.update_texture_rgba(&f.r, render.create_texture_rgba(&f.r, 1, 1), 0, 0, 1, 1, pixels)
		render.heap_alloc(&f.r, .Slots, 1)
		render.read_pixels(&f.r, context.temp_allocator)
	}
	testing.expect(t, render.device_lost(&f.r), "still lost")
	testing.expect_value(t, f.r.device_generation, generation)
	testing.expect(t, render.is_offscreen(&f.r), "an offscreen renderer stays one")
	BIGGER :: [2]int{96, 80}
	render.resize(&f.r, BIGGER)
	render.fault_arm(.Create_Device, 0, 0)
	render.frame_begin(&f.r, {0, 1, 0, 1})
	draw.begin_frame(&f.dc, {f32(BIGGER.x), f32(BIGGER.y)})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	testing.expect(t, !render.device_lost(&f.r), "the device is back")
	img := render.read_pixels(&f.r, context.temp_allocator)
	testing.expect_value(t, len(img), BIGGER.x * BIGGER.y * 4)
	testing.expectf(t, mclose_to(mcenter(img, BIGGER), {0, 255, 0}), "and draws: %v", mcenter(img, BIGGER))
}

// A window set aside that cannot be made again: the device is taken as lost, not left drawing into nothing.
@(test)
a_window_not_remade_is_tried_again :: proc(t: ^testing.T) {
	when render.USE_WGPU { return }   // (the swap chain's fault: a surface does not fail on demand)
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	s: render.Surface
	testing.expect(t, render.surface_init(&f.r, &s, mwindow(), MSIZE), "a surface")
	defer render.surface_destroy(&f.r, &s)
	render.simulate_device_loss(&f.r)
	mframe(&f, MRED)   // recovers: the surface is on the old device
	render.fault_arm(.Create_Swapchain)
	render.surface_use(&f.r, &s)
	testing.expect_value(t, render.fault_fired(.Create_Swapchain), 1)
	testing.expectf(t, mclose_to(mcaptured(&f, MBLUE), {0, 0, 255}), "the next frame recovers it")
	render.surface_use(&f.r, &s)
}

// A frame the surface had no texture for: what its region changed is not forgotten by the next one.
@(test)
a_frame_with_no_texture_keeps_its_damage :: proc(t: ^testing.T) {
	when !render.USE_WGPU { return }
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	s: render.Surface
	testing.expect(t, render.surface_init(&f.r, &s, mwindow(), MSIZE), "a surface")
	render.surface_use(&f.r, &s)
	defer { render.surface_use(&f.r, &s); render.surface_destroy(&f.r, &s) }
	render.set_partial_redraw(&f.r, true)
	mframe(&f, MRED, MWHOLE)
	mframe(&f, MRED, MBOX)
	render.fault_arm(.Acquire, 0, FAULT_ALWAYS)
	mframe(&f, MGREEN, MBOX)   // no texture: nothing of it is drawn
	render.fault_arm(.Acquire, 0, 0)
	got := mcaptured(&f, MGREEN, draw.Rect{{40, 40}, {48, 48}}, 16, 16)
	testing.expectf(t, mclose_to(got, {0, 255, 0}), "the rectangle of the frame skipped is drawn: %v", got)
}

// A capture asked of a frame the surface had no texture for ends: it does not stay Pending for good.
@(test)
a_capture_of_no_frame_says_so :: proc(t: ^testing.T) {
	when !render.USE_WGPU { return }
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	s: render.Surface
	testing.expect(t, render.surface_init(&f.r, &s, mwindow(), MSIZE), "a surface")
	render.surface_use(&f.r, &s)
	defer { render.surface_use(&f.r, &s); render.surface_destroy(&f.r, &s) }
	render.fault_arm(.Acquire, 0, FAULT_ALWAYS)
	render.capture_request(&f.r)
	mframe(&f, MRED)
	render.fault_arm(.Acquire, 0, 0)
	_, _, status := render.capture_poll(&f.r, context.temp_allocator)
	testing.expect_value(t, status, render.Capture_Status.Failed)
}

// A whole frame that stopped halfway leaves nothing a region can start from.
@(test)
an_aborted_frame_is_not_kept :: proc(t: ^testing.T) {
	when render.USE_WGPU { return }   // (the fault of a buffer not mapped)
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	render.set_partial_redraw(&f.r, true)
	render.fault_arm(.Map, 0, FAULT_ALWAYS)
	mframe(&f, MRED, MWHOLE)
	render.fault_arm(.Map, 0, 0)
	mframe(&f, MRED, MBOX)
	_, _, _, _, active := draw.damage_stats(&f.dc)
	testing.expect(t, !active, "the frame after it is whole")
	testing.expectf(t, mclose_to(mcenter(render.read_pixels(&f.r, context.temp_allocator), MSIZE), {255, 0, 0}), "and shows everything")
}

// A texture that could not be made again: its handle draws nothing, and destroying it frees the slot.
@(test)
a_texture_not_remade_is_safe :: proc(t: ^testing.T) {
	f: Fx
	if !mopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer mclose(&f)
	tex := render.create_texture_rgba(&f.r, 16, 16)   // never written, with its mips to make
	testing.expect(t, tex != 0, "a texture")
	frame_with :: proc(f: ^Fx, tex: render.Texture) {
		render.frame_begin(&f.r, {0, 0, 0, 1})
		draw.begin_frame(&f.dc, {f32(MSIZE.x), f32(MSIZE.y)})
		draw.rect(&f.dc, MWHOLE, MRED)
		draw.image(&f.dc, tex, MBOX)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
	}
	render.fault_arm(.Recreate_Texture, 0, FAULT_ALWAYS)
	render.simulate_device_loss(&f.r)
	frame_with(&f, tex)
	render.fault_arm(.Recreate_Texture, 0, 0)
	testing.expect(t, !render.device_lost(&f.r), "the device is back")
	testing.expect_value(t, render.texture_size(&f.r, tex), [2]int{})
	frame_with(&f, tex)
	testing.expect(t, mclose_to(mcenter(render.read_pixels(&f.r, context.temp_allocator), MSIZE), {255, 0, 0}), "the frame is drawn")
	render.destroy_texture(&f.r, tex)
	again := render.create_texture_rgba(&f.r, 16, 16)
	testing.expect_value(t, again, tex)
}

}   // when render.RENDER_FAULTS
