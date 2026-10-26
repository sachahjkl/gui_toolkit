package platform

// The frames of a thread, as one state machine: where the thread is in its frame, and whether another frame may begin there.
//
// A thread's windows are drawn by that thread, and several things can ask for a frame while it is already making one:
// a loop of the system that pumps the thread's messages and paints the window from WM_PAINT (live resize, a menu, Alt+Space,
// a modal dialog, a drag and drop: on_frame), an application's own preemption of long work (a frame of its interface between
// two steps of the work), another window's frame. A frame begun in the middle of another's build or drawing builds the
// interface inside the one being built: the outer build goes on with what the inner one left (an empty parent stack, a freed
// arena). So every frame goes through this gate, and a frame asked for where none may begin is deferred (the window repaints
// at the next pass), never nested.
//
//     Idle -> Polling -> [Work] -> Building -> Drawing -> Presenting -> (end: back to the stage the frame began in)
//
//   Idle        between frames: any frame may begin.
//   Polling     the frame waits for its time and polls its input. A loop of the system begun here (a press on the border,
//               Alt+Space) makes its frames here: they come before anything of the polling frame, which has done nothing
//               yet. The poll of a Light frame admits only Light frames (the work it interrupts is still under way).
//   Work        the application's work for the frame (a browser's page phase: scripts, styles, layout). Only a Light frame
//               may begin here: one that runs none of that work (it draws the interface over the last picture).
//   Building    the interface is being built: no frame may begin.
//   Drawing     its drawing is recorded and submitted: no frame may begin.
//   Presenting  the picture goes to the screen: no frame may begin.
//
// A Full frame goes Polling -> Work -> Building -> Drawing -> Presenting; a Light one skips Work. A frame may end at any stage
// (nothing to draw this time). A step backwards or a skipped stage is a violation: counted, and fatal when `strict` is set
// (an application's debug builds), so that the mistake fails where it is made, not later in another frame's state.
//
// A thread has its gate (frame_gate()). An application that never calls frame_gate_begin stays Idle and everything is
// admitted, as before. The window procedure consults it for WM_PAINT: where no frame may begin, the paint is deferred
// (paint_requested) without calling on_frame.

Frame_Stage :: enum u8 {
	Idle,
	Polling,
	Work,
	Building,
	Drawing,
	Presenting,
}

Frame_Kind :: enum u8 {
	Full,    // the application's work and its interface
	Light,   // the interface alone, over the last picture: may run while the work of a Full frame is under way
}

Frame_Gate :: struct {
	stage:      Frame_Stage,
	kind:       Frame_Kind,   // of the frame in progress (stage != .Idle)
	depth:      int,          // frames in progress (1: one frame; 2: one begun inside another's poll or work)
	strict:     bool,         // a violation panics (debug builds of the application)
	// statistics
	begun:      u64,   // frames admitted
	nested:     u64,   // of which inside another frame
	deferred:   u64,   // frames asked for where none may begin (a repaint later)
	violations: u64,
	last_violation: string,   // (a constant)
}

// What frame_gate_begin returns, for frame_gate_end: the stage and kind to put back.
Frame_Token :: struct {
	stage: Frame_Stage,
	kind:  Frame_Kind,
	ok:    bool,
}

@(private = "file", thread_local) thread_gate: Frame_Gate

// The gate of the calling thread.
frame_gate :: proc() -> ^Frame_Gate { return &thread_gate }

// Whether a frame of `kind` may begin while the thread's frame is at `stage` (of kind `outer`). Pure: the table above.
frame_admits :: proc(stage: Frame_Stage, outer: Frame_Kind, kind: Frame_Kind) -> bool {
	switch stage {
	case .Idle:                           return true
	case .Polling:                        return outer == .Full || kind == .Light
	case .Work:                           return outer == .Full && kind == .Light
	case .Building, .Drawing, .Presenting: return false
	}
	return false
}

// Whether a frame of some kind may begin now (the window procedure's question: it does not know which kind the application
// will make).
frame_gate_admits_any :: proc(g: ^Frame_Gate) -> bool {
	return frame_admits(g.stage, g.kind, .Light)
}

// Whether the frame may go from `from` to `to` (a frame of `kind`). Pure.
frame_transition_ok :: proc(from, to: Frame_Stage, kind: Frame_Kind) -> bool {
	#partial switch from {
	case .Polling:  return to == .Building || (to == .Work && kind == .Full)
	case .Work:     return to == .Building && kind == .Full
	case .Building: return to == .Drawing
	case .Drawing:  return to == .Presenting
	}
	return false
}

