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
	_, hok := language_of_file("README.md")
	testing.expect(t, !hok, "a language without colours")
}

// The class of the first run that is exactly `piece`; Plain when no run is.
@(private = "file")
class_at :: proc(src: string, out: []Span, piece: string) -> Class {
	for sp in out { if src[sp.start:sp.end] == piece { return sp.class } }
	return .Plain
}

// Each language by its files: their extension, or their whole name (Dockerfile, Makefile), in a path too.
@(test)
the_new_languages_are_found_by_file :: proc(t: ^testing.T) {
	Case :: struct { file, label: string }
	cases := []Case{
		{"Main.java", "Java"}, {"Program.cs", "C#"}, {"App.kt", "Kotlin"}, {"build.gradle.kts", "Kotlin"},
		{"View.swift", "Swift"}, {"index.php", "PHP"}, {"app.rb", "Ruby"}, {"Gemfile", "Ruby"}, {"init.lua", "Lua"},
		{"main.zig", "Zig"}, {"flake.nix", "Nix"}, {"main.dart", "Dart"}, {"ci.yml", "YAML"}, {"compose.yaml", "YAML"},
		{"Cargo.toml", "TOML"}, {"setup.cfg", "INI"}, {"firefox.desktop", "INI"}, {"papier.service", "INI"},
		{"Dockerfile", "Dockerfile"}, {"dockerfile", "Dockerfile"}, {"Dockerfile.dev", "Dockerfile"},
		{"api.dockerfile", "Dockerfile"}, {"src/app/Dockerfile", "Dockerfile"}, {"Makefile", "Makefile"},
		{"makefile", "Makefile"}, {"GNUmakefile", "Makefile"}, {"rules.mk", "Makefile"}, {"index.html", "HTML"},
		{"icon.svg", "XML"}, {"App.csproj", "XML"}, {"pom.xml", "XML"}, {"style.css", "CSS"},
	}
	for c in cases {
		l, ok := language_of_file(c.file)
		testing.expectf(t, ok && l.label == c.label, "%s: %s, want %s", c.file, l.label, c.label)
	}
	_, dok := language_of_file("changes.diff")
	testing.expect(t, !dok, "a diff has no colours")
}

