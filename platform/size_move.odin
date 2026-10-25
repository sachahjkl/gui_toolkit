package platform

// Which WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE open and close a loop of the system.
//
// The system sends them from inside its own move / size loop, which runs inside the window's DefWindowProc call (for
// WM_SYSCOMMAND SC_SIZE / SC_MOVE, WM_NCLBUTTONDOWN, a key of the system menu), on the window's own thread. Other
// programs send the same two messages to a window they move themselves, with no loop at all: AltSnap (Alt + right
// button drag) posts them around a run of SetWindowPos calls it makes from its own process, so that the window believes
// it is being dragged. A window that took those for a loop of the system would paint from the message handler, nested
// in its own poll, every 16 ms (a frame inside the app's frame, two presents per turn), while the program that moves
// it waits at every step for the thread to answer. So a message counts only when the window procedure is inside
// DefWindowProc; the size change it accompanies arrives as WM_SIZE and is drawn by the app's own loop like any other.

Size_Move_Edge :: enum u8 {
	Enter,   // WM_ENTERSIZEMOVE
	Exit,    // WM_EXITSIZEMOVE
}

// `open`: the loops of the system open now. `in_def_proc`: the window procedure is inside DefWindowProc (a call that may
// run the system's loop). Returns the loops open after the message and whether the message counted (false: it came from
// outside a loop of the system, or closes a loop that was never opened: ignored).
size_move_step :: proc(open: int, edge: Size_Move_Edge, in_def_proc: bool) -> (after: int, counted: bool) {
	if !in_def_proc { return open, false }
	switch edge {
	case .Enter: return open + 1, true
	case .Exit:  return open > 0 ? open - 1 : 0, open > 0
	}
	return open, false
}
