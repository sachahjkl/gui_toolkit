// Partial redraw (draw.damage_begin) on an offscreen renderer (WARP): a frame of a region only changes the region, and what it
// shows there is what a whole frame would show. Both backends: -define:TOOLKIT_RENDER=wgpu.
package layers_test

import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

@(private = "file") WHITE :: [4]f32{1, 1, 1, 1}
@(private = "file") RED :: draw.Color{1, 0, 0, 1}
@(private = "file") GREEN :: draw.Color{0, 1, 0, 1}
@(private = "file") BLUE :: draw.Color{0, 0, 1, 1}
@(private = "file") WHOLE :: draw.Rect{{0, 0}, {f32(SIZE.x), f32(SIZE.y)}}
@(private = "file") BOX :: draw.Rect{{8, 8}, {24, 24}}
@(private = "file") INSIDE :: [2]int{16, 16}
@(private = "file") OUTSIDE :: [2]int{40, 40}

@(private = "file")
Dfx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file")
dopen :: proc(f: ^Dfx, space := render.Blend_Space.Linear, partial := true) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = space) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	render.set_partial_redraw(&f.r, partial)
	return true
}

@(private = "file")
dclose :: proc(f: ^Dfx) {
	draw.destroy(&f.dc)
	render.destroy(&f.r)
}

// How a frame says what changed.
@(private = "file")
Damage :: union { draw.Rect, No_Marks }
@(private = "file")
No_Marks :: struct {}   // damage_begin and nothing marked

// One frame in the documented order: `damage` nil is a frame without damage_begin.
@(private = "file")
dframe :: proc(f: ^Dfx, damage: Damage, body: proc(dc: ^draw.Context), clear := WHITE) -> []u8 {
	render.frame_begin(&f.r, clear)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	switch d in damage {
	case draw.Rect:
		draw.damage_begin(&f.dc)
		draw.damage(&f.dc, d)
	case No_Marks:
		draw.damage_begin(&f.dc)
	}
	if body != nil { body(&f.dc) }
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
at :: proc(img: []u8, p: [2]int) -> [4]u8 {
	o := (p.y * SIZE.x + p.x) * 4
	return {img[o], img[o + 1], img[o + 2], img[o + 3]}
}

@(private = "file") all_red :: proc(dc: ^draw.Context) { draw.rect(dc, WHOLE, RED) }
@(private = "file") all_green :: proc(dc: ^draw.Context) { draw.rect(dc, WHOLE, GREEN) }
@(private = "file") all_blue :: proc(dc: ^draw.Context) { draw.rect(dc, WHOLE, BLUE) }
@(private = "file") box_black :: proc(dc: ^draw.Context) { draw.rect(dc, BOX, {0, 0, 0, 1}) }
@(private = "file") far_away :: proc(dc: ^draw.Context) { draw.rect(dc, {{50, 50}, {60, 60}}, RED) }
@(private = "file") box_half :: proc(dc: ^draw.Context) { draw.rect(dc, BOX, {1, 0, 0, 0.5}) }

// The first frame of a region composes everything; the next one changes only what it marks.
@(test)
a_region_changes_only_what_it_marks :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Dfx
		if !dopen(&f, space) { testing.fail_now(t, "no device (WARP)") }
		defer dclose(&f)
		img := dframe(&f, BOX, all_red)
		testing.expect_value(t, at(img, OUTSIDE), [4]u8{255, 0, 0, 255})
		img = dframe(&f, BOX, all_green)
		testing.expect_value(t, at(img, INSIDE), [4]u8{0, 255, 0, 255})
		testing.expectf(t, at(img, OUTSIDE) == {255, 0, 0, 255}, "%v: outside the region the last frame stays, got %v", space, at(img, OUTSIDE))
		added, kept, px_region, px_frame, active := draw.damage_stats(&f.dc)
		testing.expect_value(t, added, 1)
		testing.expect_value(t, kept, 1)
		testing.expect_value(t, px_region, 16 * 16)
		testing.expect_value(t, px_frame, SIZE.x * SIZE.y)
		testing.expect(t, active, "the region is in effect")
	}
}

