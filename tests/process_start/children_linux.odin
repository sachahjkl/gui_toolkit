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
