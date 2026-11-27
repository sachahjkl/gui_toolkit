#+build linux
package rpc_test

import "core:sys/linux"

// (a child that a gentle stop does not end)
@(private)
ignore_terminate :: proc() {
	act: linux.Sig_Action
	act.special = .SIG_IGN
	_ = linux.rt_sigaction(.SIGTERM, &act, nil)
}
