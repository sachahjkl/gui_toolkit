package tk_process

// Command lines and command names, as pure procedures that every system compiles and tests (process-trees.md):
//
//	resolve_command       a bare name found in the folders of PATH (Windows: with PATHEXT), never in the current folder
//	windows_command_line  CreateProcessW's application and command line for a program or a .bat/.cmd script, with
//	                      Rust's BatBadBut rules (CVE-2024-24576) for a script
//	is_script             whether a path names a .bat or .cmd script

import "core:strings"
import "core:unicode/utf8"
import "../ascii"

// PATHEXT when the environment has none.
PATHEXT_DEFAULT :: ".COM;.EXE;.BAT;.CMD"

// Why a command line cannot be made.
Command_Line_Error :: enum u8 {
	None,
	Nul,             // an argument or the program holds a NUL: the system's strings end there
	Program_Quote,   // the program's name holds a '"': no file name has one, and it cannot be quoted
	Script_Name,     // a script's path holds '"', '^' or '%', or ends with '\': cmd.exe would read it
	Line_Break,      // a script's argument holds '\r' or '\n': cmd.exe ends the command there
}

// What CreateProcessW is given.
Command_Line :: struct {
	application: string,   // the file that runs: the program, or cmd.exe for a script
	line:        string,   // the whole command line, the program's own name first
}

// A file name or path that ends with .bat or .cmd (any case). Trailing dots and spaces do not count: Windows drops them
// from a file name, so "run.bat. " runs run.bat.
is_script :: proc(path: string) -> bool {
	p := strings.trim_right(path, ". ")
	if len(p) < 4 { return false }
	ext := p[len(p) - 4:]
	return ascii.equal_fold(ext, ".bat") || ascii.equal_fold(ext, ".cmd")
}

// The application and the command line that run `args` (args[0] the program's name as the caller wrote it) through
// the file `resolved` (args[0] found by resolve_command). A script runs through `<system_dir>\cmd.exe`. In `allocator`.
windows_command_line :: proc(resolved: string, args: []string, system_dir: string, allocator := context.allocator) -> (c: Command_Line, err: Command_Line_Error) {
	if len(args) == 0 { return {}, .None }
	for a in args { if strings.index_byte(a, 0) >= 0 { return {}, .Nul } }
	if strings.index_byte(resolved, 0) >= 0 { return {}, .Nul }
	b := strings.builder_make(allocator)
	if is_script(resolved) {
		if strings.index_any(resolved, "\"^%") >= 0 || strings.has_suffix(resolved, "\\") { return {}, .Script_Name }
		for a in args[1:] { if strings.index_any(a, "\r\n") >= 0 { return {}, .Line_Break } }
		strings.write_string(&b, `cmd.exe /e:ON /v:OFF /d /c ""`)
		strings.write_string(&b, resolved)
		strings.write_byte(&b, '"')
		for a in args[1:] {
			strings.write_byte(&b, ' ')
			append_script_arg(&b, a)
		}
		strings.write_byte(&b, '"')
		cmd := strings.concatenate({strings.trim_right(system_dir, "\\/"), "\\cmd.exe"}, allocator)
		return {application = cmd, line = strings.to_string(b)}, .None
	}
	if strings.index_byte(args[0], '"') >= 0 { return {}, .Program_Quote }
	strings.write_byte(&b, '"')
	strings.write_string(&b, args[0])
	strings.write_byte(&b, '"')
	for a in args[1:] {
		strings.write_byte(&b, ' ')
		append_program_arg(&b, a)
	}
	return {application = strings.clone(resolved, allocator), line = strings.to_string(b)}, .None
}

// An argument as the C runtime reads it back (CommandLineToArgvW): quoted when empty or when it holds a space or a
// tab; n backslashes before a '"' become 2n + 1, and 2n before the closing quote.
@(private = "file")
append_program_arg :: proc(b: ^strings.Builder, arg: string) {
	quote := len(arg) == 0 || strings.index_any(arg, " \t") >= 0
	if quote { strings.write_byte(b, '"') }
	backslashes := 0
	for i in 0 ..< len(arg) {
		c := arg[i]
		if c == '\\' {
			backslashes += 1
		} else {
			if c == '"' { for _ in 0 ..= backslashes { strings.write_byte(b, '\\') } }
			backslashes = 0
		}
		strings.write_byte(b, c)
	}
	if quote {
		for _ in 0 ..< backslashes { strings.write_byte(b, '\\') }
		strings.write_byte(b, '"')
	}
}

