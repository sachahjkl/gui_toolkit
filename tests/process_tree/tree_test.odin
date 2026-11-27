// gt:process's trees: a child and its grandchild end with the tree, with its child's end, and with the program that
// started them, even when that program is killed. The processes are this test program, started again with MODE_ENV
// set: its @(init) acts before the test runner starts (a package of tests/, as process_start: an @(init) in a test file
// of src would run in every program).
//   odin run tools/run_tests -- process_tree
package process_tree_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "gt:process"

@(private = "file") MODE_ENV :: "GT_PROCESS_TREE_TEST"
@(private = "file") BOUND :: 60 * time.Second
@(private = "file") END_BOUND :: 15 * time.Second
@(private = "file") IDLE :: time.Hour

// "parent": starts a tree whose child is "child" on its own standard output, then idles.
// "child" / "child_exit:<code>": starts a grandchild ("idle"), writes "<own pid> <grandchild's pid>\n", then idles or
// exits with the code. "idle": waits to be ended.
@(init)
@(private = "file")
child_main :: proc "contextless" () {
	context = runtime.default_context()
	mode, is_child := os.lookup_env(MODE_ENV, context.temp_allocator)
	if !is_child { return }
	switch {
	case mode == "parent":
		t, err := process.tree_start({command = {process.executable_path(), "child"}, env = mode_env("child"), stdout = os.stdout})
		if err != nil { os.exit(3) }
		_ = t
		idle()
	case mode == "child" || strings.has_prefix(mode, "child_exit:"):
		g, err := process.start({command = {process.executable_path()}, env = mode_env("idle")})
		if err != nil { os.exit(4) }
		fmt.printf("%d %d\n", os.get_pid(), g.pid)
		if colon := strings.index_byte(mode, ':'); colon >= 0 {
			n, _ := strconv.parse_int(mode[colon + 1:])
			os.exit(n)
		}
		idle()
	case mode == "idle":
		idle()
	}
	os.exit(5)
}

@(private = "file")
idle :: proc() -> ! {
	for { time.sleep(IDLE) }
}

@(private = "file")
mode_env :: proc(mode: string) -> []string {
	parent, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, context.temp_allocator)
	for e in parent { if !strings.has_prefix(e, MODE_ENV + "=") { append(&env, e) } }
	append(&env, fmt.tprintf("%s=%s", MODE_ENV, mode))
	return env[:]
}

// The two pids a "child" writes on its first line.
@(private = "file")
read_pids :: proc(f: ^os.File) -> (child, grandchild: int, ok: bool) {
	line := make([dynamic]u8, context.temp_allocator)
	b: [1]u8
	for {
		n, err := os.read(f, b[:])
		if err != nil || n <= 0 { return }
		if b[0] == '\n' { break }
		append(&line, b[0])
	}
	text := string(line[:])
	space := strings.index_byte(text, ' ')
	if space < 0 { return }
	x, ok1 := strconv.parse_int(text[:space])
	y, ok2 := strconv.parse_int(text[space + 1:])
	return x, y, ok1 && ok2
}

// The test kills the program that started the tree (SIGKILL on Linux, TerminateProcess on Windows): the tree's child
// and the child's own child end.
@(test)
a_tree_ends_when_its_program_is_killed :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	r, w, perr := process.pipe()
	if !testing.expect(t, perr == nil, "a pipe") { return }
	parent, err := process.start({command = {process.executable_path()}, env = mode_env("parent"), stdout = w})
	os.close(w)
	if !testing.expect(t, err == nil, "the parent starts") { os.close(r); return }
	child, grandchild, ok := read_pids(r)
	os.close(r)
	if !testing.expect(t, ok, "the child says its pids") { _ = os.process_kill(parent); return }
	testing.expect(t, alive(child) && alive(grandchild), "both run")
	_ = os.process_kill(parent)
	_, _ = os.process_wait(parent, END_BOUND)
	testing.expect(t, ends_within(child, END_BOUND), "the child ends with its program")
	testing.expect(t, ends_within(grandchild, END_BOUND), "the grandchild ends with its program")
}

