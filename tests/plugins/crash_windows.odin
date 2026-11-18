package plugins_test

import "core:os"
import crash "gt:crash"

// run_tests names a folder for crash reports: a crash of this process then says its stack in the CI's log (on Windows
// the test runner says nothing of an access violation). A second install does nothing.
crash_reports :: proc() {
	if dir := os.get_env("TOOLKIT_TEST_CRASH_DIR", context.temp_allocator); dir != "" {
		_ = crash.install({program = "plugins_test", report_dir = dir})
	}
}
