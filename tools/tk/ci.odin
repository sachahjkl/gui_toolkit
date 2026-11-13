package tk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import toolbox "../../src/toolbox"

// What a program's file ends with.
EXE :: ".exe" when ODIN_OS == .Windows else ""

// The examples, and the ones the CI builds on each system.
EXAMPLES       :: [?]string{"hello", "fidget", "todo", "smoke", "transforms", "effects", "stream", "panes", "docking", "cursors", "markdown", "whatsnew"}
CI_EXAMPLES_WINDOWS :: [?]string{"hello", "fidget", "todo", "smoke", "transforms", "effects", "docking"}
CI_EXAMPLES_LINUX   :: [?]string{"hello", "smoke", "todo", "markdown", "panes", "docking", "whatsnew"}


// The packages of the library: every folder under src/ that holds Odin files (a list written by hand forgot ten).
library_packages :: proc(root: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	walk :: proc(dir, rel: string, out: ^[dynamic]string) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { return }
		has_odin := false
		for e in entries {
			if e.type == .Directory {
				walk(e.fullpath, rel == "" ? e.name : fmt.tprintf("%s/%s", rel, e.name), out)
			} else if strings.has_suffix(e.name, ".odin") {
				has_odin = true
			}
		}
		if has_odin && rel != "" { append(out, rel) }
	}
	walk(join({root, "src"}), "", &out)
	slice.sort(out[:])
	return out[:]
}

// build [example] [-debug]: an example (default fidget) -> build/<example>[.exe], optimized (-o:speed) or with debug information
// (Windows: the D3D11 debug layer). Windows: no console (-subsystem:windows), and examples/<example>/<example>.rc as its resource
// when there is one. Linux: the native text backend first (build_text).
run_build :: proc(args: []string) -> string {
	example := len(toolbox.plain_args(args)) > 0 ? toolbox.plain_args(args)[0] : "fidget"
	known := false
	for e in EXAMPLES { known ||= e == example }
	all := EXAMPLES
	if !known { return fmt.tprintf("no example %s (%s)", example, strings.join(all[:], ", ", context.temp_allocator)) }
	return build_example(toolkit_root(), example, toolbox.has_flag(args, "debug"))
}

build_example :: proc(root, example: string, debug: bool) -> string {
	when ODIN_OS != .Windows {
		if why := build_rust_lib(root, TEXT_LIB, false); why != "" { return why }
	}
	out := join({root, "build", fmt.tprintf("%s%s", example, EXE)})
	_ = os.make_directory_all(join({root, "build"}))
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "build", join({root, "examples", example}), fmt.tprintf("-out:%s", out), "-vet", debug ? "-debug" : "-o:speed")
	when ODIN_OS == .Windows {
		append(&cmd, "-subsystem:windows")
		rc := join({root, "examples", example, fmt.tprintf("%s.rc", example)})
		if os.exists(rc) { append(&cmd, fmt.tprintf("-resource:%s", rc)) }
	} else {
		append(&cmd, toolbox.LINUX_LINK_FLAG)   // (the examples link the native text backend themselves)
	}
	if !toolbox.run(cmd[:]) { return fmt.tprintf("building examples/%s failed", example) }
	fmt.printfln("built %s", out)
	return ""
}

// ci: what the CI checks on this system, every step run whatever an earlier one said, then the failures. odin check -vet of every
// package (Linux: for Linux, with the native text backend), the CI's examples built, and the tests of tools/run_tests (its list
// says which run here; Linux's pixels: Vulkan's software rasterizer).
run_ci :: proc(args: []string) -> string {
	root := toolkit_root()
	failed := make([dynamic]string, context.temp_allocator)
	when ODIN_OS != .Windows {
		if why := build_rust_lib(root, TEXT_LIB, false); why != "" { return why }
		if why := build_rust_lib(root, MERMAID_LIB, false); why != "" { return why }   // (tests/mermaid)
	}
	packages := library_packages(root)
	for p in packages {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "odin", "check", join({root, "src", p}), "-no-entry-point", "-vet")
		when ODIN_OS != .Windows { append(&cmd, "-target:linux_amd64") }
		if toolbox.run(cmd[:]) {   // (the compiler says what is wrong, and nothing when all is well)
			fmt.printfln("check ok   %s", p)
		} else {
			fmt.printfln("check FAIL %s", p)
			append(&failed, fmt.tprintf("check %s", p))
		}
	}
	when ODIN_OS != .Windows {
		// (the Windows code, which only a Windows job compiled before: every package checked for it from here)
		scratch := join({root, toolbox.CHECK_ROOT_DEFAULT})
		for p in packages {
			if toolbox.odin_check(join({root, "src", p}), "windows_amd64", {"-no-entry-point"}, scratch) {
				fmt.printfln("check ok   %s (windows)", p)
			} else {
				fmt.printfln("check FAIL %s (windows)", p)
				append(&failed, fmt.tprintf("check %s (windows)", p))
			}
		}
	}
	// (a generated file as its source makes it)
	if ttf, err := os.read_entire_file(join({root, "src", "lucide", "lucide.ttf"}), context.temp_allocator); err == nil {
		icons, why := lucide_icons(ttf)
		have, _ := os.read_entire_file(join({root, "src", "lucide", "lucide.odin"}), context.temp_allocator)
		if why != "" || string(have) != lucide_source(icons) { append(&failed, "src/lucide/lucide.odin is not what gen_lucide makes of lucide.ttf") }
	}
	examples := CI_EXAMPLES_WINDOWS when ODIN_OS == .Windows else CI_EXAMPLES_LINUX
	for e in examples {
		if why := build_example(root, e, false); why != "" { append(&failed, why) }
	}
	if !toolbox.run({"odin", "run", join({root, "tools", "run_tests"}), "-vet", "-keep-executable", fmt.tprintf("-out:%s", join({root, "build", fmt.tprintf("run_tests%s", EXE)}))}, {dir = root}) {
		append(&failed, "tools/run_tests")
	}
	when ODIN_OS != .Windows {
		// (the Windows tests and programs, compiled for Windows from here: their own defines, nothing run)
		if !toolbox.run({join({root, "build", fmt.tprintf("run_tests%s", EXE)}), "-check:windows_amd64"}, {dir = root}) {
			append(&failed, "tools/run_tests -check:windows_amd64")
		}
	}
	if len(failed) > 0 { return fmt.tprintf("failed: %s", strings.join(failed[:], ", ", context.temp_allocator)) }
	fmt.println("ci: all passed")
	return ""
}
