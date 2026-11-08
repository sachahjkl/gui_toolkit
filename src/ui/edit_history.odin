package ui

import "core:strings"

// The undo and redo stacks of a text being edited (Text_Field, Text_Area). When an edit merges with the step before it
// is the owner's rule (field_checkpoint, begin_edit).

// The text and selection before an edit. `text` is a heap copy the stack owns.
Edit_Snapshot :: struct {
	text:         string,
	cursor, mark: int,
}

@(private)
edit_history_forget :: proc(undo, redo: ^[dynamic]Edit_Snapshot) {
	for s in undo { delete(s.text) }
	for s in redo { delete(s.text) }
	clear(undo)
	clear(redo)
}

// Before an edit: a new undo step unless it merges with the last one (the oldest goes past `max_steps`). What could be
// redone is gone.
@(private)
edit_history_record :: proc(undo, redo: ^[dynamic]Edit_Snapshot, text: []u8, cursor, mark, max_steps: int, merge: bool) {
	if !merge {
		if len(undo) >= max_steps { delete(undo[0].text); ordered_remove(undo, 0) }
		append(undo, Edit_Snapshot{text = strings.clone(string(text)), cursor = cursor, mark = mark})
	}
	for s in redo { delete(s.text) }
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
	delete(snap.text)
	return true
}