// Each language guessed from a short snippet with no name; Markdown and diffs before the code they hold.
@(test)
the_new_languages_are_guessed :: proc(t: ^testing.T) {
	Case :: struct { text, label: string }
	cases := []Case{
		{"public class Hello {\n    public static void main(String[] args) {\n        System.out.println(\"Hi\");\n    }\n}", "Java"},
		{"using System;\n\nnamespace App\n{\n    class Program\n    {\n        static void Main(string[] args)\n        {\n            Console.WriteLine(\"Hi\");\n        }\n    }\n}", "C#"},
		{"fun main() {\n    val name = \"Kotlin\"\n    println(\"Hello, $name!\")\n}", "Kotlin"},
		{"import Foundation\n\nfunc greet(name: String) -> String {\n    return \"Hello, \\(name)\"\n}", "Swift"},
		{"<?php\n$name = $_GET['name'] ?? 'world';\necho \"Hello, $name\";", "PHP"},
		{"class User {\n    public function __construct(private string $name) {}\n    public function name(): string { return $this->name; }\n}", "PHP"},
		{"require 'json'\n\nclass Greeter\n  def initialize(name)\n    @name = name\n  end\n\n  def greet\n    puts \"Hello, #{@name}\"\n  end\nend", "Ruby"},
		{"local function greet(name)\n  print(\"Hello, \" .. name)\nend\n\nfor i, v in ipairs(items) do\n  greet(v)\nend", "Lua"},
		{"const std = @import(\"std\");\n\npub fn main() !void {\n    std.debug.print(\"Hello\\n\", .{});\n}", "Zig"},
		{"{ pkgs ? import <nixpkgs> {} }:\n\npkgs.mkShell {\n  packages = [ pkgs.git ];\n}", "Nix"},
		{"import 'package:flutter/material.dart';\n\nclass MyApp extends StatelessWidget {\n  @override\n  Widget build(BuildContext context) {\n    return const Text('Hi');\n  }\n}", "Dart"},
		{"name: CI\non:\n  push:\n    branches: [main]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: make test", "YAML"},
		{"[package]\nname = \"papier\"\nversion = \"0.18.1\"\n\n[dependencies]\nserde = { version = \"1\", features = [\"derive\"] }", "TOML"},
		{"[Desktop Entry]\nName=Papier\nExec=papier %u\nTerminal=false\nType=Application", "INI"},
		{"FROM node:20-alpine\nWORKDIR /app\nCOPY package.json .\nRUN npm ci\nCMD [\"node\", \"index.js\"]", "Dockerfile"},
		{"CC = gcc\nCFLAGS = -O2\n\nall: app\n\napp: main.o\n\t$(CC) $(CFLAGS) -o $@ $^\n\n.PHONY: clean\nclean:\n\trm -f *.o app", "Makefile"},
		{"<!DOCTYPE html>\n<html>\n<head><title>Hi</title></head>\n<body>\n  <!-- main -->\n  <p class=\"lead\">Hello</p>\n</body>\n</html>", "HTML"},
		{"<ul>\n  <li>one</li>\n  <li>two</li>\n</ul>", "HTML"},
		{"<?xml version=\"1.0\"?>\n<project>\n  <name>papier</name>\n</project>", "XML"},
		{"<config>\n  <item key=\"a\"/>\n</config>", "XML"},
		{".button {\n  color: #fff;\n  padding: 4px 8px;\n}\n@media (max-width: 600px) {\n  .button { display: none; }\n}", "CSS"},
		{"# papier\n\nA clipboard manager.\n\n## Install\n\n- download the archive\n- run `papier`\n\nSee [the docs](https://example.org).", "Markdown"},
		{"Here is the fix:\n\n```odin\nx := proc() -> int { return 1 }\n```\n", "Markdown"},
		{"Steps:\n1. open it\n2. copy\n\n**Note**: it keeps 500 entries.", "Markdown"},
		{"diff --git a/app.py b/app.py\nindex 83db48f..bf269f4 100644\n--- a/app.py\n+++ b/app.py\n@@ -1,3 +1,4 @@\n import os\n+import sys\n def main():\n     print(os.getcwd())", "Diff"},
		{"@@ -10,6 +10,7 @@ main :: proc() {\n \tx := 1\n-\ty := 2\n+\ty := 3\n }", "Diff"},
	}
	for c in cases {
		l, ok := guess(c.text)
		testing.expectf(t, ok && l.label == c.label, "%q: %s, want %s", c.text[:min(len(c.text), 30)], l.label, c.label)
	}
	md, _ := guess("# Title\n\n- a\n- b")
	testing.expect(t, !md.highlight, "Markdown: a label, no colours")
	out := make([dynamic]Span, context.temp_allocator)
	spans("# Title\n\n- a `x`", md, &out)
	testing.expect(t, len(out) == 0, "no runs for a language with no colours")
	not_markdown := []string{
		"- buy milk",
		"A plain paragraph, with a comma: and a colon, and nothing else that would mark it as anything but prose at all.",
		"# install the dependencies first\napt-get install -y curl\ncurl -fsSL `cat url.txt` | sh",
		"From: Ada\nTo: Bob\nSubject: the report",
	}
	for p in not_markdown {
		l, _ := guess(p)
		testing.expectf(t, l.label != "Markdown" && l.label != "YAML", "%q: %s", p[:min(len(p), 30)], l.label)
	}
}

// One Keyword and one Comment or Str in a line of each new language; the rules of the data languages.
@(test)
the_new_languages_have_their_runs :: proc(t: ^testing.T) {
	Case :: struct { name, text: string }
	cases := []Case{
		{"java", "public class A { // c\n String s = \"x\"; }"},
		{"cs", "using System; // c\nvar s = \"x\";"},
		{"kotlin", "fun main() { val s = \"x\" } // c"},
		{"swift", "func f() { let s = \"x\" } // c"},
		{"php", "<?php function f() { return $x; } // c"},
		{"ruby", "def f\n  puts 'x' # c\nend"},
		{"lua", "local x = 1 -- c\n--[[ block ]]"},
		{"zig", "const x: u8 = 1; // c"},
		{"nix", "let x = \"a\"; in x # c"},
		{"dart", "final s = 'x'; // c"},
		{"yaml", "enabled: true # c\nname: plain text"},
		{"toml", "[package]\nname = \"x\" # c"},
		{"ini", "[Unit]\nDescription=Papier # c"},
		{"dockerfile", "FROM alpine\n# c\nRUN echo \"hi\""},
		{"makefile", "ifdef DEBUG\n# c\nendif\nall: app\n\t$(CC) -o $@ $^"},
	}
	for c in cases {
		l, ok := language(c.name)
		testing.expectf(t, ok && l.highlight, "%s is known and coloured", c.name)
		out := make([dynamic]Span, context.temp_allocator)
		spans(c.text, l, &out)
		keyword, text := false, false
		for sp in out {
			if sp.class == .Keyword { keyword = true }
			if sp.class == .Comment || sp.class == .Str { text = true }
		}
		testing.expectf(t, keyword && text, "%s: a keyword and a comment or string in %q", c.name, c.text)
		for i in 1 ..< len(out) { testing.expectf(t, out[i].start >= out[i - 1].end, "%s: in order, none overlapping", c.name) }
	}
	Want :: struct { name, text, piece: string, class: Class }
	wants := []Want{
		{"lua", "local x = 1 -- c\n--[[ block ]]", "--[[ block ]]", .Comment},
		{"yaml", "enabled: true # c\nname: plain text\n- id: 3", "enabled", .Func},
		{"yaml", "enabled: true # c\nname: plain text\n- id: 3", "true", .Keyword},
		{"yaml", "enabled: true # c\nname: plain text\n- id: 3", "plain text", .Str},
		{"yaml", "enabled: true # c\nname: plain text\n- id: 3", "id", .Func},
		{"yaml", "url: https://example.org", "https", .Plain},
		{"ini", "[Unit]\nDescription=Papier # c", "[Unit]", .Keyword},
		{"ini", "[Unit]\nDescription=Papier # c", "Description", .Func},
		{"ini", "[Unit]\nDescription=Papier # c", "Papier", .Str},
		{"ini", "[Unit]\nDescription=Papier # c", "# c", .Comment},
		{"toml", "[[bin]]\nname = \"x\"", "[[bin]]", .Keyword},
		{"makefile", "all: app\n\t$(CC) -o $@ $^", "all", .Func},
		{"makefile", "all: app\n\t$(CC) -o $@ $^", "$(CC)", .Type},
		{"makefile", "all: app\n\t$(CC) -o $@ $^", "$@", .Type},
		{"dockerfile", "from alpine AS build", "AS", .Keyword},
		{"swift", "@State var on = false", "@State", .Func},
	}
	for w in wants {
		l, _ := language(w.name)
		out := make([dynamic]Span, context.temp_allocator)
		spans(w.text, l, &out)
		testing.expectf(t, class_at(w.text, out[:], w.piece) == w.class, "%s: %q is %v", w.name, w.piece, w.class)
	}
}

