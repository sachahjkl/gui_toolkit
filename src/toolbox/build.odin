package tk_toolbox

// What a build makes once: an output beside a stamp, the hash of what it is made from. A second build with the same sources
// finds the stamp as expected and does nothing.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// What a stamp file ends with (the ones PowerShell's Set-Content wrote end so on Windows, and stay valid).
STAMP_NEWLINE :: "\r\n" when ODIN_OS == .Windows else "\n"
// The stamp beside a library build_c_lib makes.
C_LIB_STAMP :: "STAMP"

// Writes the stamp `text` at `path`, with its line end.
write_stamp :: proc(path, text: string) -> bool {
	return os.write_entire_file(path, fmt.tprintf("%s%s", text, STAMP_NEWLINE)) == nil
}

// The output is there and the stamp beside it says `expected` (its line end aside).
stamp_holds :: proc(output, stamp, expected: string) -> bool {
	if !os.exists(output) { return false }
	text, err := os.read_entire_file(stamp, context.temp_allocator)
	return err == nil && strings.trim_space(string(text)) == expected
}

// The stamp of a C library: the SHA-256 of the SHA-256 of each source (headers too), in their order, and of the flags.
// ok = false: a source cannot be read.
c_lib_stamp :: proc(sources, cflags: []string) -> (stamp: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	for s in sources {
		sum := sha256_file(s) or_return
		fmt.sbprintf(&b, "%s %s\n", sum, filepath.base(s))
	}
	fmt.sbprintf(&b, "%s\n", strings.join(cflags, " ", context.temp_allocator))
	return sha256_hex(transmute([]u8)strings.to_string(b)), true
}

// A static C library, <out>/lib<name>.a, from `sources` (the .c files compiled with cc and `cflags`, each other file, a
// header, hashed only), unless the stamp beside it (<out>/C_LIB_STAMP) says it is made of these sources and flags.
// cc and ar from the PATH (Linux, macOS).
build_c_lib :: proc(name: string, sources: []string, out: string, cflags: []string) -> bool {
	lib, stamp_file := fmt.tprintf("%s/lib%s.a", out, name), fmt.tprintf("%s/%s", out, C_LIB_STAMP)
	stamp, ok := c_lib_stamp(sources, cflags)
	if !ok { fmt.eprintfln("%s: a source cannot be read", name); return false }
	if stamp_holds(lib, stamp_file, stamp) { return true }
	if os.make_directory_all(out) != nil { fmt.eprintfln("%s cannot be made", out); return false }
	objects := make([dynamic]string, context.temp_allocator)
	for s in sources {
		if !strings.has_suffix(s, ".c") { continue }
		object := fmt.tprintf("%s/%s.o", out, filepath.stem(s))
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "cc", "-c", s, "-o", object)
		append(&cmd, ..cflags)
		if !run(cmd[:], {echo = true}) { return false }
		append(&objects, object)
	}
	_ = os.remove(lib)   // (ar adds to what is there)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "ar", "rcs", lib)
	append(&cmd, ..objects[:])
	if !run(cmd[:], {echo = true}) { return false }
	if !write_stamp(stamp_file, stamp) { fmt.eprintfln("%s cannot be written", stamp_file); return false }
	fmt.printfln("built %s", lib)
	return true
}
