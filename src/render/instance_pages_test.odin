package render

import "core:testing"

@(private = "file") PAGES_TEST_SIZE :: [2]int{32, 16}
@(private = "file") PAGES_TEST_PAGE :: 100   // instances a page holds: the frame's 512 take six pages
@(private = "file") PAGES_TEST_SPLIT :: 150  // the first batch ends inside the second page
@(private = "file") BYTE_MAX :: 255

// The colour of pixel `i`: one of seven, each channel 0 or 1 (the same bytes in every blend space).
@(private = "file")
pixel_color :: proc(i: int) -> [3]u8 {
	c := i % 7 + 1
	return {c & 1 != 0 ? BYTE_MAX : 0, c & 2 != 0 ? BYTE_MAX : 0, c & 4 != 0 ? BYTE_MAX : 0}
}

// A frame with more instances than one buffer holds is drawn from several pages, each draw cut where a page ends: every
// pixel is the rectangle drawn for it, the last page's too. (wgpu-native ended the process at the submit of a frame
// whose one instance buffer passed the device's largest buffer.)
@(test)
a_frame_of_more_instances_than_one_buffer_holds_draws_them_all :: proc(t: ^testing.T) {
	r: Renderer
	if !testing.expect(t, init_offscreen(&r, PAGES_TEST_SIZE, warp = true, space = .Srgb), "init_offscreen") { return }
	defer destroy(&r)
	set_instance_page(&r, PAGES_TEST_PAGE)

	w, h := PAGES_TEST_SIZE.x, PAGES_TEST_SIZE.y
	insts := make([]Rect_Inst, w * h)
	defer delete(insts)
	for &inst, i in insts {
		x, y := f32(i % w), f32(i / w)
		c := pixel_color(i)
		col := [4]f32{f32(c.r) / BYTE_MAX, f32(c.g) / BYTE_MAX, f32(c.b) / BYTE_MAX, 1}
		inst = {dst = {x, y, x + 1, y + 1}, colors = {col, col, col, col}, soft = 1, use_tex = KIND_SHAPE, tex_size = 1}
	}
	whole := [4]f32{0, 0, f32(w), f32(h)}
	batches := []Batch{{clip = whole, first = 0, count = PAGES_TEST_SPLIT}, {clip = whole, first = PAGES_TEST_SPLIT, count = len(insts) - PAGES_TEST_SPLIT}}
	xforms := []Xform_Data{{}}
	clips := []Clip_Data{{}}

	// twice: the second frame draws into the pages the first one made
	for _ in 0 ..< 2 {
		frame_begin(&r, {0, 0, 0, 1})
		frame_submit(&r, {insts = insts, batches = batches, xforms = xforms, clips = clips})
		frame_end(&r)
		px := read_pixels(&r)
		defer delete(px)
		if !testing.expect_value(t, len(px), w * h * 4) { return }
		wrong, first_wrong := 0, -1
		for i in 0 ..< w * h {
			c := pixel_color(i)
			if px[4 * i] != c.r || px[4 * i + 1] != c.g || px[4 * i + 2] != c.b {
				if first_wrong < 0 { first_wrong = i }
				wrong += 1
			}
		}
		testing.expectf(t, wrong == 0, "%d pixels are not their rectangle's colour, the first at %d", wrong, first_wrong)
	}
	when USE_WGPU { testing.expect_value(t, len(r.wg.inst), 6) } else { testing.expect_value(t, len(r.inst_pages), 6) }
}

// A draw's run of instances cut at the pages.
@(test)
page_run_cuts_a_draw_where_its_pages_end :: proc(t: ^testing.T) {
	p, at, n := page_run(150, 362, 100)
	testing.expect_value(t, [3]int{p, at, n}, [3]int{1, 50, 50})
	p, at, n = page_run(500, 12, 100)
	testing.expect_value(t, [3]int{p, at, n}, [3]int{5, 0, 12})
	testing.expect_value(t, pages_for(512, 100), 6)
	testing.expect_value(t, pages_for(0, 100), 0)
	// the device's largest buffer of WebGPU's defaults (256 MiB): the frame that ended plume held 2.87 million instances
	testing.expect_value(t, elements_within(256 << 20, size_of(Rect_Inst)), 1_864_135)
	testing.expect_value(t, pages_for(413_634_096 / size_of(Rect_Inst), elements_within(256 << 20, size_of(Rect_Inst))), 2)
}
