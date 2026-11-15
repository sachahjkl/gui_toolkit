package host_test

// A worker's own fonts (host.Worker_Fonts): made on its thread at the first call, kept for the next ones, they measure
// text there; the window's fonts are not touched.

import "core:testing"
import "core:thread"
import "gt:font"
import host "gt:host"

@(test)
a_worker_measures_text_with_its_own_fonts :: proc(t: ^testing.T) {
	Work :: struct { width: f32, same: bool, face: font.Font_Id }
	w: Work
	th := thread.create_and_start_with_data(&w, proc(data: rawptr) {
		w := (^Work)(data)
		f: host.Worker_Fonts
		defer host.worker_fonts_destroy(&f)
		a := host.worker_fonts(&f, headless = true)
		b := host.worker_fonts(&f, headless = true)
		w.same, w.face = a == b && a.face == b.face, a.face
		w.width = font.text_width(&a.state, a.face, 16, "watermark")
	})
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, w.face != 0, "the interface's face")
	testing.expect(t, w.same, "made once, kept for the next calls")
	testing.expectf(t, w.width > 0, "the text measured on the worker: %v", w.width)
}
