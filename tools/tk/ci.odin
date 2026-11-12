package tk

import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "../../src/toolbox"

// What a program's file ends with.
EXE :: ".exe" when ODIN_OS == .Windows else ""

// The examples, and the ones the CI builds on each system.
EXAMPLES       :: [?]string{"hello", "fidget", "todo", "smoke", "transforms", "effects", "stream", "panes", "docking", "cursors", "markdown", "whatsnew"}
CI_EXAMPLES_WINDOWS :: [?]string{"hello", "fidget", "todo", "smoke", "transforms", "effects", "docking"}
CI_EXAMPLES_LINUX   :: [?]string{"hello", "smoke", "todo", "markdown", "panes", "docking", "whatsnew"}

// What a program of the toolkit needs on Linux: the native text backend (build/text/libgt_text.a, which the examples link
// themselves), and wgpu-native beside it: both carry Rust's standard library, whose few unmangled symbols are the same code.
LINUX_FLAGS :: [?]string{"-define:FONT_BACKEND=native", "-extra-linker-flags:-Wl,--allow-multiple-definition"}

// The packages of the library, under src/.
PACKAGES :: [?]string{"arena", "ascii", "base", "capture", "cdp", "changelog", "config", "dbus", "desktop", "devtools", "diff", "draw", "flate", "font", "fsx", "gif", "host", "i18n", "instance", "markdown", "mermaid", "ocr", "paint", "platform", "png", "process", "qr", "remote", "render", "shortcuts", "site", "store", "svg", "term", "testkit", "timefmt", "toolbox", "ui", "update"}

// build [example] [-debug]: an example (default fidget) -> build/<example>[.exe], optimized (-o:speed) or with debug information
// (Windows: the D3D11 debug layer). Windows: no console (-subsystem:windows), and examples/<example>/<example>.rc as its resource
// when there is one. Linux: the native text backend first (build_text).
run_build :: proc(a: ^Args) -> string {
	example := len(a.positionals) > 0 ? a.positionals[0] : "fidget"
	known := false
	for e in EXAMPLES { known ||= e == example }
	all := EXAMPLES
	if !known { return fmt.tprintf("no example %s (%s)", example, strings.join(all[:], ", ", context.temp_allocator)) }
	return build_example(toolkit_root(), example, has_flag(a, "debug"))
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
		flags := LINUX_FLAGS
		append(&cmd, ..flags[:])
	}
	if !toolbox.run(cmd[:]) { return fmt.tprintf("building examples/%s failed", example) }
	fmt.printfln("built %s", out)
	return ""
}

// ci: what the CI checks on this system, every step run whatever an earlier one said, then the failures. odin check -vet of every
// package (Linux: for Linux, with the native text backend), the CI's examples built, and the tests of tools/run_tests (its list
// says which run here; Linux's pixels: Vulkan's software rasterizer).
run_ci :: proc(a: ^Args) -> string {
	root := toolkit_root()
	failed := make([dynamic]string, context.temp_allocator)
	when ODIN_OS != .Windows {
		if why := build_rust_lib(root, TEXT_LIB, false); why != "" { return why }
		if why := build_rust_lib(root, MERMAID_LIB, false); why != "" { return why }   // (tests/mermaid)
	}
	for p in PACKAGES {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "odin", "check", join({root, "src", p}), "-no-entry-point", "-vet")
		when ODIN_OS != .Windows { append(&cmd, "-target:linux_amd64", LINUX_FLAGS[0]) }
		if toolbox.run(cmd[:]) {   // (the compiler says what is wrong, and nothing when all is well)
			fmt.printfln("check ok   %s", p)
		} else {
			fmt.printfln("check FAIL %s", p)
			append(&failed, fmt.tprintf("check %s", p))
		}
	}
	examples := CI_EXAMPLES_WINDOWS when ODIN_OS == .Windows else CI_EXAMPLES_LINUX
	for e in examples {
		if why := build_example(root, e, false); why != "" { append(&failed, why) }
	}
	if !toolbox.run({"odin", "run", join({root, "tools", "run_tests"}), "-vet", fmt.tprintf("-out:%s", join({root, "build", fmt.tprintf("run_tests%s", EXE)}))}, {dir = root}) {
		append(&failed, "tools/run_tests")
	}
	if len(failed) > 0 { return fmt.tprintf("failed: %s", strings.join(failed[:], ", ", context.temp_allocator)) }
	fmt.println("ci: all passed")
	return ""
}