// (begin_frame before frame_begin, as many programs have it.)
@(test)
a_region_does_not_care_which_begin_comes_first :: proc(t: ^testing.T) {
	f: Dfx
	if !dopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer dclose(&f)
	dframe(&f, BOX, all_red)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	draw.damage_begin(&f.dc)
	draw.damage(&f.dc, BOX)
	render.frame_begin(&f.r, WHITE)
	all_green(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	img := render.read_pixels(&f.r, context.temp_allocator)
	testing.expect_value(t, at(img, OUTSIDE), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(img, INSIDE), [4]u8{0, 255, 0, 255})
}

// Partial redraw on, a frame without damage_begin: the same bytes as with it off.
@(test)
a_frame_without_a_region_is_a_whole_frame :: proc(t: ^testing.T) {
	on, off: Dfx
	if !dopen(&on) || !dopen(&off, partial = false) { testing.fail_now(t, "no device (WARP)") }
	defer { dclose(&on); dclose(&off) }
	a := dframe(&on, nil, box_half)
	b := dframe(&off, nil, box_half)
	testing.expect(t, string(a) == string(b), "the same bytes")
	_, _, _, _, active := draw.damage_stats(&on.dc)
	testing.expect(t, !active, "no region")
	// and a frame with nothing submitted clears
	render.frame_begin(&on.r, {0, 0, 1, 1})
	render.frame_end(&on.r)
	testing.expect_value(t, at(render.read_pixels(&on.r, context.temp_allocator), OUTSIDE), [4]u8{0, 0, 255, 255})
}

// What a frame without a region drew is what the next region starts from.
@(test)
a_region_after_a_whole_frame_starts_from_it :: proc(t: ^testing.T) {
	f: Dfx
	if !dopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer dclose(&f)
	dframe(&f, BOX, all_red)
	dframe(&f, nil, all_blue)
	img := dframe(&f, BOX, all_green)
	testing.expectf(t, at(img, OUTSIDE) != [4]u8{255, 0, 0, 255}, "a stale frame shows outside the region: %v", at(img, OUTSIDE))
	testing.expect_value(t, at(img, INSIDE), [4]u8{0, 255, 0, 255})
	// the same after a frame with nothing submitted
	dframe(&f, BOX, all_red)
	render.frame_begin(&f.r, {0, 0, 1, 1})
	render.frame_end(&f.r)
	img = dframe(&f, BOX, all_green)
	testing.expectf(t, at(img, OUTSIDE) != [4]u8{255, 0, 0, 255}, "a stale frame shows outside the region: %v", at(img, OUTSIDE))
}

// The region starts from the clear color, as a whole frame does: what was there and is drawn no more goes away.
@(test)
a_region_is_cleared_first :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Dfx
		if !dopen(&f, space) { testing.fail_now(t, "no device (WARP)") }
		defer dclose(&f)
		dframe(&f, BOX, box_black)
		img := dframe(&f, BOX, far_away)
		testing.expectf(t, at(img, INSIDE) == {255, 255, 255, 255}, "%v: something else drawn: %v", space, at(img, INSIDE))
		dframe(&f, BOX, box_black)
		img = dframe(&f, BOX, nil)
		testing.expectf(t, at(img, INSIDE) == {255, 255, 255, 255}, "%v: nothing drawn: %v", space, at(img, INSIDE))
	}
}

// Translucent drawing redrawn in a region does not pile up on what the last frame left, and the clear color is the whole
// frame's to the byte, opaque or not.
@(test)
a_region_shows_what_a_whole_frame_shows :: proc(t: ^testing.T) {
	CLEARS := [?][4]f32{{0.2, 0.3, 0.4, 1}, {0.2, 0.1, 0.05, 0.5}, {0, 0, 0, 0}}
	for space in render.Blend_Space {
		for clear in CLEARS {
			f, whole: Dfx
			if !dopen(&f, space) || !dopen(&whole, space, false) { testing.fail_now(t, "no device (WARP)") }
			defer { dclose(&f); dclose(&whole) }
			dframe(&f, BOX, box_half, clear)
			dframe(&f, BOX, box_half, clear)
			got := dframe(&f, BOX, box_half, clear)
			want := dframe(&whole, nil, box_half, clear)
			testing.expectf(t, string(got) == string(want), "%v clear %v: at the box %v, whole frame %v", space, clear, at(got, INSIDE), at(want, INSIDE))
		}
	}
}

