package tk_syntax

import "core:testing"

// The classes of a few runs of Odin, and the languages found by a file's name.
@(test)
the_runs_have_their_classes :: proc(t: ^testing.T) {
	l, ok := language("odin")
	testing.expect(t, ok)
	src := `x := proc() -> int { return 42 } // done` + "\n" + `s := "a \"q\""`
	out := make([dynamic]Span, context.temp_allocator)
	spans(src, l, &out)
	class_of :: proc(src: string, out: []Span, word: string) -> Class {
		for sp in out { if src[sp.start:sp.end] == word { return sp.class } }
		return .Plain
	}
	testing.expect_value(t, class_of(src, out[:], "proc"), Class.Keyword)
	testing.expect_value(t, class_of(src, out[:], "int"), Class.Type)
	testing.expect_value(t, class_of(src, out[:], "42"), Class.Type)
	testing.expect_value(t, class_of(src, out[:], "// done"), Class.Comment)
	testing.expect_value(t, class_of(src, out[:], `"a \"q\""`), Class.Str)
	for i in 1 ..< len(out) { testing.expect(t, out[i].start >= out[i - 1].end, "in order, none overlapping") }
	py, pok := language_of_file("Script.PY")
	testing.expect(t, pok && py.label == "Python", "by its extension, any case")
	_, nok := language_of_file("notes.txt")
	testing.expect(t, !nok, "no colours for plain text")
	_, hok := language_of_file("index.html")
	testing.expect(t, !hok, "a language without colours")
}
