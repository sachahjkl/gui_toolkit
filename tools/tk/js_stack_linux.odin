package tk

import "core:sys/linux"

// (Linux: a linker flag does not size the main thread's stack; the soft limit does, at exec)
JS_JUDGE_LINK_FLAGS :: []string{}

// What /STACK is on Windows: the judge's main thread runs the engine, which may use 48 MiB of it. The soft limit of
// this process's stack is raised to 64 MiB (no more than the hard limit); the judge and its workers inherit it.
js_judge_stack_raise :: proc() {
	limit: linux.RLimit
	if linux.getrlimit(.STACK, &limit) != nil { return }
	limit.cur = min(JS_JUDGE_STACK_BYTES, limit.max)
	_ = linux.setrlimit(.STACK, &limit)
}
