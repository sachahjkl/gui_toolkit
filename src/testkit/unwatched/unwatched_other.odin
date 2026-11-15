#+build !windows
package unwatched

import "core:testing"

// Off Windows no runner takes a caught exception for a crash: the body runs on the test's own thread.
run :: proc(t: ^testing.T, body: proc(t: ^testing.T), loc := #caller_location) {
	body(t)
}
