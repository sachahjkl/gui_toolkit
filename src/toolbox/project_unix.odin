#+build !windows
package tk_toolbox

// What an executable's file name ends with: nothing.
EXE_SUFFIX :: ""

// (no resource and no console launcher off Windows: build_windows, build_launcher and check_launcher do nothing)
build_windows :: proc(p: Project) -> bool { return true }
build_launcher :: proc(p: Project) -> bool { return true }
check_launcher :: proc(p: Project) -> bool { return true }

// The native libraries this system builds: the text backend (no DirectWrite here).
@(private)
system_native_steps :: proc(p: Project, steps: ^[dynamic]string) { append(steps, "build_text") }

@(private)
system_after_native :: proc(p: Project, root: string) -> bool { return true }
