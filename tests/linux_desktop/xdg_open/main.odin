#+build linux
// What platform.open_url calls in the desktop tests (tk desktop_tests puts it first on the PATH as xdg-open): it writes its
// argument to /tmp/gt_opened, whole (written beside, then renamed), for the test to read.
package xdg_open

import "core:os"

main :: proc() {
	if len(os.args) < 2 { os.exit(1) }
	if os.write_entire_file("/tmp/gt_opened.tmp", os.args[1]) != nil { os.exit(1) }
	if os.rename("/tmp/gt_opened.tmp", "/tmp/gt_opened") != nil { os.exit(1) }
}
