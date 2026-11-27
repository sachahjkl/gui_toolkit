#+build windows
package rpc_test

// (Windows sends no signal: the job's end is the stop's only step past the input)
@(private)
ignore_terminate :: proc() {}
