package draw

import "core:time"
import "../font"
import "../render"

// Automatic damage: the region of a frame worked out from what it draws, with nothing marked by hand.
//
// A program labels what it draws with spans (damage_span_begin / damage_span_end, nested: a box and its children). At
// end_frame what is drawn is cut into parts: a part is what one span drew between two cuts (a span with children has one
// part before its first child, one between two children, one after the last). The instances, batches and steps of each part
// are reduced to a digest: a hash of everything that decides their pixels (the instance with its transform, clip shape and
// gradient resolved, the scissor, the textures and their versions, the layer they are drawn into) and the screen bounds they
// can touch. The parts are compared with the last frame's (a Damage_Memory the program keeps per window): a part whose digest
// differs is damaged where it was and where it is now, a new part where it is, a gone part where it was. A custom draw needs
// nothing more: what it draws is in the digest.
//
// The comparison is linear: both frames' parts are in draw order, matched by position while their spans are the same, from
// the start and from the end; only the parts between (what was added, removed or moved) are matched by span through a map.
//
// What no instance shows makes the whole frame: the first frame, another size, other font settings, another device, a frame
// that copies its own target (backdrops, blend modes), a plane, parts drawn in another order (a box raised above another),
// and damage_whole. The renderer adds its own (render.damage_environment: the clear colour, the blend space, text and corner
// settings). An offscreen target (offscreen_begin) is never shown: what is drawn into it damages nothing. A picture replayed
// (draw.replay) is drawn where it lands every frame, unless its replay asked to be compared (`compare`: the picture, its
// version and slots, where it lands, its clips and textures). A span that calls damage_volatile is
// redrawn every frame (pixels that change with no instance changing: a texture written outside the renderer).
//
// Usage, each frame, with partial redraw on (set_partial_redraw):
//   draw.begin_frame(dc, size)
//   draw.damage_auto(dc, &memory)        the memory of this window, kept between frames; one memory a frame
//   draw.damage_span_begin(dc, id) ... draw.damage_span_end(dc)   as many as there are things that change apart
//   draw.end_frame(dc)                   the region is built here and the frame submitted
// Content outside every span belongs to span 0. A region begun by hand (damage_begin, damage) is kept and added to.

// What a program keeps of its last frame for damage_auto: one per window (per renderer surface).
Damage_Memory :: struct {
	parts:       [dynamic]Damage_Part,   // the last frame's, in draw order
	next:        [dynamic]Damage_Part,   // this frame's while end_frame works them out; then swapped with `parts` (no copy)
	environment: u64,                    // draw_environment of that frame
	valid:       bool,                   // the memory holds a frame drawn with damage_auto: false makes the next frame whole
	stats:       Damage_Auto_Stats,      // the last frame's
}

// What a span drew between two cuts: the hash of what decides its pixels and the screen rectangle they can reach (empty:
// nothing visible).
Damage_Part :: struct {
	span:     u64,
	hash:     u64,
	bounds:   Rect,
	volatile: bool,   // redrawn every frame (damage_volatile, a picture replayed)
}

// Why a frame was damaged whole (Damage_Auto_Stats.whole).
Damage_Whole :: enum u8 {
	No,            // a region of the parts that changed
	First,         // nothing to compare with: the first frame, or partial redraw was off
	Environment,   // another size, font settings or device
	Asked,         // damage_whole
	Reads_Itself,  // a copy of a target (a backdrop, a blend mode)
	Plane,         // drawing into a plane: where it shows is not known
	Order,         // parts drawn in another order
}

// One frame of damage_auto, for diagnostics and tests.
Damage_Auto_Stats :: struct {
	parts:     int,            // parts that drew something
	changed:   int,            // parts damaged (changed, new, gone or volatile)
	whole:     Damage_Whole,
	ms:        f32,            // what working out the region took at end_frame
	px_drawn:  int,            // pixels the renderer drew on the window (the whole window when it drew the whole frame)
	px_window: int,            // pixels of the window
}

// Frees the memory (the program's, at the end of its window).
damage_memory_destroy :: proc(m: ^Damage_Memory) {
	delete(m.parts)
	delete(m.next)
	m^ = {}
}

