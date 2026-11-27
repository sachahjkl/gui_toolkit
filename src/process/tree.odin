package tk_process

// A process tree: a child and everything it starts, which ends at tree_kill or tree_close, when the child ends (what
// it left running is killed), and when this program ends however it ends (process-trees.md). Linux: a keeper process
// per tree and a process group (tree_linux.odin); Windows: a Job Object (tree_windows.odin); elsewhere the child
// alone (tree_other.odin).
//
//	tree_start   starts the child of `desc` in a tree of its own (a blocking call: never on the interface's thread)
//	tree_signal  a signal to every process of the tree (Windows: Terminate and Kill only, both the job's end)
//	tree_kill    ends every process of the tree at once
//	tree_wait    waits for the child's end, up to a time limit (0: only asks; negative: no limit)
//	tree_close   kills what is left and releases the tree (waits for its end, TREE_CLOSE_BOUND at most)

import "core:os"
import "core:time"

// How long tree_close waits for a killed tree to be gone.
TREE_CLOSE_BOUND :: 5 * time.Second

Tree :: struct {
	process: os.Process,   // what ends with the child: Linux its keeper (whose end is the child's), Windows the child
	pid:     int,          // the child's own pid
	keep:    uintptr,      // what holds the tree: Linux the life pipe's write end, Windows the job; TREE_GONE once let go
	ended:   bool,         // tree_wait saw the end
	end:     Tree_End,
}

// How the child ended.
Tree_End :: struct {
	signaled: bool,   // by a signal (Linux): code is its number
	code:     int,    // the exit code; Windows: the process's (an exception's NTSTATUS after a crash)
}

// Tree.keep once the tree is let go.
TREE_GONE :: ~uintptr(0)
