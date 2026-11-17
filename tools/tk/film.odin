package tk

import "core:fmt"
import "core:os"
import toolbox "../../src/toolbox"

// film [name...] [-out:dir] [-list]: tools/film built (optimized, the native text backend first on Linux), then run from the
// checkout with the same arguments: each film named (none: all) -> <dir>/<name>.mp4, default build/films. It needs ffmpeg
// on the PATH; NVENC when the machine has it (src/md/features/film.md).
run_film :: proc(args: []string) -> string {
	root := toolkit_root()
	when ODIN_OS != .Windows {
		if why := build_native_default(root); why != "" { return why }
	}
	exe := join({root, "build", fmt.tprintf("film_tool%s", EXE)})
	_ = os.make_directory_all(join({root, "build"}))
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "build", join({root, "tools", "film"}), fmt.tprintf("-out:%s", exe), "-vet", "-o:speed", gt_collection(root))
	when ODIN_OS != .Windows { append(&cmd, toolbox.LINUX_LINK_FLAG) }
	if !toolbox.run(cmd[:]) { return "building tools/film failed" }
	// (its names and flags as given: tools/film checks them)
	run := make([dynamic]string, context.temp_allocator)
	append(&run, exe)
	append(&run, ..args)
	if !toolbox.run(run[:], {dir = root}) { return "a film failed" }
	return ""
}
