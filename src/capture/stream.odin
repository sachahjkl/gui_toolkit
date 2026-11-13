package capture

// A stream: the frames of an output, a window or a region of the desktop, one each time it changed, for a screen
// recorder. The backend keeps its capture of the source open between frames (a Wayland session, a Windows frame pool,
// a duplication), so a frame costs a copy, not a new capture.
//
//   st, err := capture.stream_open(s, capture.Stream_Output{id}, {fps = 30, cursor = true})
//   for recording {
//       f, ok, err := capture.stream_next(st, 100 * time.Millisecond)   // blocks: a worker's thread
//       if err != .None { break }
//       if ok { encode(f.pixels, f.timestamp) }                         // ok false: nothing changed meanwhile
//   }
//   capture.stream_close(st)
//
// The pieces that are not a system's are here and pure, tested without a desktop: the pacing of the frames and their
// timestamps (Stream_Pacer), the two buffers frames are made in (Frame_Ring), the cut of a region (crop_into).

import "base:runtime"
import "core:time"

// A whole output.
Stream_Output :: struct { id: u64 }
// One window (its own content on Wayland and Windows; the desktop at its frame on X11). .Unsupported elsewhere.
Stream_Window :: struct { id: u64 }
// A rectangle of the desktop, logical: the frames of the output that holds most of it, cut to it.
Stream_Region :: struct { rect: Rect }

Stream_Source :: union { Stream_Output, Stream_Window, Stream_Region }

STREAM_DEFAULT_FPS :: 30
STREAM_MAX_FPS :: 240

Stream_Options :: struct {
	fps:    int,    // the most frames a second (0: STREAM_DEFAULT_FPS); fewer come when the screen changes less
	cursor: bool,   // the pointer drawn in the frames, where the backend can (Stream.cursor says whether it is)
}

// A frame of a stream. Its pixels are the stream's: valid until stream_next is called twice more (two buffers turn, so
// the frame before the last one is still readable), and never freed by the caller.
Stream_Frame :: struct {
	using frame: Frame,
	timestamp:   i64,   // nanoseconds since the stream's first frame (0 for it), strictly increasing
	index:       int,   // 0 for the first frame, then 1, 2...
}

Stream :: struct {
	session:   ^Session,
	source:    Stream_Source,
	options:   Stream_Options,
	cursor:    bool,     // the pointer is drawn in the frames
	allocator: runtime.Allocator,
	region:    Rect,     // a Stream_Region's rect: what the backend's frames are cut to
	cropping:  bool,
	pacer:     Stream_Pacer,
	ring:      Frame_Ring,
	scratch:   [dynamic]u8,   // a region's frame before its cut
	frames:    int,
	impl:      rawptr,        // the backend's own state
}

// Opens a stream of `source`. It blocks (a round trip to the compositor; on Windows the capture's start): call it on the
// session's thread. .Unsupported: the backend cannot stream this source (a window with wlr-screencopy, the portal
// backend: the ScreenCast portal is not written); .Gone: the output or the window is no more.
stream_open :: proc(s: ^Session, source: Stream_Source, o := Stream_Options{}, allocator := context.allocator) -> (st: ^Stream, err: Error) {
	if s == nil { return nil, .Unsupported }
	st = new(Stream, allocator)
	st.session = s
	st.source = source
	st.options = o
	st.allocator = allocator
	st.scratch.allocator = allocator
	st.ring.allocator = allocator
	fps := o.fps > 0 ? min(o.fps, STREAM_MAX_FPS) : STREAM_DEFAULT_FPS
	st.options.fps = fps
	stream_pacer_init(&st.pacer, fps)
	if r, is_region := source.(Stream_Region); is_region {
		if r.rect.w <= 0 || r.rect.h <= 0 {
			free(st, allocator)
			return nil, .Failed
		}
		st.region, st.cropping = r.rect, true
	}
	if !revive(s) {
		stream_free(st)
		return nil, .Failed
	}
	if err = platform_stream_open(s, st); err != .None {
		stream_free(st)
		return nil, err
	}
	s.streams += 1
	return st, .None
}

// The next frame, once the source changed and the pace allows (no more than `fps` a second). It blocks up to `timeout`;
// ok false with no error: nothing changed meanwhile (ask again). An error ends the stream: .Gone, the source went away;
// .Failed, the compositor or the system stopped it.
stream_next :: proc(st: ^Stream, timeout: time.Duration) -> (f: Stream_Frame, ok: bool, err: Error) {
	if st == nil { return {}, false, .Failed }
	return platform_stream_next(st, timeout)
}

stream_close :: proc(st: ^Stream) {
	if st == nil { return }
	platform_stream_close(st)
	st.session.streams -= 1
	stream_free(st)
}

@(private = "file")
stream_free :: proc(st: ^Stream) {
	frame_ring_destroy(&st.ring)
	delete(st.scratch)
	free(st, st.allocator)
}

