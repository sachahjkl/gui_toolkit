package ui

// The state machine of one view (docs/views.md, "The state machine"). It is a pure value: view_step reads only its
// arguments, and the toolkit's builds apply the effects it returns. The tests drive it with no State and no window.

// How a view is shown, from the most attached to the least.
View_Presentation :: enum u8 { Dialog, Panel, Internal, External }

// An edge of a dock space.
View_Edge :: enum u8 { Right, Left, Bottom, Top }

// Where a panel goes: a dock space (by name; "" is the owner window's frame) and an edge of it.
View_Place :: struct {
	space: string,
	edge:  View_Edge,
}

// Closed: not built (it can hold an answer not taken). Opening: built unseen until its layout settles. Shown: built and
// drawn in one presentation. Moving: it shows in `from` and is built unseen in `as`. Dragged: its header or its tab is
// held past the threshold.
View_State :: enum u8 { Closed, Opening, Shown, Moving, Dragged }

View_Machine :: struct {
	state:      View_State,
	as:         View_Presentation,   // Opening, Shown, Dragged: where it is. Moving: where it goes.
	from:       View_Presentation,   // Moving: where it still shows. Dragged: where a cancel puts it back.
	place:      View_Place,          // with .Panel
	from_place: View_Place,          // Moving, Dragged: the place of `from`
	home:       View_Presentation,   // what Reattach goes back to (View_Options.home)
	home_place: View_Place,
	answer:     Maybe(int),          // Closed: an answer not taken yet
}

View_Event_Kind :: enum u8 {
	Open,             // the program opens it: `as` and `place` say where (memory, else first, else home)
	Settled,          // its layout settled where it is built unseen
	Present,          // a button, a menu or view_present: to `as` at `place`
	Reattach,         // back to its home (a button, view_reattach, the system's close of an external window)
	Drag_Start,       // its header or tab held past DOCK_DRAG_EM
	Drop,             // released on a target: `as` and `place`
	Drop_Outside,     // released outside the owner window (Windows, X11)
	Drag_Cancel,      // Escape during the drag
	End,              // view_end: `code`
	User_Close,       // the close button, Escape, the scrim, Ctrl+W
	Program_Close,    // view_close
	Window_Refused,   // no external window could open
	Owner_Gone,       // its owner window closed
	Quit,             // views_destroy
}

View_Event :: struct {
	kind:  View_Event_Kind,
	as:    View_Presentation,
	place: View_Place,
	code:  int,
}

View_Effect :: enum u8 {
	Drop_Answer,        // the answer of a former opening goes
	Keep_Focus,         // keep what has the focus, to give it back when the view closes
	Open_Window,        // open its external window, hidden
	Show,               // it shows: a dialog fades in, a window is shown; the focus goes into it
	Raise,              // already open: raise its window, show its tab, bring it to the front, focus the dialog
	Remember,           // write the presentation and the place it now has (`as`, `place`) to the memory
	Retire_Old,         // the old presentation (`from`) goes, in the frame where the new one shows
	Carry_State,        // the box state and the focus move with it; `moved` is called
	Leave_Scrim,        // a dialog leaves its scrim: it holds no keys any more
	Close_Windows,      // its windows close
	Give_Focus_Back,    // the owner gets back the focus that Keep_Focus kept
	Announce_Refused,   // say "No window: the renderer refused it"
	Was_Open,           // Quit: it was open (view_was_open at the next start)
}
View_Effects :: bit_set[View_Effect]

// The answer of a view that the user closed (Escape, the close button, the scrim), or whose owner window went. The
// program's own answers are 0 and up.
VIEW_CANCELLED :: -1

// Whether it is at its home presentation and place.
view_machine_at_home :: proc(m: View_Machine) -> bool {
	if m.as != m.home { return false }
	return m.as != .Panel || m.place == m.home_place
}

