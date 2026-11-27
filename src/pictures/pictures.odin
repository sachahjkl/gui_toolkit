// Package pictures: the textures of picture files, kept under a byte budget (docs/pictures.md,
// src/md/features/picture-cache.md). A program asks for a picture at each frame that shows it; the decode runs on the
// chores, the texture is made on the interface's thread when the answer arrives, and the frame after shows it.
//
//   c: pictures.Cache
//   pictures.cache_init(&c, &app.renderer, &app.state)
//   ...each frame, in the build:
//   pictures.frame(&c)
//   p := pictures.get(&c, key, bytes, 96 * ui.scale())
//   if p != nil && p.state == .Ready { draw.image(dc, p.texture, rect) }
package tk_pictures

import "base:runtime"
import "core:math"
import "core:sync"
import "core:time"
import image "../image"
import i18n "../i18n"
import render "../render"
import ui "../ui"

// The defaults of Options.
BUDGET_BYTES_DEFAULT :: 96 << 20
STAGED_FROM_BYTES_DEFAULT :: 16 << 20   // a texture this large and more is uploaded over several frames (render.Upload)
DECODERS_DEFAULT :: 3
KEEP_FRAMES_DEFAULT :: 2
MAX_SIDE_DEFAULT :: 2048

// The sizes decoded at: powers of two from CLASS_FIRST_PX up to CLASS_STEP_PX, then multiples of CLASS_STEP_PX.
CLASS_FIRST_PX :: 32
CLASS_STEP_PX :: 256

// A texture's bytes per pixel, and the share its mipmaps add (a third: 1/4 + 1/16 + ...).
@(private) BYTES_PER_PIXEL :: 4
@(private) MIP_SHARE_DIVISOR :: 3

Picture_State :: enum u8 { Pending, Ready, Failed }

// Why a picture is Failed (failure_words says it).
Failure :: enum u8 {
	None,
	Unknown_Format,   // no format image.decode reads
	Damaged,          // its format, but a decode that failed
	No_Texture,       // the renderer made no texture of its size
}

// A picture at one size class. `texture` and `size` are set once Ready; `why` once Failed. The pointer stays valid
// until `forget` of its key or its eviction by `frame`: take it again each frame.
Picture :: struct {
	state:   Picture_State,
	texture: render.Texture,
	size:    [2]int,
	why:     Failure,
	// (the cache's)
	used:    u64,   // the frame it was last asked in
	serial:  u64,   // its ask: an answer of another ask is dropped
	bytes:   int,   // what its texture holds
	upload:  render.Upload,   // a large picture's upload in steps (Pending until done), its pixels (heap) held meanwhile
}

// What turns the bytes a program has into a picture file, on the chores (get's `prepare`). Thread-safe: no state of
// the program but what `data` holds.
Prepare :: #type proc(data: []u8, allocator: runtime.Allocator) -> (file: []u8, ok: bool)

// 0 for a field: its default.
Options :: struct {
	budget_bytes: int,   // the bytes of every texture together (BUDGET_BYTES_DEFAULT)
	decoders:     int,   // decodes at a time (DECODERS_DEFAULT)
	keep_frames:  int,   // a picture asked this many frames ago is still shown: never dropped (KEEP_FRAMES_DEFAULT)
	max_side:     int,   // the longest side decoded, below the renderer's largest texture (MAX_SIDE_DEFAULT)
	// a texture of this many bytes and more is uploaded over several frames, within upload_budget a frame
	// (STAGED_FROM_BYTES_DEFAULT); a frame never spends more than that and a band on uploads
	staged_from_bytes: int,
	upload_budget:     time.Duration,   // (render.UPLOAD_BUDGET_DEFAULT)
}

// A picture of the cache: the caller's key and the side it is decoded at (0: the whole picture, mipmapped).
@(private)
Entry_Key :: struct { key: u64, side: int }

// What a decode's answer finds: the cache, or nil once it is destroyed. Shared by the cache and each decode out
// (counted), so that an answer after cache_destroy frees itself.
@(private)
Link :: struct {
	cache: ^Cache,   // read and cleared on the interface's thread only
	refs:  int,      // (atomic)
}

@(private)
Job :: struct {
	link:   ^Link,
	entry:  Entry_Key,
	serial: u64,
	data:   []u8,   // the file, or what `prepare` makes it from (owned, heap)
	side:   int,    // the longest side decoded
	prepare: Prepare,
	// the answer
	img:    image.Image,   // (heap)
	format: image.File_Format,
	ok:     bool,
}

