package crash_test

import "core:sys/linux"

// The child's crash leaves no core dump: the report is what the test reads.
quiet_faults :: proc "contextless" () {
	none := linux.RLimit{}
	linux.setrlimit(.CORE, &none)
}
