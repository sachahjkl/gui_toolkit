package draw

import "core:math"
import "../render"

// Filter results kept from frame to frame.
//
// A layer pushed with Layer_Effects.cache_id (or a backdrop captured with a cache id) whose content, filters, transform
// and size are the same as when its result was kept is not drawn again: push_effects returns false (the caller skips
// its content; whatever it draws anyway is discarded) and pop_layer composites the kept result, with the opacity, blend
// mode and trailing color matrices of this frame (they are applied by the composite, not kept). The content is what
// the caller says it is: `cache_key`, a signature of everything drawn in the layer, in a frame that moves with
// `cache_anchor` (a screen point). When the anchor moves by whole pixels (scrolling, a translation) the kept result is
// composited moved by as much, which is exact; a fractional move, a new transform (other than a translation), other
// filters or another key make it be drawn again. The toolkit adds to the key what it knows: the filters run by passes,
// the linear part of the transform (filter lengths follow it), the fractional part of the anchor, the bounds relative
// to the anchor, the blend space and the blur settings.
//
// A result is kept only after the same key was asked for two frames in a row (an animated filter or content is never
// kept: keeping costs a texture the pool cannot reuse). A layer of at most `max_px` pixels is then drawn whole, not cut
// to the visible area, so that scrolling it into view still finds it complete; a larger one is kept as drawn and
// reused while what is needed lies inside. Results not used for `idle_frames` frames are let go, and the least
// recently used go first when `budget` bytes would be exceeded. A lost device or an emptied pool drops everything.

Layer_Cache_Stats :: struct {
	hits, misses, stored, evicted: int,   // this frame
	entries, bytes: int,                  // kept now
}

@(private)
Kept_Image :: struct {
	key:     u64,
	img:     render.Image_Ref,   // origin relative to the anchor's whole pixels
	full:    [2]int,             // size at scale 1 of what img covers
	region:  Rect,               // screen region it holds, relative to the anchor's whole pixels
	used:    u64,                // frame_no of the last hit or store
	bytes:   int,
	seen_key: u64,               // the key asked for most recently (kept results need it twice in a row)
	seen_frame: u64,
}

Layer_Cache :: struct {
	entries:     map[u64]Kept_Image,
	budget:      int,     // bytes of kept textures (0: nothing is kept)
	max_px:      int,     // largest layer drawn whole to be kept
	idle_frames: int,
	targets_gen: u64,     // render.targets_generation the textures belong to
	stats:       Layer_Cache_Stats,   // this frame (entries and bytes: see layer_cache_stats)
	configured:  bool,
}

LAYER_CACHE_DEFAULT_BUDGET :: 64 << 20
LAYER_CACHE_DEFAULT_MAX_PX :: 4 << 20
LAYER_CACHE_DEFAULT_IDLE :: 600

// Budget of kept filter results in bytes (0 turns keeping off and lets everything go), the largest layer (pixels)
// drawn whole to be kept, and how many frames an unused result stays.
set_layer_cache :: proc(c: ^Context, budget_bytes: int, max_layer_px: int = LAYER_CACHE_DEFAULT_MAX_PX, idle_frames: int = LAYER_CACHE_DEFAULT_IDLE) {
	lc := &c.layer_cache
	lc.configured = true
	lc.budget, lc.max_px, lc.idle_frames = max(budget_bytes, 0), max(max_layer_px, 0), max(idle_frames, 1)
	if lc.budget == 0 { layer_cache_clear(c); return }
	cache_trim(c, 0, between_frames = true)
}

// What the cache did in the frame being drawn (or the last one drawn, between frames), and what it holds.
layer_cache_stats :: proc(c: ^Context) -> Layer_Cache_Stats {
	s := c.layer_cache.stats
	s.entries, s.bytes = 0, 0
	for _, e in c.layer_cache.entries {
		if e.img.tex != 0 { s.entries += 1; s.bytes += e.bytes }
	}
	return s
}

// Lets every kept result go.
layer_cache_clear :: proc(c: ^Context) {
	for _, &e in c.layer_cache.entries { cache_drop(c, &e) }
	clear(&c.layer_cache.entries)
}

