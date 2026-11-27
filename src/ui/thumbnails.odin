package ui

// The thumbnails of a view's items (src/md/features/thumbnails.md): small pictures of files, asked by the cards that are
// built, made elsewhere (a file source, on its workers or on its server), kept as textures under a count and a byte
// budget. The owner calls, per build:
//
//   t := thumb_cache_get(&c, thumb_key(path, size, mtime), path)   // in each card built: nil until it is asked
//   if t != nil && t.state == .Ready { thumb_picture("###thumb", t) } else { icon(...) }
//   ...after the cards:
//   thumb_cache_frame(&c, ask, user)        // the asks sent, newest first; the least used dropped over the budget
//
// and gives each answer back: thumb_cache_answer(&c, ticket, rgba, w, h) or thumb_cache_failed(&c, ticket);
// thumb_cache_clear(&c) forgets what was made. All of it on the interface's thread. A texture is made at the first draw of its picture (the draw has the renderer).

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "../draw"
import "../render"

// The sides a thumbnail is asked at, in pixels: a card's size goes up to the next (the freedesktop cache's folders:
// normal, large, x-large, xx-large), so a card that grows a little asks nothing again.
THUMB_SIDE_STEPS :: [4]int{128, 256, 512, 1024}
// The defaults of Thumb_Options.
THUMB_SIDE_DEFAULT :: 256
THUMB_COUNT_DEFAULT :: 400
THUMB_BYTES_DEFAULT :: 48 << 20
THUMB_ASKS_DEFAULT :: 2
// A waiting ask whose card was not built for this many builds is dropped when its turn comes.
THUMB_STALE_FRAMES :: 3
// An entry asked in the last this many builds is never dropped (its card is on screen).
THUMB_KEEP_FRAMES :: 2
// A texture's bytes per pixel.
@(private = "file") THUMB_PIXEL_BYTES :: 4

Thumb_State :: enum u8 {
	Waiting,   // asked by a card, not sent yet
	Asked,     // sent: its answer is on its way
	Ready,     // its pixels or its texture
	Failed,    // none: the card keeps its icon
}

// One file's thumbnail. The pointer is valid until the cache drops it (thumb_cache_frame, or a clear applied at a later
// build's first thumb_cache_get): take it again each build.
Thumb :: struct {
	state:    Thumb_State,
	key:      string,             // (owned) the cache's key: thumb_key
	path:     string,             // (owned) what the ask names
	ticket:   u64,                // its ask: an answer of another is dropped
	used:     u64,                // the cache's frame it was last asked in
	size:     [2]int,             // Ready: its pixels' size
	pixels:   []u8,               // Ready, until its texture is made (heap)
	texture:  render.Texture,
	renderer: ^render.Renderer,   // the texture's
	refused:  bool,               // no texture could be made of it: it is not drawn
	side:     int,                // the side its pixels were asked at (Ready), or are being asked at
	want:     int,                // a card asks a larger side: asked while the smaller pixels stay shown (0: none)
	better:   bool,               // `want` is waiting or asked: the entry stays Ready meanwhile
}

// 0 for a field: its default.
Thumb_Options :: struct {
	side:       int,   // the longest side asked, in pixels (THUMB_SIDE_DEFAULT)
	most_count: int,   // entries kept (THUMB_COUNT_DEFAULT)
	most_bytes: int,   // the pixels of every thumbnail together (THUMB_BYTES_DEFAULT)
	asks:       int,   // asks out at a time (THUMB_ASKS_DEFAULT)
}

// How the cache sends an ask: the owner starts the work and answers with `ticket` (thumb_cache_answer or
// thumb_cache_failed), later or at once.
Thumb_Ask :: #type proc(user: rawptr, path: string, side: int, ticket: u64)

