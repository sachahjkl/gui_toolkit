#+build linux
package platform

// File dialogs and shell actions on Linux (dialogs.odin has the API and the pure filter logic). The brief's first
// choice is the FileChooser portal (org.freedesktop.portal.FileChooser over D-Bus), which works under a sandbox and
// matches the user's desktop; writing a D-Bus client in Odin is a sizeable piece, so this ships the robust fallback the
// portal degrades to anyway — zenity (GNOME) or kdialog (KDE) spawned as a child, its chosen paths read from its
// stdout. open_url / open_path / reveal_in_folder go through xdg-open (and the file manager for "reveal"), the portal's
// OpenURI being the same idea. The portal path is the noted next step; the spawn path needs no D-Bus.
//
// A dialog blocks until the user closes it: call it from a worker of the app's blocking pool, never from the frame loop
// (dialogs.odin says so). The child's stdout is captured through a pipe with posix_spawn file actions.

import "base:runtime"
import "core:strings"
import "core:sys/posix"

open_file_dialog :: proc(d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	if dialog_test_hook != nil { return dialog_test_hook(0, d, allocator) }
	return file_dialog_spawn(0, d, allocator)
}

save_file_dialog :: proc(d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	if dialog_test_hook != nil { return dialog_test_hook(1, d, allocator) }
	return file_dialog_spawn(1, d, allocator)
}

pick_folder_dialog :: proc(d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	if dialog_test_hook != nil { return dialog_test_hook(2, d, allocator) }
	return file_dialog_spawn(2, d, allocator)
}

// The XDG user directories: $XDG_<NAME>_DIR (user-dirs.dirs), else $HOME/<Name>.
known_folder_path :: proc(k: Known_Folder, allocator := context.allocator) -> string {
	home := ""
	if h := posix.getenv("HOME"); h != nil { home = string(h) }
	sub := ""
	switch k {
	case .None:      return strings.clone(home, allocator)
	case .Home:      return strings.clone(home, allocator)
	case .Desktop:   sub = "Desktop"
	case .Documents: sub = "Documents"
	case .Downloads: sub = "Downloads"
	case .Music:     sub = "Music"
	case .Pictures:  sub = "Pictures"
	case .Videos:    sub = "Videos"
	}
	if home == "" { return "" }
	return strings.concatenate({home, "/", sub}, allocator)
}

open_url :: proc(url: string) -> bool {
	if portal_open_uri(url) { return true }   // the portal (OpenURI) first; xdg-open otherwise
	return spawn_detached({"xdg-open", url})
}
open_path :: proc(path: string) -> bool {
	uri := strings.concatenate({"file://", path}, context.temp_allocator)
	if portal_open_uri(uri) { return true }
	return spawn_detached({"xdg-open", path})
}

// Reveal a file in the file manager with it selected: the GTK file managers answer the D-Bus
// org.freedesktop.FileManager1.ShowItems; without a D-Bus client here, open the containing folder (xdg-open on the
// parent), which every desktop handles. Selecting the item itself is the portal's job, noted for later.
reveal_in_folder :: proc(path: string) -> bool {
	dir := path
	if i := strings.last_index_byte(path, '/'); i > 0 { dir = path[:i] }
	return spawn_detached({"xdg-open", dir})
}

////////////////////////////////
// zenity / kdialog

@(private)
file_dialog_spawn :: proc(kind: int, d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	// the portal first (it works under a sandbox and matches the desktop); zenity / kdialog when it is absent
	if r := portal_file_dialog(kind, d, allocator); r.status != .Unsupported { return r }
	if have_program("zenity") { return zenity_dialog(kind, d, allocator) }
	if have_program("kdialog") { return kdialog_dialog(kind, d, allocator) }
	return {status = .Unsupported}
}

@(private)
zenity_dialog :: proc(kind: int, d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "zenity", "--file-selection")
	if d.title != "" { append(&args, strings.concatenate({"--title=", d.title}, context.temp_allocator)) }
	switch kind {
	case 1: append(&args, "--save"); if d.overwrite_prompt { append(&args, "--confirm-overwrite") }
	case 2: append(&args, "--directory")
	}
	if kind == 0 && d.multiple { append(&args, "--multiple", "--separator=\n") }
	start := dialog_start_dir(d)
	if start != "" {
		name := kind == 1 && d.suggested_name != "" ? d.suggested_name : ""
		fn := name != "" ? strings.concatenate({start, "/", name}, context.temp_allocator) : start
		append(&args, strings.concatenate({"--filename=", fn}, context.temp_allocator))
	}
	for f in d.filters {
		pats := filter_patterns(f, context.temp_allocator)
		// zenity: --file-filter="Name | *.png *.jpg"
		spaced, _ := strings.replace_all(pats, ";", " ", context.temp_allocator)
		append(&args, strings.concatenate({"--file-filter=", f.name, " | ", spaced}, context.temp_allocator))
	}
	if d.all_files { append(&args, "--file-filter=All files | *") }
	out, code := run_capture(args[:])
	return parse_dialog_output(out, code, d.filter_index, allocator)
}

