// Package toolbox: what the tools of a project share (tk, ocntools, Wren's tooling), not the programs they build. A command run with
// its output shown or captured, the environment of a child, the SHA-256 of bytes and files, and a download pinned by SHA-256.
// (Named tk_toolbox: a program may have a `toolbox` package of its own.)
//
//	run              a command, its output shown (or appended to a log); its folder, its environment, a time limit
//	capture          a command's standard output and exit code; its standard error shown when it fails
//	env_with         this process's environment without some names and with some "NAME=value"
//	exit_code        the exit code of a finished process, as the program gave it (also on Windows)
//	succeeded        a finished process exited with 0
//	sha256_hex       the SHA-256 of bytes, 64 lower-case hex digits
//	sha256_file      the same of a file
//	download_pinned  a file kept when its SHA-256 is the pinned one, else downloaded (curl) and checked
//	start_group      (Linux) a command in a process group of its own; stop_group stops all of that group
//	system_program   a program of the system (curl, tar) by its full path on Windows, by its name elsewhere
//	write_logo       the files of a program's logo, from its drawing: PNG sizes, the .ico, the project's picture
//	write_version_header  the C header of a version of three numbers, for a Windows executable's VERSIONINFO
//	exe_has_icon     (Windows) a Windows executable carries its icon (group 1)
//	update_command   the update command of a project's tool: keygen, pubkey, the signed manifest of a release, verify
//	crash_symbolize  a crash report's frames named from the build's map or executable (crash_symbolize.odin)
//	tool_main        a project's tool: its commands (Command), the help, the exit codes, the line PowerShell splits joined
//	Project          a program's project: odin_command, build_native, build_launcher, check_launcher, check_windows; its
//	                 Features (feature_defines, native_crates)
//	font_subset      a TrueType font with only the glyphs of some characters; lucide_subset: a program's Lucide icons
//	version_of       the version of the sources after its line's start; version_set writes it
//	build_c_lib      a static C library, built again when the stamp of its sources and flags changes (stamp_holds)
//	check_scopes     the ui package's scopes opened under a negation, which end them at once
//	third_party_notices  THIRD-PARTY-NOTICES: the licences of the toolkit, Odin, wgpu-native and the linked crates
//	sway_start       (Linux) a desktop nobody sees, for live tests and pictures; sway_program, sway_stop
package tk_toolbox

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../ascii"

// How a command runs. The zero value: in this process's folder and environment, its output on this process's, no time limit.
Run :: struct {
	dir:   string,          // its working directory; "": this process's
	env:   []string,        // its whole environment ("NAME=value", env_with makes one); nil: this process's
	log:   string,          // "": its output on this process's; else its standard output and error appended to this file
	limit: time.Duration,   // 0: none; past it the process is killed and the run fails
	echo:  bool,            // "> command" printed first (on the log when there is one)
}

// Runs a command and waits for it. True when it started and exited with 0.
run :: proc(command: []string, how := Run{}) -> bool {
	if len(command) == 0 { return false }
	if how.echo { say(how.log, fmt.tprintfln("> %s", strings.join(command, " ", context.temp_allocator))) }
	desc := os.Process_Desc{command = command, working_dir = how.dir, env = how.env}
	log: ^os.File
	if how.log != "" {
		err: os.Error
		log, err = os.open(how.log, {.Write, .Create, .Append, .Inheritable})   // (Windows: a handle the child does not inherit is no output for it)
		if err != nil {
			fmt.eprintfln("%s: %v", how.log, err)
			return false
		}
		desc.stdout, desc.stderr = log, log
	} else {
		desc.stdin, desc.stdout, desc.stderr = os.stdin, os.stdout, os.stderr
	}
	defer if log != nil { os.close(log) }
	p, err := os.process_start(desc)
	if err != nil {
		say_error(how.log, fmt.tprintfln("%s cannot start: %v", command[0], err))
		return false
	}
	state, wait_err := os.process_wait(p, how.limit > 0 ? how.limit : os.TIMEOUT_INFINITE)
	if wait_err == os.General_Error.Timeout {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
		say_error(how.log, fmt.tprintfln("%s: stopped after %v", command[0], how.limit))
		return false
	}
	if wait_err != nil {
		say_error(how.log, fmt.tprintfln("%s: %v", command[0], wait_err))
		return false
	}
	return succeeded(state)
}

