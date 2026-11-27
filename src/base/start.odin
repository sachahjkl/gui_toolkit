package gt_base

// A program's start, measured from the process's own start: what a person waits for between the click and the window.
// main's first line is not the start: the system has loaded the program and its libraries before it, and a probe that
// starts its clock there, or skips a step another path takes (the device made early), measures another start. The
// toolkit marks its own steps (the device made early, its pipelines, the window, the font, the first frame shown); a
// program marks its own (a file read) from any thread, then gives them all (start_steps) or prints them (start_print).
//
//	base.start_mark("session read")              // a step done: its time since the process started
//	for s in base.start_steps(buf[:]) { ... }    // every step marked so far, in the order they were marked
//
// The process's start is the system's: Windows' process creation time, Linux's start time in /proc/self/stat (in
// clock ticks, 10 ms). Read once, before main (start_init); elsewhere the clock starts there.

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:time"

// A step of the start: what (a constant: the text is kept, not copied) and when, in milliseconds since the process started.
Start_Step :: struct {
	what: string,
	ms:   f64,
}

// The most steps kept: the later ones are not.
START_STEPS_MAX :: 48

@(private = "file") start_origin: time.Tick                           // the process's start on the monotonic clock
@(private = "file") start_lock: sync.Mutex                            // guards start_kept and start_count
@(private = "file") start_kept: [START_STEPS_MAX]Start_Step
@(private = "file") start_count: int

@(init, private = "file")
start_init :: proc "contextless" () {
	context = runtime.default_context()
	now := time.tick_now()
	age := process_age_ns()   // (0: the system does not say: the clock starts here)
	start_origin = time.Tick{now._nsec - age}
}

// Milliseconds since the process started.
start_ms :: proc "contextless" () -> f64 {
	return f64(time.tick_now()._nsec - start_origin._nsec) / f64(time.Millisecond)
}

// A step of the start is done (any thread). `what` is kept as it is: a constant string. A step is kept the first time
// it is marked only: the start is the first window's, and a program that opens a hundred windows marks the renderer's
// steps a hundred times without filling the list. True: kept now (its first time, and room for it).
start_mark :: proc(what: string) -> bool {
	ms := start_ms()
	sync.guard(&start_lock)
	if start_count >= START_STEPS_MAX { return false }
	for s in start_kept[:start_count] { if s.what == what { return false } }
	start_kept[start_count] = {what, ms}
	start_count += 1
	return true
}

// The steps marked so far, copied into `buf` (as many as it holds), in the order they were marked.
start_steps :: proc(buf: []Start_Step) -> []Start_Step {
	sync.guard(&start_lock)
	n := copy(buf, start_kept[:start_count])
	return buf[:n]
}

// The steps on standard error, one per line: "start: <ms> ms  <what>".
start_print :: proc() {
	buf: [START_STEPS_MAX]Start_Step
	for s in start_steps(buf[:]) { fmt.eprintfln("start: %7.1f ms  %s", s.ms, s.what) }
}