Cache :: struct {
	o:         Options,
	renderer:  ^render.Renderer,
	state:     ^ui.State,
	most:      int,        // the longest side of a texture here
	frame_no:  u64,
	serial:    u64,
	pictures:  map[Entry_Key]^Picture,
	queue:     [dynamic]^Job,   // waiting, the last asked at the end
	decoding:  int,
	held:      int,        // the bytes of every texture
	uploads:   [dynamic]Entry_Key,        // the pictures whose upload is in steps, the oldest first
	dropped:   [dynamic]render.Texture,   // destroyed at the next frame: a build may still draw them
	link:      ^Link,
	allocator: runtime.Allocator,
}

// Starts a cache whose textures are `renderer`'s and whose answers come to `state`'s interface's thread. Its maps are
// in context.allocator.
cache_init :: proc(c: ^Cache, renderer: ^render.Renderer, state: ^ui.State, o := Options{}) {
	c^ = {renderer = renderer, state = state, o = o, allocator = context.allocator}
	if c.o.budget_bytes <= 0 { c.o.budget_bytes = BUDGET_BYTES_DEFAULT }
	if c.o.decoders <= 0 { c.o.decoders = DECODERS_DEFAULT }
	if c.o.keep_frames <= 0 { c.o.keep_frames = KEEP_FRAMES_DEFAULT }
	if c.o.max_side <= 0 { c.o.max_side = MAX_SIDE_DEFAULT }
	if c.o.staged_from_bytes <= 0 { c.o.staged_from_bytes = STAGED_FROM_BYTES_DEFAULT }
	if c.o.upload_budget <= 0 { c.o.upload_budget = render.UPLOAD_BUDGET_DEFAULT }
	c.most = c.o.max_side
	if renderer != nil { c.most = min(c.most, render.max_texture_size(renderer)) }
	c.pictures = make(map[Entry_Key]^Picture, c.allocator)
	c.queue = make([dynamic]^Job, c.allocator)
	c.uploads = make([dynamic]Entry_Key, c.allocator)
	c.dropped = make([dynamic]render.Texture, c.allocator)
	c.link = new(Link, runtime.heap_allocator())
	c.link^ = {cache = c, refs = 1}
}

// Every texture destroyed. Decodes still out end on their thread; their answers are dropped.
cache_destroy :: proc(c: ^Cache) {
	context.allocator = c.allocator
	for _, p in c.pictures {
		if p.texture != 0 { append(&c.dropped, p.texture) }
		delete(p.upload.pixels, runtime.heap_allocator())
		free(p)
	}
	for j in c.queue { job_free(j) }
	textures_destroy(c)
	delete(c.pictures)
	delete(c.queue)
	delete(c.uploads)
	delete(c.dropped)
	if c.link != nil {
		c.link.cache = nil
		link_release(c.link)
	}
	c^ = {}
}

// The longest side decoded for a place whose longest side is `need_px` frame pixels (0 or less: `most`, the whole
// picture), with `most` the longest side a texture may have. Pure.
class_side :: proc(need_px: f32, most: int) -> int {
	if need_px <= 0 { return most }
	n := int(max(1, math.ceil(need_px)))
	c := CLASS_FIRST_PX
	if n <= CLASS_STEP_PX {
		for c < n { c *= 2 }
	} else {
		c = (n + CLASS_STEP_PX - 1) / CLASS_STEP_PX * CLASS_STEP_PX
	}
	return min(c, most)
}

// The picture of `key` for a place whose longest side is `need_px` frame pixels (0: the whole picture, mipmapped, for
// a viewer that zooms it). The first ask of a size copies `data` and queues its decode; nil when `data` is empty and
// the picture is not known. Call it on the interface's thread, at each frame that shows it.
// `prepare` not nil: `data` is not the file yet (base64 text, a data URL); it makes the file on the chores, before the
// decode, so that the interface's thread never decodes the text. Its file is in `allocator`; not ok: the picture
// fails as Unknown_Format.
get :: proc(c: ^Cache, key: u64, data: []u8, need_px: f32, prepare: Prepare = nil) -> ^Picture {
	ek := Entry_Key{key, need_px <= 0 ? 0 : class_side(need_px, c.most)}
	if p, ok := c.pictures[ek]; ok {
		p.used = c.frame_no
		return p
	}
	if len(data) == 0 { return nil }
	context.allocator = c.allocator
	c.serial += 1
	p := new(Picture)
	p^ = {state = .Pending, used = c.frame_no, serial = c.serial}
	c.pictures[ek] = p
	heap := runtime.heap_allocator()
	j := new(Job, heap)
	j^ = {link = c.link, entry = ek, serial = c.serial, side = ek.side == 0 ? c.most : ek.side, prepare = prepare}
	j.data = make([]u8, len(data), heap)
	copy(j.data, data)
	append(&c.queue, j)
	pump(c)
	return p
}

