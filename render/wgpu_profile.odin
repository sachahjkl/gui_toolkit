package render

import "core:sync"
import "vendor:wgpu"

// WebGPU backend: GPU time of frame_submit (gpu_ms) and of each of its steps (set_gpu_profile). Timestamp queries
// written between the passes of the command encoder (the TimestampQueryInsideEncoders feature), resolved into a buffer,
// copied to a mappable one, and read GPU_QUERY_FRAMES submits later like the Direct3D 11 backend does: the CPU never waits.
// A step is a pass (a run of draw calls into a target, a clear, a filter pass) or a copy; the detailed profile (every draw
// call) is not available here: timestamps inside passes would need TimestampQueryInsidePasses.

@(private) WPROF_TIMESTAMP_BYTES :: 8
@(private) NS_PER_MS :: 1e6
@(private) WPROF_QUERIES :: 1024   // per slot (a query set holds 4096): the submit's start, then one after each step; later steps are counted in the last

@(private)
Wprof_State :: enum u8 { Free, Mapping, Mapped }   // Mapped: its results are ready

@(private)
Wgpu_Prof :: struct {
	qs:      wgpu.QuerySet,
	resolve: wgpu.Buffer,
	read:    [GPU_QUERY_FRAMES]wgpu.Buffer,
	count:   [GPU_QUERY_FRAMES]int,    // timestamps written in the slot
	frame:   [GPU_QUERY_FRAMES]int,    // the submit the slot measured (gpu_frame at the time)
	recs:    [GPU_QUERY_FRAMES][dynamic]Prof_Rec,
	trunc:   [GPU_QUERY_FRAMES]bool,
	period:  f32,                      // nanoseconds per timestamp tick
	slot:    int,                      // the slot being recorded (-1: none)
}

@(private)
wprof_init :: proc(r: ^Renderer) -> bool {
	g := &r.wg
	if g.pf.qs != nil { return g.pf.resolve != nil }
	g.pf.slot = -1
	g.pf.qs = wgpu.DeviceCreateQuerySet(g.device, &{label = "gpu time", type = .Timestamp, count = GPU_QUERY_FRAMES * WPROF_QUERIES})
	g.pf.resolve = wgpu.DeviceCreateBuffer(g.device, &{label = "gpu time", usage = {.QueryResolve, .CopySrc}, size = GPU_QUERY_FRAMES * WPROF_QUERIES * WPROF_TIMESTAMP_BYTES})
	for i in 0 ..< GPU_QUERY_FRAMES {
		g.pf.read[i] = wgpu.DeviceCreateBuffer(g.device, &{label = "gpu time read", usage = {.MapRead, .CopyDst}, size = WPROF_QUERIES * WPROF_TIMESTAMP_BYTES})
	}
	g.pf.period = wgpu.QueueGetTimestampPeriod(g.queue)
	return g.pf.qs != nil && g.pf.resolve != nil
}

@(private)
wgpu_profile_release :: proc(r: ^Renderer) {
	g := &r.wg
	for i in 0 ..< GPU_QUERY_FRAMES {
		if g.pf.read[i] != nil {
			if sync.atomic_load(&g.shared.prof[i]) == .Mapped { wgpu.BufferUnmap(g.pf.read[i]) }
			wgpu.BufferRelease(g.pf.read[i])
		}
		delete(g.pf.recs[i])
	}
	if g.pf.resolve != nil { wgpu.BufferRelease(g.pf.resolve) }
	if g.pf.qs != nil { wgpu.QuerySetRelease(g.pf.qs) }
	g.pf = {slot = -1}
	for &s in g.shared.prof { sync.atomic_store(&s, Wprof_State.Free) }
}

@(private)
wprof_map_done :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, u1, u2: rawptr) {
	sync.atomic_store((^Wprof_State)(u1), status == .Success ? Wprof_State.Mapped : Wprof_State.Free)
}

// Reads the slots whose results arrived: the latest becomes gpu_ms / gpu_profile.
@(private)
wprof_collect :: proc(r: ^Renderer) {
	g := &r.wg
	if g.pf.qs == nil { return }
	wgpu_poll(r, false)   // runs the map callbacks of finished work, never waits
	for slot in 0 ..< GPU_QUERY_FRAMES {
		if sync.atomic_load(&g.shared.prof[slot]) != .Mapped { continue }
		n := g.pf.count[slot]
		data := wgpu.BufferGetConstMappedRangeSlice(g.pf.read[slot], 0, uint(n), u64)
		if n >= 2 && len(data) == n {
			frame := g.pf.frame[slot]
			ms := f32(f64(data[n - 1] - data[0]) * f64(g.pf.period) / NS_PER_MS)
			if frame >= r.gpu_last_frame - 1 {
				r.gpu_last_ms = ms
				r.gpu_last_frame = frame + 1
			}
			if r.prof.on { wprof_fill(r, slot, frame, ms, data) }
		}
		wgpu.BufferUnmap(g.pf.read[slot])
		sync.atomic_store(&g.shared.prof[slot], Wprof_State.Free)
	}
}