@(private)
kdialog_dialog :: proc(kind: int, d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "kdialog")
	start := dialog_start_dir(d)
	if start == "" { start = "." }
	filt := kdialog_filter(d)
	switch kind {
	case 0:
		append(&args, d.multiple ? "--getopenfilename" : "--getopenfilename", start, filt)
		if d.multiple { append(&args, "--multiple", "--separate-output") }
	case 1:
		name := d.suggested_name != "" ? strings.concatenate({start, "/", d.suggested_name}, context.temp_allocator) : start
		append(&args, "--getsavefilename", name, filt)
	case 2:
		append(&args, "--getexistingdirectory", start)
	}
	if d.title != "" { append(&args, "--title", d.title) }
	out, code := run_capture(args[:])
	return parse_dialog_output(out, code, d.filter_index, allocator)
}

@(private)
kdialog_filter :: proc(d: File_Dialog) -> string {
	if len(d.filters) == 0 { return "*" }
	b := strings.builder_make(context.temp_allocator)
	for f, i in d.filters {
		if i > 0 { strings.write_byte(&b, '\n') }
		pats := filter_patterns(f, context.temp_allocator)
		spaced, _ := strings.replace_all(pats, ";", " ", context.temp_allocator)
		strings.write_string(&b, spaced)
		strings.write_byte(&b, '|')
		strings.write_string(&b, f.name)
	}
	return strings.to_string(b)
}

@(private)
dialog_start_dir :: proc(d: File_Dialog) -> string {
	if d.start_dir != "" { return d.start_dir }
	if d.start_known != .None { return known_folder_path(d.start_known, context.temp_allocator) }
	return ""
}

@(private)
parse_dialog_output :: proc(out: string, code: int, filter_index: int, allocator: runtime.Allocator) -> Dialog_Result {
	if code != 0 { return {status = .Cancelled} }
	trimmed := strings.trim_space(out)
	if trimmed == "" { return {status = .Cancelled} }
	lines := strings.split(trimmed, "\n", context.temp_allocator)
	paths := make([dynamic]string, allocator)
	for l in lines {
		s := strings.trim_space(l)
		if s != "" { append(&paths, strings.clone(s, allocator)) }
	}
	if len(paths) == 0 { return {status = .Cancelled} }
	return {status = .Chosen, paths = paths[:], filter = filter_index}
}

////////////////////////////////
// spawning

@(private)
have_program :: proc(name: string) -> bool {
	path := posix.getenv("PATH")
	if path == nil { return false }
	rest := string(path)
	for dir in strings.split_iterator(&rest, ":") {
		if dir == "" { continue }
		full := strings.concatenate({dir, "/", name}, context.temp_allocator)
		c := strings.clone_to_cstring(full, context.temp_allocator)
		if posix.access(c, posix.Mode_Flags{.X_OK}) == .OK { return true }
	}
	return false
}

// Starts args[0] detached (fire and forget: xdg-open), returning whether the spawn itself succeeded.
@(private)
spawn_detached :: proc(args: []string) -> bool {
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	child: posix.pid_t
	if posix.posix_spawnp(&child, argv[0], nil, nil, raw_data(argv), posix.environ) != .NONE { return false }
	// reap without blocking later: detach by waiting non-blocking once (xdg-open forks and exits fast)
	st: i32
	posix.waitpid(child, &st, {.NOHANG})
	return true
}

// The posix_spawn file-action helpers core:sys/posix does not wrap. The actions object is opaque; a byte buffer large
// enough for glibc / musl stands in (both are well under 128 bytes).
@(private) Spawn_File_Actions :: struct { _: [128]u8 }
foreign import spawnlib "system:c"
@(default_calling_convention = "c", private)
foreign spawnlib {
	posix_spawn_file_actions_init    :: proc(fa: ^Spawn_File_Actions) -> i32 ---
	posix_spawn_file_actions_destroy :: proc(fa: ^Spawn_File_Actions) -> i32 ---
	posix_spawn_file_actions_adddup2 :: proc(fa: ^Spawn_File_Actions, fd, newfd: i32) -> i32 ---
	posix_spawn_file_actions_addclose:: proc(fa: ^Spawn_File_Actions, fd: i32) -> i32 ---
}

// Runs args[0], captures its stdout to EOF, waits, and returns the text and the exit code. A pipe is set as the
// child's fd 1 through posix_spawn file actions.
@(private)
run_capture :: proc(args: []string) -> (out: string, code: int) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return "", 1 }
	read_fd, write_fd := fds[0], fds[1]
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	fa: Spawn_File_Actions
	posix_spawn_file_actions_init(&fa)
	posix_spawn_file_actions_adddup2(&fa, i32(write_fd), i32(posix.STDOUT_FILENO))
	posix_spawn_file_actions_addclose(&fa, i32(read_fd))
	child: posix.pid_t
	rc := posix.posix_spawnp(&child, argv[0], &fa, nil, raw_data(argv), posix.environ)
	posix_spawn_file_actions_destroy(&fa)
	posix.close(write_fd)
	if rc != .NONE { posix.close(read_fd); return "", 1 }
	// read the child's stdout
	buf: [4096]u8
	b := make([dynamic]u8, context.temp_allocator)
	for {
		n := posix.read(read_fd, &buf[0], len(buf))
		if n <= 0 { break }
		append(&b, ..buf[:n])
	}
	posix.close(read_fd)
	st: i32
	posix.waitpid(child, &st, {})
	code = int((st >> 8) & 0xff)
	out = string(b[:])
	return
}