// Lets the result kept under `id` go (an element that went away).
layer_cache_forget :: proc(c: ^Context, id: u64) {
	for k in ([2]u64{id, backdrop_cache_id(id)}) {
		if e, ok := &c.layer_cache.entries[k]; ok {
			cache_drop(c, e)
			delete_key(&c.layer_cache.entries, k)
		}
	}
}

@(private)
backdrop_cache_id :: proc(id: u64) -> u64 { return id == 0 ? 0 : hash_mix(id, 0x6261636b64726f70) }

@(private)
cache_drop :: proc(c: ^Context, e: ^Kept_Image) {
	if e.img.tex != 0 && c.layer_cache.targets_gen == render.targets_generation(c.renderer) { render.unkeep_target(c.renderer, e.img.tex) }
	e.img = {}
	e.bytes = 0
}

@(private)
cache_destroy :: proc(c: ^Context) {
	layer_cache_clear(c)
	delete(c.layer_cache.entries)
}

// Start of a frame: new numbers, results gone with the pool dropped, idle ones let go.
@(private)
cache_begin_frame :: proc(c: ^Context) {
	lc := &c.layer_cache
	if !lc.configured {
		lc.configured = true
		lc.budget, lc.max_px, lc.idle_frames = LAYER_CACHE_DEFAULT_BUDGET, LAYER_CACHE_DEFAULT_MAX_PX, LAYER_CACHE_DEFAULT_IDLE
	}
	if gen := render.targets_generation(c.renderer); gen != lc.targets_gen {
		// the textures are gone (device lost, pool released): forget them without handing them back
		for _, &e in lc.entries { e.img, e.bytes = {}, 0 }
		lc.targets_gen = gen
	}
	lc.stats = {}
	stale := make([dynamic]u64, 0, 8, context.temp_allocator)
	for id, &e in lc.entries {
		if e.img.tex != 0 && c.frame_no > e.used + u64(lc.idle_frames) { cache_drop(c, &e); lc.stats.evicted += 1 }
		if e.img.tex == 0 && c.frame_no > e.seen_frame + 2 { append(&stale, id) }
	}
	for id in stale { delete_key(&lc.entries, id) }
}

// Makes room for `want` more bytes, letting go of results not used this frame, least recently used first. false: no
// room (the budget is smaller, or what this frame uses already fills it).
@(private)
cache_trim :: proc(c: ^Context, want: int, between_frames := false) -> bool {
	lc := &c.layer_cache
	// during a frame, what it already composited stays (its texture is read later in the frame)
	limit := between_frames ? c.frame_no + 1 : c.frame_no
	for {
		total := 0
		oldest: ^Kept_Image
		for _, &e in lc.entries {
			if e.img.tex == 0 { continue }
			total += e.bytes
			if e.used < limit && (oldest == nil || e.used < oldest.used) { oldest = &e }
		}
		if total + want <= lc.budget { return true }
		if oldest == nil { return false }
		cache_drop(c, oldest)
		lc.stats.evicted += 1
	}
}

@(private)
hash_mix :: #force_inline proc(h, v: u64) -> u64 {
	x := (h ~ v) * 0x100000001B3
	return x ~ (x >> 29)
}

@(private)
hash_f32 :: #force_inline proc(h: u64, v: f32) -> u64 { return hash_mix(h, u64(transmute(u32)v)) }

// A position to 1/64 pixel.
@(private)
quantize :: #force_inline proc(v: f32) -> f32 { return math.round(v * 64) / 64 }

// The whole pixels of an anchor, and its fraction (to 1/64 pixel).
@(private)
anchor_split :: proc(a: Vec2) -> (whole: Vec2, frac: Vec2) {
	q := Vec2{quantize(a.x), quantize(a.y)}
	whole = {math.floor(q.x), math.floor(q.y)}
	return whole, q - whole
}