// Runs a command and returns its standard output and its exit code (-1: it did not start or did not exit). When it fails, its
// standard error is shown on this process's. `how.dir` and `how.env` apply; its output is the result, so `how.log` and `how.echo`
// do not.
capture :: proc(command: []string, how := Run{}, allocator := context.temp_allocator) -> (out: string, code: int) {
	if len(command) == 0 { return "", -1 }
	state, stdout, stderr, err := os.process_exec({command = command, working_dir = how.dir, env = how.env}, allocator)
	defer delete(stderr, allocator)
	if err != nil {
		delete(stdout, allocator)
		return "", -1
	}
	if !succeeded(state) && len(stderr) > 0 { fmt.eprint(string(stderr)) }
	return string(stdout), exit_code(state)
}

// The exit code of a finished process; -1 when it did not exit. Windows gives it as an unsigned number: it is read back as the
// program's 32-bit int (`exit(-1)` is -1, a crash's NTSTATUS is negative).
exit_code :: proc(state: os.Process_State) -> int {
	if !state.exited { return -1 }
	when ODIN_OS == .Windows {
		return int(i32(u32(state.exit_code)))
	} else {
		return state.exit_code
	}
}

// The process exited with 0. (Process_State.success only says it did not crash, and on Windows it is always true.)
succeeded :: proc(state: os.Process_State) -> bool { return state.exited && state.exit_code == 0 }

// This process's environment without the variables named in `without` nor those that `extra` sets, then `extra` ("NAME=value").
// Names compare by ASCII case on Windows, exactly elsewhere. In the frame's allocator; nil when the environment cannot be read.
env_with :: proc(without: []string, extra: ..string) -> []string {
	all, err := os.environ(context.temp_allocator)
	if err != nil { return nil }
	return env_merge(all, without, extra)
}

// `all` without the variables named in `without` nor those that `extra` sets, then `extra`. In the frame's allocator.
@(private)
env_merge :: proc(all, without, extra: []string) -> []string {
	out := make([dynamic]string, 0, len(all) + len(extra), context.temp_allocator)
	next: for e in all {
		name := env_name(e)
		if name == "" { append(&out, e); continue }   // (Windows' per-drive entries, "=C:=C:\...", have no name to match)
		for w in without { if env_name_equal(name, w) { continue next } }
		for x in extra { if env_name_equal(name, env_name(x)) { continue next } }
		append(&out, e)
	}
	append(&out, ..extra)
	return out[:]
}

// The name of "NAME=value". An entry that starts with '=' has none.
@(private)
env_name :: proc(entry: string) -> string {
	i := strings.index_byte(entry, '=')
	return i > 0 ? entry[:i] : i < 0 ? entry : ""
}

@(private)
env_name_equal :: proc(a, b: string) -> bool {
	return ODIN_OS == .Windows ? ascii.equal_fold(a, b) : a == b
}

// The SHA-256 of `data`: 64 lower-case hex digits.
sha256_hex :: proc(data: []byte, allocator := context.temp_allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, digest[:])
	return string(hex.encode(digest[:], allocator))
}

// The SHA-256 of a file: 64 lower-case hex digits. ok = false: it cannot be read.
sha256_file :: proc(path: string, allocator := context.temp_allocator) -> (sum: string, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return "", false }
	defer delete(data)
	return sha256_hex(data, allocator), true
}

// A line where a run's output goes: the log when there is one, else the standard output.
@(private)
say :: proc(log, text: string) {
	if log == "" { fmt.print(text); return }
	append_text(log, text)
}

// The same, for what went wrong: on the standard error when there is no log.
@(private)
say_error :: proc(log, text: string) {
	if log == "" { fmt.eprint(text); return }
	append_text(log, text)
}

@(private)
append_text :: proc(path, text: string) {
	f, err := os.open(path, {.Write, .Create, .Append})
	if err != nil { return }
	defer os.close(f)
	_, _ = os.write_string(f, text)
}
