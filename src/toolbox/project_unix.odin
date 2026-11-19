#+build !windows
package tk_toolbox

// What an executable's file name ends with: nothing.
EXE_SUFFIX :: ""

// (no resource, no console launcher and no thumbnail DLL off Windows: build_windows, build_launcher, check_launcher and
// build_thumbnailer do nothing; Linux's file managers run the program itself)
build_windows :: proc(p: Project) -> bool { return true }
build_launcher :: proc(p: Project) -> bool { return true }
check_launcher :: proc(p: Project) -> bool { return true }
build_thumbnailer :: proc(p: Project, release: bool) -> bool { return true }
