package devtools

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "../render"
import "../ui"

// Page.startScreencast: the window's frames as events, as Chrome sends a page's. One frame at a time (the next waits for
// Page.screencastFrameAck) and no faster than `minIntervalMs` (200: each is read back, compared on the UI thread and
// encoded on its own, which takes a core while the program is measured). A window at rest sends nothing, even one
// that shows a counter of its own frames: an ack wakes the window only if something changed since the frame it answers
// (Server.cast_dirty, read by the connection's thread), or each frame sent would make the next.

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
	id:         int,
}

@(private)
cast_start :: proc(srv: ^Server, to: Reply_To, p: json.Object) {
	cast_stop(srv)
	srv.screencast = Cast{on = true, to = hold(to), min_ms = num(p["minIntervalMs"], 200)}
	srv.screencast.owed = true   // (the first frame, at once)
}

@(private)
cast_stop :: proc(srv: ^Server) {
	c := &srv.screencast
	if !c.on { return }
	release(c.to)
	c^ = {}
}

// Each frame, after the screenshots' poll.
@(private)
cast_poll :: proc(srv: ^Server, s: ^ui.State, r: ^render.Renderer) {
	c := &srv.screencast
	if !c.on { return }
	if conn_gone(c.to.conn) { if c.pending && r != nil { render.capture_cancel(r) }; cast_stop(srv); return }
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
cast_frame :: proc(srv: ^Server, s: ^ui.State, pixels: []u8, size: [2]int) {
	c := &srv.screencast
	c.pending = false
	c.last_build = s.build_index + 1   // (the frame that reads the capture back, about to be built, is no change of the program's)
	h := u64(hash.crc32(pixels))
	if c.id > 0 && h == c.last_hash {
		delete(pixels, runtime.heap_allocator())
		return
	}
	c.last_hash = h
	c.id += 1
	c.unacked = true
	d := dpi(srv)
	meta := fmt.aprintf(`"sessionId":%d,"metadata":{{"offsetTop":0,"pageScaleFactor":1,"deviceWidth":%.0f,"deviceHeight":%.0f,"scrollOffsetX":0,"scrollOffsetY":0,"timestamp":%.3f}}`, c.id, f64(size.x) / d, f64(size.y) / d, ui.now_ms() / 1000, allocator = runtime.heap_allocator())
	encode_start(Encode_Job{srv = srv, pixels = pixels, size = size, frame = true, to = hold(c.to), meta = meta})
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
cast_touch :: proc(srv: ^Server) { srv.screencast.last_build = 0 }
