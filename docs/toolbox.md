# toolbox: what the tools of a project share

`import toolbox "<toolkit>/src/toolbox"` (a relative path: a tool has no collection of its own). The package is named
`tk_toolbox`. It is for the tools that build, check and publish a project (`tools/tk` here, occtools in opencode native,
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
