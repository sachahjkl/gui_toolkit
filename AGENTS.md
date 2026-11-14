# gui_toolkit

A native, immediate-mode GUI toolkit in Odin: Win32 and Direct3D 11 on Windows, X11 or Wayland and WebGPU over Vulkan on
Linux. The library's packages are in `src/` (a program's collection points there: `-collection:gt=<toolkit>/src`); the
examples, tests, tools and docs are beside it. Wren and opencode native use it as the `ext/gui_toolkit` submodule.

Read first: [README.md](README.md), [CONTRIBUTING.md](CONTRIBUTING.md) (a change, publishing a version),
[docs/getting-started.md](docs/getting-started.md) (where state lives, the pitfalls), [docs/testing.md](docs/testing.md).

## Build and test

Every step is a command of `tools/tk` (the head of `tools/tk/main.odin` lists them), on Windows and Linux:

- `odin run tools/tk -- build <example> [-debug]` builds an example. `build.bat` and `./build.sh` are its shortcuts.
- `odin run tools/tk -- ci` runs what the CI checks on this system: `odin check` of every package and every tool, the examples, the tests.
- `odin run tools/run_tests -- <name>` runs one test package. `odin run tools/tk -- desktop_tests` runs the Linux backends on a
  virtual desktop.
- Linux: `nix develop` first (`flake.nix`: the pinned Odin with wgpu-native, Rust, the servers of the virtual desktops).

## Intent

This project follows https://srcmd.org, with the Markdown in `src/md`. Read `src/md/README.md` first. Change the intent
there before the code it describes.

## Roadmap

[ROADMAP.md](ROADMAP.md), beside `CHANGELOG.md`, holds the planned work: the toolkit's own and every work that touches
several programs. No project keeps its plans in a global to-do file.

- Plain Markdown, no front matter: `# Roadmap`, then `## Now`, `## Next` and `## Later`, in this order, each a list.
- An entry starts with a bold summary, then one or two sentences on what it gives the user; its continuation lines are
  indented. No dates. If a design exists, the entry links its intent file in `src/md`.
- When a work is done, its entry goes in the same commit as its changelog fragment.
- `changelog.check` checks the format of a project's `ROADMAP.md`. Every program's changelog check and the toolkit's
  release run it, so a program without a roadmap fails its check.

## Key prompts

Apply these to every task, before you write code:

- "Exercise abstract thinking when considering this task."
- "Reduce this problem to its irreducible constraints and rebuild it from zero."
- "What would a principal architect immediately rewrite before even starting this?"
- "Design the single test that breaks this design on day one."
- "What higher-level abstraction would make this entire problem disappear?"
- "Find all of the implicit state machines in my app."

## Rules

- What more than one program needs goes here, generic and configurable; a program keeps its own words and layout.
- Packages import each other by relative paths. Platform code goes in files with a system suffix (`*_windows.odin`, `*_linux.odin`).
- Every new function has its documentation (`docs/`), its test and a CHANGELOG fragment in `changelog.d/`. Never edit
  `CHANGELOG.md` or `src/ui/version.odin`: `tk release` writes them.
- A new global needs a class in `tools/globals_allowed.txt`. Names and protocols fold by ASCII (`ascii.lower`); a Unicode fold
  is listed in `tools/unicode_case_allowed.txt`. The tests `tests/globals` and `tests/unicode_case` check both.
- Automation is a command of `tools/tk`, never a shell, batch, PowerShell, Python or Node script.
- Comments and commit messages are in English. Comments say why.
- Commits: author and committer `sachahjkl <sacha@sacha.house>`, no attribution trailer, no session link.
