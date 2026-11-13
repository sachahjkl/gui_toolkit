type: Changed

**`--install`, `--uninstall` and `--setup` are the same in every program.** `setup.command_of` takes them out of the arguments and `setup.command_run` installs or uninstalls the whole copy, without a window; `setup.COMMAND_OPTIONS` lists them in a program's help. `desktop.parse_cli` no longer takes `--install` and `--uninstall` as shorthands of its flag: they installed the integration alone (docs/setup.md).
