// The Rust parts, built with cargo: the static libraries of native/ (the text backend, the AccessKit adapter) and the WGSL to HLSL
// translator. Every crate is pinned by exact version in its Cargo.toml and by SHA-256 in its Cargo.lock (--locked); the stable
// toolchain of rustup (x86_64-pc-windows-msvc).
package tk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../../src/ascii"
import toolbox "../../src/toolbox"
@(require) import "core:time"   // (the build's timing is Windows')

// The toolkit's native library, native/gt: the parts asked (its cargo features: text, mermaid, a11y) in one static library
// with one copy of Rust's standard library. An application may link other Rust static libraries (Wren: its image decoders,
// Wasmtime); each carries its own standard library and all define the unmangled rust_eh_personality, so ours is renamed in
// the object that defines it (with fat LTO, the crate's single object) and they link together.
NATIVE_NAME :: "gt_native"
NATIVE_CRATE :: "native/gt"
NATIVE_OUT :: "build/native"
NATIVE_SYMBOL :: "gt_native_rust_eh_personality"
// The crates it is made of: a change in any builds it again.
@(rodata) NATIVE_CRATES := [?]string{"native/gt", "native/text", "native/mermaid", "native/a11y"}
// Its parts, each a cargo feature; a11y is AccessKit's Windows adapter.
@(rodata) NATIVE_FEATURES := [?]string{"text", "mermaid", "a11y"}
// What `build_native` builds when no feature is named: every part this system has.
NATIVE_DEFAULT :: "text,mermaid,a11y" when ODIN_OS == .Windows else "text,mermaid"

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

// The stamp of crates: the SHA-256 of their sources, Cargo.toml and Cargo.lock, of `steps` (the file of the build steps) and of
// `extra` (the features asked), one after the other in the order of their paths. ok = false: one cannot be read.
rust_stamp :: proc(crates: []string, steps: string, extra := "") -> (stamp: string, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	for crate in crates {
		w := os.walker_create_path(join({crate, "src"}))
		for fi in os.walker_walk(&w) { if fi.type != .Directory { append(&files, strings.clone(fi.fullpath, context.temp_allocator)) } }
		os.walker_destroy(&w)
		append(&files, join({crate, "Cargo.toml"}), join({crate, "Cargo.lock"}))
	}
	append(&files, steps)
	slice.sort(files[:])
	all := make([dynamic]byte, context.temp_allocator)
	for f in files {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil { return "", false }
		append(&all, ..data)
	}
	append(&all, ..transmute([]byte)extra)
	return toolbox.sha256_hex(all[:]), true
}

// The features of a `-features:` value ("text,mermaid"), each one of NATIVE_FEATURES, in their order; why not.
native_features :: proc(text: string) -> (features: []string, why: string) {
	out := make([dynamic]string, context.temp_allocator)
	asked := strings.split(text, ",", context.temp_allocator)
	for a in asked {
		f := strings.trim_space(a)
		if f == "" { continue }
		if !slice.contains(NATIVE_FEATURES[:], f) { return nil, fmt.tprintf("no part %q of the native library (%s)", f, strings.join(NATIVE_FEATURES[:], ", ", context.temp_allocator)) }
	}
	for f in NATIVE_FEATURES { for a in asked { if strings.trim_space(a) == f { append(&out, f); break } } }
	if len(out) == 0 { return nil, "no part of the native library asked" }
	return out[:], ""
}

// The native library with every part of this system (NATIVE_DEFAULT): what the toolkit's examples, tests and CI link.
build_native_default :: proc(root: string) -> string {
	features, why := native_features(NATIVE_DEFAULT)
	if why != "" { return why }
	return build_native_lib(root, features, false)
}

