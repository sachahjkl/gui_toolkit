// The plugin host in a process of its own (plugins.md, "As built: the plugin host in its own process"): the test
// program is started again as the plugin's process (child.odin's @(init)), every message and display list crosses its
// pipes. A crash of the engine there leaves the program running and the plugin Failed, Restart starts a new process,
// three crashes suspend it; a process that hangs where the interrupt does not reach is killed by Stop's bound.
package plugins_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import plugins "gt:plugins"
import "gt:testkit"
import "gt:testkit/session"

// A failed plugin restarted, once its process's end was read (Crashed comes before Ended).
restart :: proc(s: ^session.Session, fx: ^Fx) {
	session.wait_until(s, fx, proc(s: ^session.Session, fx: ^Fx) -> bool { return plugins.restart(&fx.host, "sample") }, "a restart of the failed plugin", WAIT)
}

// The toast of the sample's "hello", and a wait for one more toast.
say_hello :: proc(s: ^session.Session, fx: ^Fx) {
	wait_started(s, fx, "sample")
	toasts := fx.host.toasts
	testing.expect(s.t, plugins.run_command(&fx.host, "plugin.sample.hello"), "the command did not run")
	session.wait_until(s, Count{fx, toasts + 1}, proc(s: ^session.Session, c: Count) -> bool { return c.fx.host.toasts >= c.at }, "the plugin's toast", WAIT)
}

@(test)
a_crash_of_the_engine_leaves_the_program_running :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-crash")
	write_plugin(root, "sample", SAMPLE_MANIFEST, SAMPLE_MAIN)
	enable(root, "sample")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	say_hello(s, fx)   // (its process runs: the toast came through its pipe)
	testing.expectf(t, strings.contains(fx.host.last_toast, "Hello from Sample"), "the toast says '%s'", fx.host.last_toast)
	plugins.test_crash(&fx.host, "sample")
	wait_state(s, fx, "sample", .Failed)
	p := plugins.find(&fx.host, "sample")
	testing.expectf(t, strings.contains(p.failure, "ended without a word"), "the failure says '%s'", p.failure)
	// the program goes on: its window builds, and Restart starts a new process
	from := fx.builds
	session.frames(s, MORE_BUILDS)
	testing.expect(t, fx.builds >= from + MORE_BUILDS, "the window stopped building")
	restart(s, fx)
	say_hello(s, fx)
	wait_state(s, fx, "sample", .Running)
}

@(test)
three_crashes_suspend_a_plugin :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-crashes")
	write_plugin(root, "sample", SAMPLE_MANIFEST, SAMPLE_MAIN)
	enable(root, "sample")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	for i in 0 ..< plugins.CRASHES_TO_SUSPEND {
		if i > 0 { restart(s, fx) }
		say_hello(s, fx)
		plugins.test_crash(&fx.host, "sample")
		wait_state(s, fx, "sample", i + 1 < plugins.CRASHES_TO_SUSPEND ? .Failed : .Suspended)
	}
	testing.expect(t, !plugins.run_command(&fx.host, "plugin.sample.hello"), "a suspended plugin's command ran")
	session.wait_until(s, root, proc(s: ^session.Session, root: string) -> bool {
		data, err := os.read_entire_file(fmt.tprintf("%s/config/plugins.toml", root), context.temp_allocator)
		return err == nil && strings.contains(string(data), "[suspended]\nsample = true")
	}, "plugins.toml's suspension", WAIT)
}

@(test)
stop_kills_a_process_that_does_not_answer :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-hang")
	write_plugin(root, "sample", SAMPLE_MANIFEST, SAMPLE_MAIN)
	enable(root, "sample")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	say_hello(s, fx)
	plugins.test_hang(&fx.host, "sample")
	wait_state(s, fx, "sample", .Not_Responding)
	plugins.stop(&fx.host, "sample")
	// (its interrupt is never read: STOP_BOUND_MS later, its process is killed, and the plugin is Ready, not Failed)
	wait_state(s, fx, "sample", .Ready)
	say_hello(s, fx)
}