// Begins a frame of `kind`: admitted (the stage is Polling, the token puts back the outer frame's) or refused (counted as
// deferred: the caller asks for a repaint instead). Only frame_gate_end with the token ends it.
frame_gate_begin :: proc(g: ^Frame_Gate, kind: Frame_Kind) -> (tok: Frame_Token, ok: bool) {
	if !frame_admits(g.stage, g.kind, kind) {
		g.deferred += 1
		return {}, false
	}
	tok = {stage = g.stage, kind = g.kind, ok = true}
	if g.stage != .Idle { g.nested += 1 }
	g.begun += 1
	g.depth += 1
	g.stage, g.kind = .Polling, kind
	return tok, true
}

// The frame moves on to `to`. A move the machine does not have is a violation (the stage is set all the same: the frame goes on).
frame_gate_stage :: proc(g: ^Frame_Gate, to: Frame_Stage) {
	if g.depth == 0 {
		frame_gate_violation(g, "frame: a stage set outside any frame")
	} else if !frame_transition_ok(g.stage, to, g.kind) {
		frame_gate_violation(g, frame_gate_move_name(g.stage, to))
	}
	g.stage = to
}

// Ends the frame begun with `tok`: the outer frame's stage and kind come back.
frame_gate_end :: proc(g: ^Frame_Gate, tok: Frame_Token) {
	if !tok.ok { return }
	if g.depth == 0 { frame_gate_violation(g, "frame: a frame ended twice"); return }
	g.depth -= 1
	g.stage, g.kind = tok.stage, tok.kind
}

// A frame asked for (from WM_PAINT, a timer...) that was not made: counted with the refusals of frame_gate_begin.
frame_gate_defer :: proc(g: ^Frame_Gate) { g.deferred += 1 }

@(private = "file")
frame_gate_violation :: proc(g: ^Frame_Gate, what: string) {
	g.violations += 1
	g.last_violation = what
	if g.strict { panic(what) }
}

@(private = "file")
frame_gate_move_name :: proc(from, to: Frame_Stage) -> string {
	// (constants: nothing is allocated where a frame's state is wrong)
	NAMES :: [Frame_Stage][Frame_Stage]string{
		.Idle = {.Idle = "frame: Idle -> Idle", .Polling = "frame: Idle -> Polling without frame_gate_begin", .Work = "frame: Idle -> Work", .Building = "frame: Idle -> Building", .Drawing = "frame: Idle -> Drawing", .Presenting = "frame: Idle -> Presenting"},
		.Polling = {.Idle = "frame: Polling -> Idle (end it with frame_gate_end)", .Polling = "frame: Polling -> Polling", .Work = "frame: Polling -> Work in a Light frame", .Building = "frame: Polling -> Building", .Drawing = "frame: Polling -> Drawing (no build)", .Presenting = "frame: Polling -> Presenting (no build)"},
		.Work = {.Idle = "frame: Work -> Idle (end it with frame_gate_end)", .Polling = "frame: Work -> Polling (backwards)", .Work = "frame: Work -> Work", .Building = "frame: Work -> Building", .Drawing = "frame: Work -> Drawing (no build)", .Presenting = "frame: Work -> Presenting (no build)"},
		.Building = {.Idle = "frame: Building -> Idle (end it with frame_gate_end)", .Polling = "frame: Building -> Polling (backwards)", .Work = "frame: Building -> Work (backwards)", .Building = "frame: Building -> Building", .Drawing = "frame: Building -> Drawing", .Presenting = "frame: Building -> Presenting (no drawing)"},
		.Drawing = {.Idle = "frame: Drawing -> Idle (end it with frame_gate_end)", .Polling = "frame: Drawing -> Polling (backwards)", .Work = "frame: Drawing -> Work (backwards)", .Building = "frame: Drawing -> Building (backwards)", .Drawing = "frame: Drawing -> Drawing", .Presenting = "frame: Drawing -> Presenting"},
		.Presenting = {.Idle = "frame: Presenting -> Idle (end it with frame_gate_end)", .Polling = "frame: Presenting -> Polling (backwards)", .Work = "frame: Presenting -> Work (backwards)", .Building = "frame: Presenting -> Building (backwards)", .Drawing = "frame: Presenting -> Drawing (backwards)", .Presenting = "frame: Presenting -> Presenting"},
	}
	names := NAMES
	return names[from][to]
}
