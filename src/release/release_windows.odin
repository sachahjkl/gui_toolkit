package tk_release

import "core:fmt"
import toolbox "../toolbox"

// The release's folder, its program's file and its archive: <name>-<version>-windows-x64, <name>.exe, a zip.
@(private)
package_names :: proc(o: Release_Options, version: string) -> (name, exe, archive: string) {
	name = fmt.tprintf("%s-%s-windows-x64", o.name, version)
	return name, fmt.tprintf("%s.exe", o.name), fmt.tprintf("%s.zip", name)
}

// Its console launcher beside it: typed in cmd or PowerShell, the program gives its output and exit code.
@(private)
stage_launcher :: proc(o: Release_Options, stage: string) -> bool {
	return copy_file(o.name, toolbox.launcher_path(o.project), fmt.tprintf("%s/%s.com", stage, o.name))
}

// The archive of the staged folder (tar.exe of Windows 10 and later: -a picks the zip format by the name).
@(private)
pack :: proc(o: Release_Options, stage, name, exe, archive: string) -> bool {
	return toolbox.run({"tar", "-a", "-cf", archive, name}, {dir = o.dist})
}

// (a file runs by its extension here)
@(private)
mark_executable :: proc(path: string) {}
