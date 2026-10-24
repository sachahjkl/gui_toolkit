package main

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../../render"

// The toolkit's root and the translator (built on first use).
toolchain :: proc() -> (root, exe: string) {
	joined, _ := filepath.join({filepath.dir(#file), "..", ".."}, context.temp_allocator)
	root, _ = filepath.abs(joined, context.temp_allocator)
	exe, _ = filepath.join({root, "build", "naga", "wgsl2hlsl.exe"}, context.temp_allocator)
	if !os.exists(exe) {
		fmt.println("building naga (tools\\build_naga.ps1)...")
		if libc.system(strings.clone_to_cstring(fmt.tprintf("powershell -NoProfile -ExecutionPolicy Bypass -File \"%s\\tools\\build_naga.ps1\"", root), context.temp_allocator)) != 0 {
			fmt.eprintln("shaders: building naga failed")
			os.exit(1)
		}
	}
	return
}

// app <name> <file.wgsl> <dir> [-check]: writes <dir>/<name>.dxbc (the pixel shader ps_app of rect.wgsl + app.wgsl + <file.wgsl>,
// by naga and D3DCompile) and <dir>/<name>.sha256 (the SHA-256 of that module's source, which render.create_app_shader compares
// with the one of the WGSL it is given). -check only compares (exit code 1 when a file is missing or stale).
app_main :: proc() {
	args := os.args[2:]
	check := false
	pos: [dynamic]string
	for a in args {
		if a == "-check" { check = true } else { append(&pos, a) }
	}
	if len(pos) != 3 {
		fmt.eprintln("usage: odin run tools/shaders -- app <name> <file.wgsl> <dir> [-check]")
		os.exit(2)
	}
	name, file, dir := pos[0], pos[1], pos[2]
	root, exe := toolchain()
	source, rerr := os.read_entire_file(file, context.temp_allocator)
	if rerr != nil {
		fmt.eprintln("shaders: cannot read", file)
		os.exit(1)
	}
	file_abs, _ := filepath.abs(file, context.temp_allocator)
	dir_abs, _ := filepath.abs(dir, context.temp_allocator)
	tmp_dir, _ := filepath.join({root, "build", "tmp"}, context.temp_allocator)
	os.make_directory(filepath.dir(tmp_dir))
	os.make_directory(tmp_dir)
	hlsl, _ := filepath.join({tmp_dir, fmt.tprintf("app_%s.hlsl", name)}, context.temp_allocator)
	cmd := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&cmd, "\"%s\" \"%s\" 50", exe, hlsl)
	for b in render.APP_BINDINGS { fmt.sbprintf(&cmd, " %s", b) }
	fmt.sbprintf(&cmd, " -- \"%s\\render\\rect.wgsl\" \"%s\\render\\app.wgsl\" \"%s\"", root, root, file_abs)
	if libc.system(strings.clone_to_cstring(fmt.tprintf("\"%s\"", strings.to_string(cmd)), context.temp_allocator)) != 0 {
		fmt.eprintln("shaders: naga failed on", file)
		os.exit(1)
	}
	body, herr := os.read_entire_file(hlsl, context.temp_allocator)
	if herr != nil { fmt.eprintln("shaders: no output for", file); os.exit(1) }
	text, _ := strings.replace_all(string(body), "\r\n", "\n", context.temp_allocator)
	code, ok := render.compile_app_hlsl(text, context.temp_allocator)
	if !ok {
		fmt.eprintln("shaders:", file, "does not compile")
		os.exit(1)
	}
	hash := render.app_module_hash(string(source), context.temp_allocator)
	dxbc_path, _ := filepath.join({dir_abs, fmt.tprintf("%s.dxbc", name)}, context.temp_allocator)
	hash_path, _ := filepath.join({dir_abs, fmt.tprintf("%s.sha256", name)}, context.temp_allocator)
	stale := 0
	old_code, _ := os.read_entire_file(dxbc_path, context.temp_allocator)
	old_hash, _ := os.read_entire_file(hash_path, context.temp_allocator)
	if !slice.equal(old_code, code) {
		stale += 1
		if check {
			fmt.printfln("%s is stale", dxbc_path)
		} else {
			os.make_directory(dir_abs)
			if err := os.write_entire_file(dxbc_path, code); err != nil { fmt.eprintln("shaders: cannot write", dxbc_path, err); os.exit(1) }
			fmt.printfln("%s written (%d bytes)", dxbc_path, len(code))
		}
	}
	if strings.trim_space(string(old_hash)) != hash {
		stale += 1
		if check {
			fmt.printfln("%s is stale", hash_path)
		} else {
			if err := os.write_entire_file(hash_path, transmute([]u8)hash); err != nil { fmt.eprintln("shaders: cannot write", hash_path, err); os.exit(1) }
			fmt.printfln("%s written", hash_path)
		}
	}
	if stale == 0 { fmt.printfln("%s up to date (%d bytes)", name, len(code)) }
	if check && stale > 0 { os.exit(1) }
}
