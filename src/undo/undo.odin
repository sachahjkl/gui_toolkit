// Package undo: the undo and redo steps of a model, as snapshots. One stack serves a text field (ui.Line_Edit), a
// graph (a flowgraph.Graph's copy), a drawing: the owner says what a snapshot is and how one is freed.
//
//	history: undo.Stack(Graph)
//	undo.push(&history, graph_clone(g), 100, graph_destroy)   // before a change
//	if undo.can_undo(&history) {
//		back, _ := undo.undo(&history, g^)                   // the model as it is goes to redo
//		g^ = back
//	}
//
// A step is taken whole by the stack and given back whole: the stack frees a snapshot only when it drops it (the oldest
// past the limit, the redo steps a new change makes useless, a reset). Details: docs/undo.md.
package tk_undo

Stack :: struct($T: typeid) {
	undo: [dynamic]T,   // the oldest first
	redo: [dynamic]T,   // the last undone last
}

// Before a change: `before` (taken), the model as it was, is the step undo goes back to. The oldest steps past `limit` go
// (0 or less: no limit), and the redo steps, which the change makes useless.
push :: proc(s: ^Stack($T), before: T, limit: int, free_step: proc(step: ^T)) {
	for limit > 0 && len(s.undo) >= limit {
		old := s.undo[0]
		if free_step != nil { free_step(&old) }
		ordered_remove(&s.undo, 0)
	}
	append(&s.undo, before)
	forget_redo(s, free_step)
}

// A change that merges with the last step (typing goes on): no new step, but what could be redone is gone.
forget_redo :: proc(s: ^Stack($T), free_step: proc(step: ^T)) {
	if free_step != nil {
		for &r in s.redo { free_step(&r) }
	}
	clear(&s.redo)
}

// The last step back, taken by the caller; `now` (taken), the model as it is, goes to the redo steps. ok false: nothing
// to undo, and `now` is not taken (can_undo first spares making it).
undo :: proc(s: ^Stack($T), now: T) -> (back: T, ok: bool) {
	if len(s.undo) == 0 { return }
	back = pop(&s.undo)
	append(&s.redo, now)
	return back, true
}

// The last step undone, again: as undo, the other way.
redo :: proc(s: ^Stack($T), now: T) -> (again: T, ok: bool) {
	if len(s.redo) == 0 { return }
	again = pop(&s.redo)
	append(&s.undo, now)
	return again, true
}

// The last step pushed is dropped: the change it was kept for was refused after all.
drop_last :: proc(s: ^Stack($T), free_step: proc(step: ^T)) {
	if len(s.undo) == 0 { return }
	last := pop(&s.undo)
	if free_step != nil { free_step(&last) }
}

can_undo :: proc(s: ^Stack($T)) -> bool { return len(s.undo) > 0 }
can_redo :: proc(s: ^Stack($T)) -> bool { return len(s.redo) > 0 }

// Every step freed: the history starts again (another document shown, a text set).
reset :: proc(s: ^Stack($T), free_step: proc(step: ^T)) {
	if free_step != nil {
		for &u in s.undo { free_step(&u) }
	}
	clear(&s.undo)
	forget_redo(s, free_step)
}

// Every step freed, and the stack's memory.
destroy :: proc(s: ^Stack($T), free_step: proc(step: ^T)) {
	reset(s, free_step)
	delete(s.undo)
	delete(s.redo)
	s^ = {}
}
