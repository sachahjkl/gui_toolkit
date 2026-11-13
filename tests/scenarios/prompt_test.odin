package scenarios_test

// A prompt (ui.prompt): its field has the keyboard as it opens, Enter answers with what was typed, Escape and Cancel give
// up. line_edit_wipe leaves no byte of a secret in the field's buffer nor in its undo and redo history.

import "core:bytes"
import "core:mem"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{700, 500}
@(private = "file") SECRET :: "hunter2-secret"
@(private = "file") ARENA_BYTES :: 64 * 1024
@(private = "file") FIELD_RESERVE :: 64

@(private = "file")
Ask :: struct {
	open:    bool,
	field:   ui.Line_Edit,
	answers: [dynamic]ui.Confirm_Answer,
}

@(private = "file")
ask_build :: proc(s: ^session.Session) {
	r := (^Ask)(s.user)
	if a := ui.prompt("pin", &r.open, &r.field, {title = "Unlock", note = "Type the PIN.", secret = true}); a != .None {
		append(&r.answers, a)
	}
}

@(test)
a_prompt_answers_at_enter_and_gives_up_at_escape :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Ask{open = true}
	defer ui.line_edit_destroy(&r.field)
	defer delete(r.answers)
	s := session.start(t, {size = WINDOW, user = &r, build = ask_build})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.focused_name(s) == "prompt_field" }, "the field to have the keyboard")
	session.type_text(s, "1234")
	session.key(s, .Return)
	testing.expect(t, !r.open, "Enter closes it")
	testing.expect_value(t, len(r.answers), 1)
	testing.expect_value(t, r.answers[0], ui.Confirm_Answer.Confirmed)
	testing.expect_value(t, ui.line_edit_string(&r.field), "1234")

	ui.line_edit_wipe(&r.field)
	r.open = true
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.focused_name(s) == "prompt_field" }, "the field to have the keyboard again")
	session.type_text(s, "99")
	session.key(s, .Escape)
	testing.expect(t, !r.open, "Escape closes it")
	testing.expect_value(t, len(r.answers), 2)
	testing.expect_value(t, r.answers[1], ui.Confirm_Answer.Cancelled)

	r.open = true
	session.wait_box(s, "prompt_cancel")
	session.click(s, "prompt_cancel")
	testing.expect(t, !r.open, "Cancel closes it")
	testing.expect_value(t, r.answers[2], ui.Confirm_Answer.Cancelled)
}) }

// Every byte the field ever held is in one arena (whose frees free nothing): after line_edit_wipe, the secret is nowhere in
// it, neither in the buffer nor in a step of the history (an undo, a redo, a step merged or dropped).
@(test)
field_wipe_leaves_nothing_of_a_secret :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	secret := SECRET
	backing := make([]u8, ARENA_BYTES)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	f: ui.Line_Edit
	{
		context.allocator = mem.arena_allocator(&arena)
		reserve(&f.buf, FIELD_RESERVE)   // (a buffer that grows leaves a copy behind in the block it leaves)
		ui.line_edit_insert(&f, SECRET)
		ui.line_edit_insert(&f, "!")
		ui.line_edit_undo(&f)                // (the secret with "!" goes to the redo history)
		ui.line_edit_insert(&f, "?")         // (and is dropped from it)
		ui.line_edit_insert(&f, SECRET)
		ui.line_edit_undo(&f)
		testing.expect(t, bytes.contains(backing, transmute([]u8)secret), "the arena holds the secret before the wipe")
		ui.line_edit_wipe(&f)
	}
	testing.expect_value(t, ui.line_edit_string(&f), "")
	testing.expect(t, !ui.line_edit_can_undo(&f) && !ui.line_edit_can_redo(&f), "no history")
	testing.expect(t, !bytes.contains(backing, transmute([]u8)secret), "no copy of the secret is left")
	testing.expect(t, !bytes.contains(backing, transmute([]u8)secret[:6]), "nor a part of it")
}) }
