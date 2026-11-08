// The composition of an input method as the protocols deliver it (platform.Ime_Compose, which the Wayland text-input
// feeds): what comes before a `done` waits for it; a `done` gives the app its events (Backspace presses for the text
// replaced, .Text for the text committed) and the preedit to draw. And the caret's rectangle in the compositor's units.
// No window, no input method: the protocol's events are made up.
//   odin test tests/ime -vet
package ime_test

import "core:strings"
import "core:testing"
import "../../src/platform"

// The bytes of one kana in UTF-8: the caret's offsets in a preedit of kana.
@(private = "file") KANA_BYTES :: 3

// The text of the .Text events.
@(private = "file")
texts :: proc(evs: []platform.Event) -> string {
	b := strings.builder_make(context.temp_allocator)
	for e in evs { if e.kind == .Text { strings.write_rune(&b, e.text) } }
	return strings.to_string(b)
}

@(test)
a_preedit_waits_for_done :: proc(t: ^testing.T) {
	c: platform.Ime_Compose
	defer platform.ime_compose_destroy(&c)
	evs := make([dynamic]platform.Event, context.temp_allocator)
	platform.ime_compose_preedit(&c, "にほ", KANA_BYTES)
	testing.expect_value(t, c.preedit, "")
	testing.expect(t, !platform.ime_compose_take_changed(&c), "nothing shown before done")
	platform.ime_compose_done(&c, &evs)
	testing.expect_value(t, len(evs), 0)
	testing.expect_value(t, c.preedit, "にほ")
	testing.expect_value(t, c.cursor, KANA_BYTES)
	testing.expect(t, platform.ime_compose_take_changed(&c), "changed")
	testing.expect(t, !platform.ime_compose_take_changed(&c), "once")
	// the same preedit again: no change; the caret alone moves: a change
	platform.ime_compose_preedit(&c, "にほ", KANA_BYTES)
	platform.ime_compose_done(&c, &evs)
	testing.expect(t, !platform.ime_compose_take_changed(&c), "the same preedit")
	platform.ime_compose_preedit(&c, "にほ", 2 * KANA_BYTES)
	platform.ime_compose_done(&c, &evs)
	testing.expect(t, platform.ime_compose_take_changed(&c) && c.cursor == 2 * KANA_BYTES, "the caret moved")
}

// A commit replaces the preedit: the committed runes as .Text events, and no preedit after the done (none was sent).
@(test)
a_commit_ends_the_composition :: proc(t: ^testing.T) {
	c: platform.Ime_Compose
	defer platform.ime_compose_destroy(&c)
	evs := make([dynamic]platform.Event, context.temp_allocator)
	platform.ime_compose_preedit(&c, "にほん", 3 * KANA_BYTES)
	platform.ime_compose_done(&c, &evs)
	_ = platform.ime_compose_take_changed(&c)
	platform.ime_compose_commit(&c, "日本")
	platform.ime_compose_done(&c, &evs)
	testing.expect_value(t, texts(evs[:]), "日本")
	testing.expect_value(t, len(evs), 2)
	testing.expect_value(t, c.preedit, "")
	testing.expect_value(t, c.cursor, 0)
	testing.expect(t, platform.ime_compose_take_changed(&c), "the preedit went away")
	clear(&evs)
	platform.ime_compose_done(&c, &evs)
	testing.expect_value(t, len(evs), 0)   // a commit is applied once
}

// Text the input method replaces is deleted before the commit is inserted (a dead key, a correction); control
// characters of a commit are not text.
@(test)
a_deletion_comes_before_the_commit :: proc(t: ^testing.T) {
	c: platform.Ime_Compose
	defer platform.ime_compose_destroy(&c)
	evs := make([dynamic]platform.Event, context.temp_allocator)
	platform.ime_compose_delete(&c, 2)
	platform.ime_compose_commit(&c, "é\n\x7f!")
	testing.expect_value(t, len(evs), 0)
	platform.ime_compose_done(&c, &evs)
	if testing.expect_value(t, len(evs), 6) {
		for i in 0 ..< 2 {
			testing.expect(t, evs[2 * i].kind == .Key_Press && evs[2 * i].key == .Backspace, "a Backspace press")
			testing.expect(t, evs[2 * i + 1].kind == .Key_Release && evs[2 * i + 1].key == .Backspace, "its release")
		}
		testing.expect_value(t, texts(evs[4:]), "é!")
	}
	clear(&evs)
	platform.ime_compose_delete(&c, -1)
	platform.ime_compose_done(&c, &evs)
	testing.expect_value(t, len(evs), 0)
}

// A caret outside the preedit is put at its edge (hidden, negative: at its start); turning the input method off drops
// the preedit and what was pending.
@(test)
the_caret_is_kept_in_the_preedit_and_reset_drops_all :: proc(t: ^testing.T) {
	c: platform.Ime_Compose
	defer platform.ime_compose_destroy(&c)
	evs := make([dynamic]platform.Event, context.temp_allocator)
	platform.ime_compose_preedit(&c, "ab", 99)
	platform.ime_compose_done(&c, &evs)
	testing.expect_value(t, c.cursor, 2)
	platform.ime_compose_preedit(&c, "abc", -1)
	platform.ime_compose_done(&c, &evs)
	testing.expect_value(t, c.cursor, 0)
	_ = platform.ime_compose_take_changed(&c)
	platform.ime_compose_preedit(&c, "x", 1)
	platform.ime_compose_commit(&c, "y")
	platform.ime_compose_reset(&c)
	testing.expect(t, c.preedit == "" && platform.ime_compose_take_changed(&c), "reset: no preedit, a change")
	platform.ime_compose_done(&c, &evs)
	testing.expect_value(t, len(evs), 0)   // what was pending went with it
	testing.expect_value(t, c.preedit, "")
}

@(test)
the_caret_rect_in_logical_units :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.ime_cursor_rect_logical(100, 50, 3, 20, 2), [4]i32{50, 25, 1, 10})
	testing.expect_value(t, platform.ime_cursor_rect_logical(150, 30, 6, 30, 1.5), [4]i32{100, 20, 4, 20})
	testing.expect_value(t, platform.ime_cursor_rect_logical(10, 10, 2, 0, 2), [4]i32{5, 5, 1, 1})   // at least one unit high
	testing.expect_value(t, platform.ime_cursor_rect_logical(10, 10, 2, 8, 0), [4]i32{10, 10, 2, 8})  // no scale: 1
}
