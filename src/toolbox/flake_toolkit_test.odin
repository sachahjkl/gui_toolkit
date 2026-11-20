package tk_toolbox

import "core:fmt"
import "core:os"
import "core:testing"
import testkit "../testkit"

@(private = "file")
LOCK :: `{"nodes": {"gui_toolkit": {"flake": false, "locked": {"owner": "sachahjkl", "repo": "gui_toolkit", "rev": "bcd84069b0ad8da2fc8d7ad7fee6d6f1c39dbb8d", "type": "github"}}, "root": {"inputs": {"gui_toolkit": "gui_toolkit"}}}, "root": "root", "version": 7}`

// flake.lock's pin is read; a lock without the toolkit pins nothing, and is not checked.
@(test)
the_flake_pin_of_the_toolkit_is_read :: proc(t: ^testing.T) {
	rev, ok := flake_toolkit_pin(LOCK)
	testing.expect(t, ok)
	testing.expect_value(t, rev, "bcd84069b0ad8da2fc8d7ad7fee6d6f1c39dbb8d")
	_, none := flake_toolkit_pin(`{"nodes": {"root": {}}, "root": "root", "version": 7}`)
	testing.expect(t, !none, "no toolkit input: no pin")
	_, junk := flake_toolkit_pin("not json")
	testing.expect(t, !junk)
	testing.expect_value(t, flake_toolkit_says("bcd84069b0ad8da2fc8d7ad7fee6d6f1c39dbb8d", "bcd84069b0ad8da2fc8d7ad7fee6d6f1c39dbb8d"), "")
	testing.expect(t, flake_toolkit_says("bcd84069b0ad8da2fc8d7ad7fee6d6f1c39dbb8d", "0a0f39b8e2d1c0b9a8f7e6d5c4b3a2918071605f") != "", "a submodule moved without its pin")
}

// A submodule's checkout: its .git file names its git folder, whose HEAD is a commit, or a branch in its refs.
@(test)
the_head_of_a_submodule_is_read :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "flake")
	sub := fmt.tprintf("%s/ext/gui_toolkit", root)
	git := fmt.tprintf("%s/.git/modules/ext/gui_toolkit", root)
	testing.expect(t, os.make_directory_all(sub) == nil && os.make_directory_all(fmt.tprintf("%s/refs/heads", git)) == nil)
	_ = os.write_entire_file(fmt.tprintf("%s/.git", sub), transmute([]u8)string("gitdir: ../../.git/modules/ext/gui_toolkit\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/HEAD", git), transmute([]u8)string("bcd84069b0ad8da2fc8d7ad7fee6d6f1c39dbb8d\n"))
	head, ok := checkout_head(sub)
	testing.expect(t, ok)
	testing.expect_value(t, head, "bcd84069b0ad8da2fc8d7ad7fee6d6f1c39dbb8d")
	_ = os.write_entire_file(fmt.tprintf("%s/HEAD", git), transmute([]u8)string("ref: refs/heads/master\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/refs/heads/master", git), transmute([]u8)string("0a0f39b8e2d1c0b9a8f7e6d5c4b3a2918071605f\n"))
	head, ok = checkout_head(sub)
	testing.expect(t, ok)
	testing.expect_value(t, head, "0a0f39b8e2d1c0b9a8f7e6d5c4b3a2918071605f")
	_ = os.write_entire_file(fmt.tprintf("%s/flake.lock", root), transmute([]u8)string(LOCK))
	testing.expect(t, !flake_toolkit_check({}, root), "the lock pins bcd84069, the submodule is at 0a0f39b8")
}
