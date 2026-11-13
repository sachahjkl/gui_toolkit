package shortcuts_test

import "core:testing"
import shortcuts "../../src/shortcuts"

// What a settings page says under a shortcut, for each state the system can give.
@(test)
the_words_of_each_state :: proc(t: ^testing.T) {
	Case :: struct { asked: string, st: shortcuts.Status, status, problem: string }
	cases := [?]Case{
		{"Ctrl+Print", {.Waiting, ""}, "Waiting for the system's answer…", ""},
		{"", {.Waiting, ""}, "", ""},
		{"Ctrl+Print", {.Bound, "Ctrl+Print"}, "Works in every program: Ctrl+Print.", ""},
		// (the system's words for the keys read as the toolkit names them)
		{"Shift+Print", {.Bound, "SHIFT+Print"}, "Works in every program: Shift+Print.", ""},
		{"Ctrl+Shift+A", {.Bound, "CTRL+SHIFT+a"}, "Works in every program: Ctrl+Shift+A.", ""},
		{"Ctrl+Print", {.Bound, "Alt+Print"}, "The system gave other keys: Alt+Print. Change them in its shortcut settings.", ""},
		{"", {.Bound, "Alt+Print"}, "Works in every program: Alt+Print.", ""},
		{"", {.No_Keys, ""}, "No keys.", ""},
		{"Ctrl+Print", {.No_Keys, ""}, "The system gave no keys yet: choose them in its shortcut settings.", ""},
		{"Ctrl+Print", {.Taken, "Ctrl+Print"}, "", "Another program holds Ctrl+Print: choose other keys."},
		{"Ctrl+Print", {.Refused, ""}, "", "The system refused this shortcut."},
		{"Ctrl+Print", {.Unavailable, ""}, "", "This desktop gives programs no shortcuts of their own: bind the keys in its own settings."},
		{"", {.Unavailable, ""}, "", ""},
		{"Q", {.Unavailable, ""}, "", "\"Q\" is not a shortcut: click the field and press the keys."},
	}
	for c in cases {
		status := shortcuts.status_text(c.asked, c.st)
		problem := shortcuts.problem_text(c.asked, c.st)
		testing.expectf(t, status == c.status, "%v %q: status %q, want %q", c.st.state, c.asked, status, c.status)
		testing.expectf(t, problem == c.problem, "%v %q: problem %q, want %q", c.st.state, c.asked, problem, c.problem)
	}
}

@(test)
the_same_keys_in_other_words :: proc(t: ^testing.T) {
	testing.expect(t, shortcuts.same_keys("Ctrl+Shift+4", "CTRL+SHIFT+4"))
	testing.expect(t, shortcuts.same_keys("Shift+Print", "shift+print"))
	testing.expect(t, !shortcuts.same_keys("Ctrl+Print", "Alt+Print"))
	testing.expect(t, shortcuts.same_keys("", ""))
}