@(private)
wprof_fill :: proc(r: ^Renderer, slot, frame: int, total_ms: f32, data: []u64) {
	g := &r.wg
	p := Gpu_Profile{frame = frame, total_ms = total_ms, truncated = g.pf.trunc[slot]}
	prev := data[0]
	for rec, i in g.pf.recs[slot] {
		if i + 1 >= len(data) { break }
		if rec.kind == .Draw_Frame || rec.kind == .Draw_Layer { p.target_changes += 1 }
		profile_add(&p, rec, data[i + 1], &prev, f64(g.pf.period) / NS_PER_MS)
	}
	r.prof.last = p
	r.prof.have = true
}

// Start of a timed submit: a slot, the first timestamp.
@(private)
wprof_begin :: proc(r: ^Renderer, enc: wgpu.CommandEncoder) {
	g := &r.wg
	g.pf.slot = -1
	if !wprof_init(r) { return }
	wprof_collect(r)
	slot := r.gpu_frame % GPU_QUERY_FRAMES
	if sync.atomic_load(&g.shared.prof[slot]) != .Free { return }   // its previous results are not read yet: this frame is not timed
	g.pf.slot = slot
	g.pf.count[slot] = 0
	g.pf.frame[slot] = r.gpu_frame
	g.pf.trunc[slot] = false
	clear(&g.pf.recs[slot])
	wgpu.CommandEncoderWriteTimestamp(enc, g.pf.qs, u32(slot * WPROF_QUERIES))
	g.pf.count[slot] = 1
}

// A step was just recorded: a timestamp after it.
@(private)
wprof_step :: proc(r: ^Renderer, enc: wgpu.CommandEncoder, kind: Gpu_Step, w, h: int, pixels, bytes: int) {
	g := &r.wg
	slot := g.pf.slot
	if slot < 0 || !r.prof.on { return }
	n := g.pf.count[slot]
	if n >= WPROF_QUERIES {
		// counted in the last step
		if len(g.pf.recs[slot]) > 0 {
			last := &g.pf.recs[slot][len(g.pf.recs[slot]) - 1]
			last.pixels += pixels
			last.bytes += bytes
		}
		g.pf.trunc[slot] = true
		return
	}
	wgpu.CommandEncoderWriteTimestamp(enc, g.pf.qs, u32(slot * WPROF_QUERIES + n))
	g.pf.count[slot] = n + 1
	append(&g.pf.recs[slot], Prof_Rec{kind = kind, w = i32(w), h = i32(h), pixels = pixels, bytes = bytes, detail = Gpu_Step_Rec{batch = -1}})
}

// End of the submit: the last timestamp, resolved into the slot's mappable buffer (mapped once the work is done).
@(private)
wprof_end :: proc(r: ^Renderer, enc: wgpu.CommandEncoder) {
	g := &r.wg
	slot := g.pf.slot
	if slot < 0 { return }
	if g.pf.count[slot] < 2 {
		// no step recorded (the profile is off): the frame is two timestamps; with steps, the last one ended the frame
		wgpu.CommandEncoderWriteTimestamp(enc, g.pf.qs, u32(slot * WPROF_QUERIES + 1))
		g.pf.count[slot] = 2
	}
	base := u32(slot * WPROF_QUERIES)
	wgpu.CommandEncoderResolveQuerySet(enc, g.pf.qs, base, u32(g.pf.count[slot]), g.pf.resolve, u64(slot * WPROF_QUERIES * WPROF_TIMESTAMP_BYTES))
	wgpu.CommandEncoderCopyBufferToBuffer(enc, g.pf.resolve, u64(slot * WPROF_QUERIES * WPROF_TIMESTAMP_BYTES), g.pf.read[slot], 0, u64(g.pf.count[slot] * WPROF_TIMESTAMP_BYTES))
}

// After the submit: ask for the results (the map completes when the GPU is done with them).
@(private)
wprof_submitted :: proc(r: ^Renderer) {
	g := &r.wg
	slot := g.pf.slot
	if slot < 0 { return }
	sync.atomic_store(&g.shared.prof[slot], Wprof_State.Mapping)
	wgpu.BufferMapAsync(g.pf.read[slot], {.Read}, 0, uint(g.pf.count[slot] * WPROF_TIMESTAMP_BYTES), {mode = .AllowSpontaneos, callback = wprof_map_done, userdata1 = &g.shared.prof[slot]})
	g.pf.slot = -1
	r.gpu_frame += 1
}
