package tk_toolbox

// Checks of a program's sources that the compiler does not make.

import "core:fmt"
import "core:os"
import "core:strings"

// The toolkit's ui package, beside this one: where its scopes are read.
UI_DIR_DEFAULT :: #directory + "/../ui"

// A use of a scope that ends it at once: the file's line and the scope.
Scope_Misuse :: struct {
	line:  int,
	scope: string,
}

// The scopes of the ui package: the procedures with a deferred end (@(deferred_none = pop_parent) row :: proc ...), read
// from its sources' texts. A scope ends with the statement that opens it.
ui_scopes :: proc(sources: []string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for source in sources {
		text := source
		deferred := false
		for line in strings.split_lines_iterator(&text) {
			l := strings.trim_space(line)
			if strings.has_prefix(l, "@(deferred_") { deferred = true; continue }
			if !deferred || l == "" || strings.has_prefix(l, "@") || strings.has_prefix(l, "//") { continue }
			deferred = false
			if i := strings.index(l, " :: proc"); i > 0 { append(&out, l[:i]) }
		}
	}
	return out[:]
}

// The lines of `text` where a scope is opened under a negation: `if !ui.row(...) { return }` closes the row at once, and
// what follows goes to the parent's parent. The compiler accepts it.
scope_misuses :: proc(text: string, scopes: []string, allocator := context.temp_allocator) -> []Scope_Misuse {
	out := make([dynamic]Scope_Misuse, allocator)
	rest := text
	n := 0
	for line in strings.split_lines_iterator(&rest) {
		n += 1
		code := line
		if c := strings.index(code, "//"); c >= 0 { code = code[:c] }   // (a comment that cites the misuse is no misuse)
		at := strings.index(code, "if !ui.")
		if at < 0 { continue }
		call := code[at + len("if !ui."):]
		for sc in scopes {
			if strings.has_prefix(call, sc) && len(call) > len(sc) && call[len(sc)] == '(' { append(&out, Scope_Misuse{n, sc}) }
		}
	}
	return out[:]
}

// Every .odin file under `src_dir` checked for a scope of the ui package (read in `ui_dir`) opened under a negation; each
// one said. True when there is none.
check_scopes :: proc(src_dir: string, ui_dir := UI_DIR_DEFAULT) -> bool {
	ui_files := odin_files(ui_dir)
	if len(ui_files) == 0 { fmt.eprintfln("check_scopes: no source of the ui package in %s", ui_dir); return false }
	sources := make([dynamic]string, context.temp_allocator)
	for f in ui_files {
		if data, err := os.read_entire_file(f, context.temp_allocator); err == nil { append(&sources, string(data)) }
	}
	scopes := ui_scopes(sources[:])
	ok := true
	for f in odin_files(src_dir) {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil { fmt.eprintfln("%s cannot be read", f); ok = false; continue }
		for m in scope_misuses(string(data), scopes) {
			fmt.eprintfln("%s:%d: `if !ui.%s(...)` ends the scope at once: build inside `if ui.%s(...)` and its block", f, m.line, m.scope, m.scope)
			ok = false
		}
	}
	return ok
}

// The .odin files under `dir`, its folders' too.
@(private = "file")
odin_files :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	w := os.walker_create_path(dir)
	defer os.walker_destroy(&w)
	for fi in os.walker_walk(&w) {
		if fi.type != .Directory && strings.has_suffix(fi.name, ".odin") { append(&out, strings.clone(fi.fullpath, context.temp_allocator)) }
	}
	return out[:]
}