Thumb_Cache :: struct {
	// thumb_cache_init ran. (Not `entries == nil`: an empty map made with make has no storage yet and is nil, so that
	// test started the cache again at its first get, with the default options.)
	made:      bool,
	o:         Thumb_Options,
	frame:     u64,
	serial:    u64,
	entries:   map[string]^Thumb,   // by key (the keys are the entries')
	by_ticket: map[u64]^Thumb,      // the asks out
	waiting:   [dynamic]^Thumb,     // not sent yet, the last asked at the end
	held:      int,                 // the bytes of every Ready entry
	// thumb_cache_clear was called; when a card had taken an entry in that build (`clear_waits`), its draw may read it:
	// the entries go once the cache's frame is past `clear_frame`
	clear_due:   bool,
	clear_waits: bool,
	clear_frame: u64,
	got:         bool,              // a thumb_cache_get since the last thumb_cache_frame
	// what a test reads: the asks sent, and the waiting ones dropped as stale
	sent:      int,
	skipped:   int,
}

// The key of a file's thumbnail: its path, size and date (a file changed gets another), in temporary memory.
thumb_key :: proc(path: string, size, modified: i64) -> string { return fmt.tprintf("%s|%d|%d", path, size, modified) }

thumb_cache_init :: proc(c: ^Thumb_Cache, o := Thumb_Options{}) {
	a := runtime.heap_allocator()
	c^ = {made = true, o = o}
	if c.o.side <= 0 { c.o.side = THUMB_SIDE_DEFAULT }
	if c.o.most_count <= 0 { c.o.most_count = THUMB_COUNT_DEFAULT }
	if c.o.most_bytes <= 0 { c.o.most_bytes = THUMB_BYTES_DEFAULT }
	if c.o.asks <= 0 { c.o.asks = THUMB_ASKS_DEFAULT }
	c.entries = make(map[string]^Thumb, a)
	c.by_ticket = make(map[u64]^Thumb, a)
	c.waiting = make([dynamic]^Thumb, a)
}

// Every entry and texture freed. Asks still out answer nothing (their tickets are no longer known): call it when no
// draw reads the entries any more (ui.destroy).
thumb_cache_destroy :: proc(c: ^Thumb_Cache) {
	for _, t in c.entries { thumb_free(t) }
	delete(c.entries)
	delete(c.by_ticket)
	delete(c.waiting)
	c^ = {}
}

// The side a card of `px` pixels asks: the step at or above it (THUMB_SIDE_STEPS), the largest at most.
thumb_side_step :: proc(px: f32) -> int {
	steps := THUMB_SIDE_STEPS
	for s in steps { if f32(s) >= px { return s } }
	return steps[len(steps) - 1]
}

// The entry of `key` (thumb_key) for a card built now: Ready, Failed, or on its way (asked at the next
// thumb_cache_frame, newest first). `path` is what the ask names (copied the first time). `px`: the card's picture's
// longer side in pixels (0: the cache's side); a Ready entry asked at a smaller step is asked again at the card's, its
// pixels shown until the new ones come. Marks it used in this build.
thumb_cache_get :: proc(c: ^Thumb_Cache, key, path: string, px: f32 = 0) -> ^Thumb {
	if !c.made { thumb_cache_init(c) }
	thumb_cache_cleared(c)
	c.got = true
	side := px > 0 ? thumb_side_step(px) : c.o.side
	// (a waiting entry asked again keeps its place in the stack: moving it would be a search per card per build; the
	// stale ones above it are dropped when their turn comes)
	if t, ok := c.entries[key]; ok {
		t.used = c.frame
		if t.state == .Ready && !t.better && side > t.side {
			t.want, t.better = side, true
			append(&c.waiting, t)
		} else if t.state == .Waiting && side > t.side {
			t.side = side   // (not sent yet: it goes at the larger side)
		}
		return t
	}
	a := runtime.heap_allocator()
	t := new(Thumb, a)
	t^ = {state = .Waiting, key = strings.clone(key, a), path = strings.clone(path, a), used = c.frame, side = side}
	c.entries[t.key] = t
	append(&c.waiting, t)
	return t
}

