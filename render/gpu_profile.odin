package render

import "vendor:directx/d3d11"

// GPU time of each step of frame_submit (set_gpu_profile): a timestamp query after every step (a run of draw calls into
// one target, a clear, a copy, a filter pass), read back GPU_QUERY_FRAMES submits later like the frame's own time, so
// the CPU never waits. Steps of the same kind are summed (gpu_profile); the slowest ones are listed. Pixels and bytes are
// estimates: what a step writes (its destination region) and reads (each source region once, as a texture cache would).

Gpu_Step :: enum u8 {
	Draw_Frame,   // draw calls into the frame (page content, layer composites)
	Draw_Layer,   // draw calls into an offscreen layer
	Clear,        // a layer cleared before it is drawn
	Copy,         // a snapshot of what a target holds (backdrops, blend modes)
	Color,        // filter pass: color matrices (or a resample)
	Blur,         // filter pass: one direction of a gaussian
	Downsample,   // filter pass: reduction by 2, 4 or 8 before a large blur
	Shadow,       // filter pass: drop shadow composited under its input
	Mask,         // filter pass: a mask layer folded into the coverage, or the coverage applied to the content
	Upload,       // from the submit's start to its first draw: mip chains, structured buffers, instance upload
	Acquire,      // the back buffer cleared once before anything is drawn: the wait for the compositor to release it shows here
	Present,      // not part of the submit: the GPU time of the Present call itself (timestamps around it)
	Idle,         // not part of the submit: the GPU waiting for work between the previous frame's Present and this submit
}

Gpu_Step_Stat :: struct {
	count:  int,
	ms:     f32,
	pixels: int,   // written
	bytes:  int,   // estimated traffic: written + read
}

Gpu_Step_Rec :: struct {
	kind: Gpu_Step,
	ms:   f32,
	w, h: i32,     // destination region (0 for draw runs)
	// detailed profile (set_gpu_profile(detail = true)): each draw call is a step
	batch: i32,    // index in Frame_Data.batches (-1: not a single draw call)
	insts: i32,    // instances drawn
	kinds: u32,    // bit k: an instance of KIND k (immediate instances), bit 31: retained (a picture's replay)
	flags: u32,    // FLAG_* of its instances, together
	scissor: [4]i32,
}

GPU_PROFILE_SLOWEST :: 16
// Steps timed per frame; past it the remaining steps are counted in the last one.
GPU_PROFILE_MAX_STEPS :: 2048

Gpu_Profile :: struct {
	frame:    int,                          // the timed submit it measured (as gpu_next_frame)
	total_ms: f32,                          // the whole submit, as gpu_ms
	steps:    [Gpu_Step]Gpu_Step_Stat,
	target_changes: int,                    // render targets bound (draw targets and pass destinations)
	slowest:  [GPU_PROFILE_SLOWEST]Gpu_Step_Rec,
	n_slowest: int,
	truncated: bool,                        // more steps than GPU_PROFILE_MAX_STEPS
}

@(private)
Prof_Rec :: struct {
	kind:   Gpu_Step,
	w, h:   i32,
	pixels: int,
	bytes:  int,
	detail: Gpu_Step_Rec,   // batch, insts, kinds, flags, scissor (detailed profile)
}

@(private)
Prof_Slot :: struct {
	queries: [dynamic]^d3d11.IQuery,
	recs:    [dynamic]Prof_Rec,
	target_changes: int,
	truncated: bool,
	valid:   bool,      // recorded by a timed submit, not read back yet
	pq:      [3]^d3d11.IQuery,   // disjoint, before, after: around the Present that followed the submit
	present_rec: bool,
}

Gpu_Profiler :: struct {
	on:    bool,
	detail: bool,
	slots: [GPU_QUERY_FRAMES]Prof_Slot,
	cur:   ^Prof_Slot,  // the submit being recorded (nil: none)
	cur_slot: int,
	pend_slot: int,     // the slot of the last timed submit, while its Present has not been recorded
	pend_ok: bool,
	prev_tb: u64,       // the previous frame's last timestamp (after its Present), to measure the idle time before the next
	prev_frame: int,
	prev_ok: bool,
	last:  Gpu_Profile,
	have:  bool,
}

// Measures each step of frame_submit from now on (implies set_gpu_timing's measurement). Costs one timestamp query per
// step; off, nothing. `detail`: every draw call is a step of its own (to find an expensive one: Gpu_Profile.slowest
// gives its batch, instance count, kinds and flags); the timestamps between draw calls slow the frame more.
set_gpu_profile :: proc(r: ^Renderer, on: bool, detail := false) { r.prof.on, r.prof.detail = on, detail }
gpu_profile_enabled :: proc(r: ^Renderer) -> bool { return r.prof.on }

// The latest per-step profile read back (ok false: none yet).
gpu_profile :: proc(r: ^Renderer) -> (p: Gpu_Profile, ok: bool) { return r.prof.last, r.prof.have }

@(private)
profile_destroy :: proc(r: ^Renderer) {
	for &s in r.prof.slots {
		for q in s.queries { if q != nil { q->Release() } }
		for q in s.pq { if q != nil { q->Release() } }
		delete(s.queries)
		delete(s.recs)
		s = {}
	}
	r.prof.cur = nil
}

// Start of a timed submit in `slot` (after its previous results were read).
@(private)
profile_begin :: proc(r: ^Renderer, slot: int) {
	r.prof.cur = nil
	if !r.prof.on { r.prof.slots[slot].valid = false; return }
	s := &r.prof.slots[slot]
	clear(&s.recs)
	s.target_changes = 0
	s.truncated = false
	s.valid = true
	s.present_rec = false
	r.prof.cur = s
	r.prof.cur_slot = slot
}

