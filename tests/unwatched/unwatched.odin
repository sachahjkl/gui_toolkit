// Runs a test's body on a thread the test runner does not watch (imported by the test packages that call DirectWrite).
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
package unwatched

import "core:fmt"
import "core:os"
import "core:testing"
import "core:thread"

@(private)
Job :: struct {
	t:      ^testing.T,
	body:   proc(t: ^testing.T),
	code:   u32,       // the exception that ended the body, 0 when it returned
	module: [260]u16,  // where it was raised
	offset: uintptr,
}

@(private, thread_local)
current: ^Job

// Calls body(t) on a thread of its own and waits for it (directly, off Windows).
run :: proc(t: ^testing.T, body: proc(t: ^testing.T), loc := #caller_location) {
	when ODIN_OS != .Windows {
		body(t)
	} else {
		job := Job{t = t, body = body}
		th := thread.create_and_start_with_data(&job, proc(data: rawptr) {
			current = (^Job)(data)
			current.body(current.t)
			current = nil
		}, init_context = context)
		thread.join(th)
		thread.destroy(th)
		// (testing.fail_now ends the body with a trap too, after saying why)
		if job.code != 0 && !t._fail_now_called {
			module := module_name(job.module[:])
			testing.expectf(t, false, "exception 0x%08X at %s+0x%X in %s", job.code, module, job.offset, loc.procedure, loc = loc)
			fmt.eprintfln("unwatched: exception 0x%08X at %s+0x%X in %s", job.code, module, job.offset, loc.procedure)
			os.flush(os.stderr)
		}
	}
}
