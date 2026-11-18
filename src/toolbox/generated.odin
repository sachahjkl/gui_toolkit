package tk_toolbox

// Files a tool makes from a declaration (a program's module "app": plugin_api.app_module_dts; the toolkit's plugin
// API: `tk plugin_api`): written when they changed, or, with `check`, compared only (a CI's way: a declaration changed
// and its files not made again fails).

import "core:fmt"
import "core:os"
import "core:strings"

// Writes each [path from `root`, text] of `files` whose text differs ("": done), or with `check` writes nothing and says
// which differ. A file written is said on the standard output.
generated_files :: proc(root: string, files: [][2]string, check: bool, command := "") -> string {
	differ := make([dynamic]string, context.temp_allocator)
	for f in files {
		path := fmt.tprintf("%s/%s", root, f[0])
		have, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil && string(have) == f[1] { continue }
		if check {
			append(&differ, f[0])
			continue
		}
		if dir := dir_of(path); dir != "" { _ = os.make_directory_all(dir) }
		if os.write_entire_file(path, transmute([]u8)f[1]) != nil { return fmt.tprintf("cannot write %s", path) }
		fmt.printfln("wrote %s", f[0])
	}
	if len(differ) > 0 {
		how := command != "" ? fmt.tprintf(" (%s)", command) : ""
		return fmt.tprintf("not what the declarations make%s: %s", how, strings.join(differ[:], ", ", context.temp_allocator))
	}
	return ""
}
