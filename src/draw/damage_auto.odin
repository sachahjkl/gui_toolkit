package draw

import "../font"
import "../render"

// Automatic damage: the region of a frame worked out from what it draws, with nothing marked by hand.
//
// A program labels what it draws with spans (damage_span_begin / damage_span_end, nested: a box and its children). At
// end_frame the instances, batches and steps of each span are reduced to a digest: a hash of everything that decides their
// pixels (the instance with its transform, clip shape and gradient resolved, the scissor, the textures and their versions, the
// layer they are drawn into) and the screen bounds they can touch. The digests are compared with the last frame's (a
// Damage_Memory the program keeps per window): a span whose digest differs is damaged where it was and where it is now, a new
// span where it is, a gone span where it was. A custom draw needs nothing more: what it draws is in the digest.
//
// What no instance shows makes the whole frame: the first frame, another size, other font settings, another device, a frame
// that copies its own target (backdrops, blend modes), an offscreen layer or a plane, spans drawn in another order (a box raised
// above another), and damage_whole. The renderer adds its own (render.damage_environment: the clear colour, the blend space,
// text and corner settings). A picture replayed (draw.replay) is drawn where it lands every frame: its content is not compared.
// A span that calls damage_volatile is redrawn every frame (pixels that change with no instance changing: a texture written
// outside the renderer).
//
// Usage, each frame, with partial redraw on (set_partial_redraw):
//   draw.begin_frame(dc, size)
//   draw.damage_auto(dc, &memory)        the memory of this window, kept between frames
//   draw.damage_span_begin(dc, id) ... draw.damage_span_end(dc)   as many as there are things that change apart
//   draw.end_frame(dc)                   the region is built here and the frame submitted
// Content outside every span belongs to span 0. A region begun by hand (damage_begin, damage) is kept and added to.

// What a program keeps of its last frame for damage_auto: one per window (per renderer surface).
Damage_Memory :: struct {
	spans:       map[u64]Damage_Span,   // the last frame's spans, by id
	order:       [dynamic]u64,          // their ids in the order their parts were drawn (a repeat in a row dropped)
	environment: u64,                   // draw_environment of that frame
	valid:       bool,                  // the memory holds a frame drawn with damage_auto: false makes the next frame whole
	stats:       Damage_Auto_Stats,     // the last frame's
}

// What a span drew: the hash of what decides its pixels and the screen rectangle they can reach (empty: nothing visible).
Damage_Span :: struct {
	hash:     u64,
	bounds:   Rect,
	volatile: bool,   // redrawn every frame (damage_volatile, a picture replayed)
}

// Why a frame was damaged whole (Damage_Auto_Stats.whole).
Damage_Whole :: enum u8 {
	No,            // a region of the spans that changed
	First,         // nothing to compare with: the first frame, or partial redraw was off
	Environment,   // another size, font settings or device
	Asked,         // damage_whole
	Reads_Itself,  // a copy of a target (a backdrop, a blend mode)
	Offscreen,     // drawing into an offscreen layer or a plane: where it shows is not known
	Order,         // spans drawn in another order
}

// One frame of damage_auto, for diagnostics and tests.
Damage_Auto_Stats :: struct {
	spans:   int,            // spans that drew something
	changed: int,            // spans damaged (changed, new, gone or volatile)
	whole:   Damage_Whole,
}

// Frees the memory (the program's, at the end of its window).
damage_memory_destroy :: proc(m: ^Damage_Memory) {
	delete(m.spans)
	delete(m.order)
	m^ = {}
}

// The memory forgets its frame: the next frame with damage_auto is whole.
damage_memory_reset :: proc(m: ^Damage_Memory) { m.valid = false }