// An argument of a script, as Rust's append_bat_arg writes it: quoted when empty, when it ends with '\', or when it
// holds an ASCII character other than letters, digits and #$*+-./:?@\_ or a control character; '"' doubled (the
// backslashes before it doubled), '%' as %%cd:~,% so that cmd.exe expands no variable.
@(private = "file")
append_script_arg :: proc(b: ^strings.Builder, arg: string) {
	UNQUOTED :: "#$*+-./:?@\\_"
	quote := len(arg) == 0 || arg[len(arg) - 1] == '\\'
	for r in arg {
		if r < 0x80 {
			c := u8(r)
			alnum := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
			if !alnum && strings.index_byte(UNQUOTED, c) < 0 { quote = true }
		} else if r <= 0x9F || r == utf8.RUNE_ERROR {
			// (C1 controls; a byte that is no UTF-8 is quoted too: what cmd.exe makes of it is not known)
			quote = true
		}
	}
	if quote { strings.write_byte(b, '"') }
	backslashes := 0
	for i in 0 ..< len(arg) {
		c := arg[i]
		if c == '\\' {
			backslashes += 1
		} else {
			if c == '"' {
				for _ in 0 ..< backslashes { strings.write_byte(b, '\\') }
				strings.write_byte(b, '"')
			} else if c == '%' || c == '\r' {
				strings.write_string(b, "%%cd:~,")
			}
			backslashes = 0
		}
		strings.write_byte(b, c)
	}
	if quote {
		for _ in 0 ..< backslashes { strings.write_byte(b, '\\') }
		strings.write_byte(b, '"')
	}
}

// Whether a file is there to run (resolve_command's question to the system).
File_Exists :: #type proc(path: string, user: rawptr) -> bool

// The file that runs the command `name`. A name with a folder in it (a '/', on Windows also '\\' or a drive) is
// given back as it is. A bare name is looked for in each folder of `path_env` (PATH's value) that is absolute: an
// empty or a relative entry names the current folder, and is skipped. On Windows (`windows`), each extension of
// `pathext` (PATHEXT's value; PATHEXT_DEFAULT when "") is added in turn, after the name as it is when it already ends
// with one of them. In `allocator`; ok false: not found.
resolve_command :: proc(name: string, path_env: string, pathext: string, windows: bool, exists: File_Exists, user: rawptr = nil, allocator := context.allocator) -> (found: string, ok: bool) {
	if name == "" || strings.index_byte(name, 0) >= 0 { return }
	if has_folder(name, windows) { return strings.clone(name, allocator), true }
	list_sep: u8 = windows ? ';' : ':'
	exts := pathext != "" ? pathext : PATHEXT_DEFAULT
	listed := false
	if windows {
		rest := exts
		for e in strings.split_by_byte_iterator(&rest, ';') {
			if e != "" && len(name) > len(e) && ascii.equal_fold(name[len(name) - len(e):], e) { listed = true }
		}
	}
	rest := path_env
	for dir in strings.split_by_byte_iterator(&rest, list_sep) {
		d := windows ? strings.trim(dir, "\"") : dir
		if !is_absolute(d, windows) { continue }
		sep := windows ? "\\" : "/"
		if strings.has_suffix(d, "/") || (windows && strings.has_suffix(d, "\\")) { sep = "" }
		if !windows || listed {
			p := strings.concatenate({d, sep, name}, allocator)
			if exists(p, user) { return p, true }
			delete(p, allocator)
			if !windows { continue }
		}
		er := exts
		for e in strings.split_by_byte_iterator(&er, ';') {
			if e == "" { continue }
			p := strings.concatenate({d, sep, name, e}, allocator)
			if exists(p, user) { return p, true }
			delete(p, allocator)
		}
	}
	return
}

@(private = "file")
has_folder :: proc(name: string, windows: bool) -> bool {
	if strings.index_byte(name, '/') >= 0 { return true }
	if !windows { return false }
	return strings.index_byte(name, '\\') >= 0 || (len(name) >= 2 && name[1] == ':')
}

@(private = "file")
is_absolute :: proc(dir: string, windows: bool) -> bool {
	if !windows { return strings.has_prefix(dir, "/") }
	if strings.has_prefix(dir, `\\`) || strings.has_prefix(dir, "//") { return true }
	return len(dir) >= 3 && dir[1] == ':' && (dir[2] == '\\' || dir[2] == '/') && ((dir[0] >= 'a' && dir[0] <= 'z') || (dir[0] >= 'A' && dir[0] <= 'Z'))
}
