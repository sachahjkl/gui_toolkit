package debug_test

// These tests drive the toolkit's global UI state (one State current at a time): the test runner must take them one at
// a time.
#assert(#config(ODIN_TEST_THREADS, 0) == 1, "run these tests with -define:ODIN_TEST_THREADS=1: they drive the toolkit's global UI state one test at a time")