// Nothing marked: nothing changes, whatever is drawn.
@(test)
a_region_of_nothing_changes_nothing :: proc(t: ^testing.T) {
	f: Dfx
	if !dopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer dclose(&f)
	dframe(&f, BOX, all_red)
	img := dframe(&f, No_Marks{}, all_green)
	testing.expect_value(t, at(img, INSIDE), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(img, OUTSIDE), [4]u8{255, 0, 0, 255})
}

// A scrolled view marks only the band that came in: the pixels that moved must not stay where they were.
@(test)
a_scroll_moves_what_it_says :: proc(t: ^testing.T) {
	f, whole: Dfx
	if !dopen(&f) || !dopen(&whole, partial = false) { testing.fail_now(t, "no device (WARP)") }
	defer { dclose(&f); dclose(&whole) }
	stripe_at_8 :: proc(dc: ^draw.Context) { draw.rect(dc, {{0, 8}, {64, 16}}, RED) }
	stripe_at_16 :: proc(dc: ^draw.Context) { draw.rect(dc, {{0, 16}, {64, 24}}, RED) }
	dframe(&f, BOX, stripe_at_8)
	render.frame_begin(&f.r, WHITE)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	draw.damage_begin(&f.dc)
	draw.damage_scrolled(&f.dc, {{0, 0}, {64, 64}}, {0, 8})
	stripe_at_16(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	got := render.read_pixels(&f.r, context.temp_allocator)
	want := dframe(&whole, nil, stripe_at_16)
	testing.expect(t, string(got) == string(want), "as a whole frame")
}

// The check of render.damage.verify: says nothing of a right region, finds what a region left out.
@(test)
verify_finds_a_missing_rectangle :: proc(t: ^testing.T) {
	f: Dfx
	if !dopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer dclose(&f)
	render.set_damage_verify(&f.r, true)
	dframe(&f, BOX, box_black)
	dframe(&f, BOX, box_black)
	testing.expect_value(t, render.damage_verify_differences(&f.r), 0)
	dframe(&f, BOX, all_green)   // green everywhere, but only the box was marked
	testing.expect_value(t, render.damage_verify_differences(&f.r), 1)
}

// The objects of partial redraw belong to the device: a device lost takes them (verify's reference too), and the next region
// starts over from a whole frame.
@(test)
a_region_survives_a_device_loss :: proc(t: ^testing.T) {
	f: Dfx
	if !dopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer dclose(&f)
	render.set_damage_verify(&f.r, true)
	dframe(&f, BOX, box_black)
	dframe(&f, BOX, box_black)
	render.simulate_device_loss(&f.r)
	img := dframe(&f, BOX, all_red)
	testing.expect_value(t, at(img, OUTSIDE), [4]u8{255, 0, 0, 255})
	img = dframe(&f, BOX, all_green)
	testing.expect_value(t, at(img, OUTSIDE), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(img, INSIDE), [4]u8{0, 255, 0, 255})
}

// A size change remakes what the region starts from: the frame after it is whole.
@(test)
a_region_after_a_resize_is_whole :: proc(t: ^testing.T) {
	f: Dfx
	if !dopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer dclose(&f)
	dframe(&f, BOX, all_red)
	testing.expect(t, render.resize_offscreen(&f.r, {SIZE.x, SIZE.y + 8}))
	render.frame_begin(&f.r, WHITE)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y + 8)})
	draw.damage_begin(&f.dc)
	draw.damage(&f.dc, BOX)
	all_blue(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	img := render.read_pixels(&f.r, context.temp_allocator)
	testing.expect_value(t, at(img, OUTSIDE), [4]u8{0, 0, 255, 255})
}

