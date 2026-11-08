package render

// The steps of a frame in the order they were recorded, the same on both backends: which batches are skipped, when the target
// changes, how partial redraw cuts a batch, its scissor, and how a batch with Slug text is split between the two pipelines. What
// each step does on the GPU is the backend's: the walk_* procedures of frame.odin (Direct3D 11) and wgpu_frame.odin (WebGPU),
// chosen when the program is compiled like those of api.odin. Their Frame_Submit holds what is bound.

when USE_WGPU {
	@(private) Frame_Submit :: Submit
} else {
	@(private) Frame_Submit :: D3d_Submit
}

// `partial`: batches into the frame target are cut to the damaged region. `split_slug`: the frame has Slug text.
@(private)
frame_walk :: proc(r: ^Renderer, s: ^Frame_Submit, f: Frame_Data, partial, split_slug: bool) {
	cur, cur_ok := -1, false
	cur_size: [2]int
	cur_origin: [2]f32
	for b, bi in f.batches {
		if b.op > 0 {
			if walk_op(r, s, f, &f.ops[b.op - 1]) { cur = -1 }   // (it left another target or pipeline bound)
			continue
		}
		if b.count == 0 { continue }
		if b.replay > len(f.replays) || (b.replay > 0 && !walk_heap_ready(r)) { continue }
		if b.target != cur {
			cur = b.target
			cur_ok, cur_size, cur_origin = walk_target(r, s, f, cur)
		}
		if !cur_ok { continue }
		// partial redraw: a batch drawing into the frame target (cur == 0, screen pixels) is drawn once per rectangle of the
		// damaged region it touches (they do not overlap), and not at all when it touches none. Layers (cur > 0, their own
		// space) are not cut: they are intermediate images sampled back into the frame, and the composite that reads them is.
		if partial && cur == 0 {
			d := &r.damage
			for rr in d.rects[:d.count] {
				cut := [4]f32{max(b.clip.x, f32(rr.x0)), max(b.clip.y, f32(rr.y0)), min(b.clip.z, f32(rr.x1)), min(b.clip.w, f32(rr.y1))}
				walk_batch(r, s, f, b, bi, cut, cur_size, cur_origin, split_slug)
			}
			continue
		}
		walk_batch(r, s, f, b, bi, b.clip, cur_size, cur_origin, split_slug)
	}
}

// One draw of a batch, under the scissor `clip` (screen pixels).
@(private)
walk_batch :: proc(r: ^Renderer, s: ^Frame_Submit, f: Frame_Data, b: Batch, bi: int, clip: [4]f32, size: [2]int, origin: [2]f32, split_slug: bool) {
	rc := [4]i32{
		i32(clamp(clip.x - origin.x, 0, f32(size.x))), i32(clamp(clip.y - origin.y, 0, f32(size.y))),
		i32(clamp(clip.z - origin.x, 0, f32(size.x))), i32(clamp(clip.w - origin.y, 0, f32(size.y))),
	}
	if rc[2] <= rc[0] || rc[3] <= rc[1] { return }
	walk_bind(r, s, f, b, rc)
	if b.app > 0 {
		walk_draw_app(r, s, f, b)
	} else if split_slug {
		walk_split_slug(r, s, f, b)
	} else {
		walk_draw(r, s, false, b.first, b.count)
	}
	walk_drawn(r, s, f, b, bi, rc)
}

// Draws the instances [b.first, b.first + b.count) of the bound instance buffer: the Slug runs with the Slug shaders, the rest
// with the main ones, in order.
@(private)
walk_split_slug :: proc(r: ^Renderer, s: ^Frame_Submit, f: Frame_Data, b: Batch) {
	runs := f.slug_runs
	base := 0
	if b.replay > 0 {
		rp := f.replays[b.replay - 1]
		runs, base = rp.slug_runs, int(rp.insts)
	}
	pos, end := b.first, b.first + b.count
	// the first run that ends after pos (runs are ascending)
	lo, hi := 0, len(runs)
	for lo < hi {
		mid := (lo + hi) / 2
		if base + runs[mid][0] + runs[mid][1] <= pos { lo = mid + 1 } else { hi = mid }
	}
	for i := lo; i < len(runs) && pos < end; i += 1 {
		rs := base + runs[i][0]
		re := rs + runs[i][1]
		if rs >= end { break }
		if rs > pos { walk_draw(r, s, false, pos, rs - pos); pos = rs }
		e := min(re, end)
		walk_draw(r, s, true, pos, e - pos)
		pos = e
	}
	walk_draw(r, s, false, pos, end - pos)
}
