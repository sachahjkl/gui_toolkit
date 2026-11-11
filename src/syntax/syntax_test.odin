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

// A text with no name: its #! line, its signs and keywords; prose and a list of words are no code.
@(test)
a_language_is_guessed_from_the_text :: proc(t: ^testing.T) {
	Case :: struct { text, label: string }
	cases := []Case{
		{"#!/usr/bin/env bash\nset -euo pipefail\necho hi", "Shell"},
		{"#!/usr/bin/python3\nprint(1)", "Python"},
		{"proc fibonacci(n: u64) -> u64 {\n\tif n < 2 { return n }\n\treturn fibonacci(n - 1) + fibonacci(n - 2)\n}\nx := 3", "Odin"},
		{"SELECT name, email FROM users WHERE created_at > '2026-01-01' ORDER BY name;", "SQL"},
		{"def greet(self, name):\n    print(f\"hello {name}\")\n    return None", "Python"},
		{"const add = (a, b) => a + b;\nconsole.log(add(1, 2));", "JavaScript"},
		{"fn main() {\n    let mut v = Vec::new();\n    v.push(1);\n    println!(\"{:?}\", v);\n}", "Rust"},
		{"package main\n\nimport \"fmt\"\n\nfunc main() {\n\tx := 1\n\tif err != nil { return }\n\tfmt.Println(x)\n}", "Go"},
		{"#include <stdio.h>\nint main(void) {\n    printf(\"hi\\n\");\n    return 0;\n}", "C"},
		{"{\"name\": \"papier\", \"version\": \"0.11.0\"}", "JSON"},
		{"Get-ChildItem | Where-Object { $_.Length -gt 1000 } | ForEach-Object { Write-Host $_.Name }", "PowerShell"},
	}
	for c in cases {
		l, ok := guess(c.text)
		testing.expectf(t, ok && l.label == c.label, "%q: %s, want %s", c.text[:min(len(c.text), 30)], l.label, c.label)
	}
	prose := []string{
		"Meeting moved to Thursday 10:00, room B. Bring the slides if you can, and the notes from the last one for the team.",
		"if you want to do it for me, then do it in the morning, else I will take care of it when I am back home",
		"https://github.com/sachahjkl/papier",
		"/home/ada/Documents/report-2026.pdf",
	}
	for p in prose {
		l, ok := guess(p)
		testing.expectf(t, !ok, "%q is no code (%s)", p[:min(len(p), 30)], l.label)
	}
	sql, _ := language("sql")
	out := make([dynamic]Span, context.temp_allocator)
	spans("select * FROM t", sql, &out)
	testing.expect(t, len(out) >= 2 && out[0].class == .Keyword && out[1].class == .Keyword, "SQL's keywords in any case")
}
