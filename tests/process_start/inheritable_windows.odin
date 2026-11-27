package process_start_test

import "core:os"
import win "core:sys/windows"

// Makes the handle of `f` inheritable, as a library or a log file opened .Inheritable leaves one.
@(private)
make_inheritable :: proc(f: ^os.File) -> bool {
	return bool(win.SetHandleInformation(win.HANDLE(os.fd(f)), win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT))
}