// The pixels of the ask `ticket`: `rgba` (straight RGBA8, row by row, w * h * 4 bytes) is copied. An unknown ticket (an
// entry dropped since) is ignored.
thumb_cache_answer :: proc(c: ^Thumb_Cache, ticket: u64, rgba: []u8, w, h: int) {
	t, ok := c.by_ticket[ticket]
	if !ok { return }
	delete_key(&c.by_ticket, ticket)
	if w <= 0 || h <= 0 || len(rgba) < w * h * THUMB_PIXEL_BYTES {
		if t.better { thumb_better_end(t); return }   // (the smaller pixels stay)
		t.state = .Failed
		return
	}
	a := runtime.heap_allocator()
	if t.better {
		// (the larger pixels take the smaller ones' place; the texture is made again at the next draw)
		c.held -= thumb_bytes(t)
		if t.texture != 0 && t.renderer != nil { render.destroy_texture(t.renderer, t.texture) }
		t.texture, t.renderer, t.refused = 0, nil, false
		delete(t.pixels, a)
		t.side = t.want
		thumb_better_end(t)
	}
	t.pixels = make([]u8, w * h * THUMB_PIXEL_BYTES, a)
	copy(t.pixels, rgba)
	t.size, t.state = {w, h}, .Ready
	c.held += len(t.pixels)
	// (the card that asked shows it at the next build)
	if s := current; s != nil { s.pointer_only = false }
}

// The ask `ticket` has no thumbnail: its card keeps its icon (and does not ask again until the entry is dropped).
thumb_cache_failed :: proc(c: ^Thumb_Cache, ticket: u64) {
	t, ok := c.by_ticket[ticket]
	if !ok { return }
	delete_key(&c.by_ticket, ticket)
	if t.better {
		// (no larger one: the smaller one stays, and it is not asked again at that side)
		t.side = t.want
		thumb_better_end(t)
		return
	}
	t.state = .Failed
}

// A larger ask of a Ready entry is over (answered or not).
@(private = "file")
thumb_better_end :: proc(t: ^Thumb) { t.want, t.better, t.ticket = 0, false, 0 }

// After the cards of a build: the waiting asks sent, the newest first, while fewer than `asks` are out (a waiting one
// whose card was not built lately is dropped instead); then, over the budget, the entries used least lately dropped.
// The cache's frame moves on.
thumb_cache_frame :: proc(c: ^Thumb_Cache, ask: Thumb_Ask, user: rawptr) {
	if !c.made { thumb_cache_init(c) }
	thumb_cache_cleared(c)
	for len(c.waiting) > 0 && len(c.by_ticket) < c.o.asks {
		t := pop(&c.waiting)
		if t.better {
			// (a larger side for a Ready entry: it stays Ready, its ticket maps it while the ask is out)
			if t.used + THUMB_STALE_FRAMES < c.frame { thumb_better_end(t); continue }
			c.serial += 1
			t.ticket = c.serial
			c.by_ticket[t.ticket] = t
			c.sent += 1
			ask(user, strings.clone(t.path, context.temp_allocator), t.want, t.ticket)
			continue
		}
		if t.used + THUMB_STALE_FRAMES < c.frame {
			// (scrolled past: its card asks again if it comes back)
			delete_key(&c.entries, t.key)
			thumb_free(t)
			c.skipped += 1
			continue
		}
		c.serial += 1
		t.ticket, t.state = c.serial, .Asked
		c.by_ticket[t.ticket] = t
		c.sent += 1
		// (the path copied: an answer at once may not find the entry as it was)
		ask(user, strings.clone(t.path, context.temp_allocator), t.side, t.ticket)
	}
	if len(c.entries) > c.o.most_count || c.held > c.o.most_bytes { thumb_cache_trim(c) }
	c.frame += 1
	c.got = false
}

// Every thumbnail made forgotten (Ready and Failed): the cards shown ask for theirs again. The asks waiting and in
// flight stay: an ask out holds one of the `asks` slots until its answer, which lands as any answer. Safe in a build:
// the entries go at the cache's next thumb_cache_get or thumb_cache_frame, or, when a card took one in this build, at
// the first of a later build (after the draw of this frame, which may still read it).
thumb_cache_clear :: proc(c: ^Thumb_Cache) {
	if !c.made { return }
	c.clear_due, c.clear_waits, c.clear_frame = true, c.got, c.frame
	// (a later build must come: the cards ask again in it)
	if s := current; s != nil { s.anim_busy = true }
}

