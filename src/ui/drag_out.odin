package ui

// A drag out of the window (src/md/features/drag-out.md): a box's press that moves past the system's threshold starts the
// system's drag with what the box holds (a file, a text), once per press. platform.drag_start holds the interface's
// thread until the drop: the system's own loop runs. In a window that cannot drag (offscreen: a test, a headless run),
// what the drag would have taken is recorded in the Drag_Out instead, and the test reads it.
//
//	app.drag: ui.Drag_Out                          // one per program (or per window); zero is ready
//	sig := ui.signal(cell)
//	ui.drag_out_files(&app.drag, cell, sig, {path})  // in each box that can be dragged out
//	ui.drag_out_destroy(&app.drag)
//
// The implicit state machine of a press: Idle -> Pressed (sig.dragging, under the threshold) -> Out (past it: the drag
// started, d.key and d.started) -> Idle when that press is let go. A press is one drag: in Out no other starts.

import "base:runtime"
import "core:strings"
import "../platform"

Drag_Out :: struct {
	key:      Key,                // the box whose press started a drag (0: none)
	started:  bool,               // ... and it did: no other until that press is let go
	recorded: [dynamic]string,    // a window that cannot drag: the files (else the text) each drag would have taken (owned)
	drags:    int,                // ... and how many drags were recorded
}

// Whether the left button, pressed on the box `sig` is of, moved past the system's drag threshold since its press.
drag_past_threshold :: proc(sig: Signal) -> bool {
	if !sig.dragging { return false }
	th := platform.drag_threshold(gs().window)
	return abs(sig.drag_delta.x) >= th.x || abs(sig.drag_delta.y) >= th.y
}

// Box `b`'s drag out (`sig`: its signal of this build): once its press moved past the threshold, the system's drag with
// `data` (drag_out_start), once per press. `started`: it began in this build; `effect`: what the drop did (nil: none,
// or recorded).
drag_out :: proc(d: ^Drag_Out, b: ^Box, sig: Signal, data: platform.Drag_Data, allowed := platform.Drop_Effects{.Copy}) -> (effect: Maybe(platform.Drop_Effect), started: bool) {
	if b == nil { return }
	if !sig.dragging {
		if d.key == b.key { d.key, d.started = 0, false }
		return
	}
	if d.key == b.key && d.started { return }
	if !drag_past_threshold(sig) { return }
	d.key, d.started = b.key, true
	effect, _ = drag_out_start(d, data, allowed)
	return effect, true
}

// drag_out with files (their paths, copied for the drag).
drag_out_files :: proc(d: ^Drag_Out, b: ^Box, sig: Signal, files: []string, allowed := platform.Drop_Effects{.Copy}) -> (effect: Maybe(platform.Drop_Effect), started: bool) {
	// (the data only once the threshold is passed: a build of each cell would make it for nothing)
	if b == nil || !sig.dragging || (d.key == b.key && d.started) || !drag_past_threshold(sig) {
		return drag_out(d, b, sig, {}, allowed)
	}
	data: platform.Drag_Data
	data.files = make([dynamic]string, 0, len(files), context.temp_allocator)
	for f in files { append(&data.files, f) }
	return drag_out(d, b, sig, data, allowed)
}

// The system's drag with `data` now, from the window being built (a program that decides itself when its drag leaves
// the window: the file tree's, past the window's edge). A window that cannot drag (offscreen, none) records it.
drag_out_start :: proc(d: ^Drag_Out, data: platform.Drag_Data, allowed := platform.Drop_Effects{.Copy}) -> (effect: Maybe(platform.Drop_Effect), ok: bool) {
	s := gs()
	if s.window != nil { effect, ok = platform.drag_start(s.window, data, allowed) }
	if !ok && (s.window == nil || platform.is_offscreen(s.window)) {
		// (the heap's: a Drag_Out lives as long as what holds it, whatever allocator a build runs with)
		a := runtime.heap_allocator()
		if d.recorded == nil { d.recorded = make([dynamic]string, a) }
		for f in data.files { append(&d.recorded, strings.clone(f, a)) }
		if len(data.files) == 0 && data.text != "" { append(&d.recorded, strings.clone(data.text, a)) }
		d.drags += 1
	}
	return
}

// Frees what was recorded.
drag_out_destroy :: proc(d: ^Drag_Out) {
	for r in d.recorded { delete(r, runtime.heap_allocator()) }
	delete(d.recorded)
	d^ = {}
}
