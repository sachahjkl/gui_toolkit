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

// demos [-out:dir]: every demo built as `tk build <demo>` builds it, without the devtools endpoint, each in <dir>/<demo>-windows-x64.zip. The zip holds the
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
	return ""
}
