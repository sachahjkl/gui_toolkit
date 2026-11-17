#+build darwin, freebsd, openbsd, netbsd
package tk

// (macOS's linker sizes the main thread's stack, as /STACK does on Windows; the BSDs take their system's default, and
// test262's deep recursion tests can crash the judge there)
JS_JUDGE_LINK_FLAGS :: []string{"-extra-linker-flags:-Wl,-stack_size,0x4000000"} when ODIN_OS == .Darwin else []string{}

js_judge_stack_raise :: proc() {}
