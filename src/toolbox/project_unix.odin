#+build !windows
package tk_toolbox

// What an executable's file name ends with: nothing.
EXE_SUFFIX :: ""

// (no resource and no console launcher off Windows: build_windows, build_launcher and check_launcher do nothing)
build_windows :: proc(p: Project) -> bool { return true }
build_launcher :: proc(p: Project) -> bool { return true }
check_launcher :: proc(p: Project) -> bool { return true }

// The parts of the native library this system links: the text backend (no DirectWrite here).
@(private)
system_native_parts :: proc(p: Project, parts: ^[dynamic]string) { append(parts, "text") }