// The memory forgets its frame: the next frame with damage_auto is whole.
damage_memory_reset :: proc(m: ^Damage_Memory) { m.valid = false }

// This frame's damage is worked out at end_frame by comparing its parts with `memory`, which then holds this frame. Call it
// after begin_frame, with one memory a frame (two trees drawn in one frame share one memory: a second memory would replace
// the first, which would keep its old frame). Nothing happens while partial redraw is off (set_partial_redraw), but the
// memory forgets its frame.
damage_auto :: proc(c: ^Context, memory: ^Damage_Memory) {
	assert(c.auto_memory == nil || c.auto_memory == memory, "draw.damage_auto: a second memory in one frame")
	c.auto_memory = memory
}

// What is drawn from now on belongs to span `id` until the matching damage_span_end (spans nest; content between two children
// belongs to their parent). The same id twice in a frame is one span.
damage_span_begin :: proc(c: ^Context, id: u64) {
	if c.auto_memory == nil { return }
	append(&c.span_stack, id)
	span_cut(c)
}

// Ends the span begun last.
damage_span_end :: proc(c: ^Context) {
	if c.auto_memory == nil || len(c.span_stack) == 0 { return }
	pop(&c.span_stack)
	span_cut(c)
}

// The span being drawn changes its pixels with no instance changing (a texture written outside the renderer, a shader reading
// what it is not given): each of its parts is redrawn every frame.
damage_volatile :: proc(c: ^Context) {
	if c.auto_memory == nil { return }
	append(&c.span_volatile, len(c.span_stack) > 0 ? c.span_stack[len(c.span_stack) - 1] : 0)
}

// This frame is damaged whole (something changed that no instance shows).
damage_whole :: proc(c: ^Context) { c.auto_whole = true }

// Where what is drawn into a layer shows.
@(private)
Layer_Shows :: enum u8 {
	Screen,    // its texels are screen pixels at its origin (a layer of effects, a mask)
	Never,     // read back, never composited (an offscreen target): it reaches no screen pixel
	Unknown,   // composited through a homography (a plane): damage_auto makes the frame whole
}

// Where a layer's content can show (by layer id - 1): recorded by layer_add, read by the digest.
@(private)
Layer_Reach :: struct {
	parent:  int,           // the target it is composited into (a mask layer: its content layer)
	shows:   Layer_Shows,
	spreads: bool,          // filters move its pixels (a blur, a shadow): its content reaches all of `shown`
	shown:   Rect,          // where its result was composited (composite_layer), else its own region
}

// Adds a target to the frame's layers with where its content shows, the two side by side: its layer id.
@(private)
layer_add :: proc(c: ^Context, layer: render.Layer, reach: Layer_Reach) -> int {
	append(&c.layers, layer)
	append(&c.layer_reach, reach)
	return len(c.layers)
}

// A point from which what is drawn belongs to span `id`.
@(private)
Span_Cut :: struct {
	id:    u64,
	insts: int,   // len(insts) there
	batch: int,   // the open batch there
}

@(private)
span_cut :: proc(c: ^Context) {
	if c.rec != nil { return }   // (a picture being recorded: its instances are not the frame's)
	id := len(c.span_stack) > 0 ? c.span_stack[len(c.span_stack) - 1] : 0
	append(&c.span_cuts, Span_Cut{id = id, insts = len(c.insts), batch = len(c.batches) - 1})
}

// Mixed in between the segments of a part: the same content cut differently around a child that drew nothing is another
// order of drawing.
@(private = "file") SEGMENT_MARK :: 0x9e3779b97f4a7c15
// What a texture made by this frame (a layer, a filter result) hashes as: its pixels are those of the spans drawn into it.
@(private = "file") FRAME_MADE :: 0x51ed270b2f1e6c3d
// Instances reach this far past their rectangle (antialiasing, the rounding of the region); under a transform the quad grows a
// pixel more.
@(private = "file") REACH_PX :: 1
@(private = "file") REACH_TRANSFORMED_PX :: 2
@(private = "file") EMPTY_RECT :: Rect{{RECT_UNBOUNDED, RECT_UNBOUNDED}, {-RECT_UNBOUNDED, -RECT_UNBOUNDED}}

