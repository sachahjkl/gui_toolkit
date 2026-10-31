#+build linux
package tk_instance

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"

// The runtime directory is used only when it is this user's alone: another user could have made it first, in /tmp.
@(test)
a_directory_others_can_reach_is_not_used :: proc(t: ^testing.T) {
	base := fmt.tprintf("/tmp/tk_instance_test_%d", time.to_unix_nanoseconds(time.now()))
	dir := strings.clone_to_cstring(base, context.temp_allocator)
	testing.expect(t, !dir_is_ours(dir), "absent")
	linux.mkdir(dir, {.IRUSR, .IWUSR, .IXUSR})
	defer linux.rmdir(dir)
	testing.expect(t, dir_is_ours(dir), "this user's alone")
	linux.chmod(dir, {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP})
	testing.expect(t, !dir_is_ours(dir), "the group can reach it")
	linux.chmod(dir, {.IRUSR, .IWUSR, .IXUSR, .IWOTH})
	testing.expect(t, !dir_is_ours(dir), "others can write to it")
	linux.chmod(dir, {.IRUSR, .IWUSR, .IXUSR})
	link := strings.clone_to_cstring(fmt.tprintf("%s_link", base), context.temp_allocator)
	linux.symlink(dir, link)
	defer linux.unlink(link)
	testing.expect(t, !dir_is_ours(link), "a link is not the directory")
}
