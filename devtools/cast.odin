package devtools

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "../render"
import "../ui"

// Page.startScreencast: the window's frames as events, as Chrome sends a page's. One frame at a time (the next waits for
// Page.screencastFrameAck) and no faster than `minIntervalMs` (200: each is read back, compared on the UI thread and
// encoded on its own, which takes a core while the program is measured). A window at rest sends nothing, even one
// that shows a counter of its own frames: an ack wakes the window only if something changed since the frame it answers
// (Server.cast_dirty, read by the connection's thread), or each frame sent would make the next.

@(private)
CAST_MIN_INTERVAL_MS :: 200

@(private)
Cast :: struct {
	on:         bool,
	to:         Reply_To,   // (held)
	min_ms:     f64,
	last_ms:    f64,
	last_build: u64,
	last_hash:  u64,
	pending:    bool,       // a capture of ours is on its way
	unacked:    bool,
	owed:       bool,       // something changed, too soon to send: the ticker wakes the window for it
	touched:    bool,       // input was sent since the last capture came back
	settling:   bool,       // this capture is the one more that follows a change (cast_frame)
	same:       bool,       // the encoder's thread found the picture unchanged: nothing goes out, no ack comes (atomic)
	id:         int,
}

@(private)
cast_start :: proc(srv: ^Server, r: ^render.Renderer, to: Reply_To, p: json.Object) {
	cast_stop(srv, r)
	srv.screencast = Cast{on = true, to = hold(to), min_ms = num(p["minIntervalMs"], CAST_MIN_INTERVAL_MS)}
	srv.screencast.owed = true   // (the first frame, at once)
}

// A capture of ours on its way is cancelled: nothing would read it, and until it is read no other can start. (r nil: the
// server is ending.)
@(private)
cast_stop :: proc(srv: ^Server, r: ^render.Renderer = nil) {
	c := &srv.screencast
	if !c.on { return }
	if c.pending && r != nil { render.capture_cancel(r) }
	release(c.to)
	c^ = {}
}

// Each frame, after the screenshots' poll.
@(private)
cast_poll :: proc(srv: ^Server, s: ^ui.State, r: ^render.Renderer) {
	c := &srv.screencast
	if sync.atomic_exchange(&c.same, false) { c.unacked = false }
	if !c.on { return }
	if conn_gone(c.to.conn) { cast_stop(srv, r); return }
	c.owed = false
	if r == nil || c.pending || c.unacked || len(srv.captures) > 0 || s.build_index == c.last_build { return }
	now := ui.now_ms()
	if now - c.last_ms < c.min_ms { c.owed = true; return }
	if !render.capture_request(r, {}) { c.owed = true; return }
	c.pending = true
	c.last_ms = now
}

// The capture came back.
@(private)
cast_frame :: proc(srv: ^Server, s: ^ui.State, raw: render.Capture_Raw) {
	c := &srv.screencast
	c.pending = false
	// The frame that reads the capture back, about to be built, is no change of the program's. Unless it is: input sent
	// before this came back shows in it, as does the next step of what moves, and that would be the last frame lost. So may
	// what the program does in answer to the frame just shown, which nothing here can see: after a change one more capture is
	// taken, and only that one's reading frame is ignored. (One more, not more: a window that shows a counter of its own frames
	// must come to rest.)
	switch {
	case c.touched || ui.needs_frame(s):
		c.last_build, c.settling = 0, false
	case !c.settling:
		c.last_build, c.settling = 0, true
	case:
		c.last_build, c.settling = s.build_index + 1, false
	}
	c.touched = false
	c.id += 1
	c.unacked = true
	d := dpi(srv)
	meta := fmt.aprintf(`"sessionId":%d,"metadata":{{"offsetTop":0,"pageScaleFactor":1,"deviceWidth":%.0f,"deviceHeight":%.0f,"scrollOffsetX":0,"scrollOffsetY":0,"timestamp":%.3f}}`, c.id, f64(raw.size.x) / d, f64(raw.size.y) / d, ui.now_ms() / 1000, allocator = runtime.heap_allocator())
	// (compared on the encoder's thread: a window's whole picture takes too long here)
	encode_start(Encode_Job{srv = srv, raw = raw, frame = true, first = c.id == 1, to = hold(c.to), meta = meta})
}

// The client took the last frame: what changed in the meantime goes now.
@(private)
cast_ack :: proc(srv: ^Server, s: ^ui.State) {
	c := &srv.screencast
	c.unacked = false
	c.owed = c.on && s.build_index + 1 != c.last_build
}

// Input sent now shows after the frame that may be reading the last capture back: that frame is a change after all.
@(private)
cast_touch :: proc(srv: ^Server) { srv.screencast.last_build = 0; srv.screencast.touched = true }