// The machine after `e`, and what the toolkit must do. An event that the state does not take changes nothing.
view_step :: proc(m: View_Machine, e: View_Event) -> (next: View_Machine, fx: View_Effects) {
	next = m
	open := m.state != .Closed
	#partial switch e.kind {
	case .Quit:
		next.state, next.answer = .Closed, nil
		fx = {.Close_Windows}
		if open { fx += {.Was_Open} }
		return
	case .Open:
		if open {
			fx = {.Raise}
			return
		}
		next.state, next.as, next.from, next.place, next.answer = .Opening, e.as, e.as, e.place, nil
		fx = {.Drop_Answer, .Keep_Focus}
		if e.as == .External { fx += {.Open_Window} }
		return
	}
	if !open { return }
	switch e.kind {
	case .Open, .Quit:   // (above)
	case .End:
		next.state, next.answer = .Closed, e.code
		fx = {.Close_Windows, .Give_Focus_Back}
	case .User_Close, .Owner_Gone:
		next.state, next.answer = .Closed, VIEW_CANCELLED
		fx = {.Close_Windows, .Give_Focus_Back}
	case .Program_Close:
		next.state, next.answer = .Closed, nil
		fx = {.Close_Windows, .Give_Focus_Back}
	case .Settled:
		#partial switch m.state {
		case .Opening:
			next.state = .Shown
			fx = {.Show}
		case .Moving:
			next.state, next.from, next.from_place = .Shown, m.as, m.place
			fx = {.Show, .Retire_Old, .Carry_State}
		}
	case .Present:
		#partial switch m.state {
		case .Opening:
			// (a choice made while it is measured, before its first frame shown, is kept: it opens there)
			if e.as == m.as && (e.as != .Panel || e.place == m.place) { return }
			next.as, next.from, next.place = e.as, e.as, e.place
			fx = {.Remember}
			if e.as == .External { fx += {.Open_Window} }
		case .Shown:
			if e.as == m.as && (e.as != .Panel || e.place == m.place) { return }
			next.state, next.from, next.from_place, next.as, next.place = .Moving, m.as, m.place, e.as, e.place
			fx = {.Remember}
			if e.as == .External { fx += {.Open_Window} }
		case .Moving:
			next.as, next.place = e.as, e.place
			fx = {.Remember}
			if e.as == .External { fx += {.Open_Window} }
		}
	case .Reattach:
		#partial switch m.state {
		case .Opening:
			if view_machine_at_home(m) { return }
			next.as, next.from, next.place = m.home, m.home, m.home_place
			fx = {.Remember}
		case .Shown:
			if view_machine_at_home(m) { return }
			next.state, next.from, next.from_place, next.as, next.place = .Moving, m.as, m.place, m.home, m.home_place
			fx = {.Remember}
		case .Moving:
			next.as, next.place = m.home, m.home_place
			fx = {.Remember}
		}
	case .Drag_Start:
		if m.state != .Shown { return }
		next.state, next.from, next.from_place = .Dragged, m.as, m.place
		next.as = m.as == .External ? .External : .Internal
		if m.as == .Dialog { fx = {.Leave_Scrim} }
	case .Drop:
		if m.state != .Dragged { return }
		// (one State: the drop's frame shows it there, with no unseen build)
		next.state, next.as, next.place = .Shown, e.as, e.place
		fx = {.Remember}
	case .Drop_Outside:
		if m.state != .Dragged { return }
		next.state, next.from, next.as = .Moving, m.as, .External
		fx = {.Remember, .Open_Window}
	case .Drag_Cancel:
		if m.state != .Dragged { return }
		next.state, next.as, next.place = .Shown, m.from, m.from_place
	case .Window_Refused:
		#partial switch m.state {
		case .Opening:
			if m.as != .External { return }
			next.as = .Internal
			fx = {.Announce_Refused}
		case .Moving:
			if m.as != .External { return }
			// (back where it shows; the memory gets that presentation back)
			next.state, next.as, next.place = .Shown, m.from, m.from_place
			fx = {.Announce_Refused, .Remember}
		}
	}
	return
}
