package tk_process

import "core:strings"
import "core:testing"
import "../ascii"

@(test)
a_script_runs_through_cmd_with_rusts_quoting :: proc(t: ^testing.T) {
	// Rust's inputs (tests/ui/std/windows-bat-args.rs) and the line each gives after the script's own part.
	Case :: struct { args: []string, line: string }
	cases := [?]Case{
		{{`a`, `b`}, `a b`},
		{{`c is for cat`, `d is for dog`}, `"c is for cat" "d is for dog"`},
		{{`"`, ` "`}, `"""" " """`},
		{{`\`, `\`}, `"\\" "\\"`},
		{{`>file.txt`}, `">file.txt"`},
		{{`whoami.exe`}, `whoami.exe`},
		{{`&a.exe`}, `"&a.exe"`},
		{{`&echo hello `}, `"&echo hello "`},
		{{`&echo hello`, `&whoami`, `>file.txt`}, `"&echo hello" "&whoami" ">file.txt"`},
		{{`!TMP!`}, `"!TMP!"`},
		{{`key=value`}, `"key=value"`},
		{{`"key=value"`}, `"""key=value"""`},
		{{`key = value`}, `"key = value"`},
		{{`key=["value"]`}, `"key=[""value""]"`},
		{{``, `a=b`}, `"" "a=b"`},
		{{`key="foo bar"`}, `"key=""foo bar"""`},
		{{`key=["my_value]`}, `"key=[""my_value]"`},
		{{`key=["my_value","other-value"]`}, `"key=[""my_value"",""other-value""]"`},
		{{`key\=value`}, `"key\=value"`},
		{{`key="&whoami"`}, `"key=""&whoami"""`},
		{{`key="value"=5`}, `"key=""value""=5"`},
		{{`key=[">file.txt"]`}, `"key=["">file.txt""]"`},
		{{`%hello`}, `"%%cd:~,%hello"`},
		{{`%PATH%`}, `"%%cd:~,%PATH%%cd:~,%"`},
		{{`%%cd:~,%`}, `"%%cd:~,%%%cd:~,%cd:~,%%cd:~,%"`},
		{{`%PATH%PATH%`}, `"%%cd:~,%PATH%%cd:~,%PATH%%cd:~,%"`},
		{{`">file.txt`}, `""">file.txt"`},
		{{`abc"&echo hello`}, `"abc""&echo hello"`},
		{{`123">file.txt`}, `"123"">file.txt"`},
		{{`"&echo hello&whoami.exe`}, `"""&echo hello&whoami.exe"`},
		{{`hello^"world`, `hello &echo oh no >file.txt`}, `"hello^""world" "hello &echo oh no >file.txt"`},
	}
	SCRIPT :: `C:\npm\gemini.cmd`
	for c in cases {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "gemini")
		append(&args, ..c.args)
		cl, err := windows_command_line(SCRIPT, args[:], `C:\Windows\System32`, context.temp_allocator)
		testing.expect_value(t, err, Command_Line_Error.None)
		testing.expect_value(t, cl.application, `C:\Windows\System32\cmd.exe`)
		want := strings.concatenate({`cmd.exe /e:ON /v:OFF /d /c ""C:\npm\gemini.cmd" `, c.line, `"`}, context.temp_allocator)
		testing.expect_value(t, cl.line, want)
	}
	// (no argument: the script alone in its quotes)
	cl, _ := windows_command_line(`D:\a\run.BAT`, {"run"}, `C:\Windows\System32\`, context.temp_allocator)
	testing.expect_value(t, cl.line, `cmd.exe /e:ON /v:OFF /d /c ""D:\a\run.BAT""`)
	testing.expect_value(t, cl.application, `C:\Windows\System32\cmd.exe`)
}

@(test)
what_cmd_cannot_carry_is_refused :: proc(t: ^testing.T) {
	S :: `C:\npm\x.cmd`
	for bad in ([]string{"\n", "\r", "a\nb", "line\r\n"}) {
		_, err := windows_command_line(S, {"x", "ok", bad}, `C:\Windows\System32`, context.temp_allocator)
		testing.expect_value(t, err, Command_Line_Error.Line_Break)
	}
	for script in ([]string{`C:\a"b\x.cmd`, `C:\50%\x.cmd`, `C:\a^b\x.bat`}) {
		_, err := windows_command_line(script, {"x"}, `C:\Windows\System32`, context.temp_allocator)
		testing.expect_value(t, err, Command_Line_Error.Script_Name)
	}
	_, nul := windows_command_line(S, {"x", "a\x00b"}, `C:\Windows\System32`, context.temp_allocator)
	testing.expect_value(t, nul, Command_Line_Error.Nul)
	_, nul2 := windows_command_line(`C:\a\x.exe`, {"x", "a\x00b"}, `C:\Windows\System32`, context.temp_allocator)
	testing.expect_value(t, nul2, Command_Line_Error.Nul)
	_, quote := windows_command_line(`C:\a\x.exe`, {`x"y`}, `C:\Windows\System32`, context.temp_allocator)
	testing.expect_value(t, quote, Command_Line_Error.Program_Quote)
	// (a program, not a script: a line break is the program's to read)
	cl, ok := windows_command_line(`C:\a\x.exe`, {"x", "a\nb"}, `C:\Windows\System32`, context.temp_allocator)
	testing.expect_value(t, ok, Command_Line_Error.None)
	testing.expect_value(t, cl.line, "\"x\" a\nb")
}

@(test)
a_program_gets_the_c_runtimes_quoting :: proc(t: ^testing.T) {
	CASES :: [?]struct { arg, quoted: string }{
		{`plain`, `plain`},
		{``, `""`},
		{`a b`, `"a b"`},
		{"a\tb", "\"a\tb\""},
		{`a"b`, `a\"b`},
		{`a\"b`, `a\\\"b`},
		{`a\b`, `a\b`},
		{`a\`, `a\`},
		{`a b\`, `"a b\\"`},
		{`a b\\`, `"a b\\\\"`},
		{`&|<>%x%`, `&|<>%x%`},
		{`"`, `\"`},
	}
	for c in CASES {
		cl, err := windows_command_line(`C:\Program Files\Git\cmd\git.exe`, {"git", c.arg}, `C:\Windows\System32`, context.temp_allocator)
		testing.expect_value(t, err, Command_Line_Error.None)
		testing.expect_value(t, cl.application, `C:\Program Files\Git\cmd\git.exe`)
		testing.expect_value(t, cl.line, strings.concatenate({`"git" `, c.quoted}, context.temp_allocator))
	}
}

@(test)
a_script_is_known_by_its_extension :: proc(t: ^testing.T) {
	testing.expect(t, is_script(`C:\a\x.cmd`))
	testing.expect(t, is_script(`C:\a\x.BaT`))
	testing.expect(t, is_script("windows-bat-args1.bat .. "), "trailing dots and spaces are dropped")
	testing.expect(t, !is_script(`C:\a\x.exe`))
	testing.expect(t, !is_script("bat"))
	testing.expect(t, !is_script(`C:\a\x.cmdx`))
}

@(test)
a_bare_name_is_found_in_path_never_in_the_current_folder :: proc(t: ^testing.T) {
	Files :: struct { names: []string }
	exists := proc(path: string, user: rawptr) -> bool {
		// (Windows' file names fold their case; the Linux names here differ in more than case)
		for n in (^Files)(user).names { if ascii.equal_fold(n, path) { return true } }
		return false
	}
	win := Files{{`C:\npm\gemini.cmd`, `C:\npm\gemini`, `C:\bin\node.exe`, `C:\other\gemini.exe`, `gemini.exe`, `.\gemini.exe`}}
	// PATHEXT's order (.COM, .EXE, .BAT, .CMD) within a folder; the folders in PATH's order; "" and "." skipped
	found, ok := resolve_command("gemini", `;.;"C:\npm";C:\other`, "", true, exists, &win, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, found, `C:\npm\gemini.CMD`)
	found, ok = resolve_command("node.exe", `relative\bin;C:\bin\`, ".EXE;.CMD", true, exists, &win, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, found, `C:\bin\node.exe`)
	_, ok = resolve_command("node", `.;bin`, "", true, exists, &win, context.temp_allocator)
	testing.expect(t, !ok, "never the current folder")
	found, ok = resolve_command(`C:\tools\x.exe`, "", "", true, exists, &win, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, found, `C:\tools\x.exe`)
	found, _ = resolve_command(`sub\x.exe`, "", "", true, exists, &win, context.temp_allocator)
	testing.expect_value(t, found, `sub\x.exe`)

	nix := Files{{"/usr/bin/git", "/home/me/.npm/bin/gemini", "git"}}
	found, ok = resolve_command("gemini", "::.:bin:/usr/bin:/home/me/.npm/bin/", "", false, exists, &nix, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, found, "/home/me/.npm/bin/gemini")
	_, ok = resolve_command("git", ".:bin", "", false, exists, &nix, context.temp_allocator)
	testing.expect(t, !ok)
	found, ok = resolve_command("./git", "", "", false, exists, &nix, context.temp_allocator)
	testing.expect(t, ok && found == "./git", "a path is the caller's own")
	_, ok = resolve_command("", "/usr/bin", "", false, exists, &nix, context.temp_allocator)
	testing.expect(t, !ok)
}
