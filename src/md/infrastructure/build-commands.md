# A program's build, test and check commands

Every program's tool had its own `run_build`, `run_test` and `run_check`: the same steps, written five times, and the
copies drifted (one did not check macOS, one did not check its console launcher nor build its release without a console,
one built its debug build otherwise, each ran the checks in another order). `toolbox.build_commands(o)` gives the three
commands from the program's `Project` and a `Build_Options`; the program keeps only what is its own.

## The steps

`build [release]`, `test [names]` and `check` all start with what an odin command of the program needs: `build_native`
(on Windows its resource and console launcher; the toolkit's native library; the Lucide subset), then the program's
`prepare` (papier's SQLite), then the `build` folder (odin makes no folder for its output).

- `build`: `-debug -o:none` while iterating (the fastest build), `-o:speed` for a release; on Windows a release has no
  console of its own (`-subsystem:windows`): its text goes through the console launcher, `<name>.com`.
- `test`: each test package to `build/test_<path>`; a package with `one_thread` runs its tests one after the other, each
  said as it starts (the tests that take the toolkit's one test session; the CI's log names the test that hangs). Names
  given (`test pkg.test_a,pkg.test_b`): those tests of the program's package alone, in that order, on one thread.
- `check`, in this order, cheapest first, so a fault in a fragment is said in a second and not after a release build:
  the changelog and the roadmap, the scopes, the program's own checks, every catalogue, the notices, `odin check` for
  this system, for the other systems (from Linux: Windows and macOS; from macOS: Windows), of the tool (`-vet`), the
  tests, a release build, and on Windows its launcher (`check_launcher`: off Windows it has nothing to check).

The check's steps are a set (`check_steps(o, system)`), not code in a sequence: the test reads them for each system
without building anything, so a drift such as "this program does not check macOS" fails a test of the toolkit, not a
release.

## Decisions

- **The changelog command is a value of the options.** gt:changelog imports this package (`toolbox.Project`,
  `toolbox.Command`), so this package cannot call `changelog.check`. The program already makes `changelog.command(p)`
  for its list; the check runs that command's `check`. No hook to write, and the words are the changelog's own.
- **Every catalogue is checked.** The step reads `<folder>/*.txt`: a language added to the folder is checked from then
  on, with no option to keep in step.
- **The tool is a tool.** Its package (`tools/<name>tool` unless named) is checked and tested with the collections and
  `-vet` alone: it links no native library and takes none of the program's defines.
- **The notices are an option**, not the presence of the file: a program that ships them says so once, and a deleted
  file then fails its check instead of passing in silence.
- **The other systems from Windows: none.** A check of another system runs on an Odin root of links (`odin_check`),
  which Windows does not make without privileges. The Linux job checks Windows and macOS; a program's own part of the
  other system on Windows (classeur's `src/fs` for Linux) is one of its `checks`.
- Refused: a step list the program builds itself (the drift again), a `Build_Options` per command (the three share
  every field), a hook before each step (no program needs more than `prepare` and `checks`).

## One file writer

`write_if_changed(path, text)` is the toolkit's only writer of a generated file: it writes nothing when the file holds
the text (a build that follows sees no new file) and makes its folder. `write_stamp` is a stamp's format over it, the
line end of the system (`STAMP_NEWLINE`), read back by `stamp_holds`.
