#+build !windows
package plugins_test

// Nothing: a failed wait ends its test by a SIGILL that the test runner handles and reports, with the other signals. A
// crash handler took that SIGILL for a crash of the whole process.
crash_reports :: proc() {}