// This frame's damage is worked out at end_frame by comparing its spans with `memory`, which then holds this frame. Call it
// after begin_frame. Nothing happens while partial redraw is off (set_partial_redraw), but the memory forgets its frame.
damage_auto :: proc(c: ^Context, memory: ^Damage_Memory) {
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
// what it is not given): it is redrawn every frame.
damage_volatile :: proc(c: ^Context) {
	if c.auto_memory == nil { return }
	append(&c.span_volatile, len(c.span_stack) > 0 ? c.span_stack[len(c.span_stack) - 1] : 0)
}

// This frame is damaged whole (something changed that no instance shows).
damage_whole :: proc(c: ^Context) { c.auto_whole = true }

// Where a layer's content can show (by layer id - 1): recorded where layers are made, read by the digest.
@(private)
Layer_Reach :: struct {
	parent:  int,    // the target it is composited into (a mask layer: its content layer)
	screen:  bool,   // its texels are screen pixels at `origin` (not an offscreen layer or a plane)
	spreads: bool,   // filters move its pixels (a blur, a shadow): its content reaches all of `shown`
	shown:   Rect,   // where its result was composited (composite_layer), else its own region
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

@(private)
layer_reach_add :: proc(c: ^Context, parent: int, screen, spreads: bool, region: Rect) {
	append(&c.layer_reach, Layer_Reach{parent = parent, screen = screen, spreads = spreads, shown = region})
}

// Mixed in between the parts of a span: the same content cut differently around a child is another order of drawing.
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
	whole:    Damage_Whole,
}

// At end_frame, before the frame is submitted: builds the region from the spans (see the top of this file).
@(private)
damage_auto_finish :: proc(c: ^Context) {
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

	spans := make(map[u64]Damage_Span, len(m.spans) + 16, context.temp_allocator)
	order := make([dynamic]u64, context.temp_allocator)
	from := Span_Cut{}
	for k in 0 ..= len(c.span_cuts) {
		to := k < len(c.span_cuts) ? c.span_cuts[k] : Span_Cut{insts = len(c.insts), batch = len(c.batches) - 1}
		defer from = to
		if to.insts == from.insts && to.batch == from.batch { continue }
		h, bounds, volatile, drew := segment_digest(&d, from, to)
		if !drew { continue }
		sp := spans[from.id] or_else Damage_Span{bounds = EMPTY_RECT}
		sp.hash = hash_mix(hash_mix(sp.hash, SEGMENT_MARK), h)
		sp.bounds = rect_union(sp.bounds, bounds)
		sp.volatile = sp.volatile || volatile
		spans[from.id] = sp
		if len(order) == 0 || order[len(order) - 1] != from.id { append(&order, from.id) }
	}
	for id in c.span_volatile {
		if sp, ok := &spans[id]; ok { sp.volatile = true }
	}
	if d.whole == .No && !same_order(m, spans, order[:]) { d.whole = .Order }

	if !render.damage_building(r) { render.damage_begin(r) }
	changed := 0
	if d.whole != .No {
		damage(c, {{0, 0}, c.size})
		changed = len(spans)
	} else {
		for id, sp in spans {
			old, had := m.spans[id]
			if had && !sp.volatile && !old.volatile && old.hash == sp.hash && old.bounds == sp.bounds { continue }
			changed += 1
			if had { damage_bounds(c, old.bounds) }
			damage_bounds(c, sp.bounds)
		}
		for id, old in m.spans {
			if id in spans { continue }
			changed += 1
			damage_bounds(c, old.bounds)
		}
	}

	clear(&m.spans)
	for id, sp in spans { m.spans[id] = sp }
	clear(&m.order)
	append(&m.order, ..order[:])
	m.environment = env
	m.valid = true
	m.stats = {spans = len(spans), changed = changed, whole = d.whole}
	// a kept target drawn into now holds this frame's pixels (texture_ident)
	for l in c.layers {
		if l.tex <= 0 { continue }
		for len(c.target_frames) <= int(l.tex) { append(&c.target_frames, 0) }
		c.target_frames[l.tex] = c.frame_no
	}
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

// Whether the spans both frames drew come in the same order (new and gone ones aside): else one may now lie above another it
// was under, and pixels where neither changed differ.
@(private = "file")
same_order :: proc(m: ^Damage_Memory, spans: map[u64]Damage_Span, order: []u64) -> bool {
	a := make([dynamic]u64, context.temp_allocator)
	for id in m.order {
		if id not_in spans { continue }
		if len(a) == 0 || a[len(a) - 1] != id { append(&a, id) }
	}
	i := 0
	last: u64
	have := false
	for id in order {
		if id not_in m.spans { continue }
		if have && last == id { continue }
		if i >= len(a) || a[i] != id { return false }
		i += 1
		last, have = id, true
	}
	return i == len(a)
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
		if op.kind == .Copy && d.whole == .No { d.whole = .Reads_Itself }
	}
	for lr in c.layer_reach { if !lr.screen && d.whole == .No { d.whole = .Offscreen } }
	d.clips = make([]u64, len(c.clip_table), context.temp_allocator)
	d.app_end = make([]int, len(c.apps), context.temp_allocator)
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
		if b.op > 0 || b.replay > 0 || b.app > 0 {
			// (a step is the segment's that added it: the batch open at its start is not one)
			if bi == from.batch { continue }
			drew = true
			switch {
			case b.op > 0:
				h = hash_mix(h, op_hash(d, c.ops[b.op - 1]))
			case b.replay > 0:
				// a picture: its content is not compared, it is redrawn where it lands
				volatile = true
				h = hash_mix(h, batch_hash(d, b))
				bounds = rect_union(bounds, reach(d, scissor_of(b), b.target))
			case b.app > 0:
				h = hash_mix(h, batch_hash(d, b))
				h = hash_mix(h, app_hash(d, b.app - 1, int(c.insts[b.first].aux)))
				h, bounds = inst_digest(d, b, b.first, h, bounds)
			}
			continue
		}
		lo, hi := max(b.first, from.insts), min(b.first + b.count, to.insts)
		if hi <= lo { continue }
		drew = true
		h = hash_mix(h, batch_hash(d, b))
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
	inst := c.insts[i]
	xf, clip, aux := inst.xform, inst.clip, inst.aux
	inst.xform, inst.clip = 0, 0
	h = h0
	if xf > 0 && int(xf) < len(c.xform_table) {
		for v in c.xform_table[xf].m { h = hash_f32(h, v) }
	}
	h = hash_mix(h, clip_hash(d, clip))
	if int(inst.use_tex) == render.KIND_GRADIENT && int(aux) < len(c.grads) {
		head := transmute([4]u32)c.grads[aux]
		end := min(int(aux) + render.GRAD_HEADER + 2 * int(head[3]), len(c.grads))
		inst.aux = 0
		for e in c.grads[aux:end] { for v in e { h = hash_f32(h, v) } }
	} else if int(inst.use_tex) == render.KIND_APP {
		inst.aux = 0   // (its parameters are in app_hash)
	}
	for w in transmute([size_of(render.Rect_Inst) / 8]u64)inst { h = hash_mix(h, w) }

	r: Rect
	switch {
	case inst.flags & render.FLAG_PROJECT != 0:
		r = scissor_of(b)   // (through a homography: anywhere in its scissor)
	case xf > 0 && int(xf) < len(c.xform_table):
		m := c.xform_table[xf].m
		r = rect_pad(affine_bounds(Affine{m[0], m[1], m[2], m[3], m[4], m[5]}, inst_rect(inst)), REACH_TRANSFORMED_PX)
	case:
		r = rect_pad(inst_rect(inst), REACH_PX)
	}
	r = rect_intersect(r, scissor_of(b))
	if rect_empty(r) { return h, bounds0 }
	return h, rect_union(bounds0, reach(d, r, b.target))
}

@(private = "file")
inst_rect :: proc(inst: render.Rect_Inst) -> Rect {
	return {{min(inst.dst[0], inst.dst[2]), min(inst.dst[1], inst.dst[3])}, {max(inst.dst[0], inst.dst[2]), max(inst.dst[1], inst.dst[3])}}
}

// Where `r`, drawn into `target`, shows on the screen: cut by each layer around it, all of a layer whose filters spread it.
@(private = "file")
reach :: proc(d: ^Digest, r: Rect, target: int) -> Rect {
	c := d.c
	out := r
	for t, steps := target, 0; t > 0 && t <= len(c.layer_reach) && steps <= len(c.layer_reach); steps += 1 {
		lr := c.layer_reach[t - 1]
		if !lr.screen { return {{0, 0}, c.size} }
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
batch_hash :: proc(d: ^Digest, b: render.Batch) -> u64 {
	c := d.c
	h := hash_mix(0, 0xb47c)
	for v in b.clip { h = hash_f32(h, v) }
	h = hash_mix(h, glyph_ident(d, b.tex))
	h = hash_mix(h, glyph_ident(d, b.image))
	h = hash_mix(h, texture_ident(d, b.backdrop))
	h = hash_mix(h, target_ident(c, b.target))
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
