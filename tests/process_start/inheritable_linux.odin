package process_start_test

import "core:os"
import "core:sys/linux"

// Clears close-on-exec on `f`, as a library that opens without O_CLOEXEC leaves a descriptor.
@(private)
make_inheritable :: proc(f: ^os.File) -> bool {
	return linux.fcntl(linux.Fd(os.fd(f)), linux.F_SETFD, linux.Fd(0)) == .NONE
}
