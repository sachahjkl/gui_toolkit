package tk_process

// start and run: children started from many threads at once, each with its own input, output, error and exit code.
// The children are this test program, started again with CHILD_ENV set: its @(init) acts and ends before the test
// runner starts.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file") CHILD_ENV :: "GT_PROCESS_TEST_CHILD"
@(private = "file") THREADS :: 12
@(private = "file") RUNS :: 6
@(private = "file") BOUND :: 120 * time.Second
@(private = "file") WAIT_BOUND :: 30 * time.Second

// "echo": what it read on its input and its argument on its standard output, its argument on its standard error, an
// exit code of its argument modulo 5. "wait:<path>": ends when <path> exists (WAIT_BOUND at most, then exit code 9).
@(init)
@(private = "file")
child_main :: proc "contextless" () {
	context = runtime.default_context()
	mode, is_child := os.lookup_env(CHILD_ENV, context.temp_allocator)
	if !is_child { return }
	if strings.has_prefix(mode, "wait:") {
		path := mode[len("wait:"):]
		end := time.tick_now()
		for !os.exists(path) {
			if time.tick_since(end) > WAIT_BOUND { os.exit(9) }
			time.sleep(10 * time.Millisecond)
		}
		os.exit(0)
	}
	arg := len(os.args) > 1 ? os.args[1] : ""
	input, _ := os.read_entire_file_from_file(os.stdin, context.temp_allocator)
	fmt.printf("out:%s:%s", arg, string(input))
	fmt.eprintf("err:%s", arg)
	n, _ := strconv.parse_int(arg)
	os.exit(n % 5)
}

@(private = "file")
child_env :: proc(mode: string) -> []string {
	parent, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, context.temp_allocator)
	for e in parent { if !strings.has_prefix(e, CHILD_ENV + "=") { append(&env, e) } }
	append(&env, fmt.tprintf("%s=%s", CHILD_ENV, mode))
	return env[:]
}

// Many threads run short children at once: each child's output, error and code are its own, and nothing is left
// behind: no memory, no open handle (Linux and Windows count them).
@(test)
children_run_from_many_threads_at_once :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	Shared :: struct { exe: string, env: []string, wrong: int, leaked: int, said: string }
	sh := Shared{exe = executable_path(), env = child_env("echo")}
	if !testing.expect(t, sh.exe != "", "the test program's path") { return }
	handles := open_handles()

	threads: [THREADS]^thread.Thread
	for i in 0 ..< THREADS {
		Job :: struct { sh: ^Shared, index: int }
		threads[i] = thread.create_and_start_with_poly_data(Job{&sh, i}, proc(j: Job) {
			tracker: mem.Tracking_Allocator
			mem.tracking_allocator_init(&tracker, runtime.heap_allocator())
			context.allocator = mem.tracking_allocator(&tracker)
			for k in 0 ..< RUNS {
				n := j.index * RUNS + k
				arg := fmt.tprintf("%d", n)
				input := k % 2 == 0 ? fmt.tprintf("input %d", n) : ""
				r := run({j.sh.exe, arg}, {env = j.sh.env, input = input})
				want_out := fmt.tprintf("out:%s:%s", arg, input)
				want_err := fmt.tprintf("err:%s", arg)
				if !r.started || r.stdout != want_out || r.stderr != want_err || r.code != n % 5 || r.ok != (n % 5 == 0) {
					sync.atomic_add(&j.sh.wrong, 1)
				}
				ran_destroy(&r)
				free_all(context.temp_allocator)
			}
			if len(tracker.allocation_map) > 0 { sync.atomic_add(&j.sh.leaked, 1) }
			mem.tracking_allocator_destroy(&tracker)
		})
	}
	for th in threads {
		if th == nil { continue }
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, sh.wrong, 0)
	testing.expect_value(t, sh.leaked, 0)
	if handles >= 0 { testing.expect_value(t, open_handles(), handles) }
}

// A child that runs on (in run on another thread) holds up no start: the lock is the spawn's, never the wait's.
@(test)
a_running_child_holds_up_no_start :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, BOUND)
	dir, derr := os.make_directory_temp("", "gt-process-*", context.temp_allocator)
	if !testing.expect(t, derr == nil, "a temporary folder") { return }
	defer os.remove_all(dir)
	flag := fmt.tprintf("%s/go", dir)
	exe := executable_path()

	Long :: struct { exe: string, env: []string, r: Ran }
	long := Long{exe = exe, env = child_env(fmt.tprintf("wait:%s", flag))}
	th := thread.create_and_start_with_poly_data(&long, proc(l: ^Long) {
		l.r = run({l.exe}, {env = l.env}, context.temp_allocator)
	})
	if !testing.expect(t, th != nil, "a thread") { return }
	// (the long child runs, waiting for the flag; a quick one starts and ends meanwhile)
	quick := run({exe, "10"}, {env = child_env("echo"), input = "x"}, context.temp_allocator)
	testing.expect_value(t, quick.stdout, "out:10:x")
	testing.expect_value(t, quick.code, 0)
	testing.expect(t, quick.ok)
	_ = os.write_entire_file(flag, []u8{})
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, long.r.code, 0)
}

// A command that does not start: no Ran.ok, code -1, and why.
@(test)
a_command_that_does_not_start_says_why :: proc(t: ^testing.T) {
	r := run({"/no/such/program-gt"}, {}, context.temp_allocator)
	testing.expect(t, !r.ok && !r.started)
	testing.expect_value(t, r.code, -1)
	testing.expect(t, strings.contains(r.stderr, "/no/such/program-gt"), r.stderr)
	none := run({}, {}, context.temp_allocator)
	testing.expect(t, !none.ok && none.code == -1 && none.stderr != "")
}
