package draw

import "../font"
import "../render"

// Pictures: retained drawing. What is drawn between picture_begin and picture_end is recorded into a Picture instead
// of the frame: its instances, clips, gradients and transforms, in the picture's own space. The first replay uploads
// them to persistent GPU heaps (render.Heap_Kind); every later frame replays them for the cost of a few draw calls,
// under a matrix, an alpha and the clips around the replay, whatever the number of instances. Immediate drawing and
// replays mix freely in a frame, in the order they are issued (z order is exact).
//
// Transforms pushed while recording become *slots*: their matrices can be changed afterwards (picture_set_slot) without
// recording again, e.g. the transforms of animated elements inside a scrolled document. Changing a slot rewrites one
// GPU range.
//
// What a picture cannot hold: offscreen layers (push_layer / push_effects fall back to push_alpha, backdrops capture
// nothing): apply effects around the replay instead. Texts keep the glyph atlas positions they were recorded with, and
// the picture remembers the atlas pages they are on (font.Page_Ref): when one of those pages is reused for other
// glyphs, when the text rendering settings change, or when the picture is shown at a scale where text would be
// rasterized at another size, `replay` returns .Stale and the picture must be recorded again. Pages are tracked one by
// one: reusing a page only makes the pictures with glyphs on it stale. Images are referenced by texture handle.

// One transform slot: its matrix to its parent slot (`local`) and to the picture's space (`eff`).
Picture_Slot :: struct {
	parent:      u32,
	local, eff:  Affine,
	bounds:      Rect,     // its instances (slot units)
	has_bounds:  bool,
	glyph_scale: f32,      // > 0: text drawn in it was rasterized for this screen scale
}

Picture :: struct {
	insts:      [dynamic]render.Rect_Inst,
	batches:    [dynamic]render.Batch,       // first / count relative to insts; shape = innermost clip
	batch_bounds: [dynamic]Batch_Bounds,     // per batch: where it draws, to cull it at replay
	slots:      [dynamic]Picture_Slot,       // 0: the picture's own space
	clips:      [dynamic]render.Clip_Data,   // 0 unused
	clip_rects: [dynamic]Rect,               // per clip: local bounds of its shape (the scissor at replay)
	points:     [dynamic][2]f32,
	grads:      [dynamic][4]f32,
	pages:      [dynamic]font.Page_Ref,      // the atlas pages its glyphs are on
	pages_broken: bool,                      // a page it used was reused while it was recorded
	text_settings: u64,                      // font.atlas_settings_generation of its glyphs
	glyphs_pending: bool,                    // a color glyph it draws was still being drawn (font.Glyph_Image.pending)...
	pending_ready:  u64,                     // ... at this font.color_ready_generation: stale once it moves
	text:       bool,
	raster_scale: f32,
	version:    u64,                         // bumps at each recording
	// GPU residency (retained heaps)
	resident:   bool,
	heap_gen:   u64,
	uploaded:   u64,                         // version uploaded
	offsets:    [render.Heap_Kind]int,
	counts:     [render.Heap_Kind]int,
	dirty:      [2]int,                      // slots to upload again: [first, end)
	eff_stale:  bool,                        // slots of `dirty` need their `eff` recomputed
	last_used:  u64,
}

// Instances per batch of a picture at most: a replay culls batches whose bounds miss the clip (long runs of text are
// not all drawn when one line shows).
PICTURE_BATCH_INSTANCES :: 256

// Where a batch draws: `r` in the space of slot `slot` (max(u32): instances of several slots, never culled). `gray`,
// `color`: the atlas pages it samples as its coverage texture and its image (-1: none), bound to the replaying
// context's textures of those pages.
Batch_Bounds :: struct {
	slot:  u32,
	r:     Rect,
	gray:  i32,
	color: i32,
}

Replay_Result :: enum u8 {
	Drawn,
	Culled,   // nothing of it can show (outside the clip, empty, singular matrix): nothing was uploaded
	Stale,    // recorded against a glyph atlas or a text scale that no longer holds: record it again
}