// Builds native/gt with `features` into build/native/gt_native.lib (Windows) or build/native/libgt_native.a (elsewhere), unless
// its stamp says it is up to date (`force`: always). On Linux the symbol is not renamed: the programs link with
// --allow-multiple-definition (wgpu-native brings its own standard library too).
build_native_lib :: proc(root: string, features: []string, force: bool) -> string {
	crates := make([dynamic]string, context.temp_allocator)
	for c in NATIVE_CRATES { append(&crates, join({root, c})) }
	crate, out := join({root, NATIVE_CRATE}), join({root, NATIVE_OUT})
	asked := strings.join(features, ",", context.temp_allocator)
	stamp, ok := rust_stamp(crates[:], BUILD_STEPS_SOURCE, asked)
	if !ok { return fmt.tprintf("the sources of %s cannot be read", crate) }
	stamp_file := join({out, RUST_STAMP})
	cargo := []string{"cargo", "build", "--release", "--locked", "--lib", "--manifest-path", join({crate, "Cargo.toml"}), "--target-dir", join({out, "target"}), "--no-default-features", "--features", asked}
	when ODIN_OS != .Windows {
		name := fmt.tprintf("lib%s.a", NATIVE_NAME)
		file := join({out, name})
		if !force && toolbox.stamp_holds(file, stamp_file, stamp) {
			fmt.printfln("%s (%s) up to date in %s", NATIVE_NAME, asked, out)
			return ""
		}
		if !toolbox.run(cargo) { return "cargo build failed" }
		_ = os.make_directory_all(out)
		if os.copy_file(file, join({out, "target", "release", name})) != nil { return fmt.tprintf("%s cannot be written", file) }
		if !toolbox.write_stamp(stamp_file, stamp) { return fmt.tprintf("%s cannot be written", stamp_file) }
		fmt.printfln("built %s (%s)", file, asked)
		return ""
	} else {
		file := join({out, fmt.tprintf("%s.lib", NATIVE_NAME)})
		if !force && toolbox.stamp_holds(file, stamp_file, stamp) {
			fmt.printfln("%s (%s) up to date in %s", NATIVE_NAME, asked, out)
			return ""
		}
		if _, code := toolbox.capture({"cargo", "--version"}); code != 0 { return "cargo not found: install Rust with rustup (stable, x86_64-pc-windows-msvc)" }

		target := join({out, "target"})
		began := time.tick_now()
		if !toolbox.run(cargo) { return "cargo build failed" }
		_ = os.make_directory_all(out)
		if os.copy_file(file, join({target, "release", fmt.tprintf("%s.lib", NATIVE_NAME)})) != nil { return fmt.tprintf("%s cannot be written", file) }

		sysroot, rustc_code := toolbox.capture({"rustc", "--print", "sysroot"})
		if rustc_code != 0 { return "rustc --print sysroot failed" }
		bin := join({strings.trim_space(sysroot), "lib", "rustlib", RUST_TARGET, "bin"})
		if !os.exists(join({bin, "llvm-objcopy.exe"})) && !toolbox.run({"rustup", "component", "add", "llvm-tools"}) { return "rustup component add llvm-tools failed" }
		ar, objcopy := join({bin, "llvm-ar.exe"}), join({bin, "llvm-objcopy.exe"})
		work := join({out, "rename"})
		_ = os.remove_all(work)
		_ = os.make_directory_all(work)
		members, _ := toolbox.capture({ar, "t", file})
		member := ""
		for m in strings.split_lines(members, context.temp_allocator) {
			name := strings.trim_space(m)
			if strings.has_prefix(name, fmt.tprintf("%s-", NATIVE_NAME)) && strings.has_suffix(name, ".rcgu.o") { member = name; break }
		}
		if member == "" { return fmt.tprintf("%s.lib: the crate object was not found", NATIVE_NAME) }
		if !toolbox.run({ar, "x", file, member}, {dir = work}) { return "llvm-ar x failed" }
		if !toolbox.run({objcopy, fmt.tprintf("--redefine-sym=rust_eh_personality=%s", NATIVE_SYMBOL), member}, {dir = work}) { return "llvm-objcopy failed" }
		if !toolbox.run({ar, "r", file, member}, {dir = work}) { return "llvm-ar failed" }
		_ = os.remove_all(work)
		if os.write_entire_file(stamp_file, stamp) != nil { return fmt.tprintf("%s cannot be written", stamp_file) }
		size: i64
		if fi, err := os.stat(file, context.temp_allocator); err == nil { size = fi.size }
		fmt.printfln("built %s (%.1f MB) in %.1f s", file, f64(size) / BYTES_PER_MB, time.duration_seconds(time.tick_since(began)))
		return ""
	}
}

