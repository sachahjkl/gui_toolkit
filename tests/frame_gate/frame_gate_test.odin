// The state machine of a thread's frames (platform/frame_gate.odin): which frame may begin where, which moves a frame may make,
// and what a frame begun inside another puts back. The logic alone: no window, no clock.
//   odin test tests/frame_gate -vet
package frame_gate_test

import "core:testing"
import "core:thread"
import "../../platform"

// The admission table, every stage against both kinds.
@(test)
admission_table :: proc(t: ^testing.T) {
	Case :: struct { stage: platform.Frame_Stage, outer: platform.Frame_Kind, full, light: bool }
	cases := [?]Case{
		{.Idle, .Full, true, true},
		{.Polling, .Full, true, true},      // a loop of the system begun in a frame's poll: its frames come first
		{.Polling, .Light, false, true},    // in a Light frame's poll the work it interrupts is under way: Light only
		{.Work, .Full, false, true},        // the work of a frame: only the interface alone (preemption)
		{.Work, .Light, false, false},      // (a Light frame has no work: not a stage it reaches)
		{.Building, .Full, false, false},
		{.Building, .Light, false, false},
		{.Drawing, .Full, false, false},
		{.Presenting, .Full, false, false},
	}
	for c in cases {
		testing.expectf(t, platform.frame_admits(c.stage, c.outer, .Full) == c.full, "a Full frame in %v of a %v frame", c.stage, c.outer)
		testing.expectf(t, platform.frame_admits(c.stage, c.outer, .Light) == c.light, "a Light frame in %v of a %v frame", c.stage, c.outer)
	}
}

// The moves of a frame: forwards only, Work only in a Full frame, no stage skipped but Work.
@(test)
transitions :: proc(t: ^testing.T) {
	allowed := [?][3]int{
		{int(platform.Frame_Stage.Polling), int(platform.Frame_Stage.Work), int(platform.Frame_Kind.Full)},
		{int(platform.Frame_Stage.Polling), int(platform.Frame_Stage.Building), int(platform.Frame_Kind.Full)},
		{int(platform.Frame_Stage.Polling), int(platform.Frame_Stage.Building), int(platform.Frame_Kind.Light)},
		{int(platform.Frame_Stage.Work), int(platform.Frame_Stage.Building), int(platform.Frame_Kind.Full)},
		{int(platform.Frame_Stage.Building), int(platform.Frame_Stage.Drawing), int(platform.Frame_Kind.Full)},
		{int(platform.Frame_Stage.Building), int(platform.Frame_Stage.Drawing), int(platform.Frame_Kind.Light)},
		{int(platform.Frame_Stage.Drawing), int(platform.Frame_Stage.Presenting), int(platform.Frame_Kind.Full)},
		{int(platform.Frame_Stage.Drawing), int(platform.Frame_Stage.Presenting), int(platform.Frame_Kind.Light)},
	}
	for from in platform.Frame_Stage {
		for to in platform.Frame_Stage {
			for kind in platform.Frame_Kind {
				want := false
				for a in allowed { if a == {int(from), int(to), int(kind)} { want = true } }
				testing.expectf(t, platform.frame_transition_ok(from, to, kind) == want, "%v -> %v in a %v frame", from, to, kind)
			}
		}
	}
}

// A whole Full frame, and a Light one: no violation, Idle again after, counted.
@(test)
whole_frames :: proc(t: ^testing.T) {
	g: platform.Frame_Gate
	tok, ok := platform.frame_gate_begin(&g, .Full)
	testing.expect(t, ok)
	testing.expect_value(t, g.stage, platform.Frame_Stage.Polling)
	for s in ([?]platform.Frame_Stage{.Work, .Building, .Drawing, .Presenting}) { platform.frame_gate_stage(&g, s) }
	platform.frame_gate_end(&g, tok)
	testing.expect_value(t, g.stage, platform.Frame_Stage.Idle)
	tok, ok = platform.frame_gate_begin(&g, .Light)
	testing.expect(t, ok)
	for s in ([?]platform.Frame_Stage{.Building, .Drawing, .Presenting}) { platform.frame_gate_stage(&g, s) }
	platform.frame_gate_end(&g, tok)
	testing.expect_value(t, g.violations, 0)
	testing.expect_value(t, g.begun, 2)
	testing.expect_value(t, g.nested, 0)
	testing.expect_value(t, g.depth, 0)
}

// A frame may end early (nothing to draw), from its poll or its work.
@(test)
early_ends :: proc(t: ^testing.T) {
	g: platform.Frame_Gate
	tok, _ := platform.frame_gate_begin(&g, .Full)
	platform.frame_gate_end(&g, tok)
	tok, _ = platform.frame_gate_begin(&g, .Full)
	platform.frame_gate_stage(&g, .Work)
	platform.frame_gate_end(&g, tok)
	testing.expect_value(t, g.stage, platform.Frame_Stage.Idle)
	testing.expect_value(t, g.violations, 0)
}

