package cli_test

import "core:strings"
import "core:testing"
import cli "../../src/cli"

@(private = "file")
P :: cli.Program{name = "prog", summary = "a program", version = "1.2.3"}

@(private = "file")
OPTIONS := []cli.Option{
	{name = "session", value = "id", help = "open that session"},
	{name = "settings", value = "n", optional = true, help = "open the settings"},
	{name = "pref", value = "name=value", separate = true, help = "a preference"},
	{name = "setup", help = "open Setup"},
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
