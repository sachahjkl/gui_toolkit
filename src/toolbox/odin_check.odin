package tk_toolbox

import "core:fmt"
import "core:os"
import "core:strings"

// Where odin_check makes its Odin root for a check of another system, under a project's build folder.
CHECK_ROOT_DEFAULT :: "build/odin_root"
@(private = "file")
WGPU_WINDOWS_LIB :: "lib/wgpu-windows-x86_64-msvc-release/lib/wgpu_native.lib"

// `odin check <pkg> -vet -target:<target> <extra>`, also for another system than this one: the Windows code is checked
// from Linux (it is not run here; a check at least sees it compile), on the environment check_env gives.
odin_check :: proc(pkg, target: string, extra: []string = nil, root := CHECK_ROOT_DEFAULT, how := Run{}) -> bool {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "odin", "check", pkg, "-vet", fmt.tprintf("-target:%s", target))
	append(&command, ..extra)
	env, why := check_env(target, root)
	if why != "" { say_error(how.log, fmt.tprintfln("odin_check: %s", why)); return false }
	run_how := how
	if env != nil { run_how.env = env }
	return run(command[:], run_how)
}

// The environment of an `odin check` for `target` from this system; nil: this process's will do. Odin's wgpu package
// refuses to be checked without its Windows library, which a check does not link: a Windows check from elsewhere runs on
// an Odin root of links to the real one (made at `root`, default CHECK_ROOT_DEFAULT), whose vendor/wgpu is a copy with an
// empty library beside it (Odin follows links: a linked file is in the real folder). The Nix wrappers of Odin keep an
// ODIN_ROOT they are given (--set-default).
check_env :: proc(target: string, root := CHECK_ROOT_DEFAULT) -> (env: []string, why: string) {
	if !strings.has_prefix(target, "windows") || ODIN_OS == .Windows { return nil, "" }
	if why = check_root_make(root); why != "" { return nil, why }
	absolute, _ := os.get_absolute_path(root, context.temp_allocator)
	return env_with({"ODIN_ROOT"}, fmt.tprintf("ODIN_ROOT=%s/", absolute)), ""
}

// An Odin root for a Windows check: links to the real root's entries, its vendor/wgpu a copy with an empty library.
// Made again each time (the real root changes when the flake moves Odin).
@(private = "file")
check_root_make :: proc(root: string) -> string {
	out, code := capture({"odin", "root"})
	real := strings.trim_right(strings.trim_space(out), "/")
	if code != 0 || real == "" { return "odin root gave nothing" }
	_ = os.remove_all(root)
	wgpu := fmt.tprintf("%s/vendor/wgpu", root)
	if os.make_directory_all(wgpu) != nil { return fmt.tprintf("%s cannot be made", wgpu) }
	link_all :: proc(from, into: string, except: string) -> string {
		entries, err := os.read_all_directory_by_path(from, context.temp_allocator)
		if err != nil { return fmt.tprintf("%s cannot be read", from) }
		for e in entries {
			if e.name == except { continue }
			if os.symlink(e.fullpath, fmt.tprintf("%s/%s", into, e.name)) != nil { return fmt.tprintf("%s cannot be linked", e.fullpath) }
		}
		return ""
	}
	if why := link_all(real, root, "vendor"); why != "" { return why }
	if why := link_all(fmt.tprintf("%s/vendor", real), fmt.tprintf("%s/vendor", root), "wgpu"); why != "" { return why }
	sources, err := os.read_all_directory_by_path(fmt.tprintf("%s/vendor/wgpu", real), context.temp_allocator)
	if err != nil { return "Odin's vendor/wgpu cannot be read" }
	for e in sources {
		if !strings.has_suffix(e.name, ".odin") { continue }
		if os.copy_file(fmt.tprintf("%s/%s", wgpu, e.name), e.fullpath) != nil { return fmt.tprintf("%s cannot be copied", e.fullpath) }
	}
	lib := fmt.tprintf("%s/%s", wgpu, WGPU_WINDOWS_LIB)
	_ = os.make_directory_all(lib[:strings.last_index_byte(lib, '/')])
	if os.write_entire_file(lib, []u8{}) != nil { return fmt.tprintf("%s cannot be written", lib) }
	return ""
}
