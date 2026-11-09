package tk_toolbox

// Programs that run beside a tool and are stopped with all they started: a compositor for tests, a server. A wrapper
// (NixOS's sway is dbus-run-session, which starts sway and a session bus beside it) leaves the real program running when
// the signal goes to the wrapper alone; a signal to the process group reaches them all.

import "core:os"
import "core:sys/posix"
import "core:time"

// What stop_group gives a group to end on SIGTERM, before SIGKILL.
GROUP_STOP_WAIT :: 3 * time.Second

// Starts `command` in a process group of its own (setsid runs it in place: a child of this process is never a group
// leader, so its pid is its group's). `env`: its whole environment (nil: this process's). `out`: its standard output and
// error (nil: none). Stop it with stop_group.
start_group :: proc(command: []string, env: []string = nil, out: ^os.File = nil) -> (p: os.Process, err: os.Error) {
	cmd := make([dynamic]string, 0, len(command) + 1, context.temp_allocator)
	append(&cmd, "setsid")
	append(&cmd, ..command)
	return os.process_start({command = cmd[:], env = env, stdout = out, stderr = out})
}

// Stops the group that start_group made: SIGTERM to all of it, `wait` for the leader, then SIGKILL to what is left.
stop_group :: proc(p: os.Process, wait := GROUP_STOP_WAIT) {
	posix.kill(-posix.pid_t(p.pid), .SIGTERM)
	_, _ = os.process_wait(p, wait)
	posix.kill(-posix.pid_t(p.pid), .SIGKILL)
	_, _ = os.process_wait(p, wait)
}
