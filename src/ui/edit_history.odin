package ui

import "core:mem"
import "core:strings"

// The undo and redo stacks of a text being edited (Text_Field, Text_Area). When an edit merges with the step before it
// is the owner's rule (field_checkpoint, begin_edit).

// The text and selection before an edit. `text` is a heap copy the stack owns.
Edit_Snapshot :: struct {
	text:         string,
	cursor, mark: int,
}

// Frees a step's text, zeroed first: a field may hold a secret, and freed memory keeps what was in it.
@(private)
snapshot_free :: proc(s: Edit_Snapshot) {
	if len(s.text) > 0 { mem.zero_explicit(raw_data(s.text), len(s.text)) }
	delete(s.text)
}

@(private)
edit_history_forget :: proc(undo, redo: ^[dynamic]Edit_Snapshot) {
	for s in undo { snapshot_free(s) }
	for s in redo { snapshot_free(s) }
	clear(undo)
	clear(redo)
}

// Before an edit: a new undo step unless it merges with the last one (the oldest goes past `max_steps`). What could be
// redone is gone.
@(private)
edit_history_record :: proc(undo, redo: ^[dynamic]Edit_Snapshot, text: []u8, cursor, mark, max_steps: int, merge: bool) {
	if !merge {
		for len(undo) > 0 && len(undo) >= max_steps { snapshot_free(undo[0]); ordered_remove(undo, 0) }   // (a lower limit set meanwhile trims)
		append(undo, Edit_Snapshot{text = strings.clone(string(text)), cursor = cursor, mark = mark})
	}
	for s in redo { snapshot_free(s) }
	clear(redo)
}

// Undo or redo: the last step of `from` becomes the text, what was there goes on `to`. False when `from` is empty.
@(private)
edit_history_step :: proc(from, to: ^[dynamic]Edit_Snapshot, buf: ^[dynamic]u8, cursor, mark: ^int) -> bool {
	if len(from) == 0 { return false }
	snap := pop(from)
	append(to, Edit_Snapshot{text = strings.clone(string(buf[:])), cursor = cursor^, mark = mark^})
	clear(buf)
	append(buf, snap.text)
	cursor^, mark^ = clamp(snap.cursor, 0, len(buf)), clamp(snap.mark, 0, len(buf))
	snapshot_free(snap)
	return true
}
