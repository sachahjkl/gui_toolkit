// What the system does not fail on demand, forced (render/faults.odin):
//   odin test tests/lifecycle -vet -define:TOOLKIT_RENDER_FAULTS=true
//   odin test tests/lifecycle -vet -define:TOOLKIT_RENDER_FAULTS=true -define:TOOLKIT_RENDER=wgpu
package lifecycle_test

@(require) import "core:testing"
@(require) import win "core:sys/windows"
@(require) import "../../draw"
@(require) import "../../font"
@(require) import "../../render"

when render.RENDER_FAULTS {

@(private = "file") FSIZE :: [2]int{64, 64}

@(private = "file")
Ffx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file")
fopen :: proc(f: ^Ffx) -> bool {
	if !render.init_offscreen(&f.r, FSIZE, warp = true) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
fclose :: proc(f: ^Ffx) {
	draw.destroy(&f.dc)
	render.destroy(&f.r)
}

// A frame that uses every table: instances, a transform, a clip shape, a gradient, a filter pass.
@(private = "file")
rich_frame :: proc(f: ^Ffx) -> []u8 {
	WHOLE :: draw.Rect{{0, 0}, {f32(FSIZE.x), f32(FSIZE.y)}}
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.begin_frame(&f.dc, {f32(FSIZE.x), f32(FSIZE.y)})
	draw.rect(&f.dc, WHOLE, {1, 0, 0, 1})
	draw.push_clip_ellipse(&f.dc, {4, 4}, {3, 3})
	draw.push_transform(&f.dc, draw.affine_rotate(0.1))
	draw.rect(&f.dc, {{0, 0}, {2, 2}}, {0, 1, 0, 1})
	draw.pop_transform(&f.dc)
	draw.pop_clip(&f.dc)
	stops := [2]draw.Gradient_Stop{{pos = 0, color = {0, 0, 1, 1}}, {pos = 1, color = {0, 0, 1, 1}}}
	draw.gradient(&f.dc, {{0, 56}, {8, 64}}, draw.Gradient{kind = .Linear, start = {0, 56}, end = {8, 64}, stops = stops[:]})
	blur := [1]draw.Filter{draw.filter_blur(1)}
	draw.push_effects(&f.dc, {{56, 0}, {64, 8}}, draw.Layer_Effects{alpha = 1, filters = blur[:]})
	draw.rect(&f.dc, {{56, 0}, {64, 8}}, {0, 1, 0, 1})
	draw.pop_layer(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
red_in_the_middle :: proc(img: []u8) -> bool {
	o := (32 * FSIZE.x + 32) * 4
	return len(img) > 0 && img[o] == 255 && img[o + 1] == 0 && img[o + 2] == 0
}

when !render.USE_WGPU {

// Each call of a kind that a frame makes, refused in turn: the frame ends, and the next one draws.
@(private = "file")
each_call_fails :: proc(t: ^testing.T, kind: render.Fault, least: int) {
	calls := 0
	for skip in 0 ..< 32 {
		f: Ffx
		if !fopen(&f) { testing.fail_now(t, "no device (WARP)") }
		defer fclose(&f)
		render.fault_arm(kind, skip)
		rich_frame(&f)
		fired := render.fault_fired(kind)
		render.fault_arm(kind, 0, 0)
		testing.expectf(t, red_in_the_middle(rich_frame(&f)), "%v, call %d: the next frame", kind, skip)
		if fired == 0 { break }
		calls += 1
	}
	testing.expectf(t, calls >= least, "%v: %d calls failed, of at least %d", kind, calls, least)
}

@(test)
a_buffer_refused_ends_the_frame :: proc(t: ^testing.T) { each_call_fails(t, .Create_Buffer, 5) }

@(test)
a_buffer_not_mapped_ends_the_frame :: proc(t: ^testing.T) { each_call_fails(t, .Map, 6) }

}   // when !render.USE_WGPU

when render.USE_WGPU {

@(private = "file")
fplain_frame :: proc(f: ^Ffx) {
	render.frame_begin(&f.r, {1, 0, 0, 1})
	draw.begin_frame(&f.dc, {f32(FSIZE.x), f32(FSIZE.y)})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
}

@(private = "file")
capture_result :: proc(f: ^Ffx) -> render.Capture_Status {
	for _ in 0 ..< 400 {
		_, _, status := render.capture_poll(&f.r, context.temp_allocator)
		if status != .Pending { return status }
		win.Sleep(5)
	}
	return .Pending
}

// The map of a capture fails: the capture says so, and the next one is good.
@(test)
a_capture_map_that_fails_says_so :: proc(t: ^testing.T) {
	f: Ffx
	if !fopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer fclose(&f)
	render.fault_arm(.Capture_Map)
	render.capture_request(&f.r)
	fplain_frame(&f)
	testing.expect_value(t, capture_result(&f), render.Capture_Status.Failed)
	testing.expect_value(t, render.fault_fired(.Capture_Map), 1)
	render.capture_request(&f.r)
	fplain_frame(&f)
	testing.expect_value(t, capture_result(&f), render.Capture_Status.Ready)
}

// The callback of a map cancelled comes while the next capture is on its way: it says nothing about that one.
@(test)
a_late_callback_leaves_the_next_capture :: proc(t: ^testing.T) {
	f: Ffx
	if !fopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer fclose(&f)
	render.fault_arm(.Capture_Map_Late)
	render.capture_request(&f.r)
	fplain_frame(&f)
	_, _, first := render.capture_poll(&f.r, context.temp_allocator)
	testing.expect_value(t, first, render.Capture_Status.Pending)
	testing.expect_value(t, render.fault_fired(.Capture_Map_Late), 1)
	render.capture_cancel(&f.r)
	render.capture_request(&f.r)
	fplain_frame(&f)
	_, _, second := render.capture_poll(&f.r, context.temp_allocator)   // (an offscreen frame waits for the device: it may be ready at once)
	render.fault_capture_map_answer()
	if second == .Pending { second = capture_result(&f) }
	testing.expect_value(t, second, render.Capture_Status.Ready)
}

}   // when render.USE_WGPU

}   // when render.RENDER_FAULTS