// The lists of the frame, kept aside while a picture is recorded.
@(private)
Saved_Frame :: struct {
	insts:   [dynamic]render.Rect_Inst,
	batches: [dynamic]render.Batch,
	clips:   [dynamic]Clip,
	alphas:  [dynamic]f32,
	xforms:  [dynamic]Transform,
	clip_table: [dynamic]render.Clip_Data,
	clip_points: [dynamic][2]f32,
	grads:   [dynamic][4]f32,
	open_layers: [dynamic]Open_Layer,
	target:  int,
	// stacks reused by recordings
	spare_clips:  [dynamic]Clip,
	spare_alphas: [dynamic]f32,
	spare_xforms: [dynamic]Transform,
	spare_open:   [dynamic]Open_Layer,
}

@(private)
saved_destroy :: proc(s: ^Saved_Frame) {
	delete(s.spare_clips); delete(s.spare_alphas); delete(s.spare_xforms); delete(s.spare_open)
}

// Starts recording `pic` (its previous content is dropped). `raster_scale`: screen pixels per picture unit it will
// mostly be shown at (text is rasterized for it; 1 = the picture's units are screen pixels). Not nestable.
picture_begin :: proc(c: ^Context, pic: ^Picture, raster_scale: f32 = 1) {
	assert(c.rec == nil, "draw.picture_begin: a picture is already being recorded")
	clear(&pic.insts); clear(&pic.batches); clear(&pic.batch_bounds); clear(&pic.slots); clear(&pic.clips); clear(&pic.clip_rects)
	clear(&pic.points); clear(&pic.grads)
	clear(&pic.pages)
	pic.text, pic.pages_broken = false, false
	pic.glyphs_pending, pic.pending_ready = false, 0
	pic.dirty, pic.eff_stale = {}, false
	pic.raster_scale = raster_scale > 0 ? raster_scale : 1
	pic.text_settings = font.atlas_settings_generation(c.fonts)
	append(&pic.slots, Picture_Slot{local = AFFINE_IDENTITY, eff = AFFINE_IDENTITY})
	append(&pic.clips, render.Clip_Data{})
	append(&pic.clip_rects, Rect{})
	s := &c.saved
	s.insts, s.batches, s.clips, s.alphas, s.xforms = c.insts, c.batches, c.clips, c.alphas, c.xforms
	s.clip_table, s.clip_points, s.grads, s.open_layers, s.target = c.clip_table, c.clip_points, c.grads, c.open_layers, c.target
	c.insts, c.batches, c.clip_table, c.clip_points, c.grads = pic.insts, pic.batches, pic.clips, pic.points, pic.grads
	pic.insts, pic.batches, pic.clips, pic.points, pic.grads = {}, {}, {}, {}, {}
	c.clips, c.alphas, c.xforms, c.open_layers = s.spare_clips, s.spare_alphas, s.spare_xforms, s.spare_open
	clear(&c.clips); clear(&c.alphas); clear(&c.xforms); clear(&c.open_layers)
	BIG :: 1e9
	append(&c.clips, Clip{rect = {{-BIG, -BIG}, {BIG, BIG}}})
	append(&c.alphas, 1)
	append(&c.xforms, Transform{m = AFFINE_IDENTITY, simple = true})
	c.target = 0
	c.rec = pic
	c.raster_scale = pic.raster_scale
	start_batch(c)
}

