#+build linux
package process_start_test

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "gt:process"

// A child starts with no signal blocked and SIGPIPE at its default, whatever the starting thread blocks and whatever the
// toolkit ignores: an exec keeps a mask and an ignored disposition, and a child that ignores SIGPIPE never ends at a
// closed pipe.
@(test)
a_child_starts_with_the_default_signals :: proc(t: ^testing.T) {
	// (run with an input ignores SIGPIPE in this process from here on)
	_ = process.run({"true"}, {input = "x"}, context.temp_allocator)
	usr1: linux.Sig_Set
	usr1[0] = 1 << (u32(linux.Signal.SIGUSR1) - 1)
	old: linux.Sig_Set
	_ = linux.rt_sigprocmask(.SIG_BLOCK, &usr1, &old)
	r := process.run({"cat", "/proc/self/status"}, {}, context.temp_allocator)
	_ = linux.rt_sigprocmask(.SIG_SETMASK, &old, nil)
	if !testing.expect(t, r.ok, r.stderr) { return }
	mask :: proc(status, name: string) -> (bits: u64, ok: bool) {
		rest := status
		for line in strings.split_lines_iterator(&rest) {
			if !strings.has_prefix(line, name) { continue }
			return strconv.parse_u64_of_base(strings.trim_space(line[len(name):]), 16)
		}
		return
	}
	bit :: proc(sig: linux.Signal) -> u64 { return 1 << (u64(sig) - 1) }
	blocked, ok1 := mask(r.stdout, "SigBlk:")
	ignored, ok2 := mask(r.stdout, "SigIgn:")
	testing.expect(t, ok1 && ok2, r.stdout)
	testing.expect(t, blocked & bit(.SIGUSR1) == 0, fmt.tprintf("SIGUSR1 not blocked (SigBlk %x)", blocked))
	testing.expect(t, ignored & bit(.SIGPIPE) == 0, fmt.tprintf("SIGPIPE not ignored (SigIgn %x)", ignored))
}

// A program planted in the child's working folder never runs by its bare name, even with "." and a relative folder in
// PATH: os.process_start fell back to ./name.
@(test)
a_bare_name_never_runs_from_the_current_folder :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "gt-planted-*", context.temp_allocator)
	if !testing.expect(t, err == nil, "a folder") { return }
	defer os.remove_all(dir)
	planted := fmt.tprintf("%s/gt-planted-git", dir)
	_ = os.write_entire_file(planted, transmute([]u8)string("#!/bin/sh\nexit 0\n"))
	_ = os.chmod(planted, {.Read_User, .Write_User, .Execute_User})
	_ = os.make_directory(fmt.tprintf("%s/bin", dir))
	_ = os.write_entire_file(fmt.tprintf("%s/bin/gt-planted-git", dir), transmute([]u8)string("#!/bin/sh\nexit 0\n"))
	_ = os.chmod(fmt.tprintf("%s/bin/gt-planted-git", dir), {.Read_User, .Write_User, .Execute_User})
	_, serr := process.start({command = {"gt-planted-git"}, working_dir = dir, env = {"PATH=.:bin:"}})
	testing.expect_value(t, serr, os.Error(os.General_Error.Not_Exist))
	// (by its path, the caller's own choice, it runs)
	p, perr := process.start({command = {planted}, working_dir = dir})
	if testing.expect(t, perr == nil, fmt.tprint(perr)) {
		state, _ := os.process_wait(p)
		testing.expect(t, state.exited && state.exit_code == 0)
	}
}

// A child inherits the parent environment when env is nil and receives no empty entry in envp, whether inheriting or
// given a list containing "" (Odin's Linux os.environ appends a trailing "" from posix.environ's final nil).
@(test)
a_child_inherits_a_clean_environment :: proc(t: ^testing.T) {
	testing.expect(t, os.set_env("GT_PROCESS_CLEAN_ENV", "present") == nil)
	defer _ = os.unset_env("GT_PROCESS_CLEAN_ENV")

	check_environ :: proc(t: ^testing.T, raw: string, want_entry: string) {
		testing.expect(t, len(raw) > 0 && raw[len(raw) - 1] == 0, "environ ends with NUL")
		trimmed := strings.trim_suffix(raw, "\x00")
		entries := strings.split(trimmed, "\x00", context.temp_allocator)
		found := false
		for e, i in entries {
			testing.expectf(t, e != "", "empty envp entry at index %d of %d", i, len(entries))
			if e == want_entry { found = true }
		}
		testing.expectf(t, found, "child env missing %s", want_entry)
	}

	r := process.run({"cat", "/proc/self/environ"}, {}, context.temp_allocator)
	if testing.expect(t, r.ok, r.stderr) {
		check_environ(t, r.stdout, "GT_PROCESS_CLEAN_ENV=present")
	}

	path_env := fmt.tprintf("PATH=%s", os.get_env("PATH", context.temp_allocator))
	r2 := process.run({"cat", "/proc/self/environ"}, {env = {"", path_env, "GT_PROCESS_EXPLICIT=yes", ""}}, context.temp_allocator)
	if testing.expect(t, r2.ok, r2.stderr) {
		check_environ(t, r2.stdout, "GT_PROCESS_EXPLICIT=yes")
	}
}