@(private = "file")
Digest :: struct {
	c:        ^Context,
	made:     []bool,    // by texture id: made by this frame
	clips:    []u64,     // by clip table index: the hash of the shape and its parents (0: not yet)
	app_end:  []int,     // by app draw index: where its parameters end
	batches:  []u64,     // by batch index: batch_hash (0: not yet; the segments of one batch share it)
	hidden:   []bool,    // by target (layer id): never shown, in an offscreen target (what is drawn there decides no pixel)
	whole:    Damage_Whole,
}

// At end_frame, before the frame is submitted: builds the region from the parts (see the top of this file).
@(private)
damage_auto_finish :: proc(c: ^Context) {
	t0 := time.tick_now()
	m := c.auto_memory
	c.auto_memory = nil
	r := c.renderer
	if !render.partial_redraw(r) {
		m.valid = false
		m.stats = {whole = .First}
		return
	}
	d := Digest{c = c, whole = .No}
	if !m.valid { d.whole = .First }
	env := draw_environment(c)
	if d.whole == .No && env != m.environment { d.whole = .Environment }
	if d.whole == .No && c.auto_whole { d.whole = .Asked }
	digest_prepare(&d)

	clear(&m.next)
	from := Span_Cut{}
	for k in 0 ..= len(c.span_cuts) {
		to := k < len(c.span_cuts) ? c.span_cuts[k] : Span_Cut{insts = len(c.insts), batch = len(c.batches) - 1}
		defer from = to
		if to.insts == from.insts && to.batch == from.batch { continue }
		h, bounds, volatile, drew := segment_digest(&d, from, to)
		if !drew { continue }
		// (a child that drew nothing leaves its parent one part)
		if n := len(m.next); n == 0 || m.next[n - 1].span != from.id { append(&m.next, Damage_Part{span = from.id, bounds = EMPTY_RECT}) }
		p := &m.next[len(m.next) - 1]
		p.hash = hash_mix(hash_mix(p.hash, SEGMENT_MARK), h)
		p.bounds = rect_union(p.bounds, bounds)
		p.volatile = p.volatile || volatile
	}
	if len(c.span_volatile) > 0 { parts_volatile(m.next[:], c.span_volatile[:]) }

	if !render.damage_building(r) { render.damage_begin(r) }
	changed := 0
	if d.whole == .No { changed, d.whole = parts_compare(c, m.parts[:], m.next[:]) }
	if d.whole != .No {
		damage(c, {{0, 0}, c.size})
		changed = len(m.next)
	}

	m.parts, m.next = m.next, m.parts
	m.environment = env
	m.valid = true
	m.stats = {parts = len(m.parts), changed = changed, whole = d.whole, ms = f32(time.duration_milliseconds(time.tick_since(t0)))}
	// a kept target drawn into now holds this frame's pixels (texture_ident)
	for l in c.layers {
		if l.tex <= 0 { continue }
		for len(c.target_frames) <= int(l.tex) { append(&c.target_frames, 0) }
		c.target_frames[l.tex] = c.frame_no
	}
}

// After the frame was submitted: what the renderer drew on the window (the memory's stats, so that each window has its own).
@(private)
damage_auto_drawn :: proc(c: ^Context, m: ^Damage_Memory) {
	if !render.partial_redraw(c.renderer) { return }
	_, _, px_region, px_frame, active := render.damage_stats(c.renderer)
	m.stats.px_drawn = active ? px_region : px_frame
	m.stats.px_window = px_frame
}

// Every part of a span that called damage_volatile is redrawn every frame.
@(private = "file")
parts_volatile :: proc(parts: []Damage_Part, spans: []u64) {
	set := make(map[u64]struct{}, len(spans), context.temp_allocator)
	for id in spans { set[id] = {} }
	for &p in parts { if p.span in set { p.volatile = true } }
}

