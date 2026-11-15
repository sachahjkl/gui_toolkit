package tk_process

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"

@(private = "file") TEST_WAIT :: 5 * time.Second

// The test's own child, a sleep: found by the full path of its file, with its start time; then ended through what was
// found, and found no more. A path no process runs finds none, and the test itself is never found.
@(test)
a_process_is_found_by_the_path_of_its_file :: proc(t: ^testing.T) {
	child, err := os.process_start({command = {"sleep", "30"}})
	if !testing.expect(t, err == nil, "sleep starts") { return }
	defer { _ = os.process_kill(child); _, _ = os.process_wait(child, TEST_WAIT) }
	pid := i32(child.pid)
	exe := link_of(strings.concatenate({"/proc/", int_words(int(pid)), "/exe"}, context.temp_allocator))
	if !testing.expect(t, exe != "", "the child's file is known") { return }

	found := processes_of(exe, context.temp_allocator)
	start, _ := process_start_time(pid)
	mine := false
	for f in found { if f.pid == pid { mine = f.start_time == start } }
	testing.expect(t, mine, "the child is found, with its start time")

	testing.expect_value(t, len(processes_of("/no/such/program", context.temp_allocator)), 0)
	for f in processes_of(link_of("/proc/self/exe"), context.temp_allocator) {
		testing.expect(t, f.pid != i32(os.get_pid()), "the calling process is left out")
	}

	for f in found {
		if f.pid != pid { continue }
		r, _ := signal_process(f.pid, f.start_time, .Terminate)
		testing.expect_value(t, r, Act_Result.Done)
	}
	_, _ = os.process_wait(child, TEST_WAIT)
	for f in processes_of(exe, context.temp_allocator) { testing.expect(t, f.pid != pid, "an ended process is found no more") }
}

@(test)
an_executable_is_the_same_path :: proc(t: ^testing.T) {
	testing.expect(t, same_executable("/a/b/papier", "/a/b/papier"))
	testing.expect(t, !same_executable("/a/b/papier", "/a/c/papier"), "never by its name alone")
	testing.expect(t, !same_executable("/a/b/papier (deleted)", "/a/b/papier"), "a file replaced since is not the one there")
	testing.expect(t, !same_executable("", ""))
}

@(private = "file")
link_of :: proc(path: string) -> string {
	buf := make([]u8, 4096, context.temp_allocator)
	n, err := linux.readlink(strings.clone_to_cstring(path, context.temp_allocator), buf)
	if err != .NONE || n <= 0 { return "" }
	return string(buf[:n])
}

@(private = "file")
int_words :: proc(n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, n)
	return strings.to_string(b)
}
