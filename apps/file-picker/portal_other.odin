#+build !linux
package gt_file_picker

import req "gt:file_request"
import "gt:process"

// The XDG desktop portal is Linux's: elsewhere --portal says so.
portal_serve :: proc() -> int {
	process.console_error("gt-file-picker: --portal serves the XDG desktop portal, which only Linux has\n")
	return req.EXIT_ERROR
}
