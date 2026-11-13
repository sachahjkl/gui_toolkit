package tk_toolbox

// Programs that run beside a tool and are stopped with all they started: a compositor for tests, a server. A wrapper
// (NixOS's sway is dbus-run-session, which starts sway and a session bus beside it) leaves the real program running when
// the signal goes to the wrapper alone; a signal to the process group reaches them all.

import "core:os"
import "core:sys/posix"
import "core:time"

// What stop_group gives a group to end on SIGTERM, before SIGKILL.
GROUP_STOP_WAIT :: 3 * time.Second
// The groups guard_groups can stop at once.
@(private = "file") GROUPS_MAX :: 32

// The groups that run now, for the signal handler (it may read nothing else). Written by the thread that starts and stops
// them, the count after the slot.
@(private = "file") running_groups: [GROUPS_MAX]posix.pid_t
@(private = "file") running_count: int

// Starts `command` in a process group of its own (setsid runs it in place: a child of this process is never a group
// leader, so its pid is its group's). `env`: its whole environment (nil: this process's). `out`: its standard output and
// error (nil: none). Stop it with stop_group; a signal that ends the tool stops it too once guard_groups is called.
start_group :: proc(command: []string, env: []string = nil, out: ^os.File = nil) -> (p: os.Process, err: os.Error) {
	cmd := make([dynamic]string, 0, len(command) + 1, context.temp_allocator)
	append(&cmd, "setsid")
	append(&cmd, ..command)
	p = os.process_start({command = cmd[:], env = env, stdout = out, stderr = out}) or_return
	if running_count < GROUPS_MAX {
		running_groups[running_count] = posix.pid_t(p.pid)
		running_count += 1
	}
	return p, nil
}

// Stops the group that start_group made: SIGTERM to all of it, `wait` for the leader, then SIGKILL to what is left. (The
// leader is waited for once it is reaped never again: a second wait would close its handle twice.)
stop_group :: proc(p: os.Process, wait := GROUP_STOP_WAIT) {
	posix.kill(-posix.pid_t(p.pid), .SIGTERM)
	_, err := os.process_wait(p, wait)
	posix.kill(-posix.pid_t(p.pid), .SIGKILL)
	if err == os.General_Error.Timeout { _, _ = os.process_wait(p, wait) }
	group_forget(p)
}

// The leader of a group start_group made ended and was waited for: what it left in its group is killed, and the group
// is no longer stopped (by stop_group, or on a signal).
group_ended :: proc(p: os.Process) {
	posix.kill(-posix.pid_t(p.pid), .SIGKILL)
	group_forget(p)
}

@(private = "file")
group_forget :: proc(p: os.Process) {
	for i in 0 ..< running_count {
		if running_groups[i] != posix.pid_t(p.pid) { continue }
		running_count -= 1
		running_groups[i] = running_groups[running_count]
		return
	}
}

// A signal that ends the tool (timeout's SIGTERM, Ctrl+C, a closed terminal) kills every group start_group made and
// stop_group did not stop: a compositor or a server is never left behind.
guard_groups :: proc() {
	for sig in ([?]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP}) { posix.signal(sig, on_end_signal) }
}

// (kill and _exit only: what a signal handler may call)
@(private = "file")
on_end_signal :: proc "c" (sig: posix.Signal) {
	for i in 0 ..< running_count { posix.kill(-running_groups[i], .SIGKILL) }
	posix._exit(128 + i32(sig))
}