// Ends the recording: the picture is ready to replay (it uploads at its first replay).
picture_end :: proc(c: ^Context) {
	pic := c.rec
	if pic == nil { return }
	for len(c.open_layers) > 0 { pop_layer(c) }
	close_batch(c)
	pic.insts, pic.batches, pic.clips, pic.points, pic.grads = c.insts, c.batches, c.clip_table, c.clip_points, c.grads
	s := &c.saved
	s.spare_clips, s.spare_alphas, s.spare_xforms, s.spare_open = c.clips, c.alphas, c.xforms, c.open_layers
	c.insts, c.batches, c.clips, c.alphas, c.xforms = s.insts, s.batches, s.clips, s.alphas, s.xforms
	c.clip_table, c.clip_points, c.grads, c.open_layers, c.target = s.clip_table, s.clip_points, s.grads, s.open_layers, s.target
	s.insts, s.batches, s.clips, s.alphas, s.xforms, s.clip_table, s.clip_points, s.grads, s.open_layers = {}, {}, {}, {}, {}, {}, {}, {}, {}
	c.rec = nil
	c.raster_scale = 1
	// empty batches out; long ones cut every PICTURE_BATCH_INSTANCES so that a replay culls what lies off screen
	split := make([dynamic]render.Batch, 0, len(pic.batches) + len(pic.insts) / PICTURE_BATCH_INSTANCES + 1, context.temp_allocator)
	for b in pic.batches {
		for first := b.first; first < b.first + b.count; first += PICTURE_BATCH_INSTANCES {
			part := b
			part.first = first
			part.count = min(PICTURE_BATCH_INSTANCES, b.first + b.count - first)
			append(&split, part)
		}
	}
	clear(&pic.batches)
	clear(&pic.batch_bounds)
	for b in split {
		append(&pic.batches, b)
		// bounds when every instance is in one slot (else none: never culled)
		bb := Batch_Bounds{slot = pic.insts[b.first].xform, gray = glyph_page_of(c, b.tex), color = glyph_page_of(c, b.image)}
		for inst, k in pic.insts[b.first:][:b.count] {
			if inst.xform != bb.slot { bb.slot = max(u32); break }
			r := Rect{{min(inst.dst[0], inst.dst[2]), min(inst.dst[1], inst.dst[3])}, {max(inst.dst[0], inst.dst[2]), max(inst.dst[1], inst.dst[3])}}
			bb.r = k == 0 ? r : rect_union(bb.r, r)
		}
		append(&pic.batch_bounds, bb)
	}
	for &sl in pic.slots { sl.has_bounds = false }
	for inst in pic.insts {
		sl := &pic.slots[inst.xform]
		r := Rect{{min(inst.dst[0], inst.dst[2]), min(inst.dst[1], inst.dst[3])}, {max(inst.dst[0], inst.dst[2]), max(inst.dst[1], inst.dst[3])}}
		sl.bounds = sl.has_bounds ? rect_union(sl.bounds, r) : r
		sl.has_bounds = true
	}
	// rendering settings changed during the recording: glyphs recorded before and after it differ
	if font.atlas_settings_generation(c.fonts) != pic.text_settings { pic.pages_broken = true }
	pic.version += 1
}

@(private)
top_transform :: proc(c: ^Context) -> Affine { return len(c.xforms) > 0 ? c.xforms[len(c.xforms) - 1].m : AFFINE_IDENTITY }

@(private)
rect_union :: proc(a, b: Rect) -> Rect {
	return {{min(a.min.x, b.min.x), min(a.min.y, b.min.y)}, {max(a.max.x, b.max.x), max(a.max.y, b.max.y)}}
}

// The picture being recorded, nil when drawing the frame.
recording :: proc(c: ^Context) -> ^Picture { return c.rec }

@(private)
push_new_slot :: proc(c: ^Context, local, eff: Affine) {
	parent := c.xforms[len(c.xforms) - 1].gpu
	append(&c.rec.slots, Picture_Slot{parent = parent, local = local, eff = eff})
	append(&c.xforms, Transform{m = eff, simple = false, gpu = u32(len(c.rec.slots) - 1)})
}

// While recording: the slot of the current transform (0 = the picture's space). Keep it to change the matrix later
// with picture_set_slot, or to draw in that space again with push_slot.
current_slot :: proc(c: ^Context) -> u32 {
	if c.rec == nil { return 0 }
	return c.xforms[len(c.xforms) - 1].gpu
}

// While recording: draws what follows in slot `k` again (made earlier by push_transform in this recording). Pop with
// pop_transform.
push_slot :: proc(c: ^Context, k: u32) {
	if c.rec == nil || int(k) >= len(c.rec.slots) { append(&c.xforms, c.xforms[len(c.xforms) - 1]); return }
	sl := c.rec.slots[k]
	append(&c.xforms, Transform{m = sl.eff, simple = k == 0, gpu = k})
}

@(private)
picture_note_text :: proc(c: ^Context, slot: u32, sf: f32) {
	c.rec.text = true
	c.rec.slots[slot].glyph_scale = sf
}