// A clear asked, once no draw to come reads an entry: the Ready and Failed entries freed, their textures with them.
@(private = "file")
thumb_cache_cleared :: proc(c: ^Thumb_Cache) {
	if !c.clear_due || (c.clear_waits && c.frame <= c.clear_frame) { return }
	c.clear_due = false
	gone := make([dynamic]^Thumb, context.temp_allocator)
	for _, t in c.entries { if t.state == .Ready || t.state == .Failed { append(&gone, t) } }
	for t in gone {
		if t.better {
			// (its larger ask, waiting or out, goes with it: its answer finds no ticket)
			if t.ticket != 0 { delete_key(&c.by_ticket, t.ticket) }
			for w, i in c.waiting { if w == t { ordered_remove(&c.waiting, i); break } }
		}
		delete_key(&c.entries, t.key)
		c.held -= thumb_bytes(t)
		thumb_free(t)
	}
}

// The entries used least lately dropped, down to three quarters of the limits; never one used in the last
// THUMB_KEEP_FRAMES builds, never one waiting or asked.
@(private = "file")
thumb_cache_trim :: proc(c: ^Thumb_Cache) {
	old := make([dynamic]^Thumb, context.temp_allocator)
	for _, t in c.entries {
		if t.state == .Waiting || t.state == .Asked || t.better || t.used + THUMB_KEEP_FRAMES > c.frame { continue }
		append(&old, t)
	}
	slice.sort_by(old[:], proc(x, y: ^Thumb) -> bool { return x.used < y.used })
	count_to, bytes_to := c.o.most_count * 3 / 4, c.o.most_bytes * 3 / 4
	for t in old {
		if len(c.entries) <= count_to && c.held <= bytes_to { break }
		delete_key(&c.entries, t.key)
		c.held -= thumb_bytes(t)
		thumb_free(t)
	}
}

// The bytes a Ready entry counts for.
@(private = "file")
thumb_bytes :: proc(t: ^Thumb) -> int { return t.state == .Ready ? t.size.x * t.size.y * THUMB_PIXEL_BYTES : 0 }

@(private = "file")
thumb_free :: proc(t: ^Thumb) {
	a := runtime.heap_allocator()
	if t.texture != 0 && t.renderer != nil { render.destroy_texture(t.renderer, t.texture) }
	delete(t.key, a)
	delete(t.path, a)
	delete(t.pixels, a)
	free(t, a)
}

@(private = "file")
Thumb_Draw :: struct {
	t:      ^Thumb,
	radius: f32,
}

// A Ready thumbnail in the box `next` gives (a side it leaves unset: all the room): fitted, centred; larger than its
// pixels only when they filled the side asked (a small picture keeps its size); `radius`: its corners.
thumb_picture :: proc(id: string, t: ^Thumb, radius: f32 = 0) -> ^Box {
	d := frame_new(Thumb_Draw)
	d^ = {t, radius}
	s := gs()
	// (merged, never replaced: a place given in `next`, fixed_x and fixed_y, stays)
	if !s.has_next || s.next_mod.width == nil { next_merge({width = fill()}) }
	if s.next_mod.height == nil { next_merge({height = fill()}) }
	return custom(id, thumb_draw, d)
}

// (the texture made at the first draw: the draw has the renderer, the build has not)
@(private = "file")
thumb_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Thumb_Draw)(user)
	t := d.t
	if t.state != .Ready || t.refused { return }
	if t.texture == 0 && t.pixels != nil && dc.renderer != nil {
		w, h := t.size.x, t.size.y
		if w > render.max_texture_size(dc.renderer) || h > render.max_texture_size(dc.renderer) {
			t.refused = true
			return
		}
		t.texture = render.create_texture_rgba(dc.renderer, w, h)
		if t.texture == 0 { t.refused = true; return }
		t.renderer = dc.renderer
		render.update_texture_rgba(dc.renderer, t.texture, 0, 0, w, h, t.pixels)
		delete(t.pixels, runtime.heap_allocator())
		t.pixels = nil
	}
	if t.texture == 0 { return }
	r := b.rect
	room := r.max - r.min
	size := Vec2{f32(t.size.x), f32(t.size.y)}
	if room.x <= 0 || room.y <= 0 { return }
	// (pixels that filled the side asked came from a larger picture: they fill the card; a picture smaller than that is
	// never blown up)
	k := min(room.x / size.x, room.y / size.y)
	if max(t.size.x, t.size.y) < t.side { k = min(k, 1) }
	sz := size * k
	at := r.min + (room - sz) * 0.5
	draw.image(dc, t.texture, {at, at + sz}, radius = d.radius)
}
