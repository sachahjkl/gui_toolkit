package gt_base

import "core:testing"

// A path that climbs, a bare name, a relative path: never a full path that a restriction trusts as it is written.
@(test)
trust_path_rules :: proc(t: ^testing.T) {
	testing.expect(t, contains_dot_dot(`C:\Program Files\..\Users\me\x.exe`), "a climb with backslashes")
	testing.expect(t, contains_dot_dot("/usr/../home/me/x"), "a climb with slashes")
	testing.expect(t, contains_dot_dot(".."), "alone")
	testing.expect(t, !contains_dot_dot(`C:\Program Files\a..b\x.exe`), "two dots in a name are a name")
	testing.expect(t, windows_absolute(`C:\Windows\System32\cmd.exe`), "a drive's path")
	testing.expect(t, windows_absolute(`\\server\share\x.exe`), "a UNC path")
	testing.expect(t, !windows_absolute("cmd.exe"), "a bare name")
	testing.expect(t, !windows_absolute(`C:x.exe`), "a drive's relative path")
	testing.expect(t, !windows_absolute(`Windows\System32\cmd.exe`), "a relative path")
}

// A test build's elevation alone does not restrict it (CI runners run as an administrator): every start allowed.
@(test)
a_test_is_not_restricted :: proc(t: ^testing.T) {
	testing.expect(t, GT_ELEVATED_UNRESTRICTED, "a test build")
	restrict_if_elevated()   // (what a program's start says: in a test build, nothing)
	testing.expect(t, !restricted(), "not restricted, whatever its token")
	testing.expect(t, may_start("anything"), "an unrestricted process starts what it wants")
}