// A glyph bitmap recorded: the picture depends on its page (as it was then).
@(private)
picture_note_page :: proc(pic: ^Picture, img: font.Glyph_Image) {
	for r in pic.pages {
		if r.page != img.page { continue }
		if r.epoch != img.epoch { pic.pages_broken = true }   // the page was reused under the recording
		return
	}
	append(&pic.pages, font.Page_Ref{page = img.page, epoch = img.epoch})
}

// Changes the matrix of slot `k` relative to its parent slot (what push_transform was given). Its descendants follow.
// Uploaded at the next replay. A text whose screen size changes beyond the raster tolerance makes the picture stale.
picture_set_slot :: proc(pic: ^Picture, k: u32, local: Affine) {
	if k == 0 || int(k) >= len(pic.slots) { return }
	if pic.slots[k].local == local { return }
	pic.slots[k].local = local
	// the matrices to the picture's space are recomputed once, before the next use (slots_update)
	first := int(k)
	if pic.dirty[1] <= pic.dirty[0] { pic.dirty = {first, len(pic.slots)} } else { pic.dirty = {min(pic.dirty[0], first), len(pic.slots)} }
	pic.eff_stale = true
}

// Slots are made after their parents: one pass in order from the first changed slot brings every descendant along.
@(private)
slots_update :: proc(pic: ^Picture) {
	if !pic.eff_stale { return }
	pic.eff_stale = false
	for i in max(pic.dirty[0], 1) ..< min(pic.dirty[1], len(pic.slots)) {
		sl := &pic.slots[i]
		sl.eff = affine_mul(pic.slots[sl.parent].eff, sl.local)
	}
}

// The matrix of slot `k` relative to its parent.
picture_slot :: proc(pic: ^Picture, k: u32) -> Affine {
	if int(k) >= len(pic.slots) { return AFFINE_IDENTITY }
	return pic.slots[k].local
}

// Screen bounds of what the picture draws under `m` (after the current transform), its slots where they are now.
picture_bounds :: proc(c: ^Context, pic: ^Picture, m: Affine) -> (r: Rect, ok: bool) {
	slots_update(pic)
	return picture_bounds_l(pic, affine_mul(top_transform(c), m))
}

// Whether text of the picture would be rasterized at another size under `m`, an atlas page its glyphs are on was
// reused, or the text rendering settings changed: record it again (replay returns .Stale then). When it is not stale,
// its pages count as used by the current frame (they are not reused before it is drawn).
picture_stale :: proc(c: ^Context, pic: ^Picture, m: Affine) -> bool {
	if !pic.text { return false }
	if pic.pages_broken || pic.text_settings != font.atlas_settings_generation(c.fonts) { return true }
	if pic.glyphs_pending && font.color_ready_generation(c.fonts) != pic.pending_ready { return true }
	if !font.atlas_pages_hold(c.fonts, pic.pages[:]) { return true }
	slots_update(pic)
	l := affine_mul(top_transform(c), m)
	ls := affine_scale_factor(l)
	class :: proc(sf: f32) -> f32 { return abs(sf - 1) <= TEXT_RASTER_TOLERANCE ? 1 : sf }
	for sl in pic.slots {
		if sl.glyph_scale <= 0 { continue }
		now := class(ls * affine_scale_factor(sl.eff))
		was := class(sl.glyph_scale)
		if abs(now - was) > 1e-3 * max(was, 1) { return true }
	}
	return false
}