// libwebp for Windows: native/webp's DLL (libwebp's and sharpyuv's C sources, built by libwebp-sys with the target's
// compiler), which src/image/webp_windows.odin loads beside the program -> build/webp/gt_webp.dll; elsewhere the crate's
// shared library (libgt_webp.so: Linux loads the system's libwebp, this one is built for the crate's test alone). Rebuilt
// when build/webp/STAMP is not the hash of the crate's sources, Cargo.lock and these steps.
WEBP_CRATE :: "native/webp"
WEBP_OUT :: "build/webp"
WEBP_FILE :: "gt_webp.dll" when ODIN_OS == .Windows else "libgt_webp.so"

build_webp :: proc(root: string, force: bool) -> string {
	crate, out := join({root, WEBP_CRATE}), join({root, WEBP_OUT})
	file, stamp_file := join({out, WEBP_FILE}), join({out, RUST_STAMP})
	stamp, ok := rust_stamp({crate}, BUILD_STEPS_SOURCE)
	if !ok { return fmt.tprintf("the sources of %s cannot be read", crate) }
	if !force && toolbox.stamp_holds(file, stamp_file, stamp) {
		fmt.printfln("gt_webp up to date in %s", out)
		return ""
	}
	if _, code := toolbox.capture({"cargo", "--version"}); code != 0 { return "cargo not found: install Rust with rustup (stable)" }
	target := join({out, "target"})
	if !toolbox.run({"cargo", "build", "--release", "--locked", "--lib", "--manifest-path", join({crate, "Cargo.toml"}), "--target-dir", target}) { return "cargo build failed" }
	_ = os.make_directory_all(out)
	if os.copy_file(file, join({target, "release", WEBP_FILE})) != nil { return fmt.tprintf("%s cannot be written", file) }
	if !toolbox.write_stamp(stamp_file, stamp) { return fmt.tprintf("%s cannot be written", stamp_file) }
	fmt.printfln("built %s", file)
	return ""
}

// The stamp of the translator: the SHA-256 of each of its sources, in upper case, separated by commas. ok = false: one cannot be read.
naga_sources :: proc(crate: string) -> (stamp: string, ok: bool) {
	sums := make([dynamic]string, context.temp_allocator)
	for s in NAGA_SOURCES {
		sum := toolbox.sha256_file(join({crate, s})) or_return
		append(&sums, ascii.upper(sum))
	}
	return strings.join(sums[:], ",", context.temp_allocator), true
}

// Builds tools/wgsl2hlsl into build/naga/wgsl2hlsl.exe when its sources changed; its Cargo.lock must be the pinned one.
build_naga :: proc(root: string) -> string {
	crate, out := join({root, NAGA_CRATE}), join({root, NAGA_OUT})
	exe, stamp_file := join({out, NAGA_EXE}), join({out, NAGA_STAMP})
	got, has_lock := toolbox.sha256_file(join({crate, "Cargo.lock"}))
	if !has_lock { return "tools/wgsl2hlsl/Cargo.lock is missing" }
	if got != NAGA_LOCK_SHA256 {
		return fmt.tprintf("tools/wgsl2hlsl/Cargo.lock does not match the pinned SHA-256 (%s); review the change, then update NAGA_LOCK_SHA256 in tools/tk/native.odin", got)
	}
	sources, ok := naga_sources(crate)
	if !ok { return "the sources of tools/wgsl2hlsl cannot be read" }
	if toolbox.stamp_holds(exe, stamp_file, sources) {
		fmt.printfln("naga: %s is up to date", exe)
		return ""
	}
	_ = os.make_directory_all(out)
	if !toolbox.run({"cargo", "build", "--release", "--locked", "--target-dir", join({out, "target"})}, {dir = crate}) { return "cargo build failed" }
	if os.copy_file(exe, join({out, "target", "release", NAGA_EXE})) != nil { return fmt.tprintf("%s cannot be written", exe) }
	if !toolbox.write_stamp(stamp_file, sources) { return fmt.tprintf("%s cannot be written", stamp_file) }
	fmt.printfln("naga: built %s", exe)
	return ""
}
