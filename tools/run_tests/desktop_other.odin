#+build !windows
package run_tests

// (On Linux a test that needs a server has one nobody sees: tools/linux_desktop.sh.)
on_own_desktop :: proc(code: ^int) -> bool { return false }
