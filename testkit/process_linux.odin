package tk_testkit

import "core:os"
import "core:strconv"
import "core:strings"

@(private)
native_process_state :: proc() -> (s: Process_State) {
	data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
	if err == nil {
		kib :: proc(line, key: string) -> (i64, bool) {
			if !strings.has_prefix(line, key) { return 0, false }
			v := strings.trim_space(strings.trim_suffix(strings.trim_space(line[len(key):]), "kB"))
			n, ok := strconv.parse_i64(v)
			return n * 1024, ok
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if v, ok := kib(line, "VmRSS:");   ok { s.resident = v }
			if v, ok := kib(line, "RssAnon:"); ok { s.private += v }
			if v, ok := kib(line, "VmSwap:");  ok { s.private += v }
		}
	}
	// open file descriptors: the entries of /proc/self/fd (handles, the closest POSIX has); the handle this read opens is
	// closed before the count is taken.
	if infos, derr := os.read_all_directory_by_path("/proc/self/fd", context.temp_allocator); derr == nil {
		s.handles = i64(len(infos))
	}
	return
}

@(private)
native_memory_split :: proc() -> (m: Memory_Split) { return }   // Windows-only for now (heaps and VM regions)
