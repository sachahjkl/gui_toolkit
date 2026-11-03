// The Rust parts, built with cargo: the static libraries of native/ (the text backend, the AccessKit adapter) and the WGSL to HLSL
// translator. Every crate is pinned by exact version in its Cargo.toml and by SHA-256 in its Cargo.lock (--locked); the stable
// toolchain of rustup (x86_64-pc-windows-msvc).
package tk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
@(require) import "core:time"   // (the build is Windows')

// A static library of native/: an application may link other Rust static libraries (Wren: its image decoders, Wasmtime); each
// carries its own standard library and all define the unmangled rust_eh_personality, so ours is renamed in the object that defines
// it (with fat LTO, the crate's single object) and they link together.
Rust_Lib :: struct {
	name:   string,   // the crate's
	crate:  string,   // its folder, in the checkout
	out:    string,   // where the library goes, in the checkout
	symbol: string,   // what rust_eh_personality becomes in it
}

@(rodata) TEXT_LIB := Rust_Lib{name = "gt_text", crate = "native/text", out = "build/text", symbol = "gt_text_rust_eh_personality"}
@(rodata) A11Y_LIB := Rust_Lib{name = "gt_a11y", crate = "native/a11y", out = "build/a11y", symbol = "gt_a11y_rust_eh_personality"}

RUST_TARGET :: "x86_64-pc-windows-msvc"
// The hash of what a library is built from, beside it.
RUST_STAMP :: "STAMP"
// What the build steps are (a change to them builds the libraries again).
BUILD_STEPS_SOURCE :: #file
BYTES_PER_MB :: 1024 * 1024

// SHA-256 of tools/wgsl2hlsl/Cargo.lock (naga 29.0.4 and its dependencies): the HLSL the toolkit embeds comes from the translator
// that was reviewed. Update it with the lock file when naga is moved on purpose.
NAGA_LOCK_SHA256 :: "04ee5ed81addbb30903d1b79ce3b1080d810f2a8465ed37fe7842fc3eb8a06ad"
NAGA_CRATE :: "tools/wgsl2hlsl"
NAGA_OUT :: "build/naga"
NAGA_EXE :: "wgsl2hlsl.exe"
// The SHA-256 of the translator's sources, beside it.
NAGA_STAMP :: "wgsl2hlsl.sources"
NAGA_SOURCES := [?]string{"Cargo.toml", "Cargo.lock", "src/main.rs"}

// The stamp of a crate: the SHA-256 of its sources, Cargo.toml, Cargo.lock and `steps` (the file of the build steps), one after
// the other in the order of their paths. ok = false: one cannot be read.
rust_stamp :: proc(crate, steps: string) -> (stamp: string, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	w := os.walker_create_path(join({crate, "src"}))
	for fi in os.walker_walk(&w) { if fi.type != .Directory { append(&files, strings.clone(fi.fullpath, context.temp_allocator)) } }
	os.walker_destroy(&w)
	append(&files, join({crate, "Cargo.toml"}), join({crate, "Cargo.lock"}), steps)
	slice.sort(files[:])
	all := make([dynamic]byte, context.temp_allocator)
	for f in files {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil { return "", false }
		append(&all, ..data)
	}
	return sha256_hex(all[:]), true
}

