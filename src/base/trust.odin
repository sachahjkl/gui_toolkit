package gt_base

// A process with more rights than its user's files (src/md/features/elevated-process.md): elevated (Windows: an
// administrator's full token, or a high integrity; Linux: root). Such a process never starts, installs, updates or
// loads a program, a library or a script that the user can write: medium-integrity code that put a file there would
// run with the administrator's rights. Each place of the toolkit that starts or loads something asks `restricted`
// (process.start, platform.open_url, open_path, reveal_in_folder, desktop's install, terminal, "Open with", setup, the
// updates, the plugins, the devtools server) and refuses, saying why (`restricted_words`, `restricted_reason`:
// trust_words_<os>.odin). A process that runs unelevated has the user's own token: the rule adds nothing there, and it
// is not restricted.

import "core:sync"

Restriction :: enum u8 {
	None,
	Elevated,   // the token is an administrator's (Linux: root), or its integrity is high or more (or it could not be read)
}

// A build whose elevation alone does not restrict it: the tests (ODIN_TEST), which CI runners run as an administrator,
// or a program built for such a runner with -define:GT_ELEVATED_UNRESTRICTED=true (tk's builds with the devtools
// endpoint). Never a build that ships: the toolbox's `build release` refuses it. An
// explicit restrict counts in every build (tests/restricted).
GT_ELEVATED_UNRESTRICTED :: #config(GT_ELEVATED_UNRESTRICTED, ODIN_TEST)

@(private = "file") restriction_said: u8   // a Restriction a program said (restrict); atomic
@(private = "file") elevation_once: sync.Once
@(private = "file") elevation_seen: bool    // written once under elevation_once, then only read

// Whether this process is elevated, read once. Fail closed: a token that cannot be read counts as elevated, so a doubt
// never hands this process's rights to the user's code.
elevated :: proc() -> bool {
	sync.once_do(&elevation_once, proc() { elevation_seen = elevation_query() })
	return elevation_seen
}

// Restricts this process for good (restrict_if_elevated; a test, tests/restricted). Nothing lifts a restriction.
restrict :: proc(r: Restriction) {
	if r == .None { return }
	for {
		old := sync.atomic_load(&restriction_said)
		if old != 0 || sync.atomic_compare_exchange_strong(&restriction_said, old, u8(r)) == old { return }
	}
}

// A program says at its start that its elevation restricts it: host.program_start, setup.command_run and
// setup.task_manager_start call it first. A command-line tool made with the toolkit does not (tk, run_tests, a program's
// tool): it runs what the person typed, as any command of an administrator's console or of root does, and a CI runner
// is an administrator (Windows) or root (a container).
restrict_if_elevated :: proc() {
	when !GT_ELEVATED_UNRESTRICTED { if elevated() { restrict(.Elevated) } }
}

// What restricts this process (.None: nothing): what restrict and restrict_if_elevated said.
restriction :: proc() -> Restriction { return Restriction(sync.atomic_load(&restriction_said)) }

restricted :: proc() -> bool { return restriction() != .None }

// (restricted_words, restricted_reason: this system's words, trust_words_<os>.odin)

// A start of `program` that this process may make: always when it is not restricted; else only a program by its full
// path in a folder that only an administrator writes (trusted_program).
may_start :: proc(program: string) -> bool { return !restricted() || trusted_program(program) }
