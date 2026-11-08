package tk

// timeline_test [-exe:file] [-out:folder] [-port:n]: the timelines of src/cdp against examples/whatsnew as a program of its own
// (--headless) over a real socket: a timeline's files, played again, a difference found, a timeline recorded (from a second
// connection, while the first one records) and played back. The program must end by itself with exit code 0. (What the protocol
// does is tested in the process: tests/examples/whatsnew_test.odin; the socket by itself: tests/devtools; the client's parts that
// need no window: src/cdp's tests.)
//   tk build whatsnew, then tk timeline_test           (default: build/whatsnew[.exe], build/e2e, port 9477)

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import cdp "../../src/cdp"

TIMELINE_TEST_PORT :: 9477
// What the recording waits around each action: what a person leaves between two.
@(private = "file") RECORD_PAUSE :: 400 * time.Millisecond
@(private = "file") TYPED_PAUSE :: 900 * time.Millisecond
// A program that has been told to close has this long.
@(private = "file") END_LIMIT :: 15 * time.Second
@(private = "file") IDLE_LIMIT :: 10 * time.Second
@(private = "file") STDERR_TAIL :: 30

@(private = "file")
Test :: struct {
	c:      ^cdp.Client,
	failed: int,
}

@(private = "file")
fail :: proc(t: ^Test, what: string) {
	t.failed += 1
	fmt.printfln("FAIL %s", what)
}

@(private = "file")
pass :: proc(what: string) { fmt.printfln("ok   %s", what) }

@(private = "file")
idle :: proc(t: ^Test) {
	still, ok := cdp.wait_idle(t.c, IDLE_LIMIT)
	if !ok || !still { fail(t, "still moving after 10 s") }
}

run_timeline_test :: proc(a: ^Args) -> string {
	root := toolkit_root()
	port, why := int_flag(a, "port", TIMELINE_TEST_PORT)
	if why != "" { return why }
	return timeline_test(flag_value(a, "exe", join({root, "build", fmt.tprintf("whatsnew%s", EXE)})), flag_value(a, "out", join({root, "build", "e2e"})), port)
}

@(private = "file")
Recording :: struct {
	c:      cdp.Client,
	dir:    string,
	stop:   bool,
	result: cdp.Timeline_Result,
}

