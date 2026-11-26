package gt_base

import "core:testing"

// Only root's folders: the Nix store and the system's, by a full path that does not climb.
@(test)
trusted_programs_on_linux :: proc(t: ^testing.T) {
	testing.expect(t, trusted_program("/run/current-system/sw/bin/xdg-open"), "the system's profile")
	testing.expect(t, trusted_program("/nix/store/abc-coreutils/bin/true"), "the Nix store")
	testing.expect(t, trusted_program("/usr/bin/true"), "/usr")
	testing.expect(t, !trusted_program("/home/me/.local/bin/x"), "the user's")
	testing.expect(t, !trusted_program("/tmp/x"), "anyone's")
	testing.expect(t, !trusted_program("xdg-open"), "a bare name: the PATH is the user's")
	testing.expect(t, !trusted_program("/usr/../home/me/x"), "a climb")
	testing.expect(t, !trusted_program("/nix/store/"), "a folder alone")
}
