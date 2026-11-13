package tk_undo

import "core:strings"
import "core:testing"

@(private = "file")
free_text :: proc(s: ^string) {
	delete(s^)
	s^ = ""
}

// Undo goes back through the steps, redo comes forward again, and a new change after an undo makes the redo steps go.
@(test)
undo_and_redo_go_through_the_steps :: proc(t: ^testing.T) {
	s: Stack(string)
	defer destroy(&s, free_text)
	model := strings.clone("a")
	defer delete(model)
	edit :: proc(s: ^Stack(string), model: ^string, text: string) {
		push(s, model^, 0, free_text)   // (the model's text is the step now: a new one is made)
		model^ = strings.clone(text)
	}
	edit(&s, &model, "ab")
	edit(&s, &model, "abc")
	testing.expect(t, can_undo(&s))
	testing.expect(t, !can_redo(&s))

	back, ok := undo(&s, model)
	testing.expect(t, ok)
	model = back
	testing.expect_value(t, model, "ab")
	back, ok = undo(&s, model)
	model = back
	testing.expect_value(t, model, "a")
	testing.expect(t, !can_undo(&s))
	_, ok = undo(&s, model)
	testing.expect(t, !ok)   // (nothing left: `now` is not taken)

	again, _ := redo(&s, model)
	model = again
	testing.expect_value(t, model, "ab")
	testing.expect(t, can_redo(&s))
	edit(&s, &model, "abX")
	testing.expect(t, !can_redo(&s))   // (the change made "abc" useless)
	back, _ = undo(&s, model)
	model = back
	testing.expect_value(t, model, "ab")
}

// The oldest steps go past the limit; a step pushed for a change refused after all is dropped.
@(test)
the_limit_drops_the_oldest_steps :: proc(t: ^testing.T) {
	s: Stack(string)
	defer destroy(&s, free_text)
	for word in ([]string{"1", "2", "3", "4", "5"}) { push(&s, strings.clone(word), 3, free_text) }
	testing.expect_value(t, len(s.undo), 3)
	testing.expect_value(t, s.undo[0], "3")
	push(&s, strings.clone("refused"), 3, free_text)
	drop_last(&s, free_text)
	// (the push trimmed "3" to make room: dropping it again leaves the two after it)
	testing.expect_value(t, len(s.undo), 2)
	testing.expect_value(t, s.undo[len(s.undo) - 1], "5")
	reset(&s, free_text)
	testing.expect(t, !can_undo(&s) && !can_redo(&s))
}
