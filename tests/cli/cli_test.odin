package cli_test

import "core:strings"
import "core:testing"
import cli "../../src/cli"

@(private = "file")
P := cli.Program{name = "prog", summary = "a program", version = "1.2.3",
	examples = {{"prog --session=s1", "that session"}}, environment = {{"PROG_DEBUG=1", "says more"}}}

@(private = "file")
OPTIONS := []cli.Option{
	{name = "session", value = "id", help = "open that session", group = "Start"},
	{name = "settings", value = "n", optional = true, help = "open the settings"},
	{name = "pref", value = "name=value", separate = true, help = "a preference"},
	{name = "setup", help = "open Setup", group = "Install"},
	{name = "seek-subagent", hidden = true},
}

@(test)
what_it_understands_goes_on :: proc(t: ^testing.T) {
	for line in ([][]string{{}, {"--session=s1"}, {"--settings"}, {"--settings=2"}, {"--pref", "a.b=1"}, {"--pref=a.b=1"}, {"--setup", "--seek-subagent"}}) {
		_, _, stop := cli.check(P, OPTIONS, line)
		testing.expectf(t, !stop, "%v goes on", line)
	}
}

@(test)
help_and_version_stop_with_zero :: proc(t: ^testing.T) {
	out, code, stop := cli.check(P, OPTIONS, {"--help"})
	testing.expect(t, stop && code == cli.EXIT_OK)
	testing.expect(t, strings.contains(out, "--session=<id>") && strings.contains(out, "--settings[=<n>]") && strings.contains(out, "--pref <name=value>"), out)
	testing.expect(t, !strings.contains(out, "seek-subagent"), "a hidden option is not listed")
	testing.expect(t, strings.index(out, "Start:") < strings.index(out, "--session=") && strings.index(out, "Install:") < strings.index(out, "--setup"), out)
	testing.expect(t, strings.contains(out, "Examples:\n  prog --session=s1") && strings.contains(out, "Environment:\n  PROG_DEBUG=1"), out)
	out, code, stop = cli.check(P, OPTIONS, {"--version"})
	testing.expect(t, stop && code == cli.EXIT_OK && out == "prog 1.2.3\n", out)
}

@(test)
what_it_does_not_understand_stops_with_two :: proc(t: ^testing.T) {
	for line in ([][]string{{"--nope"}, {"file.txt"}, {"--setup=1"}, {"--session"}, {"--session="}, {"--pref"}}) {
		out, code, stop := cli.check(P, OPTIONS, line)
		testing.expectf(t, stop && code == cli.EXIT_USAGE, "%v is refused", line)
		testing.expectf(t, strings.contains(out, "Usage: prog"), "%v: with the help", line)
	}
}

// A line read once: its options in order, a separate value joined to its option, the last value of an option given twice,
// every value of a repeated one, a switch and an optional value left out.
@(test)
a_line_is_read_into_its_options :: proc(t: ^testing.T) {
	line := []string{"--session=s1", "--pref", "a.b=1", "--settings", "--pref=c.d=2", "--session=s2", "--setup"}
	given := cli.parse(OPTIONS, line, context.temp_allocator)
	testing.expect_value(t, len(given), 6)
	testing.expect(t, given[1] == cli.Given{"pref", "a.b=1", true}, "a separate value joined to its option")
	session, ok := cli.value(given, "session")
	testing.expect(t, ok && session == "s2", "the last value wins")
	prefs := cli.values(given, "pref")
	testing.expect(t, len(prefs) == 2 && prefs[0] == "a.b=1" && prefs[1] == "c.d=2", "every value, in order")
	_, page := cli.value(given, "settings")
	testing.expect(t, cli.has(given, "settings") && !page, "an optional value left out: given, no value")
	testing.expect(t, cli.has(given, "setup") && !cli.has(given, "seek-subagent"), "a switch given, one not")
}
