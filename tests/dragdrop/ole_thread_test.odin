#+build windows
package dragdrop_test

import "core:testing"
import "core:thread"
import win "core:sys/windows"
import "../../src/platform"

// What a thread answered: dragdrop_thread_init, twice.
@(private = "file")
Ole_Answer :: struct {
	multithreaded: bool,   // the thread joined the multithreaded apartment first (as a decoder's CoInitializeEx does)
	first, again:  bool,
}

@(private = "file")
ask_on_a_thread :: proc(multithreaded: bool) -> Ole_Answer {
	a := Ole_Answer{multithreaded = multithreaded}
	th := thread.create_and_start_with_poly_data(&a, proc(a: ^Ole_Answer) {
		if a.multithreaded { win.CoInitializeEx(nil, .MULTITHREADED) }
		a.first = platform.dragdrop_thread_init()
		a.again = platform.dragdrop_thread_init()
	})
	thread.join(th)
	thread.destroy(th)
	return a
}

// OLE is the thread's: a thread in the multithreaded apartment cannot take drags, which does not stop another thread, and a
// thread asks once.
@(test)
ole_is_initialized_per_thread :: proc(t: ^testing.T) {
	mta := ask_on_a_thread(multithreaded = true)
	testing.expect(t, !mta.first && !mta.again, "a thread in the multithreaded apartment has no OLE")
	sta := ask_on_a_thread(multithreaded = false)
	testing.expect(t, sta.first && sta.again, "another thread has, as often as it asks")
}
