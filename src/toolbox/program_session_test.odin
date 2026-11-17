package tk_toolbox

import "core:net"
import "core:testing"

// The port free_port gives is one a listener can take now.
@(test)
a_free_port_can_be_listened_on :: proc(t: ^testing.T) {
	port, ok := free_port()
	testing.expect(t, ok, "the system gives a port")
	if !ok { return }
	testing.expect(t, port > 0 && port < 65536, "a port")
	l, err := net.listen_tcp({address = net.IP4_Loopback, port = port})
	testing.expect(t, err == nil, "a listener takes it")
	if err != nil { return }
	defer net.close(l)
	// (a second session while the first one's program listens: never the same port)
	other, got := free_port()
	testing.expect(t, got && other != port, "a second run gets another port")
}

// A session with no command does not start, and its stop is safe: a tool's `defer program_session_stop` runs on every path.
@(test)
a_session_without_a_command_does_not_start :: proc(t: ^testing.T) {
	s: Program_Session
	why := program_session_start(&s, "build/program_session_test", {})
	testing.expect(t, why != "", "it says why")
	testing.expect_value(t, program_session_stop(&s), -1)
	_, cwhy := program_session_connect(&s)
	testing.expect(t, cwhy != "", "nothing to connect to")
}
