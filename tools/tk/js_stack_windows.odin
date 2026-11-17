package tk

// The judge's main thread runs the engine, which may use 48 MiB of it (test262's deep recursion tests): Windows takes the
// size of that stack from the executable.
JS_JUDGE_LINK_FLAGS :: []string{"-extra-linker-flags:/STACK:67108864"}

// (Windows: the executable carries its stack size)
js_judge_stack_raise :: proc() {}