@(private)
profile_end :: proc(r: ^Renderer) {
	if r.prof.cur != nil { r.prof.pend_slot, r.prof.pend_ok = r.prof.cur_slot, true }
	r.prof.cur = nil
}

// Timestamps around the Present that follows a timed submit (present_frame): its own GPU time, and the reference for the
// idle time before the next submit. Returns the slot to hand to profile_present_end (nil: not measured).
@(private)
profile_present_begin :: proc(r: ^Renderer) -> ^Prof_Slot {
	if !r.prof.pend_ok { return nil }
	r.prof.pend_ok = false
	s := &r.prof.slots[r.prof.pend_slot]
	if !s.valid { return nil }
	for i in 0 ..< 3 {
		if s.pq[i] != nil { continue }
		if r.device->CreateQuery(&{Query = i == 0 ? .TIMESTAMP_DISJOINT : .TIMESTAMP}, &s.pq[i]) < 0 || s.pq[i] == nil { return nil }
	}
	r.ctx->Begin((^d3d11.IAsynchronous)(s.pq[0]))
	r.ctx->End((^d3d11.IAsynchronous)(s.pq[1]))
	return s
}

@(private)
profile_present_end :: proc(r: ^Renderer, s: ^Prof_Slot) {
	if s == nil { return }
	r.ctx->End((^d3d11.IAsynchronous)(s.pq[2]))
	r.ctx->End((^d3d11.IAsynchronous)(s.pq[0]))
	s.present_rec = true
}

// A step just recorded: a timestamp after it.
@(private)
profile_step :: proc(r: ^Renderer, kind: Gpu_Step, w, h: int, pixels, bytes: int, detail := Gpu_Step_Rec{batch = -1}) {
	s := r.prof.cur
	if s == nil { return }
	n := len(s.recs)
	if n >= GPU_PROFILE_MAX_STEPS {
		// counted in the last step
		last := &s.recs[n - 1]
		last.pixels += pixels
		last.bytes += bytes
		s.truncated = true
		r.ctx->End((^d3d11.IAsynchronous)(s.queries[n - 1]))
		return
	}
	if n >= len(s.queries) {
		q: ^d3d11.IQuery
		if r.device->CreateQuery(&{Query = .TIMESTAMP}, &q) < 0 || q == nil { return }
		append(&s.queries, q)
	}
	append(&s.recs, Prof_Rec{kind = kind, w = i32(w), h = i32(h), pixels = pixels, bytes = bytes, detail = detail})
	r.ctx->End((^d3d11.IAsynchronous)(s.queries[n]))
}

@(private)
profile_target_change :: proc(r: ^Renderer) { if r.prof.cur != nil { r.prof.cur.target_changes += 1 } }

// The results of `slot` (its frame's timestamps ready): t0 is the submit's first timestamp, freq the disjoint query's.
@(private)
profile_collect :: proc(r: ^Renderer, slot: int, frame: int, t0: u64, freq: u64, total_ms: f32) {
	s := &r.prof.slots[slot]
	if !s.valid { return }
	s.valid = false
	p := Gpu_Profile{frame = frame, total_ms = total_ms, target_changes = s.target_changes, truncated = s.truncated}
	prev := t0
	for rec, i in s.recs {
		t: u64
		if r.ctx->GetData((^d3d11.IAsynchronous)(s.queries[i]), &t, size_of(t), 0) != 0 { return }   // not ready: skip the frame
		ms := t >= prev ? f32(f64(t - prev) * 1000 / f64(freq)) : 0
		prev = max(prev, t)
		st := &p.steps[rec.kind]
		st.count += 1
		st.ms += ms
		st.pixels += rec.pixels
		st.bytes += rec.bytes
		// the slowest steps, longest first
		k := p.n_slowest
		if k < GPU_PROFILE_SLOWEST { p.n_slowest += 1 } else if ms <= p.slowest[k - 1].ms { continue } else { k -= 1 }
		for k > 0 && p.slowest[k - 1].ms < ms { p.slowest[k] = p.slowest[k - 1]; k -= 1 }
		d := rec.detail
		d.kind, d.ms, d.w, d.h = rec.kind, ms, rec.w, rec.h
		p.slowest[k] = d
	}
	had_prev := r.prof.prev_ok && r.prof.prev_frame == frame - 1
	r.prof.prev_ok = false
	if s.present_rec {
		dj: d3d11.QUERY_DATA_TIMESTAMP_DISJOINT
		ta, tb: u64
		if r.ctx->GetData((^d3d11.IAsynchronous)(s.pq[0]), &dj, size_of(dj), 0) == 0 &&
		   r.ctx->GetData((^d3d11.IAsynchronous)(s.pq[1]), &ta, size_of(ta), 0) == 0 &&
		   r.ctx->GetData((^d3d11.IAsynchronous)(s.pq[2]), &tb, size_of(tb), 0) == 0 && !bool(dj.Disjoint) && dj.Frequency > 0 {
			if tb >= ta { p.steps[.Present] = Gpu_Step_Stat{count = 1, ms = f32(f64(tb - ta) * 1000 / f64(dj.Frequency))} }
			if had_prev && t0 >= r.prof.prev_tb {
				p.steps[.Idle] = Gpu_Step_Stat{count = 1, ms = f32(f64(t0 - r.prof.prev_tb) * 1000 / f64(freq))}
			}
			r.prof.prev_tb, r.prof.prev_frame, r.prof.prev_ok = tb, frame, true
		}
	}
	r.prof.last = p
	r.prof.have = true
}
