# cli: the command line

`import cli "gt:cli"` (the package is named `tk_cli`). A program's options in one table: `cli.check` answers `--help`
(also `-h`) with the help made from the table, `--version` with the version, and refuses an option the table does not
have, a switch given a value or an option without the value it needs: it prints why, then the help, and the program ends
with code 2. A typo or a guess no longer starts the program as if nothing was said.

```odin
OPTIONS :: []cli.Option{
	{name = "session", value = "id", help = "open that session at start"},
	{name = "settings", value = "n", optional = true, help = "open the settings at start (on page n)"},
	{name = "pref", value = "name=value", separate = true, help = "set a preference for the run"},
	{name = "frames", value = "n", hidden = true},   // (what tools and tests pass: accepted, not listed)
}
if out, code, stop := cli.check({name = "prog", summary = "what it is", version = VERSION}, OPTIONS, os.args[1:]); stop {
	print(out)
	os.exit(code)
}
```

| `Option` | |
|---|---|
| `name` | without its dashes |
| `value` | what it takes, in words: written `--name=<value>`; empty: a switch |
| `optional` | the value may be left out (`--settings`, `--settings=2`) |
| `separate` | the value may be the next argument (`--pref name=value`) |
| `hidden` | accepted, not in the help |
| `group` | the heading it is listed under; the options that follow keep it until another names one |

`Program.examples` (a line, what it does) and `Program.environment` (a variable, what it does) come after the options,
`footer` last (where the program keeps its files).

What each option does stays the program's: `check` only says whether the line is one it understands. `usage` gives the
help alone.