// Once a frame, before the pictures are asked: the textures let go since the last frame destroyed, then the pictures
// shown longest ago dropped while the textures hold more than the budget.
frame :: proc(c: ^Cache) {
	c.frame_no += 1
	textures_destroy(c)
	uploads_step(c)
	trim(c)
}

// The large pictures' uploads go on, the oldest first, within the frame's budget; one that ends is Ready. While some
// remain, the next frame comes at once. Only frame calls it: one budget a frame for every picture of the cache.
@(private)
uploads_step :: proc(c: ^Cache) {
	if len(c.uploads) == 0 { return }
	began := time.tick_now()
	stepped := false
	for len(c.uploads) > 0 {
		// (a band at least each frame, whatever the budget: an upload always moves)
		left := c.o.upload_budget - time.tick_since(began)
		if stepped && left <= 0 { break }
		stepped = true
		ek := c.uploads[0]
		p, ok := c.pictures[ek]
		// (dropped, or dropped and asked again: its new ask has no upload of this one's)
		if !ok || p.upload.texture == 0 { ordered_remove(&c.uploads, 0); continue }
		if !render.upload_step(c.renderer, &p.upload, left) { break }
		ordered_remove(&c.uploads, 0)
		delete(p.upload.pixels, runtime.heap_allocator())
		p.upload = {}
		p.state = .Ready
		c.held += p.bytes
	}
	if len(c.uploads) > 0 { ui.wake_within(c.state, 1) }
}

// The picture of `key` is gone or changed: every size of it leaves the cache (its decodes' answers are dropped).
forget :: proc(c: ^Cache, key: u64) {
	context.allocator = c.allocator
	gone := make([dynamic]Entry_Key, context.temp_allocator)
	for ek in c.pictures { if ek.key == key { append(&gone, ek) } }
	for ek in gone { entry_drop(c, ek) }
}

// The bytes the textures hold now.
held_bytes :: proc(c: ^Cache) -> int { return c.held }

////////////////////////////////
// Decodes

// Decodes for what waits, the last asked first, at most o.decoders at a time. What was not asked in the last
// keep_frames frames when its turn comes leaves the cache: asked again, it is decoded then.
@(private)
pump :: proc(c: ^Cache) {
	for c.decoding < c.o.decoders && len(c.queue) > 0 {
		j := pop(&c.queue)
		p, ok := c.pictures[j.entry]
		if !ok || p.serial != j.serial {
			job_free(j)
			continue
		}
		if !shown(c, p) {
			entry_drop(c, j.entry)
			job_free(j)
			continue
		}
		c.decoding += 1
		sync.atomic_add(&c.link.refs, 1)
		ui.task(c.state, decode_run, decoded, j, decode_lost)
	}
}

// On a thread of the chores: the file decoded, then fitted to the class's side.
@(private)
decode_run :: proc(data: rawptr) {
	j := (^Job)(data)
	heap := runtime.heap_allocator()
	if j.prepare != nil {
		file, ok := j.prepare(j.data, heap)
		delete(j.data, heap)
		j.data = file
		if !ok { j.format, j.ok = .Unknown, false; return }
	}
	img: image.Image
	// (turned as the camera was held, as browsers show a photo; a JPEG at the least scale that covers the class)
	img, j.format, j.ok = image.decode(j.data, heap, {orient = true, need_side = j.side})
	if !j.ok { return }
	if img.width <= 0 || img.height <= 0 {
		image.destroy(&img, heap)
		j.ok = false
		return
	}
	if longest := max(img.width, img.height); longest > j.side {
		k := f32(j.side) / f32(longest)
		small := image.resize(img, max(1, int(math.round(f32(img.width) * k))), max(1, int(math.round(f32(img.height) * k))), allocator = heap)
		image.destroy(&img, heap)
		img = small
	}
	j.img = img
}

