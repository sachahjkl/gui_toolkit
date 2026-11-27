#+build !linux
#+build !windows
package tk_process

// Elsewhere the tree is the child alone (process-trees.md, "Elsewhere"): no group, no keeper, no job.

import "core:os"
import "core:time"

tree_start :: proc(desc: os.Process_Desc, loc := #caller_location) -> (t: Tree, err: os.Error) {
	p := start(desc, loc) or_return
	return Tree{process = p, pid = p.pid}, nil
}

tree_signal :: proc(t: ^Tree, sig: Signal) -> bool {
	if t.ended || t.keep == TREE_GONE { return false }
	if sig != .Kill && sig != .Terminate { return false }
	return os.process_kill(t.process) == nil
}

tree_kill :: proc(t: ^Tree) {
	if t.ended || t.keep == TREE_GONE { return }
	_ = os.process_kill(t.process)
}

tree_wait :: proc(t: ^Tree, timeout: time.Duration) -> (end: Tree_End, ended: bool) {
	if t.ended { return t.end, true }
	state, err := os.process_wait(t.process, timeout < 0 ? time.MAX_DURATION : timeout)
	if err != nil || !state.exited { return }
	t.end = {code = state.exit_code}
	t.ended = true
	return t.end, true
}

tree_close :: proc(t: ^Tree) {
	tree_kill(t)
	if !t.ended { _, _ = tree_wait(t, TREE_CLOSE_BOUND) }
	t.keep = TREE_GONE
}
