package crashsite_test

import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import crashsite "gt:testkit/crashsite"

// A child that touches address 0 writes one line with its place and ends by SIGSEGV within a bound.
@(test)
a_fault_names_its_place_and_ends_the_process :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	if !testing.expect(t, posix.pipe(&fds) == .OK, "pipe") { return }
	pid := posix.fork()
	if pid == 0 {
		// (the child: the runner's handler, copied by fork, would hold this thread for ever; the default is the replaced one)
		dfl := posix.sigaction_t{}
		dfl.sa_handler = auto_cast posix.SIG_DFL
		for sig in ([]posix.Signal{.SIGILL, .SIGFPE, .SIGSEGV, .SIGBUS}) { posix.sigaction(sig, &dfl, nil) }
		posix.dup2(fds[1], posix.STDERR_FILENO)
		crashsite.arm()
		p := (^int)(uintptr(0))
		p^ = 1
		posix._exit(0)
	}
	posix.close(fds[1])
	defer posix.close(fds[0])
	status: i32
	deadline := time.tick_add(time.tick_now(), 10 * time.Second)
	ended := false
	for !ended && time.tick_diff(time.tick_now(), deadline) > 0 {
		if posix.waitpid(pid, &status, {.NOHANG}) == pid { ended = true } else { time.sleep(5 * time.Millisecond) }
	}
	if !ended { posix.kill(pid, .SIGKILL); posix.waitpid(pid, &status, {}) }
	testing.expect(t, ended, "the child ended by itself (no spin)")
	testing.expect(t, posix.WIFSIGNALED(status) && posix.WTERMSIG(status) == .SIGSEGV, "it ended by SIGSEGV")
	buf: [1024]u8
	n := posix.read(fds[0], raw_data(buf[:]), len(buf))
	out := n > 0 ? string(buf[:n]) : ""
	testing.expectf(t, strings.has_prefix(out, "crash site: SIGSEGV touching 0x0 at "), "its place on stderr: %q", out)
	// (the test's binary, with the instruction's offset in it: what the symbolizer reads)
	testing.expectf(t, strings.contains(out, "/crashsite+0x"), "the module is the test's binary: %q", out)
}
