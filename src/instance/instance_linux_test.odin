#+build linux
package tk_instance

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"

// Options that give no wait wait WAIT_MS_DEFAULT; a name nobody owns is not running, and asks to quit go nowhere, at once:
// no owner is no socket, and the default wait is for an owner that starts or closes.
@(test)
no_wait_given_is_the_default_and_nobody_answers_at_once :: proc(t: ^testing.T) {
	testing.expect_value(t, wait_of({}), WAIT_MS_DEFAULT)
	testing.expect_value(t, wait_of({wait_ms = 5}), 5)
	testing.expect_value(t, wait_of({wait_ms = -1}), 0)   // (once)
	o := Instance_Options{name = fmt.tprintf("tk_instance_nobody_%d", time.to_unix_nanoseconds(time.now()))}
	start := time.tick_now()
	testing.expect(t, !running(o), "nobody owns it")
	testing.expect(t, !quit(o), "nobody takes the quit")
	testing.expectf(t, time.tick_since(start) < time.Duration(WAIT_MS_DEFAULT) * time.Millisecond, "no owner, no wait: %v", time.tick_since(start))
}

// A listener nobody serves, whose backlog is full: a blocking connect would wait there for ever.
@(test)
a_full_backlog_does_not_hold_a_start :: proc(t: ^testing.T) {
	name := fmt.tprintf("tk_instance_backlog_%d", time.to_unix_nanoseconds(time.now()))
	path := path_of(name, ".sock")
	addr, ok := address_of(path)
	testing.expect(t, ok)
	listener, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer linux.close(listener)
	testing.expect_value(t, linux.bind(listener, &addr), linux.Errno.NONE)
	defer linux.unlink(strings.clone_to_cstring(path, context.temp_allocator))
	testing.expect_value(t, linux.listen(listener, 0), linux.Errno.NONE)
	full := make([dynamic]linux.Fd, context.temp_allocator)
	defer for s in full { linux.close(s) }
	for {
		s, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
		testing.expect_value(t, serr, linux.Errno.NONE)
		append(&full, s)
		if linux.connect(s, &addr) != .NONE { break }
	}
	testing.expect_value(t, forward_once(name, "", nil, FORWARD_MIN_MS), Reply.No_Window)
}

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