// Draws the picture under `m` (after the current transform), faded by the alpha stack, cut by the clips pushed around
// it. Its instances are uploaded first if needed (first replay, re-recorded, evicted, device lost); changed slots are
// rewritten. Not while recording.
replay :: proc(c: ^Context, pic: ^Picture, m: Affine) -> Replay_Result {
	if c.rec != nil { return .Culled }
	// (a picture of nothing but pending glyphs is empty until they are ready)
	if pic.glyphs_pending && font.color_ready_generation(c.fonts) != pic.pending_ready { return .Stale }
	if len(pic.insts) == 0 || len(pic.batches) == 0 { return .Culled }
	slots_update(pic)
	if picture_stale(c, pic, m) { return .Stale }
	l := affine_mul(top_transform(c), m)
	inv, invertible := affine_inverse(l)
	if !invertible { return .Culled }
	scissor := rect_intersect(c.clips[len(c.clips) - 1].rect, target_rect(c))
	if rect_empty(scissor) { return .Culled }
	if b, ok := picture_bounds_l(pic, l); !ok || rect_empty(rect_intersect(rect_pad(b, 1), scissor)) { return .Culled }
	if !picture_upload(c, pic) { return .Culled }
	append(&c.replays, render.Replay{
		m = {l.a, l.b, l.c, l.d, l.e, l.f}, inv = {inv.a, inv.b, inv.c, inv.d, inv.e, inv.f},
		alpha = c.alphas[len(c.alphas) - 1], outer = c.clips[len(c.clips) - 1].shape,
		slots = u32(pic.offsets[.Slots]), clips = u32(pic.offsets[.Clips]), points = u32(pic.offsets[.Points]), grads = u32(pic.offsets[.Grads]),
	})
	idx := len(c.replays)
	close_batch(c)
	base := pic.offsets[.Insts]
	for b, k in pic.batches {
		if bb := pic.batch_bounds[k]; bb.slot != max(u32) {
			if rect_empty(rect_intersect(rect_pad(affine_bounds(affine_mul(l, pic.slots[bb.slot].eff), bb.r), 1), scissor)) { continue }
		}
		sc := rect_intersect(batch_scissor(pic, b.shape, l), scissor)
		if rect_empty(sc) { continue }
		bb := pic.batch_bounds[k]
		tex := bb.gray >= 0 ? glyph_texture(c, int(bb.gray)) : c.atlas
		image := bb.color >= 0 ? glyph_texture(c, int(bb.color)) : b.image
		append(&c.batches, render.Batch{
			clip = {sc.min.x, sc.min.y, sc.max.x, sc.max.y}, tex = tex, image = image,
			first = base + b.first, count = b.count, target = c.target, replay = idx,
		})
	}
	start_batch(c)
	return .Drawn
}

@(private)
picture_bounds_l :: proc(pic: ^Picture, l: Affine) -> (r: Rect, ok: bool) {
	for sl in pic.slots {
		if !sl.has_bounds { continue }
		b := affine_bounds(affine_mul(l, sl.eff), sl.bounds)
		r = ok ? rect_union(r, b) : b
		ok = true
	}
	return
}

// The scissor of a picture batch: its clips, each where it lands under `l`. A plain rect under a uniform scale +
// translation is exact (push_clip), anything else is the bounds grown by a pixel (push_clip_shape), as when drawn
// directly.
@(private)
batch_scissor :: proc(pic: ^Picture, shape: u32, l: Affine) -> Rect {
	BIG :: 1e9
	r := Rect{{-BIG, -BIG}, {BIG, BIG}}
	for k := shape; k != 0 && int(k) < len(pic.clips); k = pic.clips[k].parent {
		cl := pic.clips[k]
		m := affine_mul(l, pic.slots[cl.xform].eff)
		b := pic.clip_rects[k]
		if cl.flags & render.CLIP_SCISSOR != 0 && affine_is_scale_translate(m) {
			s, o := m.a, Vec2{m.e, m.f}
			r = rect_intersect(r, Rect{b.min * s + o, b.max * s + o})
		} else {
			r = rect_intersect(r, rect_pad(affine_bounds(m, b), 1))
		}
	}
	return r
}

