package render

import "core:sync"
import "core:testing"

_ :: sync   // (WebGPU's tests only)

@(private = "file") LOST_TEST_SIZE :: [2]int{32, 16}
@(private = "file") BYTE_MAX :: 255

// A frame whose submit is skipped (an error since the last submit: wgpu_submit) leaves the kept target behind: the next
// frame is drawn whole, not composed over what the lost frame never wrote. (The kept target was marked ready by the
// lost frame's own commands, and the next partial frame showed the frame before it outside its region.)
@(test)
a_frame_after_a_lost_one_is_drawn_whole :: proc(t: ^testing.T) {
	when USE_WGPU {
		r: Renderer
		if !testing.expect(t, init_offscreen(&r, LOST_TEST_SIZE, warp = true, space = .Srgb), "init_offscreen") { return }
		defer destroy(&r)
		set_partial_redraw(&r, true)
		w, h := f32(LOST_TEST_SIZE.x), f32(LOST_TEST_SIZE.y)
		whole := [4]f32{0, 0, w, h}
		inst :: proc(dst: [4]f32, c: [4]f32) -> Rect_Inst {
			return {dst = dst, colors = {c, c, c, c}, soft = 1, use_tex = KIND_SHAPE, tex_size = 1}
		}
		red, green, blue := [4]f32{1, 0, 0, 1}, [4]f32{0, 1, 0, 1}, [4]f32{0, 0, 1, 1}
		xforms := []Xform_Data{{}}
		clips := []Clip_Data{{}}
		draw :: proc(r: ^Renderer, insts: []Rect_Inst, clip: [4]f32, xforms: []Xform_Data, clips: []Clip_Data) {
			batches := []Batch{{clip = clip, first = 0, count = len(insts)}}
			frame_submit(r, {insts = insts, batches = batches, xforms = xforms, clips = clips})
		}

		// a frame drawn whole: red
		frame_begin(&r, {0, 0, 0, 1})
		damage_begin(&r)
		damage_add(&r, {0, 0, i32(w), i32(h)})
		one := []Rect_Inst{inst(whole, red)}
		draw(&r, one, whole, xforms, clips)
		frame_end(&r)

		// the left half turns green, and the frame is lost
		frame_begin(&r, {0, 0, 0, 1})
		damage_begin(&r)
		damage_add(&r, {0, 0, i32(w / 2), i32(h)})
		two := []Rect_Inst{inst(whole, red), inst({0, 0, w / 2, h}, green)}
		sync.atomic_add(&r.wg.shared.errors, 1)
		draw(&r, two, whole, xforms, clips)
		frame_end(&r)

		// a corner turns blue: the left half is green all the same
		frame_begin(&r, {0, 0, 0, 1})
		damage_begin(&r)
		damage_add(&r, {i32(w) - 2, 0, i32(w), 2})
		three := []Rect_Inst{inst(whole, red), inst({0, 0, w / 2, h}, green), inst({w - 2, 0, w, 2}, blue)}
		draw(&r, three, whole, xforms, clips)
		frame_end(&r)

		px := read_pixels(&r)
		defer delete(px)
		if !testing.expect_value(t, len(px), LOST_TEST_SIZE.x * LOST_TEST_SIZE.y * 4) { return }
		at :: proc(px: []u8, x, y: int) -> [3]u8 { i := 4 * (y * LOST_TEST_SIZE.x + x); return {px[i], px[i + 1], px[i + 2]} }
		testing.expect_value(t, at(px, 4, 8), [3]u8{0, BYTE_MAX, 0})
		testing.expect_value(t, at(px, 20, 8), [3]u8{BYTE_MAX, 0, 0})
		testing.expect_value(t, at(px, LOST_TEST_SIZE.x - 1, 0), [3]u8{0, 0, BYTE_MAX})
	}
}

// A heap grown while a submit would be skipped (an error since the last one): the copy of its pictures is not made, so
// the heap stays as it was and refuses the picture this time; the next grow, the error said, copies them.
@(test)
a_heap_whose_copy_is_skipped_keeps_its_pictures :: proc(t: ^testing.T) {
	when USE_WGPU {
		r: Renderer
		if !testing.expect(t, init_offscreen(&r, LOST_TEST_SIZE, warp = true, space = .Srgb), "init_offscreen") { return }
		defer destroy(&r)
		_, made := heap_alloc(&r, .Insts, 1)
		if !testing.expect(t, made, "a first picture") { return }
		h := &r.heaps[.Insts]
		was, cap := h.wbuf, h.cap
		sync.atomic_add(&r.wg.shared.errors, 1)
		_, grew := heap_alloc(&r, .Insts, cap)
		testing.expect(t, !grew, "the grow whose copy is skipped refuses the picture")
		testing.expect(t, h.wbuf == was && h.cap == cap, "the heap is the one that holds the first picture")
		_, grew = heap_alloc(&r, .Insts, cap)
		testing.expect(t, grew && h.cap > cap, "the next grow copies it")
	}
}

// Errors said while the device was gone (calls on a lost device) are that device's: the device recovered draws its first
// frame, not skipped for them. (Direct3D 12 on WARP: the frame after the recovery read black.)
@(test)
a_recovered_device_draws_its_first_frame :: proc(t: ^testing.T) {
	when USE_WGPU {
		r: Renderer
		if !testing.expect(t, init_offscreen(&r, LOST_TEST_SIZE, warp = true, space = .Srgb), "init_offscreen") { return }
		defer destroy(&r)
		frame_begin(&r, {1, 0, 0, 1})
		frame_end(&r)
		simulate_device_loss(&r)
		sync.atomic_add(&r.wg.shared.errors, 3)   // (what the calls on the lost device said)
		frame_begin(&r, {0, 1, 0, 1})
		frame_end(&r)
		testing.expect(t, !r.lost, "recovered")
		px := read_pixels(&r)
		defer delete(px)
		if !testing.expect_value(t, len(px), LOST_TEST_SIZE.x * LOST_TEST_SIZE.y * 4) { return }
		testing.expect_value(t, [3]u8{px[0], px[1], px[2]}, [3]u8{0, BYTE_MAX, 0})
	}
}
