#+build !windows
package tk_toolbox

// What an executable's file name ends with: nothing.
EXE_SUFFIX :: ""

// (no resource and no console launcher off Windows: build_windows, build_launcher and check_launcher do nothing)
build_windows :: proc(p: Project) -> bool { return true }
build_launcher :: proc(p: Project) -> bool { return true }
check_launcher :: proc(p: Project) -> bool { return true }