timeline_test :: proc(exe, out: string, port: int) -> string {
	if !os.exists(exe) { return fmt.tprintf("%s is missing: tk build whatsnew", exe) }
	_ = os.make_directory_all(out)
	log_path := join({out, "whatsnew.stderr.txt"})
	log, log_err := os.create(log_path)
	if log_err != nil { return fmt.tprintf("%s cannot be written", log_path) }
	p, c, why := start_program({exe, "--headless"}, port, nil, stderr = log)
	os.close(log)
	if why != "" { return why }
	t := Test{c = &c}
	file :: proc(out, name: string) -> string { return join({out, name}) }
	read :: proc(path: string) -> string { text, _ := read_text(path); return text }

	checks: {
		// a timeline: its files, a run like it passes, a run that went elsewhere does not (each starts with the pointer where the last one left it)
		if !cdp.click_name(&c, "nav5") { fail(&t, c.failure); break checks }
		idle(&t)
		script := file(out, "script.txt")
		_ = os.write_entire_file(script, "click --name \"nav0\"\nidle\nclick --name \"nav5\"\nidle\n")
		r := cdp.play_timeline(&c, {source = script, dir = file(out, "timeline-a")})
		if r.steps != 3 || r.failed != 0 { fail(&t, fmt.tprintf("timeline: %d steps, %d failed", r.steps, r.failed)) }
		page := read(join({out, "timeline-a", "index.html"}))
		trace := read(join({out, "timeline-a", "trace.json"}))
		saved, _ := cdp.timeline_steps(read(join({out, "timeline-a", "timeline.json"})), context.temp_allocator)
		if !strings.contains(page, "data:image/png;base64,") { fail(&t, "timeline: no picture in its page") }
		if !strings.contains(trace, `"ph":"X"`) || strings.count(trace, `"ph":"i"`) != 3 { fail(&t, "timeline: its trace") }
		if len(saved) != 3 || !strings.contains(read(join({out, "timeline-a", "timeline.json"})), `"frameMs"`) { fail(&t, "timeline: its json") }
		same := cdp.play_timeline(&c, {source = join({out, "timeline-a", "timeline.json"}), dir = file(out, "timeline-b")})
		if same.failed != 0 { fail(&t, fmt.tprintf("timeline: played again, %d step(s) differ", same.failed)) }
		_ = os.write_entire_file(script, "click --name \"nav0\"\nidle\nclick --name \"nav3\"\nidle\n")
		other := cdp.play_timeline(&c, {source = script, dir = file(out, "timeline-c"), against = file(out, "timeline-a")})
		if other.failed != 1 { fail(&t, fmt.tprintf("timeline: another page seen as %d step(s) differing", other.failed)) } else { pass("timeline: files, played again, a difference found") }

		// recording a timeline: a picture per action, what a person types gathered, and it plays back the same. The recording has a
		// connection of its own, on a thread; the actions come from this one (the recorder takes the protocol's events: injected).
		rec := Recording{dir = file(out, "timeline-r")}
		connected: bool
		if rec.c, connected = cdp.connect(port); !connected { fail(&t, "a second connection"); break checks }
		recorder := thread.create_and_start_with_poly_data(&rec, proc(rec: ^Recording) {
			rec.result = cdp.record_timeline(&rec.c, {dir = rec.dir, stop = &rec.stop, injected = true})
		})
		time.sleep(RECORD_PAUSE)
		cdp.click_name(&c, "nav7")
		idle(&t)
		time.sleep(RECORD_PAUSE)
		cdp.type_text(&c, " odin")
		time.sleep(TYPED_PAUSE)
		cdp.click_name(&c, "nav0")
		idle(&t)
		time.sleep(RECORD_PAUSE)
		sync.atomic_store(&rec.stop, true)
		thread.join(recorder)
		thread.destroy(recorder)
		cdp.close(&rec.c)
		wanted := []string{`click --name "nav7"`, `type " odin"`, `click --name "nav0"`}
		got := strings.join(rec.result.lines, " | ", context.temp_allocator)
		if got != strings.join(wanted, " | ", context.temp_allocator) {
			fail(&t, fmt.tprintf("timeline recorded: %s", got))
		} else {
			steps, _ := cdp.timeline_steps(read(join({out, "timeline-r", "timeline.json"})), context.temp_allocator)
			times := make([dynamic]string, context.temp_allocator)
			ordered := true
			for s, i in steps {
				if i > 0 && s.t <= steps[i - 1].t { ordered = false }
				append(&times, fmt.tprintf("%.0f", s.t))
			}
			if !ordered { fail(&t, "timeline recorded: its times are not in order") }
			back := cdp.play_timeline(&c, {source = join({out, "timeline-r", "timeline.json"}), dir = file(out, "timeline-s"), realtime = true})
			// (the needle now has " odin" twice over: only the field's step and the page differ, the last step is back on the first page)
			played := read(join({out, "timeline-s", "timeline.json"}))
			last_differs := last_step_differs(played)
			if back.steps != 4 || last_differs { fail(&t, fmt.tprintf("timeline recorded, played: %d steps, the last one differs: %v", back.steps, last_differs)) } else {
				pass(fmt.tprintf("timeline recorded and played: %d actions at %s ms", len(wanted), strings.join(times[:], ", ", context.temp_allocator)))
			}
		}
		// a crash waits here: ends by itself, exit code 0
		cdp.call(&c, "Browser.close")
	}
	cdp.close(&c)

	state, wait_err := os.process_wait(p, END_LIMIT)
	if wait_err != nil || !state.exited {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p, END_LIMIT)
	}
	stderr := read(log_path)
	lines := strings.split_lines(stderr, context.temp_allocator)
	for l in lines { if strings.contains(l, "render.damage.") { fmt.println(l) } }   // (a program built with -define:TOOLKIT_DAMAGE_CHECK=true)
	if wait_err != nil || !state.exited || state.exit_code != 0 {
		fail(&t, fmt.tprintf("exit code %d (ended: %v)", state.exit_code, state.exited))
		fmt.println(strings.join(lines[max(0, len(lines) - STDERR_TAIL):], "\n", context.temp_allocator))
	} else {
		pass("ended with exit code 0")
	}
	if t.failed > 0 { return fmt.tprintf("%d failed", t.failed) }
	fmt.println("timeline: all good")
	return ""
}

// Whether the last step of a timeline.json says it differs.
@(private = "file")
last_step_differs :: proc(text: string) -> bool {
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil { return true }
	o, _ := v.(json.Object)
	steps, _ := o["steps"].(json.Array)
	if len(steps) == 0 { return true }
	last, _ := steps[len(steps) - 1].(json.Object)
	differs, _ := last["differs"].(json.Boolean)
	return bool(differs)
}