// A batch that reaches across two far rectangles draws in them and not in what lies between: translucent text would thicken there.
@(test)
a_batch_across_two_rectangles_stays_in_them :: proc(t: ^testing.T) {
	f, whole: Dfx
	if !dopen(&f) || !dopen(&whole, partial = false) { testing.fail_now(t, "no device (WARP)") }
	defer { dclose(&f); dclose(&whole) }
	half_all :: proc(dc: ^draw.Context) { draw.rect(dc, WHOLE, {1, 0, 0, 0.5}) }
	dframe(&f, BOX, half_all)
	render.frame_begin(&f.r, WHITE)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	draw.damage_begin(&f.dc)
	draw.damage(&f.dc, {{0, 0}, {4, 4}})
	draw.damage(&f.dc, {{60, 60}, {64, 64}})
	half_all(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	got := render.read_pixels(&f.r, context.temp_allocator)
	want := dframe(&whole, nil, half_all)
	testing.expect(t, string(got) == string(want), "the same bytes as a whole frame")
	_, kept, _, _, active := draw.damage_stats(&f.dc)
	testing.expect(t, active && kept == 2, "two rectangles")
}

// More rectangles than a region keeps: they are fused and never overlap, or a translucent batch would be drawn twice where they do.
@(test)
a_region_full_of_rectangles_draws_each_pixel_once :: proc(t: ^testing.T) {
	f, whole: Dfx
	if !dopen(&f) || !dopen(&whole, partial = false) { testing.fail_now(t, "no device (WARP)") }
	defer { dclose(&f); dclose(&whole) }
	half_all :: proc(dc: ^draw.Context) { draw.rect(dc, WHOLE, {1, 0, 0, 0.5}) }
	dframe(&f, BOX, half_all)
	render.frame_begin(&f.r, WHITE)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	draw.damage_begin(&f.dc)
	for y in 0 ..< 6 {
		for x in 0 ..< 6 {
			px0, py0 := f32(x * 10 + (y % 2) * 3), f32(y * 10)
			draw.damage(&f.dc, {{px0, py0}, {px0 + 2, py0 + 2}})
		}
	}
	half_all(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	got := render.read_pixels(&f.r, context.temp_allocator)
	want := dframe(&whole, nil, half_all)
	testing.expect(t, string(got) == string(want), "the same bytes as a whole frame")
}

// A backdrop reads the frame while it is drawn: what lay on top of it in the last frame, outside the region, must not get in.
@(test)
a_frame_that_reads_itself_is_drawn_whole :: proc(t: ^testing.T) {
	f, whole: Dfx
	if !dopen(&f) || !dopen(&whole, partial = false) { testing.fail_now(t, "no device (WARP)") }
	defer { dclose(&f); dclose(&whole) }
	scene :: proc(dc: ^draw.Context) {
		draw.rect(dc, WHOLE, {0, 0, 1, 1})
		blur := [1]draw.Filter{draw.filter_blur(4)}
		draw.backdrop(dc, {{10, 10}, {40, 40}}, {}, blur[:])
		draw.rect(dc, {{20, 20}, {44, 44}}, {0, 1, 0, 1})   // on top of what the backdrop read
	}
	dframe(&f, BOX, scene)
	got := dframe(&f, draw.Rect{{10, 10}, {14, 14}}, scene)
	want := dframe(&whole, nil, scene)
	testing.expect(t, string(got) == string(want), "the same bytes as a whole frame")
	_, _, _, _, active := draw.damage_stats(&f.dc)
	testing.expect(t, !active, "no region in effect: it was whole")
}

// A context destroyed can be made again in the same place: its lists do not point at what it freed.
@(test)
a_context_can_be_made_again_in_place :: proc(t: ^testing.T) {
	f: Dfx
	if !dopen(&f) { testing.fail_now(t, "no device (WARP)") }
	defer dclose(&f)
	dframe(&f, nil, all_red)
	draw.destroy(&f.dc)
	testing.expect(t, f.dc.batches == nil && f.dc.insts == nil, "nothing freed is left in it")
	draw.init(&f.dc, &f.r, &f.fonts)
	testing.expect_value(t, at(dframe(&f, nil, all_green), OUTSIDE), [4]u8{0, 255, 0, 255})
}
