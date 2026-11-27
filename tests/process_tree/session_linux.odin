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
