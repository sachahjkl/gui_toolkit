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

`run(command, how)` starts the command and waits for it. It returns true when the command started and exited with 0. The
fields of `Run`, all optional:

- `dir`: the working directory ("": this process's).
- `env`: the whole environment of the command (nil: this process's). `env_with` makes one.
- `log`: a file. The standard output and error of the command are appended to it, and so are the lines that `run` says.
  "": the command writes to this process's output, and reads this process's input.
- `limit`: a time limit (0: none). After it, the process is killed and `run` returns false. Only the process is killed, not
  the processes that it started.
- `echo`: `run` writes `> command` first.

`capture(command, how)` returns the standard output of the command and its exit code. The code is -1 when the command did not
start. When the command fails, its standard error is written to this process's. `how.dir` and `how.env` apply.

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
Use them for a program that runs beside a tool, such as a compositor for tests: a wrapper (NixOS's `sway` is
`dbus-run-session`) starts the real program as its child, and a signal to the wrapper alone leaves that child running.

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

## A program's logo

Each program draws its own logo; `write_logo(logo)` writes what every program makes of it. The program gives
`render(size, user)`, which draws the logo at that size (a canvas the toolbox frees), and says which files it wants:

- `dir` and `master`: `<dir>/logo.png` at `master` pixels (0: none).
- `sizes`: `<dir>/logo_<size>.png` each (the desktop entry, the site, the program's window).
- `ico`: the `.ico` of the Windows executable, with the sizes `ico_sizes` (nil: `ICO_SIZES`, 16 to 256 px). Each size
  is drawn at its size. The sizes from `ico_png_from` are PNG entries, the ones below are classic DIBs (0: all PNG).
- `project_image`: `PROJECT_IMAGE` (`.project/image.png`, 512 px), the picture of the repository and of opencode's
  sessions of it.

It says each file it writes and returns "" when all are written, else the file that is not. Folders are made.

```odin
why := toolbox.write_logo({render = logo_render, dir = "assets", master = 1024, sizes = {16, 32, 64, 128, 256},
                           ico = "assets/papier.ico", project_image = true})
```

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
