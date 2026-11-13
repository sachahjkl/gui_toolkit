# toolbox: what the tools of a project share

`import toolbox "<toolkit>/src/toolbox"` (a relative path: a tool has no collection of its own). The package is named
`tk_toolbox`. It is for the tools that build, check and publish a project (`tools/tk` here, ocntools in opencode native,
Wren's tooling), not for the programs they make. Pure Odin with `core:os`, Windows and Linux.

```odin
ok := toolbox.run({"cargo", "build", "--release"}, {dir = "native"})        // its output on this process's
ok = toolbox.run({"odin", "test", "tests/fsx"}, {log = "build/fsx.log", limit = 10 * time.Minute, echo = true})
out, code := toolbox.capture({"git", "rev-parse", "HEAD"})                   // standard output and exit code
env := toolbox.env_with({"XDG_CONFIG_HOME"}, "XDG_CONFIG_HOME=/tmp/c")      // this process's, changed
sum := toolbox.sha256_hex(data)                                              // 64 lower-case hex digits
sum, ok = toolbox.sha256_file("build/x.zip")
why := toolbox.download_pinned(URL, "build/x.zip", X_SHA256)                 // "" when the file is there and as pinned
```

## Run

`run(command, o: Run_Options)` starts the command and waits for it. It returns true when the command started and exited
with 0. The fields of `Run_Options`, all optional:

- `dir`: the working directory ("": this process's).
- `env`: the whole environment of the command (nil: this process's). `env_with` makes one.
- `log`: a file. The standard output and error of the command are appended to it, and so are the lines that `run` says.
  "": the command writes to this process's output, and reads this process's input.
- `limit`: a time limit (0: none). After it, the process is killed and `run` returns false. Only the process is killed, not
  the processes that it started.
- `echo`: `run` writes `> command` first.

`capture(command, o)` returns the standard output of the command and its exit code. The code is -1 when the command did not
start. When the command fails, its standard error is written to this process's. `o.dir` and `o.env` apply.

`exit_code(state)` is the exit code of a finished process (-1 when it did not exit). Windows gives the code as an unsigned
number: `exit_code` reads it back as a 32-bit signed integer, so `exit(-1)` gives -1 and a crash gives a negative NTSTATUS.
`succeeded(state)` is true when the process exited with 0. Do not use `Process_State.success`: on Windows it is always true.

`env_with(without, ..extra)` is this process's environment without the variables named in `without` and without the
variables that `extra` sets, followed by `extra` ("NAME=value"). Names compare by ASCII case on Windows and exactly on other
systems. The per-drive entries of Windows (`=C:=C:\work`) stay.

## Process groups (Linux)

`start_group(command, env, out)` starts a command in a process group of its own (`setsid`). `env` is its whole environment
(nil: this process's); `out` receives its standard output and error (nil: none). `stop_group(p, wait)` sends SIGTERM to
the whole group, waits for the leader at most `wait` (default `GROUP_STOP_WAIT`, 3 s), then sends SIGKILL to what is left.
`group_ended(p)`: the leader was waited for and ended; what it left in its group is killed, and the group is no longer
stopped. Use them for a program that runs beside a tool, such as a compositor for tests: a wrapper (NixOS's `sway` is
`dbus-run-session`) starts the real program as its child, and a signal to the wrapper alone leaves that child running.

`guard_groups()` installs a handler of SIGTERM, SIGINT and SIGHUP (timeout's signal, Ctrl+C, a closed terminal): it kills
every group that `start_group` started and `stop_group` did not stop, then ends the tool. Call it once, before the first
group.

## A desktop nobody sees: the sway session (Linux)

`sway_start(&s, dir, options)` starts sway with no screen (headless) in `dir`, made anew, and waits until it answers
(`swaymsg -t get_outputs`), at most `options.wait` (`SWAY_WAIT`, 8 s). It returns "" when sway runs, else why not.
Nothing of the person's desktop is reached:

- its own runtime directory, `<dir>/run` (mode 700): its own Wayland socket and IPC socket;
- no `DISPLAY`, no session bus (`DBUS_SESSION_BUS_ADDRESS`), no `XDG_CURRENT_DESKTOP`;
- one headless output at `options.output` (`SWAY_OUTPUT_DEFAULT`, 1600x1000), no XWayland, no input devices;
- with `options.homes`, the programs' `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME` are `<dir>/config`, `data`
  and `state`; with `options.cache`, `XDG_CACHE_HOME` is `<dir>/cache`.

`options.config` adds lines to sway's config (`for_window [app_id="x"] floating enable`); `options.renderer` is `pixman`
(the CPU, default) or `vulkan`. `sway_config(options)` is that config. The session's fields: `dir`, `runtime`, `display`
(`WAYLAND_DISPLAY`), `ipc` (`SWAYSOCK`) and `env`, what a program in the session gets.

`sway_program(&s, command, env, log)` starts a program in the session, in a group of its own, with `s.env` and `env`
("NAME=value", over it). Its output goes to `log` (`""`: `<dir>/<program>.log`). `sway_wait(&s, p, limit)` waits at most
`limit` for it to end (a quit asked): `ended` and its `state`, what it left in its group killed. `sway_stop(&s)` stops the session's programs, then sway, each with all it started, and frees the
session. On another system, `sway_start` returns why it does not run.

```odin
s: toolbox.Sway
defer toolbox.sway_stop(&s)
toolbox.guard_groups()
if why := toolbox.sway_start(&s, "build/live", {config = `for_window [app_id="papier"] floating enable`, homes = true}); why != "" { return fail(why) }
p, why := toolbox.sway_program(&s, {"build/papier", "--hidden"}, {"TOOLKIT_DEVTOOLS=9300"})
```

`tk desktop_tests wayland` runs the toolkit's desktop tests in this session.

## Hashes

`sha256_hex(data)` and `sha256_file(path)` give the SHA-256 as 64 lower-case hex digits. `sha256_file` returns ok = false
when it cannot read the file. Both use the frame's allocator unless an allocator is given.

## Pinned downloads

`download_pinned(url, path, sha256, log, quiet)` makes sure that `path` holds the file whose SHA-256 is `sha256`:

1. If the file at `path` has that SHA-256, it is kept and nothing is downloaded.
2. Else curl downloads `url` into `path` (the folder is made first). Curl tries again 5 times, 10 s apart, on any error.
3. If curl fails and `url` is the file of a GitHub release (`https://github.com/<owner>/<repo>/releases/download/<tag>/<name>`),
   `download_through_api` asks GitHub's API for the asset and downloads it. `GH_TOKEN` or `GITHUB_TOKEN` is sent when set.
4. The SHA-256 of what came is checked. If it is not the pinned one, the file is removed.

It returns "" when the file is there and as pinned, else why not. `log` receives curl's output and the lines said ("": this
process's output). `quiet` keeps the lines "downloading ..." from being said.

On Windows, curl and tar are the system's own (`system_program("curl")`: `C:\Windows\System32\curl.exe`), never another
program of that name earlier on the PATH. On other systems, `system_program` returns the name: the PATH finds it.

`release_asset_id(release_json, name)` reads the id of an asset from the answer of GitHub's API for a release ("": none).

The tests (`odin test src/toolbox`) run without a network: the hashes, `env_with`, a run with a log and a time limit, a
capture in another folder and environment, a pinned file kept, a `file:` URL downloaded, and a wrong SHA-256 refused.

## WebP

`webp_encoder(dir) -> (encoder, why)` is cwebp, libwebp's encoder: the system's elsewhere (nix `libwebp`, Debian `webp`), and on
Windows libwebp's own build, fetched into `dir` once and pinned by its SHA-256. `webp_encode(encoder, src, dst, width = 0,
quality = WEBP_QUALITY)` writes `src` (PNG, JPEG, TIFF or WebP) as a WebP, `width` pixels wide (0: its own), with `-preset text`:
a screenshot's small text stays as sharp as in its PNG, the file some twenty times smaller. `image_width(data)` reads a PNG's or
a WebP's width from its header (pure).

## A program's logo

Each program draws its own logo; `write_logo(logo)` writes what every program makes of it. The program gives
`render(size, user)`, which draws the logo at that size (a canvas the toolbox frees), and says which files it wants:

- `dir` and `master`: `<dir>/logo.png` at `master` pixels (0: none).
- `sizes`: `<dir>/logo_<size>.png` each (the desktop entry, the site, the program's window).
- `ico`: the `.ico` of the Windows executable, with the sizes `ico_sizes` (nil: `ICO_SIZES`, 16 to 256 px). Each size
  is drawn at its size. The sizes from `ico_png_from` are PNG entries, the ones below are classic DIBs (0: all PNG).
- `project_image`: `PROJECT_IMAGE` (`.project/image.png`, 512 px), the picture of the repository and of opencode's
  sessions of it.
- `files`: more PNG files, each a `Logo_File` (a path and a size): the site's logo.

It says each file it writes and returns "" when all are written, else the file that is not. Folders are made.

```odin
why := toolbox.write_logo({render = logo_render, dir = "assets", master = 1024, sizes = {16, 32, 64, 128, 256},
                           ico = "assets/papier.ico", project_image = true})
```

`logo_command(logo) -> Command` is the `logo` command of a project's tool: `write_logo` of `logo` (copied; its slices
must live as long as the tool).

## A Windows executable's version and icon

`version_header(version)` is a C header of a version of three numbers: `VER_MAJOR`, `VER_MINOR`, `VER_PATCH` (numbers)
and `VER_STRING` (the text). It is "" when the version is not three numbers. `write_version_header(path, version)`
writes it, only when it changes (the resource is not compiled again). The `.rc` file includes it for its VERSIONINFO:

```rc
#include "../build/version.h"
1 ICON "..\\assets\\papier.ico"
1 VERSIONINFO
FILEVERSION VER_MAJOR, VER_MINOR, VER_PATCH, 0
...
VALUE "ProductVersion", VER_STRING
```

`exe_has_icon(path)` (Windows) is true when the executable carries an icon group 1: what Explorer, the Start menu's
shortcut and the window show. A build checks with it that the resource is linked.

## A program's update files

`update_command(product, args)` is the `update` command of a project's tool, for its product (`docs/update.md`):

- `update keygen <file>`: a new key pair. The private key goes in `<file>` (refused inside a git work tree, or over a file
  that exists); the public key is printed, for the product's `public_key`.
- `update pubkey`: the public key of `$UPDATE_SIGNING_KEY` (`UPDATE_KEY_ENV`).
- `update manifest <program> <version> <channel> <out.json>`: the manifest of the program (named
  `expected_file_name(product, version, platform)`; `-` for no channel) and its `.sig`, signed by `$UPDATE_SIGNING_KEY`.
- `update verify <manifest.json> <channel>`: the manifest and its `.sig`, checked with the product's key.

`update_manifest(product, program, version, channel, out)` is the manifest step alone, for a tool's release step.

## A program's licences

`licence_commands(tool)` gives the `licence` and `paddle` commands of a project's tool, for its `Licence_Tool` (its
`licence.Product`, the folder of its private key, its development pair, the hint of its files, its Paddle catalogue):

- `licence keygen`, `licence pubkey`, `licence issue`, `licence verify`: the signing key pair (outside any git work tree, in
  `licence_key_dir(tool)`), a licence signed by hand, a check;
- `licence secrets <secrets.yaml> <out.env>`: the Worker's secrets decrypted by sops (`sops_dotenv`), to a file git ignores;
- `paddle [-apply]`: the product and its prices in Paddle's catalogue, over `gt:http`.

[licence.md](licence.md) says the whole flow and each command.

## Crash reports

A program's crash reports ([crash.md](crash.md)) give each frame as a module and an offset. These name the offsets of the
program's own module offline, with what its build left:

- `CRASH_LINKER_FLAGS`: what the program's `-extra-linker-flags:` must hold. Windows: `/MAP` (the linker's map of every
  function). Linux: `-Wl,--build-id` (the build id the report names).
- `crash_publish_symbols(exe, allocator) -> (named, why)`: after each link. Windows: `<dir>/<stem>.map` becomes
  `<dir>/<stem>-<build>.map`, and the older maps of that stem go; keep it with the release. Linux: checks that the
  executable has a build id; `named` is the executable. `why` says what is wrong ("": done).
- `crash_build_id(path, allocator) -> (id, ok)`: the build a file is, as a report names it: a PE file's link time stamp and
  image size (`%08X%X`), an ELF file's GNU build id. Any system reads either.
- `crash_symbolize(report_path, symbols, allocator) -> (text, why)`: the report with the program's frames named. `symbols` is a
  map, a folder that holds `<stem>-<build>.map`, or (a Linux report) the executable that crashed, read through `addr2line`.
  The map is read in pure Odin: a Windows report is named on any system. An executable of another build is refused; a map of
  another link gives a `symbols-warning` line. The text is a report again, with a `symbols` line that says from what.

`tk crash_symbolize <report> <symbols>` prints it.

```odin
// a program's build tool, after its link
append(&flags, fmt.tprintf("-extra-linker-flags:%s", toolbox.CRASH_LINKER_FLAGS))
...
if named, why := toolbox.crash_publish_symbols(exe); why != "" { return why }
```

## A project's tool

A project's tool is one program with a command each: `tools/tk` here, and every program's (`classeurtool`, `papiertool`...).
It is a list of `Command`s given to `tool_main`:

```odin
main :: proc() {
	p := project()
	r := release.commands({project = p, dist = "build/dist", files = FILES[:], check = proc() -> int { return run_check(nil) }})
	toolbox.tool_main("classeurtool", {
		{name = "build", usage = "[release]: the program", run = run_build},
		{name = "check", usage = ": the checks of the CI", run = run_check},
		changelog.command(p), site.command({meta = site_meta()}), toolbox.logo_command(LOGO), r[0], r[1], r[2],
	}, toolbox.ROOT_MARK_DEFAULT)
}
```

A `Command` has a `name`, a `usage` (its arguments and what it does, one line) and `run(args) -> exit code`, the arguments
after its name. A command made for a project (`changelog.command`, `site.command`, `release.commands`, `logo_command`,
`notices_command`) has `run_with(args, user)` and its `user` instead. With `checked`, the line is checked first: a flag is
`-name` (a switch) or `-name:value`, and must be one of `flags` (`"name"`, `"name:"`); `positionals` is the number of
plain arguments (-1: none or one). A command not checked reads its own arguments (`--port 9222`, `--dry-run`).

`tool_main(program, commands, root_mark = "")`:

1. reads the line, each `-name:` and its value joined again (`args_joined`: PowerShell 7 splits `-name:value` typed after
   `--` into two arguments);
2. with a `root_mark` (`ROOT_MARK_DEFAULT`: `odin.version`), finds the project's root, the first folder from the working
   directory up that holds it (`project_root(start, mark)`), and works there; none: exit code 2;
3. runs the command (`dispatch(program, commands, args)`) and ends with its exit code.

| Line | Exit code |
|---|---|
| no command, `help`, `-h`, `--help` | 0: the commands and their usages (`tool_usage`); `help <command>`: that one |
| a command it does not know | 2, the commands said |
| a checked command's line that is not one it takes | 2, its usage said |
| a command | its own: `EXIT_DONE` (0) when the work is done, `EXIT_FAILED` (1) when it failed, `EXIT_USAGE` (2) for a line it does not take |

`done(why) -> int` is the exit code of a work that says why it failed (`""`: 0), the failure said as `<tool> <command>: why`.
`command_find(commands, name)` and `args_check(command, args)` are the dispatcher's steps.

The flags of a line: `has_flag(args, name)`, `flag_value(args, name, default)` (the last one given wins),
`int_flag(args, name, default)` and `f64_flag(args, name, default)` (why: not a number), `plain_args(args)` (the arguments
that are not flags; a lone `-` is plain).

## A project

`Project` is what a program's project is to its tool, and to the standard commands:

| Field | What it is |
|---|---|
| `name` | the program (`classeur`): its archive's, its commit's, the launcher's answer |
| `repository` | `https://github.com/<owner>/<repo>` |
| `changelog` | `CHANGELOG.md` (`""`: that), its fragments in `changelog.d/` beside it |
| `version_file`, `version_line` | the source of the version (the program's main file) and its line's start (`APP_VERSION :: `) |
| `program` | the release build (`build/classeur`) |
| `src` | the program's package (`""`: `src`) |
| `toolkit` | the toolkit's checkout (`""`: `$GT`, else `TOOLKIT_DEFAULT`, `ext/gui_toolkit`) |
| `collections` | more collections than `gt`: a name and its folder |
| `linux_defines` | what every odin command of the program gets on Linux |
| `launcher` | Windows: its console launcher, a `Launcher` (`out` `""`: none) |
| `licence` | its licence, for its notices (`""`: MIT) |
| `features` | what it takes of the toolkit beyond the core, a `Features` (below) |

- `version_of(source, line)` is the version in quotes after `line` (`""`: no such line); `version_set(source, line, version)`
  is the source with it replaced (ok = false: no such line). `project_version(p)` reads it from `version_file`.
- `toolkit_dir(p)` is the toolkit's checkout.
- `odin_command(p, verb, pkg = "", extra = nil)` is `odin <verb> <pkg> -collection:gt=<toolkit>/src <collections> -vet`,
  the defines of the features, on Linux `linux_defines` and, but for `check`, `LINUX_LINK_FLAG` (the native text backend
  and wgpu-native carry the same Rust standard library), then `extra`. `pkg` `""`: the program's.
- `build_native(p)` builds what the features need before an odin command: the toolkit's native libraries this system
  links (`tk build_text` on Linux or with `Native_Text`, `tk build_a11y` on Windows with `Accessibility`,
  `tk build_mermaid` with `Mermaid`), by the toolkit's own tool in the project's checkout of it (nothing when a library is
  up to date), and the Lucide subset with `Lucide_Subset` (`lucide_subset`, [lucide.md](lucide.md)).

### Features

A program declares once what it takes of the toolkit beyond its core: `Project.features`, a `Features`
(`bit_set[Feature]`). The defines (`feature_defines(features, target, lucide)`), the native builds (`build_native`) and
the crates of the notices (`native_crates(features)`) follow from it. What each one gives (sizes: [builds.md](builds.md)):

| `Feature` | Define | Native build | Crates of the notices |
|---|---|---|---|
| `Native_Text` | Windows: `FONT_BACKEND=native` (the default elsewhere) | `tk build_text` (Linux: always) | `native/text` (always) |
| `Accessibility` | Windows: `A11Y_ACCESSKIT=true` | Windows: `tk build_a11y` | `native/a11y` |
| `Mermaid` | | `tk build_mermaid` | `native/mermaid` |
| `Devtools` | `TOOLKIT_DEVTOOLS=true`: the CDP endpoint in a release build ([devtools.md](devtools.md)) | | |
| `Lucide_Subset` | `LUCIDE_SUBSET=<path>`, once the file is made, but for `check` | `lucide_subset(p)` | |
| `No_Fallback_Fonts` | `FONT_EMBED_FALLBACK=false` | | |

```odin
p := toolbox.Project{name = "classeur", src = "src", program = "build/classeur", features = {.Mermaid, .Lucide_Subset}}

if !toolbox.build_native(p) { return "the native parts failed" }
if !toolbox.run(toolbox.odin_command(p, "build", extra = {"-o:speed", "-out:build/classeur"})) { return "the build failed" }
```

## Font subsets

`font_subset(data, codes, allocator)` is a TrueType font (glyf outlines) with only the glyphs of the characters `codes`
(those the font has), `.notdef`, and the glyphs a kept composite glyph is made of. The outlines and advances are the
original's; the glyphs are numbered anew in their old order, the character map holds only `codes` (format 4, or 12 past
the BMP), `post` has no glyph names, and only `OS/2`, `cmap`, `glyf`, `head`, `hhea`, `hmtx`, `loca`, `maxp`, `name` and
`post` are kept (no ligatures, kerning or hinting). why: the font cannot be read (CFF outlines, a collection).
`sfnt_tables(data)`, `sfnt_table(tables, tag)`, `sfnt_cmap(cmap)` and `sfnt_glyph(glyf, loca, long, gid)` read a font's
tables, its character map and a glyph's bytes.

`lucide_subset(p)` writes the program's icons of the Lucide font at `LUCIDE_SUBSET_FILE` (`build/lucide_subset.ttf`, in
the working directory) and returns its absolute path; `lucide_names_used(dirs)` and `lucide_codes(source, names)` are its
steps ([lucide.md](lucide.md)).
- `build_launcher(p)` builds the console launcher on Windows from the toolkit's `tools/console_launcher`, with the
  `Launcher`'s mark (`LAUNCHER_MARK`), rule (`default_rule`: `wait` or `detach`) and `others`. The program embeds it: it
  comes before a check or a build. `check_launcher(p)` checks it beside a release build: `<out> version` says
  `<name> <version>`, and with `refuses_exit`, an unknown command ends with that code.
- `check_windows(p)` and `check_darwin(p)` are `odin check` of the program for Windows (`windows_amd64`) and macOS
  (`darwin_arm64`), from any system (`odin_check`).

## Builds made once

A build that is slow makes its output once: a stamp beside it holds the hash of what it is made from.
`stamp_holds(output, stamp, expected)` is true when the output is there and the stamp says `expected` (its line end aside).
`write_stamp(path, text)` writes one, with this system's line end (`STAMP_NEWLINE`).

`build_c_lib(name, sources, out, cflags)` builds `<out>/lib<name>.a` from `sources`: each `.c` file compiled by `cc` with
`cflags`, then `ar`; another file (a header) is hashed only. It does nothing when `<out>/STAMP` says these sources and flags
(`c_lib_stamp(sources, cflags)`: the SHA-256 of each source and of the flags). For a C library a program builds itself
(papier's SQLite), on Linux and macOS.

## A check of the scopes

The scopes of the ui package (`ui.row`, `ui.parent`, `ui.menu`...) end with the statement that opens them:
`if !ui.row(...) { return }` closes the row at once, and what follows goes to the parent's parent. The compiler accepts it.
`check_scopes(src_dir, ui_dir = UI_DIR_DEFAULT)` says each such line of the `.odin` files under `src_dir`, and is true when
there is none. The scopes are read from the ui package's sources (`ui_scopes(sources)`: the procedures with a deferred
end), so a new scope is checked at once. `scope_misuses(text, scopes)` is the check of one file's text.

## Third-party notices

`third_party_notices(p, out, check_only = false)` writes the licences of what the project's executable holds besides its
own code at `out` (`NOTICES_FILE`, `THIRD-PARTY-NOTICES`), or with `check_only` says whether `out` is up to date. It returns
"" when all is well, else why not:

- gui_toolkit (MIT) and its attributions (`NOTICE.md`), Roboto, Inconsolata and Lucide's icons, from the toolkit's checkout;
- Odin's core library (`<odin root>/LICENSE`, BSD-3-Clause);
- wgpu-native (MIT or Apache-2.0), whose texts the toolbox keeps (`src/toolbox/licences`: its release archive has none);
- the Rust crates of the project's features (`native_crates(p.features)`): `cargo metadata` of each (`--locked --offline`, for `NOTICES_TARGET`, this
  system's), the crates the library links (`notices_crates(metadata)`: the normal dependencies from its package, crate after
  crate; never a build script's, a test's or a procedural macro), each with its licence files (`LICENSE*`, `LICENCE*`,
  `COPYING*`, `NOTICE*`, and its manifest's `license-file`). A crate with no licence file is an error.

`notices_text(p, works, crates, native)` is the file: the list, then each work's texts, then each crate's text once with
the crates that ship it. `notices_command(p)` is the `notices [--check]` command of a project's tool.
