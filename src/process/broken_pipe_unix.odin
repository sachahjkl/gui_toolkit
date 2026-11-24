#+build linux, darwin, freebsd, openbsd, netbsd
package tk_process

import "core:sys/posix"

// A child that closes its input while run writes to it is an EPIPE for that write, not the end of this process. Leaves
// a handler the program set itself (platform.sigpipe_ignore does the same).
@(private)
broken_pipe_ignore :: proc() {
	old: posix.sigaction_t
	if posix.sigaction(.SIGPIPE, nil, &old) == .OK && old.sa_handler == auto_cast posix.SIG_DFL { posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN) }
}
