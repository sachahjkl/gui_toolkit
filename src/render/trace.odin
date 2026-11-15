package render

// A program's own steps in the renderer's trace (TOOLKIT_RENDER_TRACE=1): from a trigger (a shortcut, a click), how long
// each step took and the time since the trigger, on standard error beside the renderer's own timings (its first present,
// its pipelines). One switch for both: a latency is read where it is spent, the program's steps and the renderer's in one
// list. Nothing is printed without it, and nothing is kept.
//
//	render.trace_start("shortcut")   // the clock starts
//	render.trace_mark("window open") // a step of the interface's thread
//	render.trace_note("decoded")     // a step of another thread: the time since the trigger only

import "core:fmt"
import "core:sync"
import "core:time"

// When the last trigger came (a time.Tick's nanoseconds; 0: none yet), and the last step of the interface's thread.
// (Atomic: a worker's note reads it.)
@(private = "file") trace_from: i64
@(private = "file") trace_last: i64

// Whether the trace is on (TOOLKIT_RENDER_TRACE or TOOLKIT_WGPU_TRACE in the environment, read once).
trace_on :: proc() -> bool { return render_trace() }

// A trigger: the clock starts.
trace_start :: proc(what: string) {
	if !render_trace() { return }
	now := time.tick_now()._nsec
	sync.atomic_store(&trace_from, now)
	sync.atomic_store(&trace_last, now)
	fmt.eprintfln("trace: %s", what)
}

// A step of the interface's thread done: its own time, and the time since the trigger.
trace_mark :: proc(what: string) {
	if !render_trace() { return }
	from := sync.atomic_load(&trace_from)
	if from == 0 { return }
	now := time.tick_now()._nsec
	last := sync.atomic_exchange(&trace_last, now)
	fmt.eprintfln("trace: %-28s +%6.1f ms  (%6.1f ms)", what, f64(now - last) / 1e6, f64(now - from) / 1e6)
}

// A step of another thread (a worker's): the time since the trigger only (the steps' own clock is the interface's).
trace_note :: proc(what: string) {
	if !render_trace() { return }
	from := sync.atomic_load(&trace_from)
	if from == 0 { return }
	fmt.eprintfln("trace:   (worker) %-19s          (%6.1f ms)", what, f64(time.tick_now()._nsec - from) / 1e6)
}