// Where a backend writes the next frame of `w` x `h` physical pixels (packed rows, w * 4 bytes): the ring's next
// buffer, or for a region the scratch buffer, cut afterwards by stream_frame_finish.
@(private)
stream_frame_target :: proc(st: ^Stream, w, h: i32) -> []u8 {
	bytes := int(w) * int(h) * 4
	if !st.cropping { return frame_ring_take(&st.ring, bytes) }
	if len(st.scratch) != bytes { resize(&st.scratch, bytes) }
	return st.scratch[:]
}

// The frame a backend wrote in stream_frame_target's buffer (`f`: placed, its pixels that buffer), cut to the region
// when there is one, stamped. ok false: the region is outside the frame (the output moved).
@(private)
stream_frame_finish :: proc(st: ^Stream, f: Frame, at_ns: i64) -> (out: Stream_Frame, ok: bool) {
	frame := f
	if st.cropping {
		w, h := crop_size(f, st.region)
		if w <= 0 || h <= 0 { return {}, false }
		frame = crop_into(f, st.region, frame_ring_take(&st.ring, int(w) * int(h) * 4)) or_return
	}
	frame.allocator = {}   // (the stream's: stream_close frees it)
	out = Stream_Frame{frame = frame, timestamp = stream_pacer_stamp(&st.pacer, at_ns), index = st.frames}
	st.frames += 1
	return out, true
}

// The output whose rect holds most of `r` (-1: none meets it).
@(private)
output_most_of :: proc(outs: []Output, r: Rect) -> int {
	best, area := -1, i64(0)
	for o, i in outs {
		x0, y0 := max(r.x, o.rect.x), max(r.y, o.rect.y)
		x1, y1 := min(r.x + r.w, o.rect.x + o.rect.w), min(r.y + r.h, o.rect.y + o.rect.h)
		if x1 <= x0 || y1 <= y0 { continue }
		a := i64(x1 - x0) * i64(y1 - y0)
		if a > area { best, area = i, a }
	}
	return best
}

////////////////////////////////
// Pacing

// The pace of a stream: when the next capture may start, and each frame's timestamp. Times are nanoseconds of one
// monotonic clock (the backend's: Wayland's presentation clock, QueryPerformanceCounter).
Stream_Pacer :: struct {
	interval:   i64,    // nanoseconds between two frames at the most frames a second
	started:    bool,   // a frame was stamped
	start:      i64,    // the first frame's time
	last:       i64,    // the last frame's time
	last_stamp: i64,
	polled:     i64,    // the last capture that gave nothing (a backend that reads and compares: X11)
}

stream_pacer_init :: proc(p: ^Stream_Pacer, fps: int) {
	p^ = {interval = i64(time.Second) / i64(max(fps, 1))}
}

// When the next capture may start: an interval after the last frame, or after the last capture that gave nothing (0
// before either: at once).
stream_pacer_due :: proc(p: ^Stream_Pacer) -> i64 {
	if !p.started && p.polled == 0 { return 0 }
	from := p.polled
	if p.started { from = max(from, p.last) }
	return from + p.interval
}

// A capture at `t` that gave no frame (nothing changed): the next one waits an interval, not less.
stream_pacer_poll :: proc(p: ^Stream_Pacer, t: i64) {
	p.polled = max(p.polled, t)
}

// The timestamp of a frame taken at `t`: its time since the first frame. It never goes back and always moves on, even
// when the clock of two frames says otherwise (a compositor's presentation time and the stream's own clock mixed).
stream_pacer_stamp :: proc(p: ^Stream_Pacer, t: i64) -> i64 {
	if !p.started {
		p.started = true
		p.start, p.last, p.last_stamp = t, t, 0
		return 0
	}
	stamp := max(t - p.start, p.last_stamp + 1)
	p.last = max(t, p.last)
	p.last_stamp = stamp
	return stamp
}

////////////////////////////////
// The two buffers

// The buffers a stream's frames are made in, taken in turn: the frame given before the last one stays readable while
// the next one is made. A buffer is made again only when the frames' size changes.
Frame_Ring :: struct {
	buffers:   [2][dynamic]u8,
	next:      int,
	allocator: runtime.Allocator,
}

// The next buffer, of `bytes` bytes (its content is the frame two before, or zero when it was just made bigger).
frame_ring_take :: proc(r: ^Frame_Ring, bytes: int) -> []u8 {
	b := &r.buffers[r.next]
	if b.allocator.procedure == nil { b.allocator = r.allocator.procedure != nil ? r.allocator : context.allocator }
	if len(b) != bytes { resize(b, bytes) }
	r.next = 1 - r.next
	return b[:]
}

// The buffer taken last is taken again by the next frame_ring_take: it was filled with nothing worth giving (an unchanged
// screen), and the buffer given before it must stay as it is.
frame_ring_return :: proc(r: ^Frame_Ring) {
	r.next = 1 - r.next
}

frame_ring_destroy :: proc(r: ^Frame_Ring) {
	for &b in r.buffers { delete(b) }
	r.buffers = {}
	r.next = 0
}