// Damages what differs between the last frame's parts and this frame's: the parts of the same span at the same place in both
// orders are compared in a line from the start and from the end; the rest, by span and rank among its parts there. `Order`:
// the parts both frames drew are not in the same order (one may now lie above another it was under).
@(private = "file")
parts_compare :: proc(c: ^Context, old, cur: []Damage_Part) -> (changed: int, whole: Damage_Whole) {
	n := min(len(old), len(cur))
	head := 0
	for head < n && old[head].span == cur[head].span {
		changed += part_damage(c, old[head], cur[head])
		head += 1
	}
	tail := 0
	for tail < n - head && old[len(old) - 1 - tail].span == cur[len(cur) - 1 - tail].span {
		changed += part_damage(c, old[len(old) - 1 - tail], cur[len(cur) - 1 - tail])
		tail += 1
	}
	old_mid, cur_mid := old[head:len(old) - tail], cur[head:len(cur) - tail]
	if len(old_mid) == 0 || len(cur_mid) == 0 {
		for p in old_mid { changed += 1; damage_bounds(c, p.bounds) }
		for p in cur_mid { changed += 1; damage_bounds(c, p.bounds) }
		return changed, .No
	}
	// (the rank of a part among its span's parts counts from `head`: the same in both frames, their heads being the same spans)
	Key :: struct { span: u64, rank: int }
	ranks := make(map[u64]int, len(old_mid), context.temp_allocator)
	where_old := make(map[Key]int, len(old_mid), context.temp_allocator)
	for p, i in old_mid {
		k := Key{p.span, ranks[p.span]}
		ranks[p.span] = k.rank + 1
		where_old[k] = i
	}
	clear(&ranks)
	matched := make([]bool, len(old_mid), context.temp_allocator)
	last := -1
	for p in cur_mid {
		k := Key{p.span, ranks[p.span]}
		ranks[p.span] = k.rank + 1
		i, had := where_old[k]
		if !had {
			changed += 1
			damage_bounds(c, p.bounds)
			continue
		}
		if i < last { return changed, .Order }
		last = i
		matched[i] = true
		changed += part_damage(c, old_mid[i], p)
	}
	for p, i in old_mid {
		if matched[i] { continue }
		changed += 1
		damage_bounds(c, p.bounds)
	}
	return changed, .No
}

// One part in both frames: where it was and where it is, when it changed (1) or not (0).
@(private = "file")
part_damage :: proc(c: ^Context, old, cur: Damage_Part) -> int {
	if !cur.volatile && !old.volatile && old.hash == cur.hash && old.bounds == cur.bounds { return 0 }
	damage_bounds(c, old.bounds)
	damage_bounds(c, cur.bounds)
	return 1
}

@(private = "file")
damage_bounds :: proc(c: ^Context, b: Rect) {
	if rect_empty(b) { return }
	damage(c, b)
}

// What shapes the pixels of every span besides its instances, on the side of draw: the size, the font settings (and the glyph
// rasters they make), the device.
@(private = "file")
draw_environment :: proc(c: ^Context) -> u64 {
	h := hash_f32(hash_f32(0, c.size.x), c.size.y)
	h = hash_mix(h, c.device_generation)
	if c.fonts != nil {
		st := c.fonts.settings
		for w in transmute([size_of(font.Settings)]u8)st { h = hash_mix(h, u64(w)) }
		h = hash_mix(h, font.atlas_settings_generation(c.fonts))
	}
	return h
}

// What the whole frame has: which textures it makes, the hashes of its clip shapes, where each app draw's parameters end, and
// whether it does what makes the frame whole.
@(private = "file")
digest_prepare :: proc(d: ^Digest) {
	c := d.c
	top := 0
	for l in c.layers { top = max(top, int(l.tex)) }
	for op in c.ops {
		top = max(top, int(op.dst))
		if op.kind == .Pass { top = max(top, int(op.pass.dst.tex)) }
	}
	d.made = make([]bool, top + 1, context.temp_allocator)
	for l in c.layers { if l.tex > 0 { d.made[l.tex] = true } }
	for op in c.ops {
		if op.dst > 0 { d.made[op.dst] = true }
		if op.kind == .Pass && op.pass.dst.tex > 0 { d.made[op.pass.dst.tex] = true }
		// (a .Read, the readback of an offscreen target, reads no pixel of the window)
		if op.kind == .Copy && d.whole == .No { d.whole = .Reads_Itself }
	}
	d.hidden = make([]bool, len(c.layer_reach) + 1, context.temp_allocator)
	for lr, k in c.layer_reach {
		if lr.shows == .Unknown && d.whole == .No { d.whole = .Plane }
		// (a layer's parent is made before it: its id is smaller)
		d.hidden[k + 1] = lr.shows == .Never || (lr.parent > 0 && lr.parent <= k && d.hidden[lr.parent])
	}
	d.clips = make([]u64, len(c.clip_table), context.temp_allocator)
	d.app_end = make([]int, len(c.apps), context.temp_allocator)
	d.batches = make([]u64, len(c.batches), context.temp_allocator)
	// (an app draw's parameters run to the next one's first: their instances are in the order of `apps`)
	last := -1
	for b in c.batches {
		if b.app <= 0 { continue }
		first := int(c.insts[b.first].aux)
		if last >= 0 { d.app_end[last] = first }
		last = b.app - 1
	}
	if last >= 0 { d.app_end[last] = len(c.app_params) }
}

