#+build windows
package font

import "base:runtime"
import "core:sync"
import "core:thread"

// Color glyphs drawn off the drawing thread (Settings.color_async). A complex color glyph costs milliseconds to draw
// (a COLR v1 emoji of Segoe UI Emoji: about 4 ms on WARP): glyph_image does not wait for it. The first lookup of a
// color glyph queues it and returns a pending image (`Glyph_Image.pending`: nothing to draw yet); one thread draws the
// queue in order, puts each bitmap in the atlas, bumps the ready generation and calls the ready callback, from which
// the application asks for a frame. A picture recorded while one of its glyphs was pending is stale once the ready
// generation moves (draw.Picture), so it is recorded again with the glyph.
//
// Whether a glyph is a color glyph at all (the digits of an emoji font are not) is found right away (a translation
// of the run, microseconds): outlines are rasterized in place as before. Requests made with older rendering settings
// are dropped when they finish. `unload` waits for the face's request in flight and drops the others; `destroy` stops
// the thread.

@(private)
Color_Job :: struct {
	key:      u64,
	fg:       [3]u8,
	known_fg: bool,    // the glyph is known to use the text color: drawn for `fg` (else for the first lookup's fg)
	face:     Font_Id,
	gid:      u16,
	size:     f32,
	x:        f32,
	settings: u64,     // atlas settings generation when queued
}

@(private)
Color_Queue :: struct {
	mu:       sync.Mutex,
	cv:       sync.Cond,
	jobs:     [dynamic]Color_Job,
	busy:     Font_Id,           // the face of the request being drawn (0: none)
	stop:     bool,
	worker:   ^thread.Thread,
	ready:    u64,               // atomic: requests finished
	on_ready: proc(user: rawptr),
	user:     rawptr,
}

// Called (from the color glyph thread) each time queued color glyphs are in the atlas: ask for a frame. The callback
// must be thread-safe and quick, and must not call into this package. Once this returns, the previous callback is not
// called any more (nil: none).
set_color_ready_callback :: proc(s: ^State, fn: proc(user: rawptr), user: rawptr) {
	q := &s.color_queue
	sync.mutex_lock(&q.mu)
	q.on_ready, q.user = fn, user
	sync.mutex_unlock(&q.mu)
}

// Color glyph requests finished so far (a picture with pending glyphs is stale when this moves).
color_ready_generation :: proc(s: ^State) -> u64 { return sync.atomic_load(&s.color_queue.ready) }

// Color glyphs queued or being drawn.
color_pending :: proc(s: ^State) -> int {
	q := &s.color_queue
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	return len(q.jobs) + (q.busy != 0 ? 1 : 0)
}

// Waits until every queued color glyph is in the atlas (tests, captures).
color_wait :: proc(s: ^State) {
	q := &s.color_queue
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	for (len(q.jobs) > 0 || q.busy != 0) && q.worker != nil { sync.cond_wait(&q.cv, &q.mu) }
}

// Queues a color glyph (false: no thread could be started: draw it in place). Caller holds the atlas lock (the pending
// maps are under it).
@(private)
color_enqueue :: proc(s: ^State, job: Color_Job) -> bool {
	context.allocator = runtime.heap_allocator()
	q := &s.color_queue
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	if q.stop { return false }
	if q.worker == nil {
		// its own context: the thread's own temporary allocator
		q.worker = thread.create_and_start_with_data(s, color_worker)
		if q.worker == nil { return false }
	}
	append(&q.jobs, job)
	sync.cond_broadcast(&q.cv)
	return true
}

// Whether glyph `gid` of color face `f` is drawn in color (not an outline of the face).
@(private)
is_color_glyph :: proc(s: ^State, f: ^Font, gid: u16, size: f32) -> bool {
	ids := [1]u16{gid}
	advs := [1]f32{0}
	offs := [1]DWRITE_GLYPH_OFFSET{}
	run := DWRITE_GLYPH_RUN{fontFace = f.dw, fontEmSize = size, glyphCount = 1, glyphIndices = &ids[0], glyphAdvances = &advs[0], glyphOffsets = &offs[0]}
	_, paint := color_caps(s)
	fmts, _ := glyph_formats(s, &run, paint)
	return fmts != 0
}

