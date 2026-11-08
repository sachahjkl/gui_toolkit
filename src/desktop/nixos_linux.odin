package tk_desktop

// NixOS: a release is linked for a usual Linux (the loader at /lib64/ld-linux-x86-64.so.2, its libraries in the
// system's folders). NixOS has neither, so the downloaded program only starts in an FHS sandbox (steam-run). The installed
// copy is made to run by itself:
//
//   <install>/nix-runtime    a link to a Nix profile of the loader and the libraries the program links and loads
//                            (`nix-build --out-link`: the link is a root of the garbage collector, so they stay)
//   <install>/<exe>          the copy, patched (patchelf) to use that loader and look in that profile first
//
// The menu entry and the link in ~/.local/bin then run the copy directly. The link is in the manifest: uninstalling
// removes it, and the next garbage collection frees the profile. A copy from the Nix store (a flake's package) already
// runs: it is never adapted (in_nix_store).
//
// What the program needs from the system is `Identity.nixos_libraries`, by nixpkgs attribute: what it links (glibc,
// libgcc_s as stdenv.cc.cc...) and what it opens with dlopen (Wayland, X11, Vulkan, EGL). patchelf comes with them.

import "core:os"
import "core:strings"

NIX_RUNTIME_NAME :: "nix-runtime"

// The Nix expression of the runtime profile. nixpkgs comes from NIX_PATH when it names one (the system's channel, or the
// flake that a flake-based system puts there), else from the flake registry.
nixos_runtime_expression :: proc(id: Identity, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "let\n")
	strings.write_string(&sb, "  nixpkgs = if builtins.any (e: e.prefix == \"nixpkgs\") builtins.nixPath then <nixpkgs> else (builtins.getFlake \"nixpkgs\").outPath;\n")
	strings.write_string(&sb, "  pkgs = import nixpkgs { };\n")
	strings.write_string(&sb, "in\npkgs.buildEnv {\n  name = \"")
	strings.write_string(&sb, id.nix_runtime_name)
	strings.write_string(&sb, "\";\n")
	strings.write_string(&sb, "  paths = map pkgs.lib.getLib (with pkgs; [")
	for name in id.nixos_libraries { strings.write_byte(&sb, ' '); strings.write_string(&sb, name) }
	strings.write_string(&sb, " ]) ++ [ pkgs.patchelf ];\n")
	strings.write_string(&sb, "  pathsToLink = [ \"/lib\" \"/bin\" ];\n}\n")
	return strings.to_string(sb)
}

// Makes the copy `dir`/`exe_name` run by itself on NixOS: builds the runtime profile (its link is added to `files`, the
// manifest's list) and patches the executable to it. Nothing on another system, for a copy of the Nix store, or for an
// identity without libraries.
nixos_adapt :: proc(id: Identity, dir, exe_name: string, files: ^[dynamic]string) -> Result {
	exe := join_path(dir, exe_name)
	if !is_nixos() || in_nix_store(exe) || len(id.nixos_libraries) == 0 { return {} }
	if !all_attributes({id.nix_runtime_name}) || !all_attributes(id.nixos_libraries) { return {.Bad_Options, "identity.nix_runtime_name or a library is not a Nix name"} }
	nix_build, found := find_on_path("nix-build")
	if !found { return {.System, "NixOS: nix-build is not on the PATH"} }
	runtime := join_path(dir, NIX_RUNTIME_NAME)
	if r := run_checked({nix_build, "--extra-experimental-features", "nix-command flakes", "--out-link", runtime, "-E", nixos_runtime_expression(id)}); r.error != .None { return r }
	append(files, NIX_RUNTIME_NAME)

	// patched on a copy that then takes the place of the executable: the running program's file cannot be written
	patched := strings.concatenate({exe, ".patch"}, context.temp_allocator)
	_ = os.remove(patched)
	if err := os.copy_file(patched, exe); err != nil { return {.Io, strings.concatenate({"cannot copy ", exe}, context.temp_allocator)} }
	_ = os.chmod(patched, os.perm_number(0o755))   // (a copy of a program from the Nix store is read-only)
	lib := join_path(runtime, "lib")
	patchelf := join_path(runtime, "bin/patchelf")
	// the runtime's folder first: its libc must be the one of its loader. Then the program's own search path (the release's
	// is $ORIGIN), unless an earlier install put the runtime there already.
	state, out, _, perr := os.process_exec(os.Process_Desc{command = {patchelf, "--print-rpath", patched}}, context.temp_allocator)
	rpath := lib
	if perr == nil && state.success {
		if old := strings.trim_space(string(out)); old != "" {
			rpath = strings.has_prefix(old, lib) ? old : strings.concatenate({lib, ":", old}, context.temp_allocator)
		}
	}
	r := run_checked({patchelf, "--set-interpreter", join_path(lib, "ld-linux-x86-64.so.2"), "--set-rpath", rpath, patched})
	if r.error == .None && os.rename(patched, exe) != nil { r = {.Io, strings.concatenate({"cannot replace ", exe}, context.temp_allocator)} }
	if r.error != .None { _ = os.remove(patched) }
	return r
}

// Runs `command` and waits; a failure carries the end of what it wrote on stderr.
@(private = "file")
run_checked :: proc(command: []string) -> Result {
	state, _, stderr, err := os.process_exec(os.Process_Desc{command = command}, context.temp_allocator)
	if err == nil && state.success { return {} }
	said := strings.trim_space(string(stderr))
	if len(said) > 400 { said = said[len(said) - 400:] }
	return {.System, strings.concatenate({"NixOS: ", command[0], " failed: ", said}, context.temp_allocator)}
}

// The names go into a Nix expression: attribute paths only (letters, digits, '-', '_', '.'), nothing that could end it.
@(private = "file")
all_attributes :: proc(names: []string) -> bool {
	for n in names {
		if n == "" { return false }
		for i in 0 ..< len(n) {
			c := n[i]
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') { return false }
		}
	}
	return true
}
