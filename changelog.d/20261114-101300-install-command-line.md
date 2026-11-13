type: Changed

**`--install`, `--uninstall`, `--setup` and `--status` are the same in every program** (docs/setup.md). `setup.command_of` takes them out of the arguments and `setup.command_run` runs them without a window; `setup.command_alone` says which ones run without a window; `setup.COMMAND_OPTIONS` lists them in a program's help. `--status` says what is installed (where, its version, the menu entry, the start with the session, the PATH) and whether the program runs (`running: true`, from `Setup_Options.running`), with the exit code 0 installed, 2 to repair, 1 not installed.
  - `desktop.parse_cli` no longer takes `--install` and `--uninstall` as shorthands of its flag (they installed the integration alone): a program passes its arguments to `setup.command_of` first.
