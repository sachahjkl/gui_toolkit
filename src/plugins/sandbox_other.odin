#+build !linux
package tk_plugins

// A plugin's process on a system with no sandbox written yet (plugins.md, "As built: the sandbox"): it runs with the
// person's rights, as the program does, and its log says so once. Windows' sandbox will be the parent's to give (an
// AppContainer or a restricted token, set when the process is made): sandbox_spawn is where it goes; sandbox_enter
// is the child's part, nothing here.

import "core:os"
import "../fsx"

@(private)
sandbox_spawn :: proc(exe: string, stdin, stdout: ^os.File) -> (os.Process, os.Error) {
	return os.process_start({command = {exe, CHILD_ARG}, stdin = stdin, stdout = stdout, stderr = os.stderr})
}

// Whether this system can isolate a plugin's process, and why not.
sandbox_available :: proc() -> (ok: bool, why: string) {
	return false, "this system has no sandbox for a plugin's process yet"
}

@(private)
sandbox_enter :: proc(mode: Sandbox_Mode) -> (isolated: bool, said: string) {
	if mode == .Off { return false, "not isolated: the program turned its sandbox off (Host_Options.sandbox)" }
	return false, "not isolated: this system has no sandbox for a plugin's process yet"
}

// What test_escape tries: here nothing stops it (the files only: a socket would need the network's package).
@(private)
escape_try :: proc(read_path, create_dir: string) -> (read, create, socket: bool) {
	_, read = fsx.read_all(read_path, context.temp_allocator, 1 << 20)
	path := fsx.path_join(create_dir, "escape.txt")
	if fsx.write_atomic(path, {}) {
		create = true
		_ = fsx.delete_file(path)
	}
	return
}
