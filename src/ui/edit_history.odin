package ui

import "core:mem"
import "core:strings"
import undo_stack "../undo"

// The undo and redo steps of a text being edited (Line_Edit, Text_Edit), on the toolkit's one undo stack (gt:undo).
// When an edit merges with the step before it is the owner's rule (line_edit_checkpoint, begin_edit).

// The text and selection before an edit. `text` is a heap copy the stack owns.
Edit_Snapshot :: struct {
	text:         string,
	cursor, mark: int,
}

Edit_History :: undo_stack.Stack(Edit_Snapshot)

// What an edit was: consecutive inserts (typing), or consecutive deletes, made within Feel.undo_merge_ms are one undo step.
Edit_Kind :: enum u8 { None, Insert, Delete, Other }

// Frees a step's text, zeroed first: a field may hold a secret, and freed memory keeps what was in it.
@(private)
snapshot_free :: proc(s: ^Edit_Snapshot) {
	if len(s.text) > 0 { mem.zero_explicit(raw_data(s.text), len(s.text)) }
	delete(s.text)
	s.text = ""
}

@(private)
edit_history_forget :: proc(h: ^Edit_History) {
	undo_stack.reset(h, snapshot_free)
}

@(private)
edit_history_destroy :: proc(h: ^Edit_History) {
	undo_stack.destroy(h, snapshot_free)
}

// Before an edit: a new undo step unless it merges with the last one (the oldest goes past `max_steps`). What could be
// redone is gone.
@(private)
edit_history_record :: proc(h: ^Edit_History, text: []u8, cursor, mark, max_steps: int, merge: bool) {
	if merge {
		undo_stack.forget_redo(h, snapshot_free)
		return
	}
	undo_stack.push(h, Edit_Snapshot{text = strings.clone(string(text)), cursor = cursor, mark = mark}, max(max_steps, 1), snapshot_free)
}

// Undo (`back`) or redo: the step becomes the text, what was there goes the other way. False when there is none.
@(private)
edit_history_step :: proc(h: ^Edit_History, back: bool, buf: ^[dynamic]u8, cursor, mark: ^int) -> bool {
	has := back ? undo_stack.can_undo(h) : undo_stack.can_redo(h)
	if !has { return false }
	now := Edit_Snapshot{text = strings.clone(string(buf[:])), cursor = cursor^, mark = mark^}
	snap: Edit_Snapshot
	if back { snap, _ = undo_stack.undo(h, now) } else { snap, _ = undo_stack.redo(h, now) }
	clear(buf)
	append(buf, snap.text)
	cursor^, mark^ = clamp(snap.cursor, 0, len(buf)), clamp(snap.mark, 0, len(buf))
	snapshot_free(&snap)
	return true
}
