#+build windows
// The Windows backend on the real desktop: opt-in (CAPTURE_LIVE=1), since it needs a signed-in desktop and reads the
// screen.
//   set CAPTURE_LIVE=1 && odin test tests/capture -vet
package capture_test

import "core:os"
import "core:testing"
import "../../src/capture"

@(private = "file")
live :: proc() -> bool {
	v, _ := os.lookup_env("CAPTURE_LIVE", context.temp_allocator)
	return v == "1"
}

// Every output gives a picture of its physical size, twice in a row (the second from the kept duplication, which has
// no new frame when the screen did not change); the desktop holds them all; the windows have rects, front to back, and
// the first one with a rect gives a picture.
@(test)
the_windows_desktop_is_captured :: proc(t: ^testing.T) {
	if !live() { return }
	s, err := capture.open()
	testing.expect_value(t, err, capture.Error.None)
	if s == nil { return }
	defer capture.close(s)
	testing.expect_value(t, s.backend, capture.Backend.Windows)
	testing.expect(t, capture.windows_have_rects(s))

	outs := capture.outputs(s)
	testing.expect(t, len(outs) > 0, "at least one output")
	for o in outs {
		testing.expect(t, o.scale >= 1, o.name)
		for _ in 0 ..< 2 {
			f, ferr := capture.output(s, o.id)
			testing.expectf(t, ferr == .None, "%s: %v", o.name, ferr)
			testing.expect(t, abs(f32(f.width) - f32(o.rect.w) * o.scale) <= o.scale + 1, o.name)
			testing.expect_value(t, f.origin, [2]i32{o.rect.x, o.rect.y})
			testing.expect(t, len(f.pixels) == 0 || f.pixels[3] == 255, "opaque")
			capture.frame_free(&f)
		}
	}

	d, derr := capture.desktop(s)
	testing.expect_value(t, derr, capture.Error.None)
	testing.expect(t, d.width > 0 && d.height > 0)
	capture.frame_free(&d)

	wins := capture.windows(s)
	for w in wins {
		if !w.has_rect || w.minimized { continue }
		testing.expect(t, w.rect.w > 0 && w.rect.h > 0, w.title)
		f, werr := capture.window(s, w.id)
		testing.expectf(t, werr == .None, "%s (%s): %v", w.title, w.app_id, werr)
		testing.expect(t, f.width > 0 && f.height > 0, w.title)
		capture.frame_free(&f)
		break
	}
}
