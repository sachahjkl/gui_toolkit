// platform.sigpipe_ignore: a write to a pipe whose reader is gone is an error of that write; the process goes on (a
// plugin's process that died, a compositor's reader that closed its end).
//   odin test tests/sigpipe -collection:gt=src -vet
package sigpipe_test

import "core:os"
import "core:testing"
import "gt:platform"

@(test)
a_write_to_a_closed_pipe_is_an_error :: proc(t: ^testing.T) {
	platform.sigpipe_ignore()
	r, w, err := os.pipe()
	if !testing.expectf(t, err == nil, "no pipe: %v", err) { return }
	os.close(r)
	defer os.close(w)
	// (without the call, SIGPIPE would end the test's process here)
	_, werr := os.write(w, transmute([]u8)string("gone"))
	testing.expect(t, werr != nil, "the write to a closed pipe succeeded")
}