// Makes the picture's data resident in the retained heaps (allocating, evicting other pictures over the budget,
// uploading), then rewrites its changed slots.
@(private)
picture_upload :: proc(c: ^Context, pic: ^Picture) -> bool {
	r := c.renderer
	if pic.resident && pic.heap_gen != r.heap_generation { pic.resident = false }   // heaps emptied: ranges are gone
	pic.last_used = c.frame_no
	counts := [render.Heap_Kind]int{
		.Insts = len(pic.insts), .Slots = len(pic.slots), .Clips = len(pic.clips), .Points = len(pic.points), .Grads = len(pic.grads),
	}
	if pic.resident && pic.uploaded == pic.version {
		if pic.dirty[1] > pic.dirty[0] {
			write_slots(r, pic, pic.dirty[0], pic.dirty[1])
			pic.dirty = {}
		}
		return true
	}
	if pic.resident && counts != pic.counts { picture_release(c, pic) }
	if !pic.resident {
		need := 0
		for n, k in counts { need += n * render.HEAP_STRIDE[k] }
		evict_for(c, need)
		for n, k in counts {
			off, ok := render.heap_alloc(r, k, n)
			if !ok {
				for kk in render.Heap_Kind { if kk >= k { break }; render.heap_free(r, kk, pic.offsets[kk], counts[kk]) }
				return false
			}
			pic.offsets[k] = off
		}
		pic.counts = counts
		pic.resident = true
		pic.heap_gen = r.heap_generation
		register_picture(c, pic)
	}
	render.heap_write(r, .Insts, pic.offsets[.Insts], raw_data(pic.insts), len(pic.insts))
	render.heap_write(r, .Clips, pic.offsets[.Clips], raw_data(pic.clips), len(pic.clips))
	render.heap_write(r, .Points, pic.offsets[.Points], raw_data(pic.points), len(pic.points))
	render.heap_write(r, .Grads, pic.offsets[.Grads], raw_data(pic.grads), len(pic.grads))
	write_slots(r, pic, 0, len(pic.slots))
	pic.dirty = {}
	pic.uploaded = pic.version
	return true
}

@(private)
write_slots :: proc(r: ^render.Renderer, pic: ^Picture, first, end: int) {
	n := end - first
	if n <= 0 { return }
	data := make([]render.Slot_Data, n, context.temp_allocator)
	for i in 0 ..< n {
		e := pic.slots[first + i].eff
		inv, _ := affine_inverse(e)
		data[i] = render.Slot_Data{m = {e.a, e.b, e.c, e.d, e.e, e.f}, inv = {inv.a, inv.b, inv.c, inv.d, inv.e, inv.f}}
	}
	render.heap_write(r, .Slots, pic.offsets[.Slots] + first, raw_data(data), n)
}

@(private)
register_picture :: proc(c: ^Context, pic: ^Picture) {
	for p in c.pictures { if p == pic { return } }
	append(&c.pictures, pic)
}

// Pictures not drawn this frame give their heap ranges back, least recently drawn first, until `need` more bytes fit
// in the budget. They upload again from their CPU copy when drawn next.
@(private)
evict_for :: proc(c: ^Context, need: int) {
	if c.retained_budget <= 0 { return }
	for {
		used, _ := render.heap_bytes(c.renderer)
		if used + need <= c.retained_budget { return }
		oldest := -1
		for p, i in c.pictures {
			if p.last_used >= c.frame_no { continue }
			if oldest < 0 || p.last_used < c.pictures[oldest].last_used { oldest = i }
		}
		if oldest < 0 { return }   // the frame's own pictures do not fit: the heaps grow past the budget
		picture_release(c, c.pictures[oldest])
	}
}

// Gives the picture's GPU ranges back (it keeps its recording and uploads again when replayed).
picture_release :: proc(c: ^Context, pic: ^Picture) {
	if pic.resident && pic.heap_gen == c.renderer.heap_generation {
		for n, k in pic.counts { render.heap_free(c.renderer, k, pic.offsets[k], n) }
	}
	pic.resident = false
	for p, i in c.pictures { if p == pic { unordered_remove(&c.pictures, i); break } }
}

// Frees the picture: its GPU ranges and its recording.
picture_destroy :: proc(c: ^Context, pic: ^Picture) {
	picture_release(c, pic)
	delete(pic.insts); delete(pic.batches); delete(pic.batch_bounds); delete(pic.slots); delete(pic.clips); delete(pic.clip_rects)
	delete(pic.points); delete(pic.grads); delete(pic.pages)
	pic^ = {}
}

// Bytes of retained heaps the context keeps before evicting pictures not drawn in the current frame (0: no limit).
set_retained_budget :: proc(c: ^Context, bytes: int) { c.retained_budget = max(bytes, 0) }

// Retained heap memory: allocated to pictures, and reserved on the GPU.
retained_bytes :: proc(c: ^Context) -> (used, capacity: int) { return render.heap_bytes(c.renderer) }

// Number of instances recorded in the picture.
picture_size :: proc(pic: ^Picture) -> int { return len(pic.insts) }
