// A program's steps in the renderer's trace (render.trace_start, trace_mark, trace_note): on with the renderer's switch,
// a mark before any trigger says nothing, a worker's note and the interface's marks go on together.
//   odin test tests/render_trace -collection:gt=src -vet
package render_trace_test

import "core:os"
import "core:testing"
import "core:thread"
import "gt:render"

@(test)
the_programs_steps_join_the_renderers_trace :: proc(t: ^testing.T) {
	// (the switch is read once in the process: set before anything reads it)
	_ = os.set_env("TOOLKIT_RENDER_TRACE", "1")
	testing.expect(t, render.trace_on(), "the renderer's switch turns it on")
	render.trace_mark("before any trigger")   // (nothing to measure from: says nothing)
	render.trace_start("a trigger")
	th := thread.create_and_start(proc() { for _ in 0 ..< 100 { render.trace_note("a worker's step") } })
	for _ in 0 ..< 100 { render.trace_mark("an interface's step") }
	thread.join(th)
	thread.destroy(th)
}
