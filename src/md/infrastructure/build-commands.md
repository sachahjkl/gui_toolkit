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
  this system, for the other systems of the program (`Project.systems`; from Linux: Windows and macOS; from macOS:
  Windows), of the tool (`-vet`), the tests, a release build, and on Windows its launcher (`check_launcher`: off Windows
  it has nothing to check).

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

## The options of a build

opencode native built itself by hand: defines on every system, its own linker flags, a third build mode, a build that
cannot overwrite the running program, a pinned Odin. Each is an option of the one path above, off by default, so
papier, classeur, inspecteur and cliche build as they did.

- **`Project.defines`**: what every odin command of the program gets, on every system (`IMAGE_WEBP_NATIVE_LINK=false`:
  a program that links a part inside its own Rust library). They go to `check` too, and to the check of another
  system, because a define changes what compiles. `linux_defines` stays for the defines of one system.
- **`Project.link`**: what the linker gets. Odin keeps only the last `-extra-linker-flags`, so `linker_flag(p, target,
  verb, release)` makes the one flag of a command from every source: Linux's `--allow-multiple-definition` (always),
  Linux's `-s` in a release with `strip` (the symbol table is a quarter of the file, and a panic says its place from
  `#caller_location`), Windows' static C runtime with `static_vcruntime` (no `vcruntime140.dll` to ship). A flag that
  each source appended would lose all but one in silence. `check` links nothing and gets none.
- **`Build_Mode`**: `Debug` (`-debug -o:none`, the console on Windows), `Dev` (`-o:minimal`: Odin keeps the modules
  apart and between builds, a second at most), `Release` (`-o:speed`). `Build_Options.iterate` is the build with no
  word; `Debug` is its default. `build debug` and `build release` ask for the others. Every mode but `Debug` has no
  console of its own on Windows: the console launcher gives its text.
- **The mode file.** Every build writes its mode to `<program>.mode` (`build_mode_of`). Odin writes nothing in the
  executable that says how it was built, and a program's tool must know: a package refuses what is not a release, a
  measure of speed reads only a release. One small file in `build/` is the cost for the programs that do not read it.
- **`Build_Options.fresh`**: the build goes to `<dir>/<name>-new`, then takes the program's place (`swap_in`). Windows
  refuses to write a running executable but lets it be renamed: the program goes to `<name>-old`, the fresh file to
  the program's path, and `<name>-old` is removed when nothing runs it (else by the next build). On Linux the same
  renames are harmless. A failed build leaves the program as it was. A Windows `-debug` build's `.pdb` keeps the name
  `<name>-new.pdb`: the executable names it, and a renamed `.pdb` would not be found.
- **`Build_Options.pinned_odin`**: before a build, a test or a check, `odin version` must hold the text of
  `odin.version` (the root mark). A version that is a prefix of the found one holds (`dev-2026-11` in `dev-2026-11a`),
  as opencode native's tool did. `GT_ANY_ODIN=1` builds anyway: a try of a new Odin needs no edit.
- Refused: a `build_line` the program writes itself (the second build routine again); one list of extra odin flags
  (the linker flags would overwrite each other, and the toolkit could not test what each option gives); the swap on
  every program by default (it changes what is in `build/` for programs that did not ask); a `strip` step after the
  link (a second program to run and to find, where the linker's `-s` does the same).

## The systems and the native library of a program

opencode native's check could not use these commands: it checked macOS, for which it has no code, and `build_native`
built the toolkit's Rust library (`native/gt`) that it does not link. Its own Rust library (`ocn_native`) carries the
toolkit's crates (text on Linux, Mermaid, WebP), so the toolkit's library was two uncached minutes in its CI for
nothing, and failed in the Nix sandbox: `native/gt`'s `Cargo.lock` wants crates that the program's vendored set lacks.

- **`Project.systems`**: the systems the program is built for, a `Systems` (`bit_set` of `runtime.Odin_OS_Type`).
  Empty is `SYSTEMS_DEFAULT` (Windows, Linux, macOS): the programs that do not set it check what they checked.
  `check_steps` reads it through `project_systems(p)`: the check of another system is a step only for a system in the
  set. The check of this system does not read it: a check on a system the program does not name fails at its first
  odin step, which says so better than a skip.
- **`Project.native_carried`**: the program's own Rust library (one of `crates`) carries the toolkit's native crates.
  `build_native` then builds no part of the toolkit's library; it still makes what the program needs from the toolkit
  apart from Rust: on Windows the resource and the console launcher (`build_windows`), and the Lucide subset.
  `native_parts(p, target)` is the list of parts, a pure procedure: the test reads it for each system and each option,
  with no build.
- **One switch, not a set of carried parts.** The program's library carries every toolkit crate it links, or none: no
  program links a part from each. A set would be a second list to keep in step with the program's `Cargo.toml`.
- **The defines stay the program's.** A program that carries a crate builds with its `*_NATIVE_LINK=false` define
  (`FONT_NATIVE_LINK`, `MERMAID_NATIVE_LINK`, `IMAGE_WEBP_NATIVE_LINK`) in `Project.defines`. `native_carried` does not
  derive them from `features`: the program's `Cargo.toml` decides what its library carries (opencode native carries
  WebP through its own defines, not through `Feature.Webp`), and the toolkit cannot read that choice.
- **The notices read the program's manifests only.** With `native_carried`, the notices skip the toolkit's
  `native_crates(features)`: the program's library walks the same crates through its own `Cargo.toml` (`crates`), and
  the toolkit's lock files want crates the program's vendoring does not have (`cargo metadata --locked` failed in
  opencode native's Nix sandbox, as its build did).
- Refused: a `build_native` per program (the second routine again); macOS removed from the default set (papier,
  classeur, inspecteur and cliche check it today); `systems` read from the sources' file suffixes (a program's `_other`
  files say nothing of which systems it ships for).

## One file writer

`write_if_changed(path, text)` is the toolkit's only writer of a generated file: it writes nothing when the file holds
the text (a build that follows sees no new file) and makes its folder. `write_stamp` is a stamp's format over it, the
line end of the system (`STAMP_NEWLINE`), read back by `stamp_holds`.
