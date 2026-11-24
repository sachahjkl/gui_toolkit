#+build linux
package process_start_test

import "core:os"

// The descriptors this process has open (-1: not known).
@(private)
open_handles :: proc() -> int {
	entries, err := os.read_all_directory_by_path("/proc/self/fd", context.temp_allocator)
	if err != nil { return -1 }
	return len(entries) - 1   // (the folder's own descriptor, open while it is read)
}