// The digest of what was drawn between two cuts: its hash, the screen rectangle it can reach, whether it is redrawn every frame,
// and whether it drew anything.
@(private = "file")
segment_digest :: proc(d: ^Digest, from, to: Span_Cut) -> (h: u64, bounds: Rect, volatile, drew: bool) {
	c := d.c
	bounds = EMPTY_RECT
	for bi in max(from.batch, 0) ..= min(to.batch, len(c.batches) - 1) {
		b := c.batches[bi]
		// (drawn into an offscreen target: read back, never shown; its steps are left in, they do not change with what it holds)
		if b.op == 0 && b.target > 0 && b.target < len(d.hidden) && d.hidden[b.target] { continue }
		if b.op > 0 || b.replay > 0 || b.app > 0 {
			// (a step is the segment's that added it: the batch open at its start is not one)
			if bi == from.batch { continue }
			drew = true
			switch {
			case b.op > 0:
				h = hash_mix(h, op_hash(d, c.ops[b.op - 1]))
			case b.replay > 0:
				// a picture: compared when its replay asked (replay's `compare`: what decides its pixels is its ident, its
				// outer clip and its batches' state), else redrawn where it lands
				ident := b.replay - 1 < len(c.replay_idents) ? c.replay_idents[b.replay - 1] : 0
				if ident == 0 {
					volatile = true
				} else {
					h = hash_mix(h, ident)
					h = hash_mix(h, clip_hash(d, c.replays[b.replay - 1].outer))
				}
				h = hash_mix(h, batch_hash(d, bi))
				bounds = rect_union(bounds, reach(d, scissor_of(b), b.target))
			case b.app > 0:
				h = hash_mix(h, batch_hash(d, bi))
				h = hash_mix(h, app_hash(d, b.app - 1, int(c.insts[b.first].aux)))
				h, bounds = inst_digest(d, b, b.first, h, bounds)
			}
			continue
		}
		lo, hi := max(b.first, from.insts), min(b.first + b.count, to.insts)
		if hi <= lo { continue }
		drew = true
		h = hash_mix(h, batch_hash(d, bi))
		for i in lo ..< hi { h, bounds = inst_digest(d, b, i, h, bounds) }
	}
	return
}

@(private = "file")
scissor_of :: proc(b: render.Batch) -> Rect { return {{b.clip[0], b.clip[1]}, {b.clip[2], b.clip[3]}} }

// One instance into the hash, with what its indices point to, and its reach into the bounds.
@(private = "file")
inst_digest :: proc(d: ^Digest, b: render.Batch, i: int, h0: u64, bounds0: Rect) -> (h: u64, bounds: Rect) {
	c := d.c
	inst := &c.insts[i]
	xf := inst.xform
	h = h0
	if xf > 0 && int(xf) < len(c.xform_table) {
		for v in c.xform_table[xf].m { h = hash_f32(h, v) }
	}
	h = hash_mix(h, clip_hash(d, inst.clip))
	aux := inst.aux
	if int(inst.use_tex) == render.KIND_GRADIENT && int(aux) < len(c.grads) {
		head := transmute([4]u32)c.grads[aux]
		end := min(int(aux) + render.GRAD_HEADER + 2 * int(head[3]), len(c.grads))
		for e in c.grads[aux:end] { for v in e { h = hash_f32(h, v) } }
		aux = 0
	} else if int(inst.use_tex) == render.KIND_APP {
		aux = 0   // (its parameters are in app_hash)
	}
	// (read in place, not copied: the words before the indices, then the flags and aux; the indices are hashed by what they
	// point to, above)
	words := ([^]u64)(inst)[:INST_HEAD_WORDS]
	h = hash_mix(h, hash_words(words))
	h = hash_mix(h, u64(inst.flags) | u64(aux) << 32)

	r: Rect
	switch {
	case inst.flags & render.FLAG_PROJECT != 0:
		r = scissor_of(b)   // (through a homography: anywhere in its scissor)
	case xf > 0 && int(xf) < len(c.xform_table):
		m := c.xform_table[xf].m
		r = rect_pad(affine_bounds(Affine{m[0], m[1], m[2], m[3], m[4], m[5]}, inst_rect(inst.dst)), REACH_TRANSFORMED_PX)
	case:
		r = rect_pad(inst_rect(inst.dst), REACH_PX)
	}
	r = rect_intersect(r, scissor_of(b))
	if rect_empty(r) { return h, bounds0 }
	return h, rect_union(bounds0, reach(d, r, b.target))
}