// A tree killed: the child and the grandchild end, and the end is the kill.
@(test)
a_tree_killed_ends_whole :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	r, w, _ := process.pipe()
	tree, err := process.tree_start({command = {process.executable_path()}, env = mode_env("child"), stdout = w})
	os.close(w)
	if !testing.expect(t, err == nil, "the tree starts") { os.close(r); return }
	defer process.tree_close(&tree)
	child, grandchild, ok := read_pids(r)
	os.close(r)
	if !testing.expect(t, ok) { return }
	testing.expect_value(t, child, tree.pid)
	_, ended := process.tree_wait(&tree, 0)
	testing.expect(t, !ended, "it runs")
	process.tree_kill(&tree)
	end, done := process.tree_wait(&tree, END_BOUND)
	testing.expect(t, done, "it ends")
	when ODIN_OS == .Linux { testing.expect(t, end.signaled && end.code == 9, "killed") } else { testing.expect(t, !end.signaled) }
	testing.expect(t, ends_within(grandchild, END_BOUND), "the grandchild ends with it")
}

// The child exits with a code: the tree says the code, and the grandchild it left running is ended.
@(test)
a_tree_ends_with_its_child :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	r, w, _ := process.pipe()
	tree, err := process.tree_start({command = {process.executable_path()}, env = mode_env("child_exit:7"), stdout = w})
	os.close(w)
	if !testing.expect(t, err == nil, "the tree starts") { os.close(r); return }
	defer process.tree_close(&tree)
	_, grandchild, ok := read_pids(r)
	os.close(r)
	if !testing.expect(t, ok) { return }
	end, done := process.tree_wait(&tree, END_BOUND)
	testing.expect(t, done && !end.signaled && end.code == 7, fmt.tprint(end))
	testing.expect(t, ends_within(grandchild, END_BOUND), "what it left running ends")
}

// A tree started from a thread that ends at once lives on: the end of a thread is not the program's (Linux's
// PR_SET_PDEATHSIG follows the thread that forked; the keeper's fork is its own).
@(test)
a_tree_outlives_the_thread_that_started_it :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	Start :: struct { env: []string, tree: process.Tree, err: os.Error }
	s := Start{env = mode_env("idle")}
	th := thread.create_and_start_with_poly_data(&s, proc(s: ^Start) {
		s.tree, s.err = process.tree_start({command = {process.executable_path()}, env = s.env})
	})
	thread.join(th)
	thread.destroy(th)
	if !testing.expect(t, s.err == nil, "the tree starts") { return }
	defer process.tree_close(&s.tree)
	_, ended := process.tree_wait(&s.tree, 0)
	testing.expect(t, !ended, "it runs after its thread ended")
	testing.expect(t, alive(s.tree.pid))
	testing.expect(t, process.tree_signal(&s.tree, .Terminate), "a signal goes")
	end, done := process.tree_wait(&s.tree, END_BOUND)
	testing.expect(t, done, "it ends")
	when ODIN_OS == .Linux { testing.expect(t, end.signaled && end.code == 15, fmt.tprint(end)) } else { testing.expect(t, !end.signaled) }
}

// A command that cannot start: an error, and no tree.
@(test)
a_tree_that_cannot_start_says_so :: proc(t: ^testing.T) {
	_, err := process.tree_start({command = {"no-such-program-gt-tree"}})
	testing.expect(t, err != nil)
	_, err2 := process.tree_start({command = {}})
	testing.expect(t, err2 != nil)
	when ODIN_OS == .Linux {
		// (a file that is there but cannot run: the exec's error comes back from the keeper's child)
		dir, _ := os.make_directory_temp("", "gt-tree-*", context.temp_allocator)
		defer os.remove_all(dir)
		path := fmt.tprintf("%s/not-executable", dir)
		_ = os.write_entire_file(path, transmute([]u8)string("#!/bin/sh\n"))
		_, err3 := process.tree_start({command = {path}})
		testing.expect(t, err3 != nil, "a file without the right to run")
	}
}
