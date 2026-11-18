#+build linux, darwin, freebsd, openbsd, netbsd
package platform

import "core:sys/posix"

// A peer that closes its pipe while this process writes to it is an EPIPE for that write, not the end of the process:
// a compositor's data source, a plugin's process that died. Leaves a handler the program set itself.
sigpipe_ignore :: proc() {
	old: posix.sigaction_t
	if posix.sigaction(.SIGPIPE, nil, &old) == .OK && old.sa_handler == auto_cast posix.SIG_DFL { posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN) }
}