@(private)
color_worker :: proc(data: rawptr) {
	s := (^State)(data)
	q := &s.color_queue
	for {
		sync.mutex_lock(&q.mu)
		for len(q.jobs) == 0 && !q.stop { sync.cond_wait(&q.cv, &q.mu) }
		if q.stop { sync.mutex_unlock(&q.mu); return }
		job := q.jobs[0]
		ordered_remove(&q.jobs, 0)
		q.busy = job.face
		sync.mutex_unlock(&q.mu)

		color_job_run(s, job)
		free_all(context.temp_allocator)

		sync.mutex_lock(&q.mu)
		q.busy = 0
		n := sync.atomic_add(&q.ready, 1) + 1
		// one call when the queue drains, and every 16 requests of a long one; under the lock, so that once
		// set_color_ready_callback returns the previous callback is never called again
		if q.on_ready != nil && (len(q.jobs) == 0 || n % 16 == 0) { q.on_ready(q.user) }
		sync.cond_broadcast(&q.cv)
		sync.mutex_unlock(&q.mu)
	}
}

// Draws one request (outside the atlas lock) and puts the result in the atlas.
@(private)
color_job_run :: proc(s: ^State, job: Color_Job) {
	context.allocator = runtime.heap_allocator()
	f := face_ptr(s, job.face)   // alive: unload waits for the request in flight
	a := &s.atlas
	ids := [1]u16{job.gid}
	advs := [1]f32{0}
	offs := [1]DWRITE_GLYPH_OFFSET{}
	px: []u8
	w, h: int
	origin: [2]int
	uses_fg, drawn: bool
	fmts: DWRITE_GLYPH_IMAGE_FORMATS
	run: DWRITE_GLYPH_RUN
	if f != nil {
		run = DWRITE_GLYPH_RUN{fontFace = f.dw, fontEmSize = job.size, glyphCount = 1, glyphIndices = &ids[0], glyphAdvances = &advs[0], glyphOffsets = &offs[0]}
		_, paint := color_caps(s)
		text_color: bool
		fmts, text_color = glyph_formats(s, &run, paint)
		if fmts != 0 { px, w, h, origin, uses_fg, drawn = color_render(s, f, &run, job.x, job.fg, !job.known_fg, fmts, text_color) }
	}
	atlas_lock(a)
	defer atlas_unlock(a)
	fk := Fg_Key{job.key, job.fg}
	if job.known_fg { delete_key(&a.fg_pending, fk) } else { delete_key(&a.pending, job.key) }
	if f == nil || job.settings != a.settings_generation { return }   // unloaded, or made with other settings
	g: Glyph_Image
	switch {
	case drawn:
		g = color_bitmap_put(s, px, w, h, origin)
	case fmts & DWRITE_GLYPH_IMAGE_FORMATS_COLR != 0:
		g, uses_fg, _ = rasterize_colr_layers(s, &run, job.x, job.fg)
	case:
		// not drawable in color: its outline, as coverage
		g, _ = rasterize_outline(s, f, &run, job.x)
	}
	if job.known_fg || uses_fg {
		g.uses_fg = true
		a.glyphs[job.key] = Glyph_Image{page = -1, color = true, uses_fg = true}
		a.fg_glyphs[fk] = g
	} else {
		a.glyphs[job.key] = g
	}
}

// Drops the queued requests of a face and waits for the one in flight (unload).
@(private)
color_forget_face :: proc(s: ^State, face: Font_Id) {
	q := &s.color_queue
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	for i := len(q.jobs) - 1; i >= 0; i -= 1 { if q.jobs[i].face == face { ordered_remove(&q.jobs, i) } }
	for q.busy == face && face != 0 { sync.cond_wait(&q.cv, &q.mu) }
}

// Stops the thread (destroy).
@(private)
color_queue_destroy :: proc(s: ^State) {
	q := &s.color_queue
	sync.mutex_lock(&q.mu)
	q.stop = true
	sync.cond_broadcast(&q.cv)
	w := q.worker
	sync.mutex_unlock(&q.mu)
	if w != nil {
		thread.join(w)
		thread.destroy(w)
	}
	delete(q.jobs)
	q^ = {}
}