// HTML and XML: tag names keywords, attribute names calls, values strings, comments, directives; CSS: selectors,
// properties, values.
@(test)
markup_and_style_sheets_have_their_runs :: proc(t: ^testing.T) {
	Want :: struct { piece: string, class: Class }
	check :: proc(t: ^testing.T, name, src: string, wants: []Want) {
		l, ok := language(name)
		testing.expectf(t, ok && l.highlight, "%s is coloured", name)
		out := make([dynamic]Span, context.temp_allocator)
		spans(src, l, &out)
		for w in wants { testing.expectf(t, class_at(src, out[:], w.piece) == w.class, "%s: %q is %v", name, w.piece, w.class) }
		for i in 1 ..< len(out) { testing.expectf(t, out[i].start >= out[i - 1].end, "%s: in order, none overlapping", name) }
	}
	check(t, "html", "<!DOCTYPE html>\n<p class=\"lead\" hidden>Hi &amp; Bye</p><!-- note --><script>let x = 1</script><style>a { color: red }</style>", {
		{"<!DOCTYPE html>", .Func}, {"p", .Keyword}, {"class", .Func}, {"\"lead\"", .Str}, {"hidden", .Func},
		{"&amp;", .Type}, {"<!-- note -->", .Comment}, {"Hi", .Plain}, {"Bye", .Plain}, {"script", .Keyword},
		{"let", .Keyword}, {"color", .Func},
	})
	check(t, "xml", "<?xml version=\"1.0\"?><root a='1' b=two/><![CDATA[x < y]]>", {
		{"<?xml version=\"1.0\"?>", .Func}, {"root", .Keyword}, {"a", .Func}, {"'1'", .Str}, {"two", .Str},
		{"<![CDATA[x < y]]>", .Str},
	})
	check(t, "css", "a:hover { color: #fff; margin: 0 4px } /* c */\n@media (max-width: 600px) { .b { display: none !important; background: url(x.png) } }", {
		{"a", .Keyword}, {":hover", .Func}, {"color", .Func}, {"#fff", .Type}, {"4px", .Type}, {"/* c */", .Comment},
		{"@media", .Keyword}, {"600px", .Type}, {".b", .Type}, {"display", .Func}, {"none", .Plain},
		{"!important", .Keyword}, {"url", .Func},
	})
	check(t, "css", "  color: red;", {{"color", .Func}, {"red", .Plain}})
}

// A text with no name: its #! line, its signs and keywords; prose and a list of words are no code.
@(test)
a_language_is_guessed_from_the_text :: proc(t: ^testing.T) {
	Case :: struct { text, label: string }
	cases := []Case{
		{"#!/usr/bin/env bash\nset -euo pipefail\necho hi", "Shell"},
		{"#!/usr/bin/python3\nprint(1)", "Python"},
		{"proc fibonacci(n: u64) -> u64 {\n\tif n < 2 { return n }\n\treturn fibonacci(n - 1) + fibonacci(n - 2)\n}\nx := 3", "Odin"},
		{"proc fibonacci(n: u64) -> u64 {\n\tif n < 2 { return n }\n\treturn fibonacci(n - 1) + fibonacci(n - 2)\n}", "Odin"},
		{"SELECT name, email FROM users\nWHERE created_at > now() - interval '7 days'\nORDER BY created_at DESC;", "SQL"},
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
