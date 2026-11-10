// Runs a test's body on a thread the test runner does not watch: on Windows, the test packages whose code calls DirectWrite,
// Direct3D or DXGI (a program's tests with a window too).
//
// On Windows the runner of core:testing takes any exception raised on a test's own thread for a crash, even one caught
// further up: its vectored exception handler marks the test failed ("Signal caught: Unknown") and the runner kills the
// thread. DirectWrite throws C++ exceptions and catches them itself when an entry of its in-process cache does not fit
// (CacheWriter::AllocateDataAligned for a face or a shaping entry, GlyphDataElement::AddGlyph for a glyph's bitmap).
// Which call meets a full cache depends on all that the tests of the process put in that shared cache before (the
// factory is shared): a test failed now and then (on a 4-core CI runner, text_test.atlas_stress about once in five
// runs, while concurrent_measure_while_unloading filled the cache with fonts), and a thread killed while DirectWrite
// or the font package held a lock could keep the whole runner from ending.
//
// On the body's thread a caught C++ exception (0xE06D7363) is nobody's business. Any other exception fails the test
// and ends that thread, as the runner does with a test's thread: a failed assertion, a bounds check, testing.fail_now
// (testing.expect_signal and expect_assert do not work in a body run here).
//
// What the body leaves to testing.cleanup is done on its thread when it returns, last first, as the runner does: a window,
// a renderer or a testkit session made in the body ends on the thread that made it (a window answers only there). A body
// ended by an exception leaves them to the runner.
package unwatched

import "core:testing"

// Calls body(t) on a thread of its own and waits for it (directly, off Windows).
run :: proc(t: ^testing.T, body: proc(t: ^testing.T), loc := #caller_location) {
	when ODIN_OS == .Windows {
		run_unwatched(t, body, loc)
	} else {
		body(t)
	}
}
