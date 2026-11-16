#+build linux
package crash_test

import "core:os"
import "core:sys/posix"
import "core:testing"
import crash "gt:crash"
import "gt:testkit"

// A session the system ends (SIGTERM: the person's session closes) is no crash: its session file goes with it, and the
// next start finds nothing to report. (Every program said it had crashed after each logout.)
@(test)
a_session_the_system_ends_is_no_crash :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "terminated")
	context.allocator = context.temp_allocator
	p, started := start_child(t, "hang", dir)
	if !started { return }
	testing.expect(t, posix.kill(posix.pid_t(p.pid), .SIGTERM) == .OK)
	_, _ = os.process_wait(p, CHILD_LIMIT)
	testing.expect_value(t, len(sessions(dir)), 0)
	out, _ := run_child(t, "last", dir)
	testing.expect_value(t, len(reports(dir, crash.UNCLEAN_PREFIX)), 0)
	testing.expect_value(t, out, NO_REPORT)
}