// An instance's words before its indices (xform, clip), then flags and aux: all of it.
@(private = "file") INST_HEAD_WORDS :: offset_of(render.Rect_Inst, xform) / 8
#assert(offset_of(render.Rect_Inst, xform) % 8 == 0 && offset_of(render.Rect_Inst, clip) == offset_of(render.Rect_Inst, xform) + 4)
#assert(offset_of(render.Rect_Inst, flags) == offset_of(render.Rect_Inst, clip) + 4 && offset_of(render.Rect_Inst, aux) == offset_of(render.Rect_Inst, flags) + 4)
#assert(size_of(render.Rect_Inst) == offset_of(render.Rect_Inst, aux) + 4)

// Words hashed in four lanes, then the lanes together: a lane's multiplications do not wait for the others' (one chain made
// the hash of 20,000 instances most of what damage_auto costs).
@(private = "file")
hash_words :: #force_inline proc(w: []u64) -> u64 {
	lanes := [4]u64{0x243f6a8885a308d3, 0x13198a2e03707344, 0xa4093822299f31d0, 0x082efa98ec4e6c89}
	i := 0
	for ; i + 4 <= len(w); i += 4 {
		lanes[0] = hash_mix(lanes[0], w[i])
		lanes[1] = hash_mix(lanes[1], w[i + 1])
		lanes[2] = hash_mix(lanes[2], w[i + 2])
		lanes[3] = hash_mix(lanes[3], w[i + 3])
	}
	for ; i < len(w); i += 1 { lanes[0] = hash_mix(lanes[0], w[i]) }
	return hash_mix(hash_mix(hash_mix(lanes[0], lanes[1]), lanes[2]), lanes[3])
}

@(private = "file")
inst_rect :: proc(dst: [4]f32) -> Rect {
	return {{min(dst[0], dst[2]), min(dst[1], dst[3])}, {max(dst[0], dst[2]), max(dst[1], dst[3])}}
}

// Where `r`, drawn into `target`, shows on the screen: cut by each layer around it, all of a layer whose filters spread it.
@(private = "file")
reach :: proc(d: ^Digest, r: Rect, target: int) -> Rect {
	c := d.c
	out := r
	for t, steps := target, 0; t > 0 && t <= len(c.layer_reach) && steps <= len(c.layer_reach); steps += 1 {
		lr := c.layer_reach[t - 1]
		switch lr.shows {
		case .Screen:
		case .Never:   return EMPTY_RECT
		case .Unknown: return {{0, 0}, c.size}
		}
		if lr.spreads {
			out = lr.shown
		} else {
			out = rect_intersect(out, lr.shown)
			if rect_empty(out) { return EMPTY_RECT }
		}
		t = lr.parent
	}
	return out
}

// A batch's state: its scissor, textures and target.
@(private = "file")
batch_hash :: proc(d: ^Digest, bi: int) -> u64 {
	if d.batches[bi] != 0 { return d.batches[bi] }
	c := d.c
	b := &c.batches[bi]
	h := hash_mix(0, 0xb47c)
	for v in b.clip { h = hash_f32(h, v) }
	h = hash_mix(h, glyph_ident(d, b.tex))
	h = hash_mix(h, glyph_ident(d, b.image))
	h = hash_mix(h, texture_ident(d, b.backdrop))
	h = hash_mix(h, target_ident(c, b.target))
	if h == 0 { h = 1 }
	d.batches[bi] = h
	return h
}

