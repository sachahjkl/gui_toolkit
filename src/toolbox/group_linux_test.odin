#+build linux
package tk_toolbox

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// A wrapper that starts a program and waits: stop_group ends the program too, not only the wrapper.
@(test)
a_group_stops_with_what_it_started :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	pid_file := fmt.tprintf("%s/tk_toolbox_group_%d", base, os.get_pid())
	defer os.remove(pid_file)
	p, err := start_group({"sh", "-c", fmt.tprintf("sleep 60 & echo $! > %s; wait", pid_file)})
	testing.expect(t, err == nil)
	if err != nil { return }
	child := 0
	for _ in 0 ..< 200 {
		if data, rerr := os.read_entire_file(pid_file, context.temp_allocator); rerr == nil {
			if n, ok := strconv.parse_int(strings.trim_space(string(data))); ok { child = n; break }
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, child > 0, "the wrapper started its program")
	if child <= 0 { stop_group(p); return }
	stop_group(p)
	// (the child is the shell's, which is gone: init reaps it; until then it may linger as a zombie, which kill(0) sees)
	gone := false
	for _ in 0 ..< 200 {
		if posix.kill(posix.pid_t(child), .NONE) != .OK { gone = true; break }
		if stat, serr := os.read_entire_file(fmt.tprintf("/proc/%d/stat", child), context.temp_allocator); serr == nil && strings.contains(string(stat), ") Z ") { gone = true; break }
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, gone, "the program the wrapper started is stopped too")
}
