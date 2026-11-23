#+build !windows
package unwatched

import "core:testing"
import crashsite "../crashsite"

// Off Windows no runner takes a caught exception for a crash: the body runs on the test's own thread (on Linux a crash
// names its place: crashsite).
run :: proc(t: ^testing.T, body: proc(t: ^testing.T), loc := #caller_location) {
	crashsite.arm()
	body(t)
}