// Builds a static library of native/ into <out>/<name>.lib, unless its stamp says it is up to date (`force`: always).
build_rust_lib :: proc(root: string, lib: Rust_Lib, force: bool) -> string {
	when ODIN_OS != .Windows {
		return "the static libraries are built here on Windows (Linux: tools/linux_ci.sh)"
	} else {
		crate, out := join({root, lib.crate}), join({root, lib.out})
		file := join({out, fmt.tprintf("%s.lib", lib.name)})
		stamp_file := join({out, RUST_STAMP})
		stamp, ok := rust_stamp(crate, BUILD_STEPS_SOURCE)
		if !ok { return fmt.tprintf("the sources of %s cannot be read", crate) }
		if !force && stamp_holds(file, stamp_file, stamp) {
			fmt.printfln("%s up to date in %s", lib.name, out)
			return ""
		}
		if _, found := capture({"cargo", "--version"}); !found { return "cargo not found: install Rust with rustup (stable, x86_64-pc-windows-msvc)" }

		target := join({out, "target"})
		began := time.tick_now()
		if !run({"cargo", "build", "--release", "--locked", "--lib", "--manifest-path", join({crate, "Cargo.toml"}), "--target-dir", target}) { return "cargo build failed" }
		_ = os.make_directory_all(out)
		if os.copy_file(file, join({target, "release", fmt.tprintf("%s.lib", lib.name)})) != nil { return fmt.tprintf("%s cannot be written", file) }

		sysroot, has_rustc := capture({"rustc", "--print", "sysroot"})
		if !has_rustc { return "rustc --print sysroot failed" }
		bin := join({strings.trim_space(sysroot), "lib", "rustlib", RUST_TARGET, "bin"})
		if !os.exists(join({bin, "llvm-objcopy.exe"})) && !run({"rustup", "component", "add", "llvm-tools"}) { return "rustup component add llvm-tools failed" }
		ar, objcopy := join({bin, "llvm-ar.exe"}), join({bin, "llvm-objcopy.exe"})
		work := join({out, "rename"})
		_ = os.remove_all(work)
		_ = os.make_directory_all(work)
		members, _ := capture({ar, "t", file})
		member := ""
		for m in strings.split_lines(members, context.temp_allocator) {
			name := strings.trim_space(m)
			if strings.has_prefix(name, fmt.tprintf("%s-", lib.name)) && strings.has_suffix(name, ".rcgu.o") { member = name; break }
		}
		if member == "" { return fmt.tprintf("%s.lib: the crate object was not found", lib.name) }
		if !run({ar, "x", file, member}, work) { return "llvm-ar x failed" }
		if !run({objcopy, fmt.tprintf("--redefine-sym=rust_eh_personality=%s", lib.symbol), member}, work) { return "llvm-objcopy failed" }
		if !run({ar, "r", file, member}, work) { return "llvm-ar failed" }
		_ = os.remove_all(work)
		if os.write_entire_file(stamp_file, stamp) != nil { return fmt.tprintf("%s cannot be written", stamp_file) }
		size: i64
		if fi, err := os.stat(file, context.temp_allocator); err == nil { size = fi.size }
		fmt.printfln("built %s (%.1f MB) in %.1f s", file, f64(size) / BYTES_PER_MB, time.duration_seconds(time.tick_since(began)))
		return ""
	}
}

// The stamp of the translator: the SHA-256 of each of its sources, in upper case, separated by commas. ok = false: one cannot be read.
naga_sources :: proc(crate: string) -> (stamp: string, ok: bool) {
	sums := make([dynamic]string, context.temp_allocator)
	for s in NAGA_SOURCES {
		sum := sha256_file(join({crate, s})) or_return
		append(&sums, strings.to_upper(sum, context.temp_allocator))
	}
	return strings.join(sums[:], ",", context.temp_allocator), true
}

// Builds tools/wgsl2hlsl into build/naga/wgsl2hlsl.exe when its sources changed; its Cargo.lock must be the pinned one.
build_naga :: proc(root: string) -> string {
	crate, out := join({root, NAGA_CRATE}), join({root, NAGA_OUT})
	exe, stamp_file := join({out, NAGA_EXE}), join({out, NAGA_STAMP})
	got, has_lock := sha256_file(join({crate, "Cargo.lock"}))
	if !has_lock { return "tools/wgsl2hlsl/Cargo.lock is missing" }
	if got != NAGA_LOCK_SHA256 {
		return fmt.tprintf("tools/wgsl2hlsl/Cargo.lock does not match the pinned SHA-256 (%s); review the change, then update NAGA_LOCK_SHA256 in tools/tk/native.odin", got)
	}
	sources, ok := naga_sources(crate)
	if !ok { return "the sources of tools/wgsl2hlsl cannot be read" }
	if stamp_holds(exe, stamp_file, sources) {
		fmt.printfln("naga: %s is up to date", exe)
		return ""
	}
	_ = os.make_directory_all(out)
	if !run({"cargo", "build", "--release", "--locked", "--target-dir", join({out, "target"})}, crate) { return "cargo build failed" }
	if os.copy_file(exe, join({out, "target", "release", NAGA_EXE})) != nil { return fmt.tprintf("%s cannot be written", exe) }
	if !write_stamp(stamp_file, sources) { return fmt.tprintf("%s cannot be written", stamp_file) }
	fmt.printfln("naga: built %s", exe)
	return ""
}