// On the interface's thread: the pixels become the picture's texture.
@(private)
decoded :: proc(data: rawptr, _: u64) {
	j := (^Job)(data)
	defer job_end(j)
	c := j.link.cache
	if c == nil { return }
	c.decoding -= 1
	defer pump(c)
	p, ok := c.pictures[j.entry]
	if !ok || p.serial != j.serial { return }
	switch {
	case j.format == .Unknown:
		failed(p, .Unknown_Format)
		return
	case !j.ok:
		failed(p, .Damaged)
		return
	}
	mips := j.entry.side == 0
	w, h := j.img.width, j.img.height
	p.size = {w, h}
	p.bytes = w * h * BYTES_PER_PIXEL
	if mips { p.bytes += p.bytes / MIP_SHARE_DIVISOR }
	if w * h * BYTES_PER_PIXEL >= c.o.staged_from_bytes {
		// (a large picture over several frames: its upload in one would hold the interface's thread for it)
		u, made := render.upload_begin(c.renderer, j.img.pixels, w, h, mips = mips)
		if !made {
			failed(p, .No_Texture)
			return
		}
		p.texture, p.upload = u.texture, u
		j.img = {}   // (its pixels are the upload's now, freed when it ends)
		// (its first band at this build's frame, with the others: an answer stepping its own would give each answer of a
		// build a budget of its own, and five large answers in one build held the thread five budgets)
		append(&c.uploads, j.entry)
		return
	}
	p.texture = render.create_texture_rgba(c.renderer, w, h, mips = mips)
	if p.texture == 0 {
		failed(p, .No_Texture)
		return
	}
	render.update_texture_rgba(c.renderer, p.texture, 0, 0, w, h, j.img.pixels)
	p.state = .Ready
	c.held += p.bytes
}

// The State is gone or the chores stopped: no answer will come (on any thread: the cache is not touched).
@(private)
decode_lost :: proc(data: rawptr) { job_end((^Job)(data)) }

@(private)
failed :: proc(p: ^Picture, why: Failure) {
	p.state = .Failed
	p.why = why
}

// Why a picture cannot be shown, in the person's language ("" for None).
failure_words :: proc(why: Failure) -> string {
	switch why {
	case .None:           return ""
	case .Unknown_Format: return i18n.tr("not a picture file this program reads")
	case .Damaged:        return i18n.tr("the picture file is damaged")
	case .No_Texture:     return i18n.tr("too large for the graphics card")
	}
	return ""
}

////////////////////////////////
// The budget

// Whether `p` was asked in the last keep_frames frames.
@(private)
shown :: proc(c: ^Cache, p: ^Picture) -> bool { return p.used + u64(c.o.keep_frames) >= c.frame_no }

// The pictures asked longest ago go while the textures hold more than the budget; never one shown, nor one that waits.
@(private)
trim :: proc(c: ^Cache) {
	for c.held > c.o.budget_bytes {
		oldest: Entry_Key
		best := max(u64)
		for ek, p in c.pictures {
			if p.state == .Ready && !shown(c, p) && p.used < best { best, oldest = p.used, ek }
		}
		if best == max(u64) { return }
		entry_drop(c, oldest)
	}
}

// One picture out of the cache: its texture destroyed at the next frame.
@(private)
entry_drop :: proc(c: ^Cache, ek: Entry_Key) {
	p, ok := c.pictures[ek]
	if !ok { return }
	context.allocator = c.allocator
	if p.texture != 0 { append(&c.dropped, p.texture) }
	if p.state == .Ready { c.held -= p.bytes }
	// (an upload in steps given up: its texture goes with the others, its pixels now)
	delete(p.upload.pixels, runtime.heap_allocator())
	delete_key(&c.pictures, ek)
	free(p)
}

@(private)
textures_destroy :: proc(c: ^Cache) {
	for t in c.dropped { render.destroy_texture(c.renderer, t) }
	clear(&c.dropped)
}

////////////////////////////////
// Jobs

// A job never sent to the chores.
@(private)
job_free :: proc(j: ^Job) {
	heap := runtime.heap_allocator()
	delete(j.data, heap)
	image.destroy(&j.img, heap)
	free(j, heap)
}

// A job back from the chores (or lost): its hold on the link let go.
@(private)
job_end :: proc(j: ^Job) {
	link := j.link
	job_free(j)
	link_release(link)
}

@(private)
link_release :: proc(l: ^Link) {
	if sync.atomic_sub(&l.refs, 1) == 1 { free(l, runtime.heap_allocator()) }
}
