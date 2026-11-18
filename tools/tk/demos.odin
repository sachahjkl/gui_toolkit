package tk

import "core:fmt"
import "core:os"
import archive "../../src/archive"
import toolbox "../../src/toolbox"

// The examples a person downloads from a release to see the toolkit at work. Left out:
//   smoke   a check that the layers below the UI draw at all, not something to look at;
//   stream  what it shows is a way to write a program (ui.post from a thread, 0 % CPU between lines), seen in its code
//           and a CPU meter, not on its screen.
DEMOS :: [?]string{"hello", "fidget", "todo", "transforms", "effects", "panes", "docking", "cursors", "markdown", "whatsnew", "showcase"}

DEMOS_OUT_DEFAULT :: "build/demos"

// demos [-out:dir]: every demo built as `tk build <demo>` builds it, without the devtools endpoint, each in <dir>/<demo>-windows-x64.zip,
// then gt-runtime-windows-x64.zip and gt-skills.zip (skills.odin). A demo's zip holds the
// exe alone: on Windows a demo needs nothing beside it (D3D11 and DirectWrite are the system's, the native library is not
// linked by default, the icons are in the .rc, transforms #loads its picture, what docking writes it makes itself).
run_demos :: proc(args: []string) -> string {
	// (an if, not a when: the code below still compiles everywhere, so tk ci's check of tools/tk sees it on Linux too)
	if ODIN_OS != .Windows { return "the demos of a release are Windows builds: run tk demos on Windows" }
	root := toolkit_root()
	out := toolbox.flag_value(args, "out", join({root, DEMOS_OUT_DEFAULT}))
	_ = os.make_directory_all(out)   // (a folder that cannot be made fails the first zip_begin, which says so)
	for demo in DEMOS {
		if why := build_example(root, demo, false, devtools = false); why != "" { return why }
		exe_name := fmt.tprintf("%s%s", demo, EXE)
		exe, err := os.read_entire_file(join({root, "build", exe_name}), context.temp_allocator)
		if err != nil { return fmt.tprintf("build/%s cannot be read: %v", exe_name, err) }
		zip := join({out, fmt.tprintf("%s-windows-x64.zip", demo)})
		w: archive.Zip_Writer
		archive.zip_begin(&w, zip)
		archive.zip_add(&w, exe_name, exe, mode = 0o755)
		if zerr := archive.zip_end(&w); zerr != .None { return fmt.tprintf("%s cannot be written: %v", zip, zerr) }
		fmt.printfln("packed %s", zip)
	}
	if why := pack_runtime(root, out); why != "" { return why }
	// (the agent skills of this release beside its programs: their references are this tag's docs)
	skills := join({out, SKILLS_ZIP_NAME})
	if why := skills_zip(root, skills); why != "" { return fmt.tprintf("%s: %s", skills, why) }
	fmt.printfln("packed %s", skills)
	return ""
}

// gt-runtime-windows-x64.zip: gt-runtime.exe and the JavaScript demos beside it (examples/js/<demo> as js/<demo>), so that
// `gt-runtime js\todo` runs one where the zip was opened. (The release job runs on Windows: no Linux archive yet.)
@(private = "file")
pack_runtime :: proc(root, out: string) -> string {
	if why := build_app(root, "gt-runtime", false); why != "" { return why }
	exe_name := fmt.tprintf("gt-runtime%s", EXE)
	exe, err := os.read_entire_file(join({root, "build", exe_name}), context.temp_allocator)
	if err != nil { return fmt.tprintf("build/%s cannot be read: %v", exe_name, err) }
	zip := join({out, "gt-runtime-windows-x64.zip"})
	w: archive.Zip_Writer
	archive.zip_begin(&w, zip)
	archive.zip_add(&w, exe_name, exe, mode = 0o755)
	if why := zip_folder(&w, join({root, "examples", "js"}), "js"); why != "" { return why }
	if zerr := archive.zip_end(&w); zerr != .None { return fmt.tprintf("%s cannot be written: %v", zip, zerr) }
	fmt.printfln("packed %s", zip)
	return ""
}

// Every file under `dir`, as `prefix`/<its path under dir> (with '/', as a zip names them).
@(private = "file")
zip_folder :: proc(w: ^archive.Zip_Writer, dir, prefix: string) -> string {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return fmt.tprintf("%s cannot be read: %v", dir, err) }
	for e in entries {
		name := fmt.tprintf("%s/%s", prefix, e.name)
		if e.type == .Directory {
			if why := zip_folder(w, e.fullpath, name); why != "" { return why }
			continue
		}
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { return fmt.tprintf("%s cannot be read: %v", e.fullpath, rerr) }
		archive.zip_add(w, name, data)
	}
	return ""
}
