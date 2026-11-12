// The pure parts of a stream: its pace and its timestamps, the two buffers its frames are made in, the cut of a region
// without an allocation. No desktop needed: they run on every system.
//   odin test tests/capture -vet
package capture_test

import "core:testing"
import "core:time"
import "../../src/capture"

// The first frame is at 0; the next capture waits an interval after the last frame; timestamps count from the first.
@(test)
pacer_spaces_the_frames :: proc(t: ^testing.T) {
	p: capture.Stream_Pacer
	capture.stream_pacer_init(&p, 25)   // 40 ms
	testing.expect_value(t, capture.stream_pacer_due(&p), i64(0))
	base := i64(5 * time.Second)
	testing.expect_value(t, capture.stream_pacer_stamp(&p, base), i64(0))
	testing.expect_value(t, capture.stream_pacer_due(&p), base + i64(40 * time.Millisecond))
	testing.expect_value(t, capture.stream_pacer_stamp(&p, base + i64(100 * time.Millisecond)), i64(100 * time.Millisecond))
	testing.expect_value(t, capture.stream_pacer_due(&p), base + i64(140 * time.Millisecond))
}

// A frame whose time is before the last one (two clocks mixed) still gets a later timestamp.
@(test)
pacer_timestamps_never_go_back :: proc(t: ^testing.T) {
	p: capture.Stream_Pacer
	capture.stream_pacer_init(&p, 60)
	_ = capture.stream_pacer_stamp(&p, 1000)
	a := capture.stream_pacer_stamp(&p, 50_000_000)
	b := capture.stream_pacer_stamp(&p, 40_000_000)
	c := capture.stream_pacer_stamp(&p, 50_000_000)
	testing.expect(t, a > 0)
	testing.expect(t, b > a, "a frame stamped earlier than the one before")
	testing.expect(t, c > b, "two frames with one time and one timestamp")
}

// A capture that gave nothing moves the next one an interval on: a backend that compares does not read in a loop.
@(test)
pacer_poll_waits_an_interval :: proc(t: ^testing.T) {
	p: capture.Stream_Pacer
	capture.stream_pacer_init(&p, 10)   // 100 ms
	capture.stream_pacer_poll(&p, 1_000_000_000)
	testing.expect_value(t, capture.stream_pacer_due(&p), i64(1_100_000_000))
	_ = capture.stream_pacer_stamp(&p, 1_200_000_000)
	testing.expect_value(t, capture.stream_pacer_due(&p), i64(1_300_000_000))
	capture.stream_pacer_poll(&p, 1_350_000_000)
	testing.expect_value(t, capture.stream_pacer_due(&p), i64(1_450_000_000))
}

// The two buffers alternate, so the frame given before stays as it was while the next is written; a size change makes
// them again; a buffer given back is taken again.
@(test)
ring_alternates_its_buffers :: proc(t: ^testing.T) {
	r: capture.Frame_Ring
	defer capture.frame_ring_free(&r)
	a := capture.frame_ring_take(&r, 16)
	a[0] = 1
	b := capture.frame_ring_take(&r, 16)
	b[0] = 2
	testing.expect(t, raw_data(a) != raw_data(b))
	testing.expect_value(t, a[0], u8(1))
	c := capture.frame_ring_take(&r, 16)
	testing.expect(t, raw_data(c) == raw_data(a), "the third take is the first buffer")
	capture.frame_ring_return(&r)
	d := capture.frame_ring_take(&r, 16)
	testing.expect(t, raw_data(d) == raw_data(a), "a buffer given back is taken again")
	testing.expect_value(t, b[0], u8(2))
	e := capture.frame_ring_take(&r, 64)
	testing.expect_value(t, len(e), 64)
}

// A region of a frame at scale 2, cut into a buffer of the caller's: the pixels of the region, and its place.
@(test)
crop_into_cuts_a_region :: proc(t: ^testing.T) {
	// a 4 x 4 frame at scale 2 placed at (10, 20): logical 2 x 2; pixel (x, y) holds x + 10 * y in its blue byte
	pixels := make([]u8, 4 * 4 * 4, context.temp_allocator)
	for y in 0 ..< 4 { for x in 0 ..< 4 { pixels[(y * 4 + x) * 4] = u8(x + 10 * y) } }
	f := capture.Frame{pixels = pixels, width = 4, height = 4, stride = 16, scale = 2, origin = {10, 20}}
	r := capture.Rect{11, 21, 1, 1}   // the bottom right quarter
	w, h := capture.crop_size(f, r)
	testing.expect_value(t, w, i32(2))
	testing.expect_value(t, h, i32(2))
	dst := make([]u8, int(w * h * 4), context.temp_allocator)
	out, ok := capture.crop_into(f, r, dst)
	testing.expect(t, ok)
	testing.expect_value(t, out.origin, [2]i32{11, 21})
	testing.expect(t, raw_data(out.pixels) == raw_data(dst), "the cut is in the caller's buffer")
	want := [4]u8{22, 23, 32, 33}
	for i in 0 ..< 4 { testing.expect_value(t, out.pixels[i * 4], want[i]) }
	// too small a buffer, or a region outside the frame: no frame
	_, ok = capture.crop_into(f, r, dst[:4])
	testing.expect(t, !ok)
	_, ok = capture.crop_into(f, {100, 100, 2, 2}, dst)
	testing.expect(t, !ok)
}
