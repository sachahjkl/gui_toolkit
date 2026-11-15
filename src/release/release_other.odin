#+build !windows
package tk_release

import "core:fmt"
import "core:os"
import toolbox "../toolbox"

// The release's folder, its program's file and its archive: <name>-<version>-linux-x64, <name>, a tar.gz.
@(private)
package_names :: proc(o: Release_Options, version: string) -> (name, exe, archive: string) {
	name = fmt.tprintf("%s-%s-linux-x64", o.name, version)
	return name, o.name, fmt.tprintf("%s.tar.gz", name)
}

// (no console launcher: a shell's terminal is the program's console already)
@(private)
stage_launcher :: proc(o: Release_Options, stage: string) -> bool { return true }

// The archive of the staged folder, its program stripped (the symbols are a third of a program: a crash in a release
// is read again with a build of its tag) and executable, owned by nobody in particular.
@(private)
pack :: proc(o: Release_Options, stage, name, exe, archive: string) -> bool {
	program := fmt.tprintf("%s/%s", stage, exe)
	if !toolbox.run({"strip", program}) { return false }
	mark_executable(program)
	return toolbox.run({"tar", "--owner=0", "--group=0", "--numeric-owner", "-czf", archive, name}, {dir = o.dist})
}

@(private)
mark_executable :: proc(path: string) {
	_ = os.chmod(path, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
}