// The sources of re-entrance, as the browser meets them: a loop of the system in a frame's poll (its frames are made, the
// outer frame goes on from its poll), a preemption in the work (a Light frame; its own poll pumps a loop of the system,
// which gets only a Light frame), and WM_PAINT of a menu opened from the build (deferred).
@(test)
nesting :: proc(t: ^testing.T) {
	g: platform.Frame_Gate
	outer, _ := platform.frame_gate_begin(&g, .Full)

	// live resize begun in the poll: full frames inside, the outer frame back in its poll after each
	inner, ok := platform.frame_gate_begin(&g, .Full)
	testing.expect(t, ok, "a frame in the poll of a Full frame")
	testing.expect_value(t, g.depth, 2)
	for s in ([?]platform.Frame_Stage{.Work, .Building, .Drawing, .Presenting}) { platform.frame_gate_stage(&g, s) }
	platform.frame_gate_end(&g, inner)
	testing.expect_value(t, g.stage, platform.Frame_Stage.Polling)
	testing.expect_value(t, g.kind, platform.Frame_Kind.Full)

	// the work: a Full frame waits, a Light one is made
	platform.frame_gate_stage(&g, .Work)
	_, ok = platform.frame_gate_begin(&g, .Full)
	testing.expect(t, !ok, "no Full frame inside the work")
	light, lok := platform.frame_gate_begin(&g, .Light)
	testing.expect(t, lok, "a Light frame inside the work")
	// its poll pumps a loop of the system: a Full frame would run the work again under itself
	_, ok = platform.frame_gate_begin(&g, .Full)
	testing.expect(t, !ok, "no Full frame in a Light frame's poll")
	light2, l2 := platform.frame_gate_begin(&g, .Light)
	testing.expect(t, l2, "a Light frame in a Light frame's poll")
	platform.frame_gate_stage(&g, .Building); platform.frame_gate_stage(&g, .Drawing); platform.frame_gate_stage(&g, .Presenting)
	platform.frame_gate_end(&g, light2)
	platform.frame_gate_stage(&g, .Building); platform.frame_gate_stage(&g, .Drawing); platform.frame_gate_stage(&g, .Presenting)
	platform.frame_gate_end(&g, light)
	testing.expect_value(t, g.stage, platform.Frame_Stage.Work)

	// the build: a menu's loop paints the window; nothing may begin
	platform.frame_gate_stage(&g, .Building)
	testing.expect(t, !platform.frame_gate_admits_any(&g))
	_, ok = platform.frame_gate_begin(&g, .Light)
	testing.expect(t, !ok, "nothing inside the build")
	platform.frame_gate_stage(&g, .Drawing)
	platform.frame_gate_stage(&g, .Presenting)
	testing.expect(t, !platform.frame_gate_admits_any(&g))
	platform.frame_gate_end(&g, outer)

	testing.expect_value(t, g.stage, platform.Frame_Stage.Idle)
	testing.expect_value(t, g.depth, 0)
	testing.expect_value(t, g.begun, 4)
	testing.expect_value(t, g.nested, 3)
	testing.expect_value(t, g.deferred, 3)   // (frame_gate_admits_any only asks)
	testing.expect_value(t, g.violations, 0)
	testing.expect(t, platform.frame_gate_admits_any(&g))
}

// What the machine does not have is counted (and would panic with `strict`): a skipped build, a step backwards, a stage set
// outside a frame, a Light frame doing work, a frame ended twice.
@(test)
violations :: proc(t: ^testing.T) {
	g: platform.Frame_Gate
	tok, _ := platform.frame_gate_begin(&g, .Full)
	platform.frame_gate_stage(&g, .Drawing)
	testing.expect_value(t, g.violations, 1)
	testing.expect_value(t, g.last_violation, "frame: Polling -> Drawing (no build)")
	platform.frame_gate_stage(&g, .Building)
	testing.expect_value(t, g.last_violation, "frame: Drawing -> Building (backwards)")
	platform.frame_gate_end(&g, tok)
	platform.frame_gate_end(&g, tok)
	testing.expect_value(t, g.last_violation, "frame: a frame ended twice")
	platform.frame_gate_stage(&g, .Building)
	testing.expect_value(t, g.last_violation, "frame: a stage set outside any frame")
	g.stage = .Idle
	tok, _ = platform.frame_gate_begin(&g, .Light)
	platform.frame_gate_stage(&g, .Work)
	testing.expect_value(t, g.last_violation, "frame: Polling -> Work in a Light frame")
	testing.expect_value(t, g.violations, 5)
	// a refused begin gives a token that ends nothing
	g2: platform.Frame_Gate
	o, _ := platform.frame_gate_begin(&g2, .Full)
	platform.frame_gate_stage(&g2, .Work)
	platform.frame_gate_stage(&g2, .Building)
	refused, ok := platform.frame_gate_begin(&g2, .Light)
	testing.expect(t, !ok)
	platform.frame_gate_end(&g2, refused)
	testing.expect_value(t, g2.stage, platform.Frame_Stage.Building)
	testing.expect_value(t, g2.depth, 1)
	platform.frame_gate_stage(&g2, .Drawing)
	platform.frame_gate_stage(&g2, .Presenting)
	platform.frame_gate_end(&g2, o)
	testing.expect_value(t, g2.violations, 0)
}

// The thread's gate is the thread's: another thread starts Idle.
@(test)
per_thread :: proc(t: ^testing.T) {
	g := platform.frame_gate()
	g^ = {}
	tok, _ := platform.frame_gate_begin(g, .Full)
	testing.expect(t, platform.frame_gate() == g)
	testing.expect_value(t, platform.frame_gate().stage, platform.Frame_Stage.Polling)
	other_stage := platform.Frame_Stage.Presenting
	th := thread.create_and_start_with_poly_data(&other_stage, proc(s: ^platform.Frame_Stage) { s^ = platform.frame_gate().stage })
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, other_stage, platform.Frame_Stage.Idle)
	platform.frame_gate_end(g, tok)
	g^ = {}
}
