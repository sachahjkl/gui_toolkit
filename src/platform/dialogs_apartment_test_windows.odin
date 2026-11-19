#+build windows
package platform

// The system's file dialog gets a single-threaded apartment of its own, whatever the caller's thread is in: here the
// caller is in the multithreaded apartment (as a pool's thread can be, or implicitly once another thread made it), and
// the dialog's thread still opens a fresh single-threaded one (S_OK). Before, the dialog ran in the caller's apartment
// and its Explorer view corrupted the heap while it listed the files.

import "core:testing"
import win "core:sys/windows"

@(test)
the_file_dialog_has_a_single_threaded_apartment_of_its_own :: proc(t: ^testing.T) {
	mta := win.CoInitializeEx(nil, .MULTITHREADED)
	defer if mta >= 0 { win.CoUninitialize() }
	testing.expect(t, mta >= 0, "the caller's thread is in the multithreaded apartment")
	testing.expect_value(t, dialog_thread_apartment(), win.S_OK)
}