// What the toolkit adds to the caller's key: the filters run by passes, the transform's linear part, the anchor's
// fraction, the bounds relative to the anchor, the space and the blur settings.
@(private)
cache_full_key :: proc(c: ^Context, caller: u64, filters: []Filter, m: Affine, frac: Vec2, rel_bounds: Rect, space: render.Blend_Space) -> u64 {
	h := hash_mix(0x6c61796572636163, caller)
	h = hash_mix(h, u64(len(filters)))
	for f in filters {
		h = hash_mix(h, u64(f.kind))
		for v in f.cm { h = hash_f32(h, v) }
		h = hash_f32(h, f.sigma)
		h = hash_f32(hash_f32(h, f.offset.x), f.offset.y)
		for v in f.color { h = hash_f32(h, v) }
	}
	h = hash_f32(hash_f32(hash_f32(hash_f32(h, m.a), m.b), m.c), m.d)
	h = hash_f32(hash_f32(h, frac.x), frac.y)
	h = hash_f32(hash_f32(h, quantize(rel_bounds.min.x)), quantize(rel_bounds.min.y))
	h = hash_f32(hash_f32(h, quantize(rel_bounds.max.x)), quantize(rel_bounds.max.y))
	h = hash_mix(h, u64(space) | u64(render.filter_precision(c.renderer)) << 8)
	h = hash_f32(h, c.renderer.blur_sigma_limit)
	return h
}

// The decision for a layer or backdrop asking for its kept result: hit (composite it, moved to `whole`), or whether
// to keep what is drawn now.
@(private)
Cache_Ask :: struct {
	id, key: u64,
	whole:   Vec2,
	hit:     bool,
	img:     render.Image_Ref,   // hit: in screen pixels
	full:    [2]int,
	store:   bool,               // miss: keep the result made this frame
	result:  bool,               // what is kept is the blended pixels (Layer_Effects.cache_under), not the layer
}

@(private)
cache_ask :: proc(c: ^Context, id, key: u64, whole: Vec2, needed: Rect) -> Cache_Ask {
	lc := &c.layer_cache
	a := Cache_Ask{id = id, key = key, whole = whole}
	if lc.budget <= 0 || id == 0 { return a }
	e, ok := &lc.entries[id]
	if !ok {
		lc.entries[id] = Kept_Image{seen_key = key, seen_frame = c.frame_no}
		lc.stats.misses += 1
		return a
	}
	if e.used == c.frame_no || e.seen_frame == c.frame_no {
		// the same id twice in a frame: the caller's ids are not unique; keep nothing for it
		return a
	}
	need := Rect{needed.min - whole, needed.max - whole}
	if e.img.tex != 0 && e.key == key && rect_contains_rect(e.region, need) {
		e.used, e.seen_key, e.seen_frame = c.frame_no, key, c.frame_no
		a.hit = true
		a.img = e.img
		a.img.origin += whole
		a.full = e.full
		lc.stats.hits += 1
		return a
	}
	lc.stats.misses += 1
	a.store = e.seen_key == key && e.seen_frame + 1 == c.frame_no
	e.seen_key, e.seen_frame = key, c.frame_no
	return a
}

// Keeps `img` (a pooled texture written this frame, covering `region`) under the ask's id. false: not kept (no room,
// or not a pooled texture): the caller releases it as usual.
@(private)
cache_store :: proc(c: ^Context, a: Cache_Ask, img: render.Image_Ref, full: [2]int, region: Rect) -> bool {
	lc := &c.layer_cache
	if !a.store || img.tex == 0 { return false }
	e, ok := &lc.entries[a.id]
	if !ok { return false }
	ts := render.texture_size(c.renderer, img.tex)
	bytes := ts.x * ts.y * render.texture_bpp(c.renderer, img.tex)
	if e.img.tex != 0 { cache_drop(c, e) }
	if !cache_trim(c, bytes) { return false }
	e = &lc.entries[a.id]   // (trimming does not add entries, the pointer stays valid; read again for clarity)
	if !render.keep_target(c.renderer, img.tex) { return false }
	kept := img
	kept.origin -= a.whole
	e.key, e.img, e.full, e.bytes, e.used = a.key, kept, full, bytes, c.frame_no
	e.region = Rect{region.min - a.whole, region.max - a.whole}
	lc.stats.stored += 1
	return true
}

@(private)
rect_contains_rect :: proc(outer, inner: Rect) -> bool {
	if inner.max.x <= inner.min.x || inner.max.y <= inner.min.y { return true }
	return inner.min.x >= outer.min.x && inner.min.y >= outer.min.y && inner.max.x <= outer.max.x && inner.max.y <= outer.max.y
}
