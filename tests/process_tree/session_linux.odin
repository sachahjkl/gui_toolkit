#+build linux
package process_tree_test

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "gt:process"

// The tree's child leads a session and a group of its own from the moment tree_start returns: no terminal of the
// program's stops it, and a signal right after the start reaches its group.
@(test)
a_tree_child_leads_a_session_of_its_own :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	tree, err := process.tree_start({command = {"sleep", "30"}})
	if !testing.expect(t, err == nil, fmt.tprint(err)) { return }
	defer process.tree_close(&tree)
	stat, rerr := os.read_entire_file(fmt.tprintf("/proc/%d/stat", tree.pid), context.temp_allocator)
	if !testing.expect(t, rerr == nil, "its stat") { return }
	text := string(stat)
	// (after the name: state, ppid, pgrp, session)
	fields := strings.fields(text[strings.last_index_byte(text, ')') + 1:], context.temp_allocator)
	pgrp, _ := strconv.parse_int(fields[2])
	session, _ := strconv.parse_int(fields[3])
	testing.expect_value(t, pgrp, tree.pid)
	testing.expect_value(t, session, tree.pid)
	testing.expect(t, process.tree_signal(&tree, .Terminate), "a signal goes")
	end, done := process.tree_wait(&tree, 15 * time.Second)
	testing.expect(t, done && end.signaled && end.code == 15, fmt.tprint(end))
}

// A tree's child receives no empty entry in envp, whether inheriting or given an explicit list containing "".
@(test)
a_tree_child_inherits_a_clean_environment :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	testing.expect(t, os.set_env("GT_TREE_CLEAN_ENV", "present") == nil)
	defer _ = os.unset_env("GT_TREE_CLEAN_ENV")

	read_tree_env :: proc(t: ^testing.T, env: []string, want_entry: string) {
		r, w, perr := process.pipe()
		if !testing.expect(t, perr == nil, "a pipe") { return }
		tree, err := process.tree_start({command = {"cat", "/proc/self/environ"}, env = env, stdout = w})
		os.close(w)
		if !testing.expect(t, err == nil, fmt.tprint(err)) { os.close(r); return }
		data, _ := os.read_entire_file_from_file(r, context.temp_allocator)
		os.close(r)
		end, done := process.tree_wait(&tree, 15 * time.Second)
		process.tree_close(&tree)
		testing.expect(t, done && !end.signaled && end.code == 0, fmt.tprint(end))
		raw := string(data)
		testing.expect(t, len(raw) > 0 && raw[len(raw) - 1] == 0, "environ ends with NUL")
		entries := strings.split(strings.trim_suffix(raw, "\x00"), "\x00", context.temp_allocator)
		found := false
		for e, i in entries {
			testing.expectf(t, e != "", "empty envp entry at index %d of %d", i, len(entries))
			if e == want_entry { found = true }
		}
		testing.expectf(t, found, "tree child env missing %s", want_entry)
	}

	read_tree_env(t, nil, "GT_TREE_CLEAN_ENV=present")
	path_env := fmt.tprintf("PATH=%s", os.get_env("PATH", context.temp_allocator))
	read_tree_env(t, {"", path_env, "GT_TREE_EXPLICIT=yes", ""}, "GT_TREE_EXPLICIT=yes")
}
