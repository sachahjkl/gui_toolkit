# base: what every package stands on

`import base "gt:base"` (the package is named `gt_base`, so a program keeps its own `base`). Pure Odin, any target. It
holds the interface thread's check (`base.blocking`, [tasks.md](tasks.md)), the start clock (below), the opt-in performance checks
(`base.perf_enabled`, `base.perf_skip`, [testing.md](testing.md)) and the readers of binary formats below.

## The start of a program

A start is measured from the process's own start, as the system knows it (Windows' creation time; Linux's start time in
`/proc/self/stat`, in steps of 10 ms), not from `main`: the system has loaded the program before `main` runs, and a probe
that starts its clock there measures another start. The toolkit marks its own steps: the device made early and its first
pipelines, the window, the font, the renderer, the first frame shown. A program marks its own, from any thread.

```odin
base.start_mark("session read")                   // a step done (a constant string): its time since the process started
ms := base.start_ms()                             // milliseconds since the process started
buf: [base.START_STEPS_MAX]base.Start_Step
for s in base.start_steps(buf[:]) { fmt.printfln("%s %.1f", s.what, s.ms) }   // every step, in the order marked
base.start_print()                                // the same on standard error
```

A program's probe of its start opens its window as a person's start does (`host.host_open` asks for the device early
itself), waits for its first frame shown (`render: first frame shown`), then reads the steps. With
`TOOLKIT_RENDER_TRACE=1` the renderer prints them at the process's first present. A step is kept the first time it is
marked only (`start_mark` returns true then): the start is the first window's, and a program of many windows does not
fill the list. At most `START_STEPS_MAX` (48) steps are kept; later ones are dropped.

## Big-endian integers

| Procedure | Result |
|---|---|
| `read_be16(d, at) -> (v: int, ok: bool)` | the unsigned 16 bits at `at` of `d` |
| `read_be32(d, at) -> (v: int, ok: bool)` | the unsigned 32 bits at `at` of `d` |

A read that starts before `d` or ends past it gives `0, false`, never a panic: a font or a file is untrusted input. Both
are `#optional_ok`: a reader that checked the lengths takes the value alone, one that did not ends with `or_return`.

```odin
count := base.read_be16(table, 2)                 // the lengths were checked before
offset := base.read_be32(table, at) or_return     // the procedure gives up on a short table
```

## Restricted processes

A process with more rights than its user's files starts, opens, installs, updates and loads nothing that a user can
write ([src/md/features/elevated-process.md](../src/md/features/elevated-process.md) says why and where).

```odin
base.restrict_if_elevated()                                     // host.program_start does it; a program's own first call may
if base.restricted() { log.info(base.restricted_reason()) }    // elevated: an administrator, or root
if !base.may_start(path) { ... }                                // process.start asks this itself
```

| | |
|---|---|
| `elevated() -> bool` | the token is an administrator's (Windows: TokenElevation, or an integrity high or more; Linux: root); read once; a failure counts as elevated |
| `restrict(r)` | restricts the process for good (`.Elevated`; tests/restricted does it to itself); nothing lifts it |
| `restrict_if_elevated()` | elevated (Windows: an administrator's token or a high integrity, fail closed; Linux: root), the process is restricted from then on. `host.program_start`, `setup.command_run` and `setup.task_manager_start` call it first; a command-line tool (tk, run_tests) does not, and runs what the person typed |
| `restriction() -> Restriction`, `restricted() -> bool` | `.None` or `.Elevated` |
| `restricted_words(w) -> string` | why, to the person, in this system's words (Windows: "as administrator"; Linux: "as root") and the language in use: `.Installs`, `.Opens`, `.Plugins`, `.Updates`, `.Update_Placed` |
| `restricted_reason() -> string` | the same, in English, for a log or a test |
| `trusted_program(path) -> bool` | a full path in an administrator's folder: a file directly in System32 or SysWOW64 (their subfolders are not: some are the users'), System32's `WindowsPowerShell\v1.0`, anything under Program Files and Program Files (x86), never a path with a stream (`:`); Linux: the Nix store, `/run/current-system/sw`, `/usr`, `/bin`, `/sbin`, `/lib`. Never a bare name |
| `may_start(path) -> bool` | not restricted, or `trusted_program` |
| `dll_search_restrict()` | Windows: a library loaded by name comes from the program's folder or System32 only (SetDefaultDllDirectories); `host.program_start` calls it first |
| `GT_ELEVATED_UNRESTRICTED` | `#config`, on in test builds and in tk's builds with the devtools endpoint: `restrict_if_elevated` does nothing (CI runners are administrators or root); the toolbox's `build release` refuses it |
