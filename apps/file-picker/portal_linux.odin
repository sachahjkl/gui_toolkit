#+build linux
package gt_file_picker

import "core:strings"
import req "gt:file_request"
import "gt:process"

// The XDG portal's FileChooser backend: each call is answered by this same program, run again with --json.
portal_serve :: proc() -> int {
	s: req.Portal_Server
	// (/proc/self/exe: this executable, wherever it was started from)
	child := []string{"/proc/self/exe", "--json"}
	if why := req.portal_open(&s, child); why != "" {
		process.console_error(strings.concatenate({"gt-file-picker: ", why, "\n"}, context.temp_allocator))
		return req.EXIT_ERROR
	}
	defer req.portal_close(&s)
	req.portal_run(&s)
	return 0
}
