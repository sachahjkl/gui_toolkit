#+build !linux
#+build !windows
package rpc_test

// (no signals to ignore where the peer does not start)
@(private)
ignore_terminate :: proc() {}
