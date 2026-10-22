// The renderer's shaders are written once, in WGSL (render/*.wgsl). This writes what the Direct3D 11 backend embeds:
//   1. the HLSL of each module (render/shaders/*.hlsl), by naga (tools/wgsl2hlsl, built by tools/build_naga.ps1);
//   2. the DXBC of each entry point (render/shaders/*.dxbc), by D3DCompile.
//   odin run tools/shaders            write what differs from the sources
//   odin run tools/shaders -- -check  only compare (exit code 1 when something is stale)
// Run it after editing a .wgsl file; tests/shaders fails until then (it checks the SHA-256 of the sources named by the header of each
// HLSL file, and that each blob is what its HLSL compiles to; with build\naga\wgsl2hlsl.exe built it runs naga again and compares).
package main

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "../../render"

NAGA_EXE :: "build/naga/wgsl2hlsl.exe"

main :: proc() {
	check := len(os.args) > 1 && os.args[1] == "-check"
	joined, _ := filepath.join({filepath.dir(#file), "..", ".."}, context.temp_allocator)
	root, _ := filepath.abs(joined, context.temp_allocator)
	exe, _ := filepath.join({root, "build", "naga", "wgsl2hlsl.exe"}, context.temp_allocator)
	if !os.exists(exe) {
		fmt.println("building naga (tools\\build_naga.ps1)...")
		if libc.system(strings.clone_to_cstring(fmt.tprintf("powershell -NoProfile -ExecutionPolicy Bypass -File \"%s\\tools\\build_naga.ps1\"", root), context.temp_allocator)) != 0 {
			fmt.eprintln("shaders: building naga failed")
			os.exit(1)
		}
	}
	shaders_dir, _ := filepath.join({root, "render", "shaders"}, context.temp_allocator)
	tmp_dir, _ := filepath.join({root, "build", "tmp"}, context.temp_allocator)
	build_dir, _ := filepath.join({root, "build"}, context.temp_allocator)
	os.make_directory(build_dir)
	os.make_directory(tmp_dir)
	stale := 0
	generated: [render.Shader_Module]string
	for desc, m in render.MODULES {
		t0 := time.tick_now()
		out, _ := filepath.join({tmp_dir, desc.file}, context.temp_allocator)
		cmd := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&cmd, "\"%s\" \"%s\" 50", exe, out)
		for b in desc.bindings { fmt.sbprintf(&cmd, " %s", b) }
		fmt.sbprintf(&cmd, " --")
		for f in desc.wgsl_files { fmt.sbprintf(&cmd, " \"%s\\render\\%s\"", root, f) }
		// cmd.exe strips the outer quotes of a command that starts with one: wrap the whole line
		if libc.system(strings.clone_to_cstring(fmt.tprintf("\"%s\"", strings.to_string(cmd)), context.temp_allocator)) != 0 {
			fmt.eprintln("shaders: naga failed on", desc.file)
			os.exit(1)
		}
		body, rerr := os.read_entire_file(out, context.temp_allocator)
		if rerr != nil { fmt.eprintln("shaders: no output for", desc.file); os.exit(1) }
		text := fmt.tprintf("%s%s", render.module_header(m, context.temp_allocator), string(body))
		text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
		generated[m] = text
		path, _ := filepath.join({shaders_dir, desc.file}, context.temp_allocator)
		if text == desc.hlsl {
			fmt.printfln("%s up to date (naga %.1f s)", desc.file, time.duration_seconds(time.tick_since(t0)))
			continue
		}
		stale += 1
		if check { fmt.printfln("%s is stale", desc.file); continue }
		if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
			fmt.eprintln("shaders: cannot write", path, err)
			os.exit(1)
		}
		fmt.printfln("%s written (%d bytes)", desc.file, len(text))
	}
	for d, id in render.SHADERS {
		t0 := time.tick_now()
		code, ok := render.compile_hlsl(generated[d.module], id)
		if !ok {
			fmt.eprintln("shaders:", d.name, d.entry, "does not compile")
			os.exit(1)
		}
		ms := time.duration_milliseconds(time.tick_since(t0))
		if slice.equal(code, d.blob) {
			fmt.printfln("%s up to date (%d bytes, compiled in %.1f ms)", d.file, len(code), ms)
			continue
		}
		stale += 1
		if check {
			fmt.printfln("%s is stale", d.file)
			continue
		}
		path, _ := filepath.join({shaders_dir, d.file}, context.temp_allocator)
		if err := os.write_entire_file(path, code); err != nil {
			fmt.eprintln("shaders: cannot write", path, err)
			os.exit(1)
		}
		fmt.printfln("%s written (%d bytes, compiled in %.1f ms)", d.file, len(code), ms)
	}
	if check && stale > 0 { os.exit(1) }
	if !check && stale > 0 { fmt.println("(the written files are embedded when the toolkit is built again: run this once more to see them up to date)") }
}