// A glyph page is written as glyphs come; a glyph already drawn keeps its texels: its instance (where on the page) is what
// tells it. Any other texture: texture_ident.
@(private = "file")
glyph_ident :: proc(d: ^Digest, t: render.Texture) -> u64 {
	if t == 0 { return 0 }
	if t == d.c.atlas || glyph_page_of(d.c, t) >= 0 { return hash_mix(0x6c79, u64(t)) }
	return texture_ident(d, t)
}

// What a texture's texels are: made by this frame (they come from its spans), else the texture and its version (an upload,
// or the last frame that drew into a kept target).
@(private = "file")
texture_ident :: proc(d: ^Digest, t: render.Texture) -> u64 {
	if t <= 0 { return 0 }
	if int(t) < len(d.made) && d.made[t] { return FRAME_MADE }
	h := hash_mix(hash_mix(0x7e47, u64(t)), render.texture_version(d.c.renderer, t))
	if int(t) < len(d.c.target_frames) { h = hash_mix(h, d.c.target_frames[t]) }
	return h
}

// A target as its place on the screen (its index changes when a span before it draws another number of layers).
@(private = "file")
target_ident :: proc(c: ^Context, target: int) -> u64 {
	if target <= 0 || target > len(c.layers) { return 0 }
	l := c.layers[target - 1]
	h := hash_mix(0x1a7e, u64(l.space))
	h = hash_f32(hash_f32(h, l.origin.x), l.origin.y)
	return hash_mix(hash_mix(h, u64(l.size.x)), u64(l.size.y))
}

// A clip shape and the ones around it.
@(private = "file")
clip_hash :: proc(d: ^Digest, index: u32) -> u64 {
	c := d.c
	if index == 0 || int(index) >= len(c.clip_table) { return 0 }
	if d.clips[index] != 0 { return d.clips[index] }
	cd := c.clip_table[index]
	parent := cd.parent < index ? clip_hash(d, cd.parent) : 0   // (a parent comes first: no loop)
	cd.parent = 0
	h := hash_mix(0xc11b, parent)
	for w in transmute([size_of(render.Clip_Data) / 8]u64)cd { h = hash_mix(h, w) }
	if cd.kind == render.CLIP_POLYGON {
		end := min(int(cd.first + cd.count), len(c.clip_points))
		for p in c.clip_points[min(int(cd.first), end):end] { h = hash_f32(hash_f32(h, p.x), p.y) }
	}
	if h == 0 { h = 1 }
	d.clips[index] = h
	return h
}

// A step: what it does, with its textures as texture_ident and its targets as target_ident.
@(private = "file")
op_hash :: proc(d: ^Digest, op: render.Op) -> u64 {
	c := d.c
	o := op
	h := hash_mix(0x0b5e, u64(o.kind))
	h = hash_mix(h, texture_ident(d, o.dst))
	h = hash_mix(h, target_ident(c, o.source))
	for v in o.box { h = hash_mix(h, u64(u32(v))) }
	if o.kind == .Pass {
		p := o.pass
		h = hash_mix(h, texture_ident(d, p.src.tex))
		h = hash_mix(h, texture_ident(d, p.src2.tex))
		h = hash_mix(h, texture_ident(d, p.dst.tex))
		p.src.tex, p.src2.tex, p.dst.tex = 0, 0, 0
		for w in transmute([size_of(render.Pass)]u8)p { h = hash_mix(h, u64(w)) }
	}
	return h
}

// An app draw: its shader, blend, textures and parameters.
@(private = "file")
app_hash :: proc(d: ^Digest, k, first: int) -> u64 {
	c := d.c
	a := c.apps[k]
	h := hash_mix(hash_mix(0xa995, u64(a.shader)), u64(a.blend))
	for t in a.textures { h = hash_mix(h, texture_ident(d, t)) }
	end := k < len(d.app_end) ? d.app_end[k] : len(c.app_params)
	for p in c.app_params[min(first, end):end] { for v in p { h = hash_f32(h, v) } }
	return h
}
