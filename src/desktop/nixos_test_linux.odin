package tk_desktop

// NixOS: the installed copy runs by itself (nixos_linux.odin). The last test builds the runtime with Nix and runs a
// patched copy: it runs on NixOS only.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
os_release_names_nixos :: proc(t: ^testing.T) {
	testing.expect(t, os_release_is_nixos("NAME=NixOS\nID=nixos\nVERSION_ID=\"26.05\"\n"))
	testing.expect(t, os_release_is_nixos("ID=\"nixos\"\n"))
	testing.expect(t, !os_release_is_nixos("NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n"))
	testing.expect(t, !os_release_is_nixos("ID_LIKE=nixos\nID=other\n"))
	testing.expect(t, !os_release_is_nixos(""))
	testing.expect(t, in_nix_store("/nix/store/abc-sample-0.6.32/lib/sample/sample"))
	testing.expect(t, !in_nix_store("/home/u/.local/share/sample/sample"))
}

@(test)
nixos_runtime_is_the_identitys :: proc(t: ^testing.T) {
	id := test_identity()
	e := nixos_runtime_expression(id)
	testing.expect(t, strings.contains(e, "name = \"sample-runtime\";"), e)
	testing.expect(t, strings.contains(e, "(with pkgs; [ glibc stdenv.cc.cc ])"), e)
	// a name that would end the expression is refused before Nix runs (on NixOS; elsewhere nothing is adapted)
	if is_nixos() {
		id.nix_runtime_name = "x\"; builtins.abort \"y"
		files := make([dynamic]string, context.temp_allocator)
		testing.expect_value(t, nixos_adapt(id, "/tmp/tk-desktop-not-made", "sample", &files).error, Error.Bad_Options)
	}
}

// Day one on NixOS: the installed copy starts from the menu, without steam-run. A program of the system stands for the
// program (its loader is moved to the runtime's like a release's); it must run after the install and leave nothing after removal. The
// system's own: the runtime comes from the system's nixpkgs, so its glibc is the one this program was built with.
@(test)
nixos_installed_copy_runs_by_itself :: proc(t: ^testing.T) {
	if !is_nixos() { return }
	program := "/run/current-system/sw/bin/bash"   // (not coreutils: it picks its program by its name)
	if !testing.expect(t, os.is_file(program), "the system has bash") { return }
	tr := tree_make()
	defer tree_destroy(&tr)
	src := fmt.tprintf("%s/sample", tr.src)
	if !testing.expect(t, os.copy_file(src, program) == nil, "copy true") { return }
	tr.opts.identity.exe_name = "sample"
	plan := Install_Plan{identity = tr.opts.identity, src_exe = src, dir = tr.dst, exe_name = "sample", version = "0.3.0", channel = "release", adapt = true}
	r := files_install(plan)
	if !testing.expectf(t, r.error == .None, "%v: %s", r.error, r.detail) { return }

	exe := fmt.tprintf("%s/sample", tr.dst)
	runtime := fmt.tprintf("%s/%s", tr.dst, NIX_RUNTIME_NAME)
	state, _, said, err := os.process_exec(os.Process_Desc{command = {exe, "-c", "exit 0"}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.success, "the patched copy runs: %v %s", err, said)
	_, interp, _, _ := os.process_exec(os.Process_Desc{command = {fmt.tprintf("%s/bin/patchelf", runtime), "--print-interpreter", exe}}, context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(interp)), fmt.tprintf("%s/lib/ld-linux-x86-64.so.2", runtime))
	// what the identity's libraries give (glibc, stdenv.cc.cc)
	for so in ([]string{"libc.so.6", "libm.so.6", "libgcc_s.so.1"}) {
		testing.expectf(t, os.exists(fmt.tprintf("%s/lib/%s", runtime, so)), "the runtime has %s", so)
	}
	info := installed_info(&tr.opts, tr.dst, context.temp_allocator)
	testing.expect_value(t, info.missing, 0)
	testing.expect(t, strings.contains(read_text(fmt.tprintf("%s/%s", tr.dst, tr.opts.identity.manifest_name)), "file=" + NIX_RUNTIME_NAME + "\n"))

	rm := files_remove(&tr.opts, tr.dst)
	testing.expect_value(t, rm.result.error, Error.None)
	testing.expect(t, rm.folder, "the install folder is gone, the runtime's link with it")
}

@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}
