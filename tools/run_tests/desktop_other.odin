#+build !windows
package run_tests

// (On Linux a test that needs a server has one nobody sees: tk desktop_tests.)
on_own_desktop :: proc(code: ^int) -> bool { return false }
